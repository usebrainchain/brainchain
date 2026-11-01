// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {MockERC20} from "./MockERC20.sol";

/// Three proposers bond on a few executor calls; the brain records Change
/// decisions on them, sometimes enacting one through the executor (which moves
/// the change threshold under open proposals); anyone settles with the latest,
/// an earlier or an unrelated decision, or expires; the admin reprices the bond
/// and the decision window.
contract ProposalBondHandler is Test {
    bytes32 internal constant YES = bytes32(uint256(1));

    ProposalBonds public immutable bonds;
    DecisionExecutor public immutable executor;
    DecisionLog public immutable decisionLog;
    MockERC20 public immutable token;
    address public immutable admin;
    address public immutable recipient;
    address[3] public proposers;

    uint256 public pulledSum;
    uint256 public openSum;
    uint256 public returnedSum;
    uint256 public burnedSum;
    uint256 public badHold;
    uint256 public offPath;
    uint256 public closedTwice;
    uint256 public decisionReused;

    mapping(uint256 => uint256) public pulled;
    mapping(uint256 => uint256) public closes;
    mapping(uint256 => bool) internal _settledWith;
    mapping(bytes32 => uint256[]) internal _decisionsAbout;

    constructor(
        ProposalBonds bonds_,
        DecisionExecutor executor_,
        DecisionLog decisionLog_,
        MockERC20 token_,
        address admin_,
        address[3] memory proposers_
    ) {
        bonds = bonds_;
        executor = executor_;
        decisionLog = decisionLog_;
        token = token_;
        admin = admin_;
        proposers = proposers_;
        recipient = makeAddr("recipient");
    }

    function _call(uint256 seed) internal view returns (address, bytes memory) {
        uint256 k = uint256(keccak256(abi.encode(seed))) % 4;
        if (k == 3) return (address(executor), abi.encodeCall(DecisionExecutor.transfer, (recipient, 1e6)));
        uint16[3] memory thresholds = [uint16(5_000), 9_000, 6_000];
        uint64[3] memory locks = [uint64(1 hours), 1 hours, 48 hours];
        return
            (address(executor), abi.encodeCall(DecisionExecutor.setParameters, (thresholds[k], locks[k], 5, 2e6, 10e6)));
    }

    function _record(address target, bytes memory data, DecisionLog.Kind kind, bool yes, uint16 confidence)
        internal
        returns (uint256 id)
    {
        bytes32 subject = executor.changeSubject(target, data);
        vm.prank(decisionLog.brain());
        id = decisionLog.record(kind, subject, 0, yes ? YES : bytes32(0), confidence, 0, "");
        _decisionsAbout[subject].push(id);
    }

    function _proposal(uint256 seed) internal view returns (uint256 id, ProposalBonds.Proposal memory p) {
        id = bound(seed, 1, bonds.count());
        p = bonds.get(id);
    }

    function _closed(uint256 id, uint256 amount, bool burned) internal {
        if (++closes[id] > 1) closedTwice++;
        openSum -= amount;
        if (burned) burnedSum += amount;
        else returnedSum += amount;
    }

    function propose(uint256 who, uint256 callSeed) external {
        (address target, bytes memory data) = _call(callSeed);
        address proposer = proposers[who % 3];
        uint128 bond = bonds.bond();
        uint256 before = token.balanceOf(proposer);
        vm.prank(proposer);
        uint256 id = bonds.propose(target, data, "");
        uint256 amount = before - token.balanceOf(proposer);
        ProposalBonds.Proposal memory p = bonds.get(id);
        if (amount != bond || p.bond != bond || p.proposer != proposer || p.state != ProposalBonds.State.Open) {
            badHold++;
        }
        pulled[id] = amount;
        pulledSum += amount;
        openSum += amount;
    }

    function decide(uint256 callSeed, bool yes, uint16 confidence, bool otherKind) external {
        (address target, bytes memory data) = _call(callSeed);
        DecisionLog.Kind kind = otherKind ? DecisionLog.Kind.Ruling : DecisionLog.Kind.Change;
        _record(target, data, kind, yes, uint16(bound(confidence, 0, 10_000)));
    }

    /// Jev adopts a call outright and it runs, which can move the change threshold.
    function enact(uint256 callSeed) external {
        (address target, bytes memory data) = _call(callSeed);
        uint256 d = _record(target, data, DecisionLog.Kind.Change, true, 10_000);
        vm.prank(decisionLog.brain());
        try executor.queue(d, target, data) returns (uint256 changeId) {
            vm.warp(block.timestamp + executor.timelock());
            try executor.execute(changeId) {} catch {}
        } catch {}
    }

    /// Settles with the latest Change decision on the proposal, any earlier decision on it, or any decision at all.
    function settle(uint256 seed, uint256 decisionSeed, uint8 pick) external {
        if (bonds.count() == 0) return;
        (uint256 id, ProposalBonds.Proposal memory p) = _proposal(seed);
        uint256[] storage history = _decisionsAbout[p.subject];
        uint256 decisionId;
        if (pick % 3 == 0) decisionId = decisionLog.latestOf(p.subject, DecisionLog.Kind.Change);
        else if (pick % 3 == 1 && history.length > 0) decisionId = history[decisionSeed % history.length];
        else decisionId = bound(decisionSeed, 0, decisionLog.count() + 1);

        uint16 threshold = executor.changeThresholdBps();
        uint256 proposerBefore = token.balanceOf(p.proposer);
        uint256 burnBefore = token.balanceOf(bonds.BURN());
        try bonds.settle(id, decisionId) {
            if (_settledWith[decisionId]) decisionReused++;
            _settledWith[decisionId] = true;
            bool adopted = _checkDecision(p, decisionId, threshold);
            ProposalBonds.State state = bonds.get(id).state;
            if (adopted) {
                if (state != ProposalBonds.State.Returned || token.balanceOf(p.proposer) - proposerBefore != p.bond) {
                    offPath++;
                }
            } else if (state != ProposalBonds.State.Burned || token.balanceOf(bonds.BURN()) - burnBefore != p.bond) {
                offPath++;
            }
            _closed(id, p.bond, !adopted);
        } catch {}
    }

    /// Counts a settlement on anything but Jev's latest Change decision on the
    /// call, recorded after the proposal; returns whether it adopted the call.
    function _checkDecision(ProposalBonds.Proposal memory p, uint256 decisionId, uint16 threshold)
        internal
        returns (bool)
    {
        DecisionLog.Decision memory d = decisionLog.get(decisionId);
        if (
            d.kind != DecisionLog.Kind.Change || d.subject != p.subject || d.recordedAt < p.createdAt
                || decisionLog.latestOf(p.subject, DecisionLog.Kind.Change) != decisionId
        ) offPath++;
        return d.answer == YES && d.confidenceBps >= threshold;
    }

    function expire(uint256 seed) external {
        if (bonds.count() == 0) return;
        (uint256 id, ProposalBonds.Proposal memory p) = _proposal(seed);
        uint256 window = bonds.decideWithin();
        uint256 before = token.balanceOf(p.proposer);
        try bonds.expire(id) {
            if (
                block.timestamp <= uint256(p.createdAt) + window || bonds.get(id).state != ProposalBonds.State.Returned
                    || token.balanceOf(p.proposer) - before != p.bond
            ) offPath++;
            _closed(id, p.bond, false);
        } catch {}
    }

    function setConfig(uint128 bond, uint64 window) external {
        vm.prank(admin);
        bonds.setConfig(uint128(bound(bond, 1, 1_000_000e18)), uint64(bound(window, 1, 14 days)));
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
    }
}

contract ProposalBondInvariants is StdInvariant, Test {
    uint256 internal constant MINTED = 1e30;

    ProposalBondHandler internal h;
    ProposalBonds internal bonds;
    MockERC20 internal token;
    address[3] internal proposers = [makeAddr("proposer-0"), makeAddr("proposer-1"), makeAddr("proposer-2")];

    function setUp() public {
        address admin = makeAddr("admin");
        MockERC20 usdg = new MockERC20();
        token = new MockERC20();
        DecisionLog decisionLog = new DecisionLog(admin, makeAddr("brain"));
        DecisionExecutor executor = new DecisionExecutor(
            decisionLog, IERC20(address(usdg)), makeAddr("guardian"), 6_000, 48 hours, 5, 2e6, 10e6
        );
        usdg.mint(address(executor), 1e12);
        bonds = new ProposalBonds(
            IERC20(address(token)), decisionLog, IDecisionExecutor(address(executor)), admin, 250_000e18, 7 days
        );
        for (uint256 i; i < 3; i++) {
            token.mint(proposers[i], MINTED);
            vm.prank(proposers[i]);
            token.approve(address(bonds), type(uint256).max);
        }
        h = new ProposalBondHandler(bonds, executor, decisionLog, token, admin, proposers);
        targetContract(address(h));
    }

    function invariant_holdsExactlyTheOpenBonds() public view {
        uint256 open;
        for (uint256 id = 1; id <= bonds.count(); id++) {
            ProposalBonds.Proposal memory p = bonds.get(id);
            if (p.state == ProposalBonds.State.Open) open += p.bond;
        }
        assertEq(token.balanceOf(address(bonds)), open);
        assertEq(open, h.openSum());
    }

    function invariant_eachProposalBondsOnce() public view {
        assertEq(h.badHold(), 0);
        for (uint256 id = 1; id <= bonds.count(); id++) {
            assertEq(bonds.get(id).bond, h.pulled(id));
        }
    }

    function invariant_bondsLeaveOnlyByAdoptionRejectionOrTimeout() public view {
        assertEq(h.offPath(), 0);
        assertEq(token.balanceOf(bonds.BURN()), h.burnedSum());
        uint256 held;
        for (uint256 i; i < 3; i++) {
            held += token.balanceOf(proposers[i]);
        }
        assertEq(held, 3 * MINTED - h.openSum() - h.burnedSum());
    }

    function invariant_aProposalClosesOnceAndADecisionSettlesOne() public view {
        assertEq(h.closedTwice(), 0);
        assertEq(h.decisionReused(), 0);
        for (uint256 id = 1; id <= bonds.count(); id++) {
            assertEq(bonds.get(id).state == ProposalBonds.State.Open, h.closes(id) == 0);
        }
    }
}
