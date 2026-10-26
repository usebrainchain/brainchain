// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BrainChainSetup} from "./BrainChain.t.sol";
import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {MockERC20} from "./MockERC20.sol";

/// Each test reproduces a v2 finding from the October 2026 review and asserts
/// the v3 behaviour. The comment above each test says what v2 did.
contract TaskBoardRegressions is BrainChainSetup {
    event BountyPaid(uint256 indexed id, bytes32 indexed model, address indexed account, uint128 bounty, uint128 fee);
    event FeeTaken(uint256 indexed id, address indexed recipient, uint128 fee);
    event BountyRefunded(uint256 indexed id, address indexed poster, uint128 amount, TaskBoard.RefundReason reason);

    function _accepted() internal returns (uint256 id) {
        id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_200);
        assertTrue(board.get(id).accepted);
    }

    /// v2 paid whatever account the registry named at settlement.
    function test_paysTheAccountThatSubmitted() public {
        uint256 id = _accepted();
        address other = makeAddr("other");
        registry.setModel(CLAUDE, other, 0.4e6, true);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(claudeAccount), BOUNTY);
        assertEq(usdg.balanceOf(other), 0);
        assertEq(board.get(id).payee, claudeAccount);
    }

    /// v2 accepted a grade recorded before the work existed.
    function test_gradeMustBeRecordedAfterTheSubmission() public {
        uint256 id = postTask();
        hireClaude(id);
        uint256 early = decide(DecisionLog.Kind.Grade, board.subjectOf(id), YES, 10_000);
        vm.warp(block.timestamp + 1);
        deliver(id);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.grade(id, early);
    }

    function test_rulingMustBeRecordedAfterTheDispute() public {
        uint256 id = _accepted();
        uint256 early = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), NO, 10_000);
        vm.warp(block.timestamp + 1);
        vm.prank(poster);
        board.dispute(id);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.rule(id, early);
    }

    function test_hireCannotBeRecordedBeforeThePost() public {
        uint256 next = board.count() + 1;
        uint256 early = decide(DecisionLog.Kind.Hire, board.subjectOf(next), CLAUDE, 10_000);
        vm.warp(block.timestamp + 1);
        uint256 id = postTask();
        assertEq(id, next);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.hire(id, early);
    }

    /// v2 let the brain record several answers and apply whichever it liked.
    function test_onlyTheLatestDecisionApplies() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        uint256 reject = decide(DecisionLog.Kind.Grade, board.subjectOf(id), NO, 9_000);
        uint256 accept = decide(DecisionLog.Kind.Grade, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.StaleDecision.selector);
        board.grade(id, reject);
        vm.prank(brain);
        board.grade(id, accept);
        assertTrue(board.get(id).accepted);
    }

    /// v2 decisions named only a task id, so a second board accepted the first board's decisions.
    function test_decisionsDoNotReplayOnAnotherBoard() public {
        TaskBoard board2 = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(this),
            guardian,
            defaultConfig()
        );
        uint256 id = postTask();
        uint256 d = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 8_000);
        vm.prank(poster);
        usdg.approve(address(board2), type(uint256).max);
        vm.prank(poster);
        uint256 id2 = board2.post(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        assertEq(id2, id);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board2.hire(id2, d);
        assertTrue(board.subjectOf(id) != board2.subjectOf(id));
    }

    /// v2 read windows live and without limits: one change could close the refund path forever.
    function test_configIsCappedAndInFlightTasksKeepTheirWindows() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        TaskBoard.Config memory c = defaultConfig();
        c.gradeWindow = type(uint64).max;
        vm.prank(address(executor));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setConfig(c);
        c.gradeWindow = 7 days;
        vm.prank(address(executor));
        board.setConfig(c);
        assertEq(board.get(id).gradeWindow, 6 hours);
        vm.warp(block.timestamp + 6 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_configBounds() public {
        TaskBoard.Config memory c = defaultConfig();
        c.maxDuration = 30 days + 1;
        vm.startPrank(address(executor));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setConfig(c);
        c.maxDuration = 30 days;
        c.disputeWindow = 7 days + 1;
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setConfig(c);
        c.disputeWindow = 7 days;
        c.ruleWindow = 7 days + 1;
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setConfig(c);
        c.ruleWindow = 7 days;
        board.setConfig(c);
        vm.stopPrank();
    }

    function test_thresholdsAreFixedAtPosting() public {
        uint256 id = postTask();
        TaskBoard.Config memory c = defaultConfig();
        c.gradeThresholdBps = 9_500;
        vm.prank(address(executor));
        board.setConfig(c);
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);
        assertTrue(board.get(id).accepted, "graded under the 70% threshold it was posted with");
    }

    function test_feeIsFixedAtPostingAndAnnouncedWithItsRecipient() public {
        address feeTo = makeAddr("fee-to");
        vm.prank(address(executor));
        board.setFee(300, feeTo);
        uint256 id = postTask();
        vm.prank(address(executor));
        board.setFee(1_000, makeAddr("someone-else"));
        hireClaude(id);
        deliver(id);
        gradeAs(id, YES, 9_000);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectEmit(true, true, false, true, address(board));
        emit FeeTaken(id, feeTo, 0.15e6);
        vm.expectEmit(true, true, true, true, address(board));
        emit BountyPaid(id, CLAUDE, claudeAccount, BOUNTY, 0.15e6);
        board.finalize(id);
        assertEq(usdg.balanceOf(feeTo), 0.15e6);
        assertEq(usdg.balanceOf(claudeAccount), BOUNTY - 0.15e6);
    }

    /// v2 kept grading and ruling while paused, so a pause could not stop a compromised brain.
    function test_pauseStopsGradesAndRulings() public {
        uint256 graded = postTask();
        hireClaude(graded);
        deliver(graded);
        uint256 disputed = _accepted();
        vm.prank(poster);
        board.dispute(disputed);

        vm.prank(guardian);
        board.setPaused(true);
        uint256 g = decide(DecisionLog.Kind.Grade, board.subjectOf(graded), YES, 9_900);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.grade(graded, g);
        uint256 r = decide(DecisionLog.Kind.Ruling, board.subjectOf(disputed), NO, 9_900);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.rule(disputed, r);

        // Work in flight still settles by its windows.
        vm.warp(block.timestamp + 6 hours + 1);
        board.finalize(graded);
        board.finalize(disputed);
        assertEq(uint8(board.get(graded).status), uint8(TaskBoard.Status.Refunded));
        assertEq(uint8(board.get(disputed).status), uint8(TaskBoard.Status.Paid));
    }

    function test_refundsSayWhy() public {
        uint256 notHired = postTask();
        uint256 notDelivered = postTask();
        hireClaude(notDelivered);
        uint256 notGraded = postTask();
        hireClaude(notGraded);
        deliver(notGraded);
        uint256 rejected = postTask();
        hireClaude(rejected);
        deliver(rejected);
        gradeAs(rejected, NO, 9_000);
        uint256 ruled = _accepted();
        vm.prank(poster);
        board.dispute(ruled);

        uint256 r = decide(DecisionLog.Kind.Ruling, board.subjectOf(ruled), NO, 9_000);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(ruled, poster, BOUNTY, TaskBoard.RefundReason.RuledForPoster);
        vm.prank(brain);
        board.rule(ruled, r);

        vm.warp(block.timestamp + DAY + 1);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(notHired, poster, BOUNTY, TaskBoard.RefundReason.NotHired);
        board.finalize(notHired);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(notDelivered, poster, BOUNTY, TaskBoard.RefundReason.NotDelivered);
        board.finalize(notDelivered);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(notGraded, poster, BOUNTY, TaskBoard.RefundReason.NotGraded);
        board.finalize(notGraded);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(rejected, poster, BOUNTY, TaskBoard.RefundReason.Rejected);
        board.finalize(rejected);
    }
}

contract DecisionExecutorRegressions is BrainChainSetup {
    function _adopt(address target, bytes memory data) internal returns (uint256 d) {
        d = decide(DecisionLog.Kind.Change, executor.changeSubject(target, data), YES, 9_900);
    }

    /// v2 capped house tasks by count only: one house task could carry the whole treasury.
    function test_houseTasksAreCappedInAmount() public {
        usdg.mint(address(executor), 100e6);
        vm.prank(address(executor)); // as an executed change would
        executor.setParameters(8_500, 2 days, 5, 10e6, 15e6);
        vm.startPrank(brain);
        vm.expectRevert(DecisionExecutor.OverHouseBounty.selector);
        executor.postHouseTask(10e6 + 1, uint64(block.timestamp + DAY), 0, "");
        executor.postHouseTask(10e6, uint64(block.timestamp + DAY), 0, "");
        vm.expectRevert(DecisionExecutor.HouseSpendReached.selector);
        executor.postHouseTask(5e6 + 1, uint64(block.timestamp + DAY), 0, "");
        executor.postHouseTask(5e6, uint64(block.timestamp + DAY), 0, "");
        vm.stopPrank();
        assertEq(executor.houseSpentOnDay(block.timestamp / 1 days), 15e6);

        vm.warp(block.timestamp + DAY);
        vm.prank(brain);
        executor.postHouseTask(10e6, uint64(block.timestamp + DAY), 0, "");
    }

    /// v2 let a change call any address, including the token itself.
    function test_changesReachOnlyTheExecutorBoardAndRegistry() public {
        address attacker = makeAddr("attacker");
        usdg.mint(address(executor), 10e6);
        bytes memory steal = abi.encodeCall(IERC20.transfer, (attacker, 10e6));
        uint256 d = _adopt(address(usdg), steal);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenTarget.selector);
        executor.queue(d, address(usdg), steal);

        bytes memory replaceBrain = abi.encodeCall(DecisionLog.setBrain, (attacker));
        d = _adopt(address(decisionLog), replaceBrain);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenTarget.selector);
        executor.queue(d, address(decisionLog), replaceBrain);

        bytes memory model = abi.encodeCall(ModelRegistry.setModel, (keccak256("gemini"), attacker, 1, true));
        registry.setOwner(address(executor));
        d = _adopt(address(registry), model);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(registry), model);
        vm.warp(block.timestamp + 2 days);
        executor.execute(changeId);
        assertEq(registry.get(keccak256("gemini")).account, attacker);
    }

    function test_changesNeedASelector() public {
        bytes memory empty = "";
        uint256 d = _adopt(address(board), empty);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
        executor.queue(d, address(board), empty);
    }

    /// v2 queued changes never expired: a failed call could be executed months later.
    function test_queuedChangesExpireAfterTheGracePeriod() public {
        address to = makeAddr("to");
        bytes memory data = abi.encodeCall(DecisionExecutor.transfer, (to, 10e6));
        uint256 d = _adopt(address(executor), data);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(executor), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        executor.execute(changeId); // empty treasury: fails, stays pending
        vm.warp(block.timestamp + 14 days + 1);
        usdg.mint(address(executor), 10e6);
        vm.expectRevert(DecisionExecutor.Expired.selector);
        executor.execute(changeId);
        assertEq(usdg.balanceOf(to), 0);
    }

    function test_executesAtTheEndOfTheGracePeriod() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = _adopt(address(board), data);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(board), data);
        vm.warp(block.timestamp + 2 days + 14 days);
        executor.execute(changeId);
        assertTrue(board.paused());
    }

    /// v2 accepted a timelock near 2^64, which overflowed and broke queue() for good.
    function test_timelockHasACeiling() public {
        bytes memory data =
            abi.encodeCall(DecisionExecutor.setParameters, (8_500, type(uint64).max - 100, 2, 10e6, 20e6));
        uint256 d = _adopt(address(executor), data);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(executor), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        executor.execute(changeId);
        assertEq(executor.timelock(), 2 days);
    }

    function test_onlyTheLatestChangeDecisionQueues() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 older = _adopt(address(board), data);
        uint256 newer = decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), data), NO, 9_900);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.StaleDecision.selector);
        executor.queue(older, address(board), data);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.BelowThreshold.selector);
        executor.queue(newer, address(board), data);
    }

    function test_changeSubjectBindsChainAndExecutor() public view {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        assertTrue(executor.changeSubject(address(board), data) != keccak256(abi.encode(address(board), data)));
    }

    function test_bindBoardChecksTheBoard() public {
        DecisionExecutor fresh =
            new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, 2, 10e6, 20e6);
        DecisionLog otherLog = new DecisionLog(address(this), brain);
        TaskBoard foreign = new TaskBoard(
            IERC20(address(usdg)),
            otherLog,
            registry,
            WorkerStaking(address(0)),
            address(fresh),
            guardian,
            defaultConfig()
        );
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.BadBoard.selector);
        fresh.bindBoard(foreign);

        MockERC20 otherToken = new MockERC20();
        TaskBoard wrongToken = new TaskBoard(
            IERC20(address(otherToken)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(fresh),
            guardian,
            defaultConfig()
        );
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.BadBoard.selector);
        fresh.bindBoard(wrongToken);
    }

    function test_treasuryTransferIsAnnounced() public {
        usdg.mint(address(executor), 10e6);
        bytes memory data = abi.encodeCall(DecisionExecutor.transfer, (poster, 4e6));
        uint256 d = _adopt(address(executor), data);
        vm.prank(brain);
        uint256 changeId = executor.queue(d, address(executor), data);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(true, false, false, true, address(executor));
        emit DecisionExecutor.Transferred(poster, 4e6);
        executor.execute(changeId);
    }
}

/// Testnet configuration (staking on): v2 let the brain key plus any address
/// that staked faucet tBRAIN take any poster's escrow.
contract StakingRegressions is BrainChainSetup {
    function test_selfStakedWorkerCannotTakeEscrow() public {
        MockERC20 brainToken = new MockERC20();
        WorkerStaking staking = new WorkerStaking(IERC20(address(brainToken)), address(this), 500e18, 3 days, 2_000);
        TaskBoard tb = new TaskBoard(
            IERC20(address(usdg)), decisionLog, registry, staking, address(this), guardian, defaultConfig()
        );
        staking.setSlasher(address(tb));
        address attacker = makeAddr("attacker");
        brainToken.mint(attacker, 500e18);
        vm.startPrank(attacker);
        brainToken.approve(address(staking), 500e18);
        staking.stake(500e18, 0);
        vm.stopPrank();

        vm.prank(poster);
        usdg.approve(address(tb), type(uint256).max);
        vm.prank(poster);
        uint256 id = tb.post(500e6, uint64(block.timestamp + DAY), 0, "");
        uint256 d = decide(DecisionLog.Kind.Hire, tb.subjectOf(id), staking.idOf(attacker), 10_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.ModelInactive.selector);
        tb.hire(id, d);
    }
}
