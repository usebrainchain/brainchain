// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {Erc8183AppealHook} from "../src/evaluators/Erc8183AppealHook.sol";
import {Erc8183Evaluator} from "../src/evaluators/Erc8183Evaluator.sol";
import {ERC8183} from "./erc8183/ERC8183.sol";
import {MockERC20} from "./MockERC20.sol";

/// Drives jobs through every path, with brain key rotations and revocations,
/// detached hooks and a paused job contract, and works out from the decisions
/// it signs and the standard's rules alone where each job's money should end up.
contract Erc8183Handler is Test {
    uint256 internal constant BOND = 50e6;
    uint32 internal constant WINDOW = 1 days;
    uint32 internal constant RULING = 2 days;
    uint16 internal constant BAR = 6_000;
    uint256 internal constant PLATFORM_FEE_BPS = 100;
    uint256 internal constant EVALUATOR_FEE_BPS = 50;

    ERC8183 public immutable acp;
    Erc8183Evaluator public immutable evaluator;
    Erc8183AppealHook public immutable hook;
    MockERC20 public immutable usdc;
    address public immutable client = makeAddr("inv-client");
    address public immutable provider = makeAddr("inv-provider");
    address public immutable decisionLog = makeAddr("inv-log");
    address public immutable admin;
    address public immutable safe;

    struct Ghost {
        uint256 budget;
        IERC8183.JobStatus status;
        bool decided;
        bool completes;
        uint256 decidedAt;
        address appellant;
        uint256 appealedAt;
        bool bondHeld;
        bool detached;
        /// The key that signed the first decision.
        uint256 signer;
    }

    uint256[] public ids;
    mapping(uint256 => Ghost) public ghosts;
    uint256 internal nextDecisionId = 1;

    /// The key the evaluator should accept, or zero while revoked.
    uint256 public brainKey = 0xB4A1;
    /// The key that last held the seat: it keeps signing after a revoke, as a leaked key would.
    uint256 public lastKey = 0xB4A1;
    uint256 public pendingKey;
    uint256 public pendingReadyAt;
    bool public paused;

    uint256 public clientIn;
    uint256 public clientOut;
    uint256 public providerIn;
    uint256 public providerOut;
    uint256 public treasuryIn;
    uint256 public evaluatorIn;
    uint256 public escrowed;
    uint256 public bondsHeld;
    /// Calls that went through when the rules say they must not.
    uint256 public breaches;
    uint256 public settlements;
    uint256 public appeals;

    constructor(
        ERC8183 acp_,
        Erc8183Evaluator evaluator_,
        Erc8183AppealHook hook_,
        MockERC20 usdc_,
        address admin_,
        address safe_
    ) {
        acp = acp_;
        evaluator = evaluator_;
        hook = hook_;
        usdc = usdc_;
        admin = admin_;
        safe = safe_;
        address[2] memory parties = [client, provider];
        for (uint256 i; i < 2; ++i) {
            usdc.mint(parties[i], type(uint128).max);
            vm.startPrank(parties[i]);
            usdc.approve(address(acp), type(uint256).max);
            usdc.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function open(uint256 budget, uint256 duration) external {
        if (paused) return;
        budget = bound(budget, 1, 1_000_000e6);
        duration = bound(duration, WINDOW + RULING, 20 days);
        vm.prank(client);
        uint256 id =
            acp.createJob(provider, address(evaluator), uint48(block.timestamp + duration), "brief", address(hook), 0);
        vm.prank(provider);
        acp.setBudget(id, address(usdc), budget, "");
        vm.prank(client);
        acp.fund(id, address(usdc), budget, abi.encode(BOND, WINDOW, RULING));
        vm.prank(provider);
        acp.submit(id, keccak256(abi.encode(id)), "");

        ids.push(id);
        ghosts[id].budget = budget;
        ghosts[id].status = IERC8183.JobStatus.Submitted;
        clientOut += budget;
        escrowed += budget;
    }

    function decide(uint256 seed, bool accept, uint16 confidenceBps) external {
        (uint256 id, bool found) = _find(seed, _undecided);
        if (!found) return;
        confidenceBps = uint16(bound(confidenceBps, 0, 10_000));
        Erc8183Evaluator.Decision memory d = _decision(id, false, accept, confidenceBps);
        bytes memory signature = _sign(_signingKey(), d);
        try evaluator.decide(d, signature) {
            Ghost storage g = ghosts[id];
            if (brainKey == 0 || g.detached || block.timestamp + WINDOW + RULING > acp.getJob(id).expiredAt) {
                breaches++;
            }
            g.decided = true;
            g.signer = brainKey;
            g.completes = accept && confidenceBps >= BAR;
            g.decidedAt = block.timestamp;
        } catch {}
    }

    function appeal(uint256 seed, bool wrongSide) external {
        (uint256 id, bool found) = _find(seed, _appealable);
        if (!found) return;
        Ghost storage g = ghosts[id];
        address losing = g.completes ? client : provider;
        address caller = wrongSide ? (losing == client ? provider : client) : losing;
        vm.prank(caller);
        try hook.appeal(id) {
            if (wrongSide || g.detached || block.timestamp > g.decidedAt + WINDOW) breaches++;
            g.appellant = caller;
            g.appealedAt = block.timestamp;
            g.bondHeld = true;
            bondsHeld += BOND;
            if (caller == client) clientOut += BOND;
            else providerOut += BOND;
            appeals++;
        } catch {}
    }

    function rule(uint256 seed, bool accept, uint16 confidenceBps) external {
        (uint256 id, bool found) = _find(seed, _appealed);
        if (!found) return;
        confidenceBps = uint16(bound(confidenceBps, 0, 10_000));
        Erc8183Evaluator.Decision memory d = _decision(id, true, accept, confidenceBps);
        bytes memory signature = _sign(_signingKey(), d);
        try evaluator.decide(d, signature) {
            Ghost storage g = ghosts[id];
            if (brainKey == 0 || g.detached || paused || block.timestamp > g.appealedAt + RULING) breaches++;
            bool confident = confidenceBps >= BAR;
            bool keep = confident && accept == g.completes;
            _settle(id, confident ? accept : g.completes);
            _payBond(id, keep ? (g.appellant == client ? provider : client) : g.appellant);
        } catch {}
    }

    function finalize(uint256 seed) external {
        (uint256 id, bool found) = _find(seed, _decidedOpen);
        if (!found) return;
        Ghost storage g = ghosts[id];
        try evaluator.finalize(address(acp), id) {
            bool appealed_ = g.appellant != address(0);
            bool early = appealed_ ? block.timestamp <= g.appealedAt + RULING : block.timestamp <= g.decidedAt + WINDOW;
            // A detached hook holds nothing, and its bond waits for releaseBond.
            if (paused || g.signer != brainKey || (early && !g.detached)) breaches++;
            _settle(id, g.completes);
            if (appealed_ && !g.detached) _payBond(id, g.appellant);
        } catch {}
    }

    function claimRefund(uint256 seed) external {
        (uint256 id, bool found) = _find(seed, _open);
        if (!found) return;
        try acp.claimRefund(id) {
            if (paused || block.timestamp < acp.getJob(id).expiredAt + acp.EVALUATION_GRACE_PERIOD()) breaches++;
            ghosts[id].status = IERC8183.JobStatus.Expired;
            escrowed -= ghosts[id].budget;
            clientIn += ghosts[id].budget;
        } catch {}
    }

    function releaseBond(uint256 seed) external {
        (uint256 id, bool found) = _find(seed, _bondPending);
        if (!found) return;
        try hook.releaseBond(id) {
            if (ghosts[id].status != IERC8183.JobStatus.Expired && !ghosts[id].detached) breaches++;
            _payBond(id, ghosts[id].appellant);
        } catch {}
    }

    /// A decision signed by any key but the current one, including a revoked or rotated-out key.
    function forge(uint256 seed, uint256 key, bool useLastKey, bool appeal_, bool accept) external {
        (uint256 id, bool found) = _find(seed, _open);
        if (!found) return;
        key = useLastKey ? lastKey : bound(key, 1, 1e18);
        if (key == brainKey) return;
        Erc8183Evaluator.Decision memory d = _decision(id, appeal_, accept, 10_000);
        bytes memory signature = _sign(key, d);
        try evaluator.decide(d, signature) {
            breaches++;
        } catch {}
    }

    /// A brain-signed decision moved onto another job, or naming another deliverable.
    function misapply(uint256 seed, uint256 otherSeed, bool appeal_, bool accept) external {
        (uint256 id, bool found) = _find(seed, _open);
        if (!found) return;
        uint256 other = ids[otherSeed % ids.length];
        Erc8183Evaluator.Decision memory d = _decision(other, appeal_, accept, 10_000);
        if (other == id) d.deliverable = keccak256("not delivered");
        bytes memory signature = _sign(_signingKey(), d);
        d.jobId = id;
        try evaluator.decide(d, signature) {
            breaches++;
        } catch {}
    }

    function rotate(uint256 key) external {
        if (pendingKey != 0) return;
        key = bound(key, 1, 1e18);
        if (key == lastKey) return;
        vm.prank(safe);
        evaluator.proposeBrain(vm.addr(key));
        pendingKey = key;
        pendingReadyAt = block.timestamp + evaluator.delay();
    }

    function acceptRotation() external {
        if (pendingKey == 0) return;
        try evaluator.acceptBrain() {
            if (block.timestamp < pendingReadyAt) breaches++;
            brainKey = pendingKey;
            lastKey = pendingKey;
            pendingKey = 0;
        } catch {}
    }

    /// Revokes on one call in eight, so runs also spend time with a working key.
    function revoke(uint256 seed) external {
        if (seed % 8 != 0) return;
        vm.prank(safe);
        evaluator.revokeBrain();
        brainKey = 0;
    }

    function detach(uint256 seed) external {
        if (seed % 4 != 0) return;
        (uint256 id, bool found) = _find(seed / 4, _attached);
        if (!found) return;
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        vm.prank(admin);
        acp.batchDetachHook(one);
        ghosts[id].detached = true;
    }

    /// Pauses on one call in four and unpauses otherwise.
    function setPaused(uint256 seed) external {
        bool paused_ = seed % 4 == 0;
        vm.prank(admin);
        if (paused_) acp.pause();
        else acp.unpause();
        paused = paused_;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 3 days));
    }

    function _settle(uint256 id, bool completes) private {
        Ghost storage g = ghosts[id];
        uint256 budget = g.budget;
        escrowed -= budget;
        settlements++;
        if (!completes) {
            g.status = IERC8183.JobStatus.Rejected;
            clientIn += budget;
            return;
        }
        g.status = IERC8183.JobStatus.Completed;
        uint256 platformFee = (budget * PLATFORM_FEE_BPS) / 10_000;
        uint256 evaluatorFee = (budget * EVALUATOR_FEE_BPS) / 10_000;
        treasuryIn += platformFee;
        evaluatorIn += evaluatorFee;
        providerIn += budget - platformFee - evaluatorFee;
    }

    function _signingKey() private view returns (uint256) {
        return brainKey != 0 ? brainKey : lastKey;
    }

    function _payBond(uint256 id, address to) private {
        ghosts[id].bondHeld = false;
        bondsHeld -= BOND;
        if (to == client) clientIn += BOND;
        else providerIn += BOND;
    }

    function _decision(uint256 id, bool appeal_, bool accept, uint16 confidenceBps)
        private
        returns (Erc8183Evaluator.Decision memory)
    {
        return Erc8183Evaluator.Decision({
            jobContract: address(acp),
            jobId: id,
            deliverable: keccak256(abi.encode(id)),
            appeal: appeal_,
            accept: accept,
            confidenceBps: confidenceBps,
            logChainId: 274663,
            decisionLog: decisionLog,
            decisionId: nextDecisionId++
        });
    }

    function _sign(uint256 key, Erc8183Evaluator.Decision memory d) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, evaluator.hashDecision(d));
        return abi.encodePacked(r, s, v);
    }

    function _find(uint256 seed, function(uint256) view returns (bool) matches) private view returns (uint256, bool) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[(seed % n + i) % n];
            if (matches(id)) return (id, true);
        }
        return (0, false);
    }

    function _open(uint256 id) private view returns (bool) {
        return ghosts[id].status == IERC8183.JobStatus.Submitted;
    }

    function _undecided(uint256 id) private view returns (bool) {
        return _open(id) && !ghosts[id].decided;
    }

    function _decidedOpen(uint256 id) private view returns (bool) {
        return _open(id) && ghosts[id].decided;
    }

    function _appealable(uint256 id) private view returns (bool) {
        return _decidedOpen(id) && ghosts[id].appellant == address(0);
    }

    function _appealed(uint256 id) private view returns (bool) {
        return _open(id) && ghosts[id].appellant != address(0);
    }

    function _attached(uint256 id) private view returns (bool) {
        return _open(id) && !ghosts[id].detached;
    }

    function _bondPending(uint256 id) private view returns (bool) {
        return ghosts[id].bondHeld;
    }
}

contract Erc8183InvariantsTest is StdInvariant, Test {
    MockERC20 internal usdc;
    ERC8183 internal acp;
    Erc8183Evaluator internal evaluator;
    Erc8183AppealHook internal hook;
    Erc8183Handler internal handler;
    address internal treasury = makeAddr("inv-treasury");
    uint256 internal clientStart;
    uint256 internal providerStart;

    function setUp() public {
        address safe = makeAddr("inv-safe");
        address admin = makeAddr("inv-admin");
        usdc = new MockERC20();
        acp = new ERC8183(treasury, admin);
        evaluator = new Erc8183Evaluator(safe, vm.addr(0xB4A1), 2 days, 6_000);
        hook = new Erc8183AppealHook(acp, address(evaluator), safe, 1 days, 2 days);
        vm.startPrank(safe);
        hook.setBond(address(usdc), 50e6);
        evaluator.proposeHook(address(hook));
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        evaluator.acceptHook(address(hook));
        vm.startPrank(admin);
        acp.setHookWhitelist(address(hook), true);
        acp.setPaymentTokenAllowed(address(usdc), true);
        acp.setPlatformFee(100, treasury);
        acp.setEvaluatorFee(50);
        vm.stopPrank();

        handler = new Erc8183Handler(acp, evaluator, hook, usdc, admin, safe);
        clientStart = usdc.balanceOf(handler.client());
        providerStart = usdc.balanceOf(handler.provider());
        targetContract(address(handler));
    }

    function invariant_escrowHoldsExactlyTheOpenBudgets() public view {
        assertEq(usdc.balanceOf(address(acp)), handler.escrowed());
    }

    function invariant_theHookHoldsExactlyThePendingBonds() public view {
        assertEq(usdc.balanceOf(address(hook)), handler.bondsHeld());
    }

    function invariant_everyPartyHoldsWhatTheDecisionsGaveIt() public view {
        assertEq(usdc.balanceOf(handler.client()), clientStart + handler.clientIn() - handler.clientOut());
        assertEq(usdc.balanceOf(handler.provider()), providerStart + handler.providerIn() - handler.providerOut());
        assertEq(usdc.balanceOf(treasury), handler.treasuryIn());
        assertEq(usdc.balanceOf(address(evaluator)), handler.evaluatorIn());
    }

    function invariant_everyJobEndsAsItsDecisionsSay() public view {
        uint256 n = handler.idsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (, IERC8183.JobStatus expected,,,,,,,,) = handler.ghosts(id);
            assertEq(uint8(acp.getJob(id).status), uint8(expected));
        }
    }

    function invariant_theBrainIsTheKeyTheOwnerNamed() public view {
        uint256 key = handler.brainKey();
        assertEq(evaluator.brain(), key == 0 ? address(0) : vm.addr(key));
        uint256 pending = handler.pendingKey();
        assertEq(evaluator.pendingBrain(), pending == 0 ? address(0) : vm.addr(pending));
    }

    function invariant_nothingWentThroughThatTheRulesForbid() public view {
        assertEq(handler.breaches(), 0);
    }
}
