// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {MockERC20} from "./MockERC20.sol";

abstract contract BrainChainSetup is Test {
    bytes32 internal constant CLAUDE = keccak256("claude");
    bytes32 internal constant GPT = keccak256("gpt");
    bytes32 internal constant YES = bytes32(uint256(1));
    bytes32 internal constant NO = bytes32(0);
    uint128 internal constant BOUNTY = 5e6;
    uint64 internal constant DAY = 1 days;

    address internal brain = makeAddr("brain");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal claudeAccount = makeAddr("claude-account");
    address internal gptAccount = makeAddr("gpt-account");

    MockERC20 internal usdg;
    DecisionLog internal decisionLog;
    ModelRegistry internal registry;
    TaskBoard internal board;
    DecisionExecutor internal executor;

    function setUp() public virtual {
        usdg = new MockERC20();
        decisionLog = new DecisionLog(address(this), brain);
        executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, 2);
        registry = new ModelRegistry(address(this));
        registry.setModel(CLAUDE, claudeAccount, 0.4e6, true);
        registry.setModel(GPT, gptAccount, 0.35e6, true);
        board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(executor),
            guardian,
            defaultConfig()
        );
        vm.prank(guardian);
        executor.bindBoard(board);

        usdg.mint(poster, 1_000e6);
        vm.prank(poster);
        usdg.approve(address(board), type(uint256).max);
    }

    function defaultConfig() internal pure returns (TaskBoard.Config memory) {
        return TaskBoard.Config({
            hireThresholdBps: 7_000,
            gradeThresholdBps: 7_000,
            ruleThresholdBps: 7_000,
            minDuration: 1 hours,
            maxDuration: 7 days,
            gradeWindow: 6 hours,
            disputeWindow: 1 hours,
            ruleWindow: 6 hours,
            minBounty: 1e6
        });
    }

    function postTask() internal returns (uint256 id) {
        vm.prank(poster);
        id = board.post(BOUNTY, uint64(block.timestamp + DAY), keccak256("brief"), "ipfs://brief");
    }

    function decide(DecisionLog.Kind kind, bytes32 subject, bytes32 answer, uint16 confidenceBps)
        internal
        returns (uint256)
    {
        vm.prank(brain);
        return
            decisionLog.record(
                kind, subject, keccak256("input"), answer, confidenceBps, keccak256("payload"), "ipfs://d"
            );
    }

    function hireClaude(uint256 id) internal {
        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(id), CLAUDE, 8_000);
        vm.prank(brain);
        board.hire(id, d);
    }

    function deliver(uint256 id) internal {
        vm.prank(claudeAccount);
        board.submit(id, keccak256("result"), "ipfs://result");
    }

    function gradeAs(uint256 id, bytes32 answer, uint16 confidenceBps) internal {
        uint256 d = decide(DecisionLog.Kind.Grade, bytes32(id), answer, confidenceBps);
        vm.prank(brain);
        board.grade(id, d);
    }
}

contract DecisionLogTest is BrainChainSetup {
    function test_onlyBrainRecords() public {
        vm.expectRevert(DecisionLog.NotBrain.selector);
        decisionLog.record(DecisionLog.Kind.Hire, bytes32(uint256(1)), 0, CLAUDE, 8_000, 0, "");
    }

    function test_rejectsConfidenceAboveOne() public {
        vm.prank(brain);
        vm.expectRevert(DecisionLog.BadConfidence.selector);
        decisionLog.record(DecisionLog.Kind.Hire, bytes32(uint256(1)), 0, CLAUDE, 10_001, 0, "");
    }

    function test_rejectsKindNone() public {
        vm.prank(brain);
        vm.expectRevert(DecisionLog.BadKind.selector);
        decisionLog.record(DecisionLog.Kind.None, bytes32(uint256(1)), 0, CLAUDE, 1, 0, "");
    }

    function test_recordsAndReads() public {
        uint256 id = decide(DecisionLog.Kind.Grade, bytes32(uint256(7)), YES, 9_100);
        DecisionLog.Decision memory d = decisionLog.get(id);
        assertEq(uint8(d.kind), uint8(DecisionLog.Kind.Grade));
        assertEq(d.subject, bytes32(uint256(7)));
        assertEq(d.answer, YES);
        assertEq(d.confidenceBps, 9_100);
        assertEq(decisionLog.count(), 1);
    }

    function test_unknownDecisionReverts() public {
        vm.expectRevert(DecisionLog.UnknownDecision.selector);
        decisionLog.get(99);
    }

    function test_ownerRotatesBrain() public {
        address next = makeAddr("next-brain");
        decisionLog.setBrain(next);
        assertEq(decisionLog.brain(), next);
        vm.prank(brain);
        vm.expectRevert(DecisionLog.NotOwner.selector);
        decisionLog.setBrain(brain);
    }
}

contract TaskBoardTest is BrainChainSetup {
    function test_happyPathPaysTheModelAfterTheDisputeWindow() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);

        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);

        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(claudeAccount), BOUNTY);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Paid));
        assertEq(usdg.balanceOf(address(board)), 0);
    }

    function test_rejectedWorkRefundsThePoster() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, NO, 9_500);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(claudeAccount), 0);
    }

    function test_lowConfidenceAcceptStillRefunds() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 6_999);
        assertFalse(board.get(id).accepted);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_lowConfidenceHireLeavesTaskOpen() public {
        uint256 id = postTask();
        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(id), CLAUDE, 6_500);
        vm.prank(brain);
        board.hire(id, d);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Open));

        hireClaude(id);
        assertEq(board.get(id).model, CLAUDE);
    }

    function test_noHireRefundsAtDeadline() public {
        uint256 id = postTask();
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        vm.warp(block.timestamp + DAY + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_hiredButNoDeliveryRefundsAtDeadline() public {
        uint256 id = postTask();
        hireClaude(id);
        vm.warp(block.timestamp + DAY + 1);
        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.submit(id, 0, "");
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_ungradedWorkRefundsAfterTheGradeWindow() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        vm.warp(block.timestamp + 6 hours + 1);
        uint256 d = decide(DecisionLog.Kind.Grade, bytes32(id), YES, 9_900);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.grade(id, d);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_disputeThenRulingPays() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, NO, 9_000);

        vm.prank(claudeAccount);
        board.dispute(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, bytes32(id), YES, 8_000);
        vm.prank(brain);
        board.rule(id, d);
        assertEq(usdg.balanceOf(claudeAccount), BOUNTY);
    }

    function test_lowConfidenceRulingRefunds() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);
        vm.prank(poster);
        board.dispute(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, bytes32(id), YES, 5_000);
        vm.prank(brain);
        board.rule(id, d);
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(claudeAccount), 0);
    }

    function test_unruledDisputeRefundsAfterTheRuleWindow() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);
        vm.prank(poster);
        board.dispute(id);
        vm.warp(block.timestamp + 6 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_disputeOnlyOnceAndOnlyByParties() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(TaskBoard.NotDisputant.selector);
        board.dispute(id);

        vm.prank(poster);
        board.dispute(id);
        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.dispute(id);
    }

    function test_disputeClosesAfterTheWindow() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(poster);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.dispute(id);
    }

    function test_decisionsAreSingleUse() public {
        uint256 first = postTask();
        // A held hire leaves the task open, so only the single-use rule stops a replay.
        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(first), CLAUDE, 5_000);
        vm.startPrank(brain);
        board.hire(first, d);
        vm.expectRevert(TaskBoard.DecisionUsed.selector);
        board.hire(first, d);
        vm.stopPrank();
    }

    function test_decisionMustMatchKindAndTask() public {
        uint256 a = postTask();
        uint256 b = postTask();
        uint256 forA = decide(DecisionLog.Kind.Hire, bytes32(a), CLAUDE, 9_000);
        uint256 wrongKind = decide(DecisionLog.Kind.Grade, bytes32(b), YES, 9_000);
        vm.startPrank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.hire(b, forA);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.hire(b, wrongKind);
        vm.stopPrank();
    }

    function test_onlyBrainAppliesDecisions() public {
        uint256 id = postTask();
        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(id), CLAUDE, 9_000);
        vm.expectRevert(TaskBoard.NotBrain.selector);
        board.hire(id, d);
    }

    function test_onlyTheHiredModelSubmits() public {
        uint256 id = postTask();
        hireClaude(id);
        vm.prank(gptAccount);
        vm.expectRevert(TaskBoard.NotWorker.selector);
        board.submit(id, 0, "");
    }

    function test_inactiveModelCannotBeHired() public {
        registry.setModel(GPT, gptAccount, 0.35e6, false);
        uint256 id = postTask();
        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(id), GPT, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.ModelInactive.selector);
        board.hire(id, d);
    }

    function test_postRejectsBadBountyAndDeadline() public {
        vm.startPrank(poster);
        vm.expectRevert(TaskBoard.BadBounty.selector);
        board.post(0.5e6, uint64(block.timestamp + DAY), 0, "");
        vm.expectRevert(TaskBoard.BadDeadline.selector);
        board.post(BOUNTY, uint64(block.timestamp + 10 minutes), 0, "");
        vm.expectRevert(TaskBoard.BadDeadline.selector);
        board.post(BOUNTY, uint64(block.timestamp + 8 days), 0, "");
        vm.stopPrank();
    }

    function test_pauseStopsPostsAndHiresButNotRefunds() public {
        uint256 id = postTask();
        vm.prank(guardian);
        board.setPaused(true);

        vm.prank(poster);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.post(BOUNTY, uint64(block.timestamp + DAY), 0, "");

        uint256 d = decide(DecisionLog.Kind.Hire, bytes32(id), CLAUDE, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.hire(id, d);

        vm.warp(block.timestamp + DAY + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_onlyOwnerSetsConfig() public {
        vm.expectRevert(TaskBoard.NotOwner.selector);
        board.setConfig(defaultConfig());
    }

    function test_configRejectsNonsense() public {
        TaskBoard.Config memory c = defaultConfig();
        c.hireThresholdBps = 10_001;
        vm.prank(address(executor));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setConfig(c);
    }

    function test_settledTaskCannotBeFinalizedAgain() public {
        uint256 id = postTask();
        vm.warp(block.timestamp + DAY + 1);
        board.finalize(id);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.finalize(id);
    }
}

contract DecisionExecutorTest is BrainChainSetup {
    function changeDecision(address target, bytes memory data, bytes32 answer, uint16 confidenceBps)
        internal
        returns (uint256)
    {
        return decide(DecisionLog.Kind.Change, keccak256(abi.encode(target, data)), answer, confidenceBps);
    }

    function test_adoptedChangeRunsAfterTheTimelock() public {
        TaskBoard.Config memory c = defaultConfig();
        c.minBounty = 2e6;
        bytes memory data = abi.encodeCall(TaskBoard.setConfig, (c));
        uint256 d = changeDecision(address(board), data, YES, 9_000);

        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(board), data);

        vm.expectRevert(DecisionExecutor.NotReady.selector);
        executor.execute(changeId);

        vm.warp(block.timestamp + 2 days);
        executor.execute(changeId);
        (,,,,,,,, uint128 minBounty) = board.config();
        assertEq(minBounty, 2e6);

        vm.expectRevert(DecisionExecutor.Closed.selector);
        executor.execute(changeId);
    }

    function test_changeBelowThresholdIsRefused() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = changeDecision(address(board), data, YES, 8_499);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.BelowThreshold.selector);
        executor.queue(d, address(board), data);
    }

    function test_changeAnsweredNoIsRefused() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = changeDecision(address(board), data, NO, 9_900);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.BelowThreshold.selector);
        executor.queue(d, address(board), data);
    }

    function test_decisionMustCoverTheExactCall() public {
        bytes memory decided = abi.encodeCall(TaskBoard.setPaused, (false));
        bytes memory other = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = changeDecision(address(board), decided, YES, 9_900);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.BadDecision.selector);
        executor.queue(d, address(board), other);
    }

    function test_guardianVetoesDuringTheTimelock() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = changeDecision(address(board), data, YES, 9_900);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(board), data);

        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.NotGuardian.selector);
        executor.veto(changeId);

        vm.prank(guardian);
        executor.veto(changeId);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(DecisionExecutor.Closed.selector);
        executor.execute(changeId);
        assertFalse(board.paused());
    }

    function test_selfParametersOnlyThroughAChange() public {
        vm.expectRevert(DecisionExecutor.NotSelf.selector);
        executor.setParameters(9_000, 3 days, 5);

        bytes memory data = abi.encodeCall(DecisionExecutor.setParameters, (9_000, 3 days, 5));
        uint256 d = changeDecision(address(executor), data, YES, 9_000);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(executor), data);
        vm.warp(block.timestamp + 2 days);
        executor.execute(changeId);
        assertEq(executor.timelock(), 3 days);
        assertEq(executor.changeThresholdBps(), 9_000);
    }

    function test_parametersCannotDisableTheSafeguards() public {
        bytes memory data = abi.encodeCall(DecisionExecutor.setParameters, (4_000, 0, 5));
        uint256 d = changeDecision(address(executor), data, YES, 9_000);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(executor), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        executor.execute(changeId);
    }

    function test_treasuryMovesOnlyThroughAChange() public {
        usdg.mint(address(executor), 100e6);
        vm.expectRevert(DecisionExecutor.NotSelf.selector);
        executor.transfer(poster, 1e6);
    }

    function test_houseTasksAreCappedPerDay() public {
        usdg.mint(address(executor), 100e6);
        vm.startPrank(brain);
        uint256 first = executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.expectRevert(DecisionExecutor.HouseCapReached.selector);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.stopPrank();

        assertEq(board.get(first).poster, address(executor));
        vm.warp(block.timestamp + DAY + 1);
        board.finalize(first);
        assertEq(usdg.balanceOf(address(executor)), 95e6);
    }

    function test_onlyBrainPostsHouseTasksAndQueues() public {
        vm.expectRevert(DecisionExecutor.NotBrain.selector);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.expectRevert(DecisionExecutor.NotBrain.selector);
        executor.queue(1, address(board), "");
    }

    function test_boardBindsOnce() public {
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.Closed.selector);
        executor.bindBoard(board);
    }
}
