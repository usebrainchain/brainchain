// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IERC8183} from "../src/interfaces/IERC8183.sol";
import {Erc8183AppealHook} from "../src/evaluators/Erc8183AppealHook.sol";
import {Erc8183Evaluator, IBrainKeyCheck} from "../src/evaluators/Erc8183Evaluator.sol";
import {ERC8183} from "./erc8183/ERC8183.sol";
import {MockERC20} from "./MockERC20.sol";

/// Answers every getter the evaluator reads, but no owner allowed it.
contract LookalikeHook {
    address public immutable evaluator;
    address public immutable jobContract;

    constructor(address evaluator_, address jobContract_) {
        evaluator = evaluator_;
        jobContract = jobContract_;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id != 0xffffffff;
    }

    function beforeAction(uint256, bytes4, bytes calldata) external {}

    function afterAction(uint256, bytes4, bytes calldata) external {}

    function deliverableOf(uint256) external pure returns (bytes32) {
        return keccak256("deliverable");
    }

    function onDecision(uint256, bool) external {}
}

contract KeyCheck is IBrainKeyCheck {
    mapping(address => bool) public isAttested;

    function attest(address key) external {
        isAttested[key] = true;
    }
}

abstract contract Erc8183Setup is Test {
    uint256 internal constant BUDGET = 1_000e6;
    uint256 internal constant BOND = 50e6;
    uint256 internal constant PLATFORM_FEE_BPS = 100;
    uint256 internal constant EVALUATOR_FEE_BPS = 50;
    uint32 internal constant WINDOW = 1 days;
    uint32 internal constant RULING = 2 days;
    uint48 internal constant DURATION = 7 days;
    uint256 internal constant BRAIN_DELAY = 2 days;
    uint16 internal constant BAR = 6_000;
    uint256 internal constant LOG_CHAIN = 274663;
    bytes32 internal constant DELIVERABLE = keccak256("deliverable");

    uint256 internal constant BRAIN_KEY = 0xB4A1;
    address internal brain = vm.addr(BRAIN_KEY);
    address internal safe = makeAddr("safe");
    address internal admin = makeAddr("acp-admin");
    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal stranger = makeAddr("stranger");
    address internal decisionLog = makeAddr("decision-log");

    MockERC20 internal usdc;
    ERC8183 internal acp;
    Erc8183Evaluator internal evaluator;
    Erc8183AppealHook internal hook;
    uint256 internal nextDecisionId = 100;

    function setUp() public virtual {
        usdc = new MockERC20();
        acp = new ERC8183(treasury, admin);
        evaluator = new Erc8183Evaluator(safe, brain, BRAIN_DELAY, BAR);
        hook = new Erc8183AppealHook(acp, address(evaluator), safe, WINDOW, RULING);

        vm.startPrank(safe);
        hook.setBond(address(usdc), BOND);
        evaluator.proposeHook(address(hook));
        vm.stopPrank();
        vm.warp(block.timestamp + BRAIN_DELAY);
        evaluator.acceptHook(address(hook));
        vm.startPrank(admin);
        acp.setHookWhitelist(address(hook), true);
        acp.setPaymentTokenAllowed(address(usdc), true);
        acp.setPlatformFee(PLATFORM_FEE_BPS, treasury);
        acp.setEvaluatorFee(EVALUATOR_FEE_BPS);
        vm.stopPrank();

        address[2] memory parties = [client, provider];
        for (uint256 i; i < 2; ++i) {
            usdc.mint(parties[i], 10_000e6);
            vm.startPrank(parties[i]);
            usdc.approve(address(acp), type(uint256).max);
            usdc.approve(address(hook), type(uint256).max);
            vm.stopPrank();
        }
    }

    function createJob(address evaluator_, address hook_) internal returns (uint256 id) {
        vm.prank(client);
        id = acp.createJob(provider, evaluator_, uint48(block.timestamp) + DURATION, "brief", hook_, 0);
    }

    function fundJob(uint256 id) internal {
        vm.prank(provider);
        acp.setBudget(id, address(usdc), BUDGET, "");
        vm.prank(client);
        acp.fund(id, address(usdc), BUDGET, pinned());
    }

    /// The terms a client pins when it funds a job under the hook.
    function pinned() internal pure returns (bytes memory) {
        return abi.encode(BOND, WINDOW, RULING);
    }

    function submitJob(uint256 id) internal {
        vm.prank(provider);
        acp.submit(id, DELIVERABLE, "");
    }

    function submittedJob() internal returns (uint256 id) {
        id = createJob(address(evaluator), address(hook));
        fundJob(id);
        submitJob(id);
    }

    function decision(uint256 id, bool appeal, bool accept, uint16 confidenceBps)
        internal
        returns (Erc8183Evaluator.Decision memory)
    {
        return Erc8183Evaluator.Decision({
            jobContract: address(acp),
            jobId: id,
            deliverable: DELIVERABLE,
            appeal: appeal,
            accept: accept,
            confidenceBps: confidenceBps,
            logChainId: LOG_CHAIN,
            decisionLog: decisionLog,
            decisionId: nextDecisionId++
        });
    }

    function sign(uint256 key, Erc8183Evaluator.Decision memory d) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, evaluator.hashDecision(d));
        return abi.encodePacked(r, s, v);
    }

    /// Signs before arming the revert: signing calls the evaluator, which would consume it.
    function decideReverts(Erc8183Evaluator.Decision memory d, uint256 key, bytes4 err) internal {
        bytes memory signature = sign(key, d);
        vm.expectRevert(err);
        evaluator.decide(d, signature);
    }

    function decideReverts(Erc8183Evaluator.Decision memory d, bytes4 err) internal {
        decideReverts(d, BRAIN_KEY, err);
    }

    function decide(uint256 id, bool accept, uint16 confidenceBps)
        internal
        returns (Erc8183Evaluator.Decision memory d)
    {
        d = decision(id, false, accept, confidenceBps);
        evaluator.decide(d, sign(BRAIN_KEY, d));
    }

    function rule(uint256 id, bool accept, uint16 confidenceBps) internal returns (Erc8183Evaluator.Decision memory d) {
        d = decision(id, true, accept, confidenceBps);
        evaluator.decide(d, sign(BRAIN_KEY, d));
    }

    function status(uint256 id) internal view returns (IERC8183.JobStatus) {
        return acp.getJob(id).status;
    }

    function stage(uint256 id) internal view returns (Erc8183AppealHook.Stage) {
        return hook.holdOf(id).stage;
    }

    function pastWindow(uint256 id) internal {
        vm.warp(uint256(hook.holdOf(id).decidedAt) + WINDOW + 1);
    }

    function net() internal pure returns (uint256) {
        return BUDGET - (BUDGET * PLATFORM_FEE_BPS) / 10_000 - (BUDGET * EVALUATOR_FEE_BPS) / 10_000;
    }
}

contract Erc8183EvaluatorTest is Erc8183Setup {
    function test_aJobCompletesOnceTheWindowClosesUnappealed() public {
        uint256 id = submittedJob();
        assertEq(usdc.balanceOf(address(acp)), BUDGET);

        Erc8183Evaluator.Decision memory d = decide(id, true, 9_000);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Submitted));
        assertEq(uint8(stage(id)), uint8(Erc8183AppealHook.Stage.Decided));
        Erc8183Evaluator.Judgment memory j = evaluator.judgmentOf(address(acp), id);
        assertTrue(j.decided && j.completes);
        assertEq(j.decisionId, d.decisionId);
        assertEq(j.digest, evaluator.hashDecision(d));

        pastWindow(id);
        vm.expectEmit(address(evaluator));
        emit Erc8183Evaluator.Settled(address(acp), id, d.decisionId, true);
        vm.expectEmit(address(acp));
        emit ERC8183.JobCompleted(id, address(evaluator), evaluator.hashDecision(d));
        vm.prank(stranger);
        evaluator.finalize(address(acp), id);

        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        assertEq(uint8(stage(id)), uint8(Erc8183AppealHook.Stage.Settled));
        assertEq(usdc.balanceOf(provider), 10_000e6 + net());
        assertEq(usdc.balanceOf(treasury), (BUDGET * PLATFORM_FEE_BPS) / 10_000);
        assertEq(usdc.balanceOf(address(evaluator)), (BUDGET * EVALUATOR_FEE_BPS) / 10_000);
        assertEq(usdc.balanceOf(address(acp)), 0);
    }

    function test_aRefusedJobRefundsTheClientOnceTheWindowCloses() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decide(id, false, 9_000);
        pastWindow(id);
        vm.expectEmit(address(acp));
        emit ERC8183.JobRejected(id, address(evaluator), evaluator.hashDecision(d));
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(provider), 10_000e6);
        assertEq(usdc.balanceOf(address(evaluator)), 0);
    }

    function test_settlementWaitsForTheWindow() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        vm.expectRevert(Erc8183AppealHook.WindowOpen.selector);
        evaluator.finalize(address(acp), id);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(Erc8183AppealHook.WindowOpen.selector);
        evaluator.finalize(address(acp), id);
        vm.warp(block.timestamp + 1);
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
    }

    function test_anAcceptBelowTheBarRejects() public {
        uint256 id = submittedJob();
        decide(id, true, BAR - 1);
        assertFalse(evaluator.judgmentOf(address(acp), id).completes);
        pastWindow(id);
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));

        uint256 atBar = submittedJob();
        decide(atBar, true, BAR);
        assertTrue(evaluator.judgmentOf(address(acp), atBar).completes);
    }

    function test_anyoneMaySubmitASignedDecision() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        bytes memory signature = sign(BRAIN_KEY, d);
        vm.prank(stranger);
        evaluator.decide(d, signature);
        assertTrue(evaluator.judgmentOf(address(acp), id).decided);
    }

    function test_aDecisionNotSignedByTheBrainReverts() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        decideReverts(d, 0xBAD, Erc8183Evaluator.NotBrain.selector);
    }

    function test_aDecisionForAnotherJobReverts() public {
        uint256 first = submittedJob();
        uint256 second = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(second, false, true, 9_000);
        bytes memory signature = sign(BRAIN_KEY, d);
        d.jobId = first;
        vm.expectRevert(Erc8183Evaluator.NotBrain.selector);
        evaluator.decide(d, signature);

        d.jobId = second;
        d.jobContract = address(new ERC8183(treasury, admin));
        vm.expectRevert(Erc8183Evaluator.NotBrain.selector);
        evaluator.decide(d, signature);
    }

    function test_aDecisionForAJobWithAnotherEvaluatorReverts() public {
        uint256 id = createJob(makeAddr("other-evaluator"), address(0));
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        decideReverts(d, Erc8183Evaluator.NotEvaluator.selector);
    }

    function test_aDecisionForAnotherDeliverableReverts() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        d.deliverable = keccak256("another deliverable");
        decideReverts(d, Erc8183Evaluator.WrongDeliverable.selector);
    }

    function test_aDecisionSignedForAnotherEvaluatorOrChainReverts() public {
        uint256 id = submittedJob();
        Erc8183Evaluator other = new Erc8183Evaluator(safe, brain, BRAIN_DELAY, BAR);
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BRAIN_KEY, other.hashDecision(d));
        vm.expectRevert(Erc8183Evaluator.NotBrain.selector);
        evaluator.decide(d, abi.encodePacked(r, s, v));

        bytes memory signature = sign(BRAIN_KEY, d);
        vm.chainId(8453);
        vm.expectRevert(Erc8183Evaluator.NotBrain.selector);
        evaluator.decide(d, signature);
    }

    function test_aReplayedDecisionReverts() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decide(id, true, 9_000);
        bytes memory signature = sign(BRAIN_KEY, d);
        vm.expectRevert(Erc8183Evaluator.DecisionUsed.selector);
        evaluator.decide(d, signature);

        Erc8183Evaluator.Decision memory again = decision(id, false, false, 9_000);
        decideReverts(again, Erc8183Evaluator.AlreadyDecided.selector);
    }

    function test_aBrainChainDecisionAppliesOnce() public {
        uint256 first = submittedJob();
        uint256 second = submittedJob();
        Erc8183Evaluator.Decision memory d = decide(first, true, 9_000);
        d.jobId = second;
        decideReverts(d, Erc8183Evaluator.DecisionUsed.selector);

        d.appeal = true;
        d.jobId = first;
        vm.prank(client);
        hook.appeal(first);
        decideReverts(d, Erc8183Evaluator.DecisionUsed.selector);
    }

    function test_confidenceAboveTenThousandReverts() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 10_001);
        decideReverts(d, Erc8183Evaluator.BadConfidence.selector);
    }

    function test_onlyASubmittedJobCanBeDecided() public {
        uint256 id = createJob(address(evaluator), address(hook));
        fundJob(id);
        Erc8183Evaluator.Decision memory d = decision(id, false, false, 9_000);
        decideReverts(d, Erc8183Evaluator.NotSubmitted.selector);
    }

    function test_aJobWithoutTheHookCannotBeDecided() public {
        uint256 id = createJob(address(evaluator), address(0));
        fundJob(id);
        submitJob(id);
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        decideReverts(d, Erc8183Evaluator.WrongHook.selector);
    }

    function test_aRulingNeedsAFirstDecision() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, true, true, 9_000);
        decideReverts(d, Erc8183Evaluator.NotDecided.selector);
        vm.expectRevert(Erc8183Evaluator.NotDecided.selector);
        evaluator.finalize(address(acp), id);
    }

    function test_aFirstDecisionTooLateForAnAppealReverts() public {
        uint256 id = submittedJob();
        uint256 expiredAt = acp.getJob(id).expiredAt;
        vm.warp(expiredAt - WINDOW - RULING + 1);
        Erc8183Evaluator.Decision memory d = decision(id, false, true, 9_000);
        decideReverts(d, Erc8183AppealHook.NoTimeToAppeal.selector);

        vm.warp(expiredAt + acp.EVALUATION_GRACE_PERIOD());
        acp.claimRefund(id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), 10_000e6);
    }

    function test_theLastMomentForAFirstDecisionStillLeavesAWindowAndARuling() public {
        uint256 id = submittedJob();
        uint256 expiredAt = acp.getJob(id).expiredAt;
        vm.warp(expiredAt - WINDOW - RULING);
        decide(id, true, 9_000);
        vm.warp(block.timestamp + WINDOW);
        vm.prank(client);
        hook.appeal(id);
        vm.warp(block.timestamp + RULING);
        rule(id, true, 9_000);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
    }

    function test_theDigestIsTheEip712HashOfTheDecision() public {
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory d = decision(id, true, false, 7_250);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("BrainChain ERC-8183 Evaluator"),
                keccak256("1"),
                block.chainid,
                address(evaluator)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Decision(address jobContract,uint256 jobId,bytes32 deliverable,bool appeal,bool accept,uint16 confidenceBps,uint256 logChainId,address decisionLog,uint256 decisionId)"
                ),
                d.jobContract,
                d.jobId,
                d.deliverable,
                d.appeal,
                d.accept,
                d.confidenceBps,
                d.logChainId,
                d.decisionLog,
                d.decisionId
            )
        );
        assertEq(evaluator.DOMAIN_SEPARATOR(), domain);
        assertEq(evaluator.hashDecision(d), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = evaluator.eip712Domain();
        assertEq(name, "BrainChain ERC-8183 Evaluator");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifying, address(evaluator));
    }

    function test_constructorRefusesBadArguments() public {
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        new Erc8183Evaluator(address(0), brain, BRAIN_DELAY, BAR);
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        new Erc8183Evaluator(safe, address(0), BRAIN_DELAY, BAR);
        vm.expectRevert(Erc8183Evaluator.BadDelay.selector);
        new Erc8183Evaluator(safe, brain, 1 days - 1, BAR);
        vm.expectRevert(Erc8183Evaluator.BadConfidence.selector);
        new Erc8183Evaluator(safe, brain, BRAIN_DELAY, 10_001);

        assertEq(evaluator.owner(), safe);
        assertEq(evaluator.brain(), brain);
        assertEq(evaluator.delay(), BRAIN_DELAY);
        assertEq(evaluator.minConfidenceBps(), BAR);
    }

    function test_aNewBrainKeyTakesEffectOnlyAfterTheDelay() public {
        uint256 nextKey = 0xB4A2;
        address next = vm.addr(nextKey);
        vm.prank(safe);
        evaluator.proposeBrain(next);
        assertEq(evaluator.pendingBrain(), next);
        assertEq(evaluator.brainReadyAt(), block.timestamp + BRAIN_DELAY);

        vm.warp(block.timestamp + BRAIN_DELAY - 1);
        vm.expectRevert(Erc8183Evaluator.TooEarly.selector);
        evaluator.acceptBrain();
        uint256 id = submittedJob();
        Erc8183Evaluator.Decision memory early = decision(id, false, true, 9_000);
        decideReverts(early, nextKey, Erc8183Evaluator.NotBrain.selector);

        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        evaluator.acceptBrain();
        assertEq(evaluator.brain(), next);
        assertEq(evaluator.pendingBrain(), address(0));
        assertEq(evaluator.brainReadyAt(), 0);

        Erc8183Evaluator.Decision memory old = decision(id, false, true, 9_000);
        decideReverts(old, Erc8183Evaluator.NotBrain.selector);
        Erc8183Evaluator.Decision memory current = decision(id, false, true, 9_000);
        evaluator.decide(current, sign(nextKey, current));
    }

    function test_onlyTheOwnerProposesOrCancelsABrainKey() public {
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.proposeBrain(stranger);
        vm.prank(safe);
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        evaluator.proposeBrain(address(0));

        vm.prank(safe);
        vm.expectRevert(Erc8183Evaluator.NoPendingBrain.selector);
        evaluator.cancelBrain();
        vm.expectRevert(Erc8183Evaluator.NoPendingBrain.selector);
        evaluator.acceptBrain();

        vm.prank(safe);
        evaluator.proposeBrain(stranger);
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.cancelBrain();
        vm.prank(safe);
        evaluator.cancelBrain();
        assertEq(evaluator.pendingBrain(), address(0));
        vm.warp(block.timestamp + BRAIN_DELAY);
        vm.expectRevert(Erc8183Evaluator.NoPendingBrain.selector);
        evaluator.acceptBrain();
        assertEq(evaluator.brain(), brain);
    }

    function test_aKeyCheckMustPassBeforeANewKeyTakesEffect() public {
        KeyCheck check = new KeyCheck();
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.setKeyCheck(check);
        vm.startPrank(safe);
        evaluator.setKeyCheck(check);
        evaluator.proposeBrain(stranger);
        vm.stopPrank();
        vm.warp(block.timestamp + BRAIN_DELAY);

        vm.expectRevert(Erc8183Evaluator.KeyNotAttested.selector);
        evaluator.acceptBrain();
        check.attest(stranger);
        evaluator.acceptBrain();
        assertEq(evaluator.brain(), stranger);
    }

    function test_ownershipMovesInTwoSteps() public {
        address next = makeAddr("next-safe");
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.transferOwnership(next);
        vm.prank(safe);
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        evaluator.transferOwnership(address(0));
        vm.prank(safe);
        evaluator.transferOwnership(next);
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotPendingOwner.selector);
        evaluator.acceptOwnership();
        vm.prank(next);
        evaluator.acceptOwnership();
        assertEq(evaluator.owner(), next);
        assertEq(evaluator.pendingOwner(), address(0));
    }

    function test_theOwnerSweepsEvaluatorFees() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        pastWindow(id);
        evaluator.finalize(address(acp), id);
        uint256 fee = (BUDGET * EVALUATOR_FEE_BPS) / 10_000;

        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.sweep(usdc, stranger);
        vm.prank(safe);
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        evaluator.sweep(usdc, address(0));
        vm.prank(safe);
        evaluator.sweep(usdc, treasury);
        assertEq(usdc.balanceOf(address(evaluator)), 0);
        assertEq(usdc.balanceOf(treasury), (BUDGET * PLATFORM_FEE_BPS) / 10_000 + fee);
    }

    function test_revokeStopsALeakedKeyAtOnce() public {
        uint256 decided = submittedJob();
        decide(decided, true, 9_000);
        vm.prank(client);
        hook.appeal(decided);
        uint256 undecided = submittedJob();
        uint256 nextKey = 0xB4A2;
        vm.prank(safe);
        evaluator.proposeBrain(vm.addr(nextKey));

        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.revokeBrain();
        vm.expectEmit(address(evaluator));
        emit Erc8183Evaluator.BrainRevoked(brain);
        vm.prank(safe);
        evaluator.revokeBrain();
        assertEq(evaluator.brain(), address(0));

        decideReverts(decision(undecided, false, true, 9_000), Erc8183Evaluator.NoBrain.selector);
        decideReverts(decision(decided, true, true, 9_000), Erc8183Evaluator.NoBrain.selector);
        decideReverts(decision(undecided, false, true, 9_000), nextKey, Erc8183Evaluator.NoBrain.selector);

        vm.warp(block.timestamp + BRAIN_DELAY);
        evaluator.acceptBrain();
        assertEq(evaluator.brain(), vm.addr(nextKey));
        decideReverts(decision(undecided, false, true, 9_000), Erc8183Evaluator.NotBrain.selector);
        Erc8183Evaluator.Decision memory d = decision(undecided, false, true, 9_000);
        evaluator.decide(d, sign(nextKey, d));
        assertTrue(evaluator.judgmentOf(address(acp), undecided).decided);
    }

    function test_aDecisionAppliedBeforeARevokeStillSettlesWhenItsTimeRunsOut() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        vm.prank(client);
        hook.appeal(id);
        vm.prank(safe);
        evaluator.revokeBrain();
        vm.warp(block.timestamp + RULING + 1);
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET);
    }

    function test_aHookTheOwnerNeverAllowedIsRefused() public {
        LookalikeHook lookalike = new LookalikeHook(address(evaluator), address(acp));
        vm.prank(admin);
        acp.setHookWhitelist(address(lookalike), true);
        uint256 id = createJob(address(evaluator), address(lookalike));
        fundJob(id);
        submitJob(id);
        decideReverts(decision(id, false, true, 9_000), Erc8183Evaluator.WrongHook.selector);
    }

    function test_aHookIsAllowedOnlyAfterTheDelayAndRemovedAtOnce() public {
        Erc8183AppealHook second = new Erc8183AppealHook(acp, address(evaluator), safe, WINDOW, RULING);
        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.proposeHook(address(second));
        vm.prank(safe);
        vm.expectRevert(Erc8183Evaluator.ZeroAddress.selector);
        evaluator.proposeHook(address(0));
        vm.expectRevert(Erc8183Evaluator.NoPendingHook.selector);
        evaluator.acceptHook(address(second));

        vm.prank(safe);
        evaluator.proposeHook(address(second));
        assertEq(evaluator.hookReadyAt(address(second)), block.timestamp + BRAIN_DELAY);
        vm.warp(block.timestamp + BRAIN_DELAY - 1);
        vm.expectRevert(Erc8183Evaluator.TooEarly.selector);
        evaluator.acceptHook(address(second));
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        evaluator.acceptHook(address(second));
        assertTrue(evaluator.hookAllowed(address(second)));
        assertEq(evaluator.hookReadyAt(address(second)), 0);

        vm.prank(stranger);
        vm.expectRevert(Erc8183Evaluator.NotOwner.selector);
        evaluator.removeHook(address(hook));
        uint256 id = submittedJob();
        vm.prank(safe);
        evaluator.removeHook(address(hook));
        assertFalse(evaluator.hookAllowed(address(hook)));
        decideReverts(decision(id, false, true, 9_000), Erc8183Evaluator.WrongHook.selector);

        vm.prank(safe);
        evaluator.proposeHook(address(hook));
        vm.prank(safe);
        evaluator.removeHook(address(hook));
        vm.warp(block.timestamp + BRAIN_DELAY);
        vm.expectRevert(Erc8183Evaluator.NoPendingHook.selector);
        evaluator.acceptHook(address(hook));
    }

    function testFuzz_aFirstDecisionCompletesOnlyWhenAcceptedAtOrAboveTheBar(bool accept, uint16 confidenceBps) public {
        confidenceBps = uint16(bound(confidenceBps, 0, 10_000));
        uint256 id = submittedJob();
        decide(id, accept, confidenceBps);
        pastWindow(id);
        evaluator.finalize(address(acp), id);
        bool completes = accept && confidenceBps >= BAR;
        assertEq(uint8(status(id)), uint8(completes ? IERC8183.JobStatus.Completed : IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(provider), 10_000e6 + (completes ? net() : 0));
        assertEq(usdc.balanceOf(client), 10_000e6 - (completes ? BUDGET : 0));
    }
}
