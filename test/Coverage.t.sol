// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {BrainChainSetup} from "./BrainChain.t.sol";

/// @dev A token that keeps 1% of every transfer, to exercise the bounty check.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

contract DecisionLogCoverage is BrainChainSetup {
    event Recorded(
        uint256 indexed id,
        DecisionLog.Kind indexed kind,
        bytes32 indexed subject,
        bytes32 inputHash,
        bytes32 answer,
        uint16 confidenceBps,
        bytes32 payloadHash,
        string payloadURI
    );
    event BrainSet(address indexed brain);
    event OwnerSet(address indexed owner);

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(DecisionLog.ZeroAddress.selector);
        new DecisionLog(address(0), brain);
        vm.expectRevert(DecisionLog.ZeroAddress.selector);
        new DecisionLog(address(this), address(0));
    }

    function test_constructorAnnouncesOwnerAndBrain() public {
        vm.expectEmit(true, false, false, false);
        emit OwnerSet(address(this));
        vm.expectEmit(true, false, false, false);
        emit BrainSet(brain);
        new DecisionLog(address(this), brain);
    }

    function test_recordEmitsTheFullDecision() public {
        vm.expectEmit(true, true, true, true, address(decisionLog));
        emit Recorded(
            1, DecisionLog.Kind.Grade, bytes32(uint256(9)), keccak256("in"), YES, 8_100, keccak256("p"), "uri"
        );
        vm.prank(brain);
        decisionLog.record(
            DecisionLog.Kind.Grade, bytes32(uint256(9)), keccak256("in"), YES, 8_100, keccak256("p"), "uri"
        );
    }

    function test_recordStoresTheTimeAndAcceptsFullConfidence() public {
        vm.warp(1_700_000_000);
        uint256 id = decide(DecisionLog.Kind.Hire, bytes32(uint256(1)), CLAUDE, 10_000);
        DecisionLog.Decision memory d = decisionLog.get(id);
        assertEq(d.recordedAt, 1_700_000_000);
        assertEq(d.confidenceBps, 10_000);
        assertEq(d.inputHash, keccak256("input"));
    }

    function test_setBrainAnnouncesAndRejectsZero() public {
        address next = makeAddr("next");
        vm.expectEmit(true, false, false, false, address(decisionLog));
        emit BrainSet(next);
        decisionLog.setBrain(next);
        vm.expectRevert(DecisionLog.ZeroAddress.selector);
        decisionLog.setBrain(address(0));
    }

    function test_ownershipIsTwoStepAndOwnerOnly() public {
        vm.prank(brain);
        vm.expectRevert(DecisionLog.NotOwner.selector);
        decisionLog.transferOwnership(brain);
        vm.expectRevert(DecisionLog.ZeroAddress.selector);
        decisionLog.transferOwnership(address(0));
        address next = makeAddr("next-owner");
        decisionLog.transferOwnership(next);
        assertEq(decisionLog.owner(), address(this));
        vm.prank(brain);
        vm.expectRevert(DecisionLog.NotPendingOwner.selector);
        decisionLog.acceptOwnership();
        vm.expectEmit(true, false, false, false, address(decisionLog));
        emit OwnerSet(next);
        vm.prank(next);
        decisionLog.acceptOwnership();
        assertEq(decisionLog.owner(), next);
        assertEq(decisionLog.pendingOwner(), address(0));
    }

    function test_latestTracksTheNewestDecisionPerSubjectAndKind() public {
        bytes32 subject = bytes32(uint256(5));
        assertEq(decisionLog.latestOf(subject, DecisionLog.Kind.Grade), 0);
        uint256 first = decide(DecisionLog.Kind.Grade, subject, YES, 9_000);
        uint256 hire = decide(DecisionLog.Kind.Hire, subject, CLAUDE, 9_000);
        uint256 second = decide(DecisionLog.Kind.Grade, subject, NO, 9_000);
        assertEq(decisionLog.latestOf(subject, DecisionLog.Kind.Grade), second);
        assertEq(decisionLog.latestOf(subject, DecisionLog.Kind.Hire), hire);
        assertTrue(first != second);
    }
}

contract DecisionExecutorCoverage is BrainChainSetup {
    event Queued(uint256 indexed changeId, uint256 indexed decisionId, address indexed target, bytes data, uint64 eta);
    event Executed(uint256 indexed changeId);
    event Vetoed(uint256 indexed changeId);
    event HouseTaskPosted(uint256 indexed taskId, uint128 bounty);
    event ParametersSet(
        uint16 changeThresholdBps,
        uint64 timelock,
        uint32 houseTasksPerDay,
        uint128 maxHouseBounty,
        uint128 houseSpendPerDay
    );
    event GuardianSet(address indexed guardian);

    function _adopt(address target, bytes memory data, uint16 confidence) internal returns (uint256 changeId) {
        uint256 d = decide(DecisionLog.Kind.Change, executor.changeSubject(target, data), YES, confidence);
        vm.prank(brain);
        changeId = executor.queue(d, target, data);
    }

    function _ready(address target, bytes memory data) internal returns (uint256 changeId) {
        changeId = _adopt(target, data, 9_000);
        vm.warp(block.timestamp + executor.timelock());
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        new DecisionExecutor(DecisionLog(address(0)), IERC20(address(usdg)), guardian, 8_500, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        new DecisionExecutor(decisionLog, IERC20(address(0)), guardian, 8_500, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), address(0), 8_500, 2 days, 2, 10e6, 20e6);
    }

    function test_bindBoardIsGuardianOnlyAndRejectsZero() public {
        DecisionExecutor fresh =
            new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.NotGuardian.selector);
        fresh.bindBoard(board);
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        fresh.bindBoard(TaskBoard(address(0)));
    }

    function test_queueAnnouncesAndNumbersChanges() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), data), YES, 9_000);
        vm.expectEmit(true, true, true, true, address(executor));
        emit Queued(1, d, address(board), data, uint64(block.timestamp + 2 days));
        vm.prank(brain);
        assertEq(executor.queue(d, address(board), data), 1);
        assertEq(_adopt(address(board), data, 9_000), 2);
        assertEq(executor.changeCount(), 2);

        DecisionExecutor.Change memory change = executor.getChange(1);
        assertEq(change.target, address(board));
        assertEq(change.data, data);
        assertEq(change.eta, block.timestamp + 2 days);
    }

    function test_aDecisionQueuesOnlyOnce() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 d = decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), data), YES, 9_000);
        vm.startPrank(brain);
        executor.queue(d, address(board), data);
        vm.expectRevert(DecisionExecutor.DecisionUsed.selector);
        executor.queue(d, address(board), data);
        vm.stopPrank();
    }

    function test_queueRejectsZeroTargetAndAcceptsExactThreshold() public {
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        executor.queue(1, address(0), "");
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        _adopt(address(board), data, 8_500);
    }

    function test_executeRunsExactlyAtTheEtaAndAnnounces() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 changeId = _adopt(address(board), data, 9_000);
        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(DecisionExecutor.NotReady.selector);
        executor.execute(changeId);
        vm.warp(block.timestamp + 1);
        vm.expectEmit(true, false, false, false, address(executor));
        emit Executed(changeId);
        executor.execute(changeId);
        assertTrue(board.paused());
        assertTrue(executor.getChange(changeId).executed);
    }

    function test_executeAndVetoRejectUnknownChanges() public {
        vm.expectRevert(DecisionExecutor.UnknownChange.selector);
        executor.execute(7);
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.UnknownChange.selector);
        executor.veto(7);
    }

    function test_vetoAnnouncesAndCannotRepeatOrFollowExecution() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        uint256 vetoed = _adopt(address(board), data, 9_000);
        vm.prank(guardian);
        vm.expectEmit(true, false, false, false, address(executor));
        emit Vetoed(vetoed);
        executor.veto(vetoed);
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.Closed.selector);
        executor.veto(vetoed);
        assertTrue(executor.vetoedCall(keccak256(abi.encode(address(board), data))));

        // v2 let the brain record a fresh decision and queue the vetoed call again.
        uint256 again = decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), data), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.VetoedCall.selector);
        executor.queue(again, address(board), data);

        uint256 executed = _adopt(address(board), abi.encodeCall(TaskBoard.setPaused, (false)), 9_000);
        vm.warp(block.timestamp + 2 days);
        executor.execute(executed);
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.Closed.selector);
        executor.veto(executed);
    }

    function test_failedCallRevertsTheExecution() public {
        // A fee above the 10% cap: queued like any change, reverted by the board when executed.
        bytes memory data = abi.encodeCall(TaskBoard.setFee, (2_000, makeAddr("router")));
        uint256 changeId = _adopt(address(board), data, 9_000);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        executor.execute(changeId);
        assertFalse(executor.getChange(changeId).executed);
    }

    function test_houseTasksAnnounceResetApprovalAndResetDaily() public {
        usdg.mint(address(executor), 100e6);
        vm.warp(10 days);
        vm.startPrank(brain);
        vm.expectEmit(true, false, false, true, address(executor));
        emit HouseTaskPosted(1, BOUNTY);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        assertEq(usdg.allowance(address(executor), address(board)), 0);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.expectRevert(DecisionExecutor.HouseCapReached.selector);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");

        // Still the same UTC day one second before midnight.
        vm.warp(11 days - 1);
        vm.expectRevert(DecisionExecutor.HouseCapReached.selector);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.warp(11 days);
        executor.postHouseTask(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.stopPrank();
        assertEq(executor.houseTasksOnDay(11), 1);
    }

    /// v2 let a change replace the guardian, so the brain could remove the key that vetoes it.
    function test_guardianChangesOnlyThroughTheAdmin() public {
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.NotAdmin.selector);
        executor.setGuardian(poster);

        address next = makeAddr("next-guardian");
        bytes memory data = abi.encodeCall(DecisionExecutor.setGuardian, (next));
        uint256 d = decide(DecisionLog.Kind.Change, executor.changeSubject(address(executor), data), YES, 9_900);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
        executor.queue(d, address(executor), data);
        bytes memory boardData = abi.encodeCall(TaskBoard.setGuardian, (next));
        d = decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), boardData), YES, 9_900);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
        executor.queue(d, address(board), boardData);

        // The admin is the DecisionLog's owner (this test contract in the setup).
        vm.expectEmit(true, false, false, false, address(executor));
        emit GuardianSet(next);
        executor.setGuardian(next);
        assertEq(executor.guardian(), next);
        assertEq(board.guardian(), next);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        executor.setGuardian(address(0));
    }

    function test_treasuryTransferRunsThroughAChange() public {
        usdg.mint(address(executor), 10e6);
        executor.execute(_ready(address(executor), abi.encodeCall(DecisionExecutor.transfer, (poster, 4e6))));
        assertEq(usdg.balanceOf(poster), 1_000e6 + 4e6);

        uint256 changeId = _adopt(address(executor), abi.encodeCall(DecisionExecutor.transfer, (address(0), 1)), 9_000);
        vm.warp(block.timestamp + executor.timelock());
        vm.expectRevert();
        executor.execute(changeId);
    }

    function test_parameterBoundsAreExact() public {
        uint256 paramsChange =
            _ready(address(executor), abi.encodeCall(DecisionExecutor.setParameters, (10_000, 1 hours, 3, 10e6, 20e6)));
        vm.expectEmit(false, false, false, true, address(executor));
        emit ParametersSet(10_000, 1 hours, 3, 10e6, 20e6);
        executor.execute(paramsChange);
        assertEq(executor.timelock(), 1 hours);
        assertEq(executor.maxHouseBounty(), 10e6);
        assertEq(executor.houseSpendPerDay(), 20e6);

        vm.expectRevert(DecisionExecutor.BadConfig.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 30 days + 1, 2, 10e6, 20e6);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 30 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.BadConfig.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, 2, 20e6 + 1, 20e6);

        vm.expectRevert(DecisionExecutor.BadConfig.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 10_001, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.BadConfig.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 4_999, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.BadConfig.selector);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 1 hours - 1, 2, 10e6, 20e6);
        new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 5_000, 1 hours, 2, 10e6, 20e6);
    }

    function test_unboundExecutorRejectsAZeroGuardian() public {
        DecisionExecutor fresh =
            new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, 2, 10e6, 20e6);
        vm.expectRevert(DecisionExecutor.ZeroAddress.selector);
        fresh.setGuardian(address(0));
    }
}

contract TaskBoardCoverage is BrainChainSetup {
    event Posted(
        uint256 indexed id, address indexed poster, uint128 bounty, uint64 deadline, bytes32 briefHash, string briefURI
    );
    event WorkerHired(uint256 indexed id, bytes32 indexed model, uint256 indexed decisionId);
    event HireHeld(uint256 indexed id, uint256 indexed decisionId);
    event WorkSubmitted(uint256 indexed id, bytes32 indexed model, bytes32 resultHash, string resultURI);
    event WorkGraded(uint256 indexed id, uint256 indexed decisionId, bool accepted);
    event GradeDisputed(uint256 indexed id, address indexed opener);
    event Ruled(uint256 indexed id, uint256 indexed decisionId, bool paid, bool confident);
    event BountyPaid(uint256 indexed id, bytes32 indexed model, address indexed account, uint128 bounty, uint128 fee);
    event BountyRefunded(uint256 indexed id, address indexed poster, uint128 amount, TaskBoard.RefundReason reason);
    event PausedSet(bool paused);
    event ConfigSet(TaskBoard.Config config);
    event OwnerSet(address indexed owner);
    event GuardianSet(address indexed guardian);

    function test_constructorRejectsEveryZeroAddress() public {
        TaskBoard.Config memory c = defaultConfig();
        IERC20 t = IERC20(address(usdg));
        WorkerStaking none = WorkerStaking(address(0));
        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        new TaskBoard(IERC20(address(0)), decisionLog, registry, none, address(this), guardian, c);
        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        new TaskBoard(t, DecisionLog(address(0)), registry, none, address(this), guardian, c);
        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        new TaskBoard(t, decisionLog, ModelRegistry(address(0)), none, address(this), guardian, c);
        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        new TaskBoard(t, decisionLog, registry, none, address(0), guardian, c);
        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        new TaskBoard(t, decisionLog, registry, none, address(this), address(0), c);
    }

    function test_constructorAnnouncesOwnerAndGuardian() public {
        vm.expectEmit(true, false, false, false);
        emit OwnerSet(address(this));
        vm.expectEmit(true, false, false, false);
        emit GuardianSet(guardian);
        new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(this),
            guardian,
            defaultConfig()
        );
    }

    function test_postStoresAndAnnouncesTheTask() public {
        uint64 deadline = uint64(block.timestamp + DAY);
        vm.expectEmit(true, true, false, true, address(board));
        emit Posted(1, poster, BOUNTY, deadline, keccak256("brief"), "ipfs://brief");
        uint256 id = postTask();
        TaskBoard.Task memory task = board.get(id);
        assertEq(task.briefHash, keccak256("brief"));
        assertEq(task.deadline, deadline);
        assertEq(task.bounty, BOUNTY);
        assertEq(task.poster, poster);
    }

    function test_postRejectsAShortTransfer() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        TaskBoard fotBoard = new TaskBoard(
            IERC20(address(fot)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(this),
            guardian,
            defaultConfig()
        );
        fot.mint(poster, 100e6);
        vm.startPrank(poster);
        fot.approve(address(fotBoard), type(uint256).max);
        vm.expectRevert(TaskBoard.TransferMismatch.selector);
        fotBoard.post(BOUNTY, uint64(block.timestamp + DAY), 0, "");
        vm.stopPrank();
    }

    function test_everyStepAnnouncesAndRecordsItsTime() public {
        uint256 id = postTask();

        uint256 held = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 1_000);
        vm.expectEmit(true, true, false, false, address(board));
        emit HireHeld(id, held);
        vm.prank(brain);
        board.hire(id, held);

        uint256 hire = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        vm.expectEmit(true, true, true, false, address(board));
        emit WorkerHired(id, CLAUDE, hire);
        vm.prank(brain);
        board.hire(id, hire);

        vm.warp(block.timestamp + 10);
        vm.expectEmit(true, true, false, true, address(board));
        emit WorkSubmitted(id, CLAUDE, keccak256("result"), "ipfs://result");
        deliver(id);
        assertEq(board.get(id).resultHash, keccak256("result"));
        assertEq(board.get(id).submittedAt, block.timestamp);

        vm.warp(block.timestamp + 10);
        uint256 grade = decide(DecisionLog.Kind.Grade, board.subjectOf(id), NO, 9_000);
        vm.expectEmit(true, true, false, true, address(board));
        emit WorkGraded(id, grade, false);
        vm.prank(brain);
        board.grade(id, grade);
        assertEq(board.get(id).gradedAt, block.timestamp);

        vm.warp(block.timestamp + 10);
        vm.expectEmit(true, true, false, false, address(board));
        emit GradeDisputed(id, claudeAccount);
        vm.prank(claudeAccount);
        board.dispute(id);
        assertTrue(board.get(id).disputed);
        assertEq(board.get(id).disputedAt, block.timestamp);

        uint256 ruling = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.expectEmit(true, true, false, true, address(board));
        emit Ruled(id, ruling, true, true);
        vm.expectEmit(true, true, true, true, address(board));
        emit BountyPaid(id, CLAUDE, claudeAccount, BOUNTY, 0);
        vm.prank(brain);
        board.rule(id, ruling);
    }

    function test_refundIsAnnounced() public {
        uint256 id = postTask();
        vm.warp(block.timestamp + DAY + 1);
        vm.expectEmit(true, true, false, true, address(board));
        emit BountyRefunded(id, poster, BOUNTY, TaskBoard.RefundReason.NotHired);
        board.finalize(id);
    }

    function test_stepsRejectTheWrongStatus() public {
        uint256 id = postTask();
        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.submit(id, 0, "");

        uint256 g = decide(DecisionLog.Kind.Grade, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.grade(id, g);

        uint256 r = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.rule(id, r);

        vm.prank(poster);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.dispute(id);

        hireClaude(id);
        uint256 h = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.hire(id, h);
    }

    function test_hireClosesAtTheDeadline() public {
        uint256 id = postTask();
        vm.warp(board.get(id).deadline);
        uint256 d = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.hire(id, d);
    }

    function test_gradeWindowBoundaryIsInclusive() public {
        uint256 id = postTask();
        hireClaude(id);
        uint256 t1 = block.timestamp + 100;
        vm.warp(t1);
        deliver(id);
        vm.warp(t1 + 6 hours);
        gradeAs(id, YES, 9_000);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Graded));
    }

    function test_finalizeWindowsAreExact() public {
        uint256 submitted = postTask();
        hireClaude(submitted);
        uint256 t2 = block.timestamp + 100;
        vm.warp(t2);
        deliver(submitted);
        vm.warp(t2 + 6 hours);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(submitted);
        vm.warp(t2 + 6 hours + 1);
        board.finalize(submitted);

        uint256 graded = postTask();
        hireClaude(graded);
        deliver(graded);
        uint256 t3 = block.timestamp + 100;
        vm.warp(t3);
        gradeAs(graded, YES, 9_000);
        vm.warp(t3 + 1 hours);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(graded);
        vm.warp(t3 + 1 hours + 1);
        board.finalize(graded);
    }

    function test_disputeAndRuleWindowsAreExact() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        uint256 t4 = block.timestamp + 100;
        vm.warp(t4);
        gradeAs(id, NO, 9_000);
        vm.warp(t4 + 1 hours);
        vm.prank(claudeAccount);
        board.dispute(id);

        vm.warp(t4 + 1 hours + 6 hours);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        uint256 r = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), NO, 9_000);
        vm.prank(brain);
        board.rule(id, r);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Refunded));
    }

    function test_ruleClosesAfterItsWindow() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, NO, 9_000);
        vm.prank(poster);
        board.dispute(id);
        vm.warp(block.timestamp + 6 hours + 1);
        uint256 r = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.rule(id, r);
    }

    function test_adminChangesAreGuardedAndAnnounced() public {
        vm.prank(address(executor));
        vm.expectEmit(false, false, false, true, address(board));
        emit PausedSet(true);
        board.setPaused(true);

        vm.expectRevert(TaskBoard.NotGuardian.selector);
        board.setPaused(false);

        vm.startPrank(address(executor));
        vm.expectEmit(false, false, false, true, address(board));
        emit ConfigSet(defaultConfig());
        board.setConfig(defaultConfig());

        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        board.setGuardian(address(0));
        vm.expectEmit(true, false, false, false, address(board));
        emit GuardianSet(poster);
        board.setGuardian(poster);

        vm.expectRevert(TaskBoard.ZeroAddress.selector);
        board.setOwner(address(0));
        vm.expectEmit(true, false, false, false, address(board));
        emit OwnerSet(poster);
        board.setOwner(poster);
        vm.stopPrank();

        vm.expectRevert(TaskBoard.NotOwner.selector);
        board.setOwner(address(this));
        vm.expectRevert(TaskBoard.NotOwner.selector);
        board.setGuardian(address(this));
    }
}

contract ModelRegistryCoverage is BrainChainSetup {
    function test_setModelIsOwnerOnlyAndRejectsZeroes() public {
        vm.prank(poster);
        vm.expectRevert(ModelRegistry.NotOwner.selector);
        registry.setModel(CLAUDE, claudeAccount, 1, true);
        vm.expectRevert(ModelRegistry.ZeroAddress.selector);
        registry.setModel(bytes32(0), claudeAccount, 1, true);
        vm.expectRevert(ModelRegistry.ZeroAddress.selector);
        registry.setModel(CLAUDE, address(0), 1, true);
    }

    function test_updatingAModelKeepsOneIdAndUnknownModelsRevert() public {
        assertEq(registry.ids().length, 2);
        registry.setModel(CLAUDE, makeAddr("new-claude"), 0.5e6, false);
        assertEq(registry.ids().length, 2);
        ModelRegistry.Model memory m = registry.get(CLAUDE);
        assertEq(m.account, makeAddr("new-claude"));
        assertFalse(m.active);
        vm.expectRevert(ModelRegistry.UnknownModel.selector);
        registry.get(keccak256("nobody"));
    }

    function test_setOwnerIsOwnerOnlyAndRejectsZero() public {
        vm.prank(poster);
        vm.expectRevert(ModelRegistry.NotOwner.selector);
        registry.setOwner(poster);
        vm.expectRevert(ModelRegistry.ZeroAddress.selector);
        registry.setOwner(address(0));
        registry.setOwner(poster);
        assertEq(registry.owner(), poster);
    }
}
