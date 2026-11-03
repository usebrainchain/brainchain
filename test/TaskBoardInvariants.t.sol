// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {MockERC20} from "./MockERC20.sol";

contract TaskBoardHandler is Test {
    bytes32 internal constant YES = bytes32(uint256(1));

    TaskBoard public immutable board;
    DecisionLog public immutable decisionLog;
    MockERC20 public immutable usdg;
    address public immutable brain;
    address public immutable poster;
    bytes32[2] public modelIds;
    address[2] public accounts;

    uint256[] public ids;
    uint256 public openSum;
    uint256 public bondSum;
    uint256 public appealsOpened;
    uint256 public appealsRuled;
    uint256 public paidWithoutAcceptedGrade;
    mapping(uint256 => bool) public everAccepted;
    /// A ruling, first or on appeal, decided to pay.
    mapping(uint256 => bool) public ruledToPay;

    constructor(
        TaskBoard board_,
        DecisionLog log_,
        MockERC20 usdg_,
        address brain_,
        bytes32[2] memory ids_,
        address[2] memory accounts_
    ) {
        board = board_;
        decisionLog = log_;
        usdg = usdg_;
        brain = brain_;
        modelIds = ids_;
        accounts = accounts_;
        poster = makeAddr("inv-poster");
        usdg.mint(poster, type(uint128).max);
        vm.prank(poster);
        usdg.approve(address(board), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            usdg.mint(accounts_[i], type(uint128).max);
            vm.prank(accounts_[i]);
            usdg.approve(address(board), type(uint256).max);
        }
    }

    function _pick(uint256 seed) private view returns (uint256) {
        return ids[seed % ids.length];
    }

    /// The first task from `seed` on in `status`, or zero: appeals need a task at the right step.
    function _find(uint256 seed, TaskBoard.Status status) private view returns (uint256) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[(seed % ids.length + i) % ids.length];
            if (board.get(id).status == status) return id;
        }
        return 0;
    }

    function _decide(DecisionLog.Kind kind, uint256 id, bytes32 answer, uint16 confidence) private returns (uint256) {
        bytes32 subject = board.subjectOf(id);
        vm.prank(brain);
        return decisionLog.record(kind, subject, 0, answer, confidence, 0, "");
    }

    function post(uint128 bounty, uint64 duration) external {
        bounty = uint128(bound(bounty, 1e6, 1_000_000e6));
        duration = uint64(bound(duration, 1 hours, 7 days));
        vm.prank(poster);
        uint256 id = board.post(bounty, uint64(block.timestamp) + duration, 0, "");
        ids.push(id);
        openSum += bounty;
    }

    function hire(uint256 seed, uint256 modelSeed, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        uint256 d = _decide(DecisionLog.Kind.Hire, id, modelIds[modelSeed % 2], uint16(bound(confidence, 0, 10_000)));
        vm.prank(brain);
        try board.hire(id, d) {} catch {}
    }

    function submit(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        TaskBoard.Task memory task = board.get(id);
        address account = task.model == modelIds[0] ? accounts[0] : accounts[1];
        vm.prank(account);
        try board.submit(id, keccak256("r"), "") {} catch {}
    }

    /// A task runs to its grade in one go: posted, hired, delivered and graded.
    function deliver(uint128 bounty, uint256 model, bool yes, uint16 confidence) external {
        bounty = uint128(bound(bounty, 1e6, 1_000_000e6));
        vm.prank(poster);
        uint256 id = board.post(bounty, uint64(block.timestamp) + 1 days, 0, "");
        ids.push(id);
        openSum += bounty;
        uint256 d = _decide(DecisionLog.Kind.Hire, id, modelIds[model % 2], 10_000);
        vm.prank(brain);
        board.hire(id, d);
        vm.prank(accounts[model % 2]);
        board.submit(id, keccak256("r"), "");
        d = _decide(DecisionLog.Kind.Grade, id, yes ? YES : bytes32(0), uint16(bound(confidence, 0, 10_000)));
        vm.prank(brain);
        board.grade(id, d);
        if (board.get(id).accepted) everAccepted[id] = true;
    }

    /// A task runs to its first ruling in one go, so appeals have rulings to work on.
    function disputeAndRule(uint128 bounty, uint256 model, bool yes, bool asPoster, bool pay, uint16 confidence)
        external
    {
        this.deliver(bounty, model, yes, 9_000);
        uint256 id = ids[ids.length - 1];
        vm.prank(asPoster ? poster : accounts[model % 2]);
        board.dispute(id);
        this.rule(ids.length - 1, pay, confidence);
    }

    function grade(uint256 seed, bool yes, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        uint256 d = _decide(DecisionLog.Kind.Grade, id, yes ? YES : bytes32(0), uint16(bound(confidence, 0, 10_000)));
        vm.prank(brain);
        try board.grade(id, d) {
            if (board.get(id).accepted) everAccepted[id] = true;
        } catch {}
    }

    function dispute(uint256 seed, bool asPoster) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        TaskBoard.Task memory task = board.get(id);
        vm.prank(asPoster ? poster : (task.model == modelIds[0] ? accounts[0] : accounts[1]));
        try board.dispute(id) {} catch {}
    }

    function rule(uint256 seed, bool pay, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        uint256 d = _decide(DecisionLog.Kind.Ruling, id, pay ? YES : bytes32(0), uint16(bound(confidence, 0, 10_000)));
        vm.prank(brain);
        try board.rule(id, d) {
            TaskBoard.Task memory task = board.get(id);
            if (task.status == TaskBoard.Status.Ruled) ruledToPay[id] = board.appealOf(id).pays;
            else ruledToPay[id] = task.status == TaskBoard.Status.Paid;
            _afterSettle(id);
        } catch {}
    }

    function appeal(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _find(seed, TaskBoard.Status.Ruled);
        if (id == 0) return;
        TaskBoard.Task memory task = board.get(id);
        vm.prank(board.appealOf(id).pays ? poster : task.payee);
        try board.appeal(id) {
            bondSum += board.appealOf(id).bond;
            appealsOpened += 1;
        } catch {}
    }

    function ruleAppeal(uint256 seed, bool pay, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _find(seed, TaskBoard.Status.Appealed);
        if (id == 0) return;
        uint256 d = _decide(DecisionLog.Kind.Ruling, id, pay ? YES : bytes32(0), uint16(bound(confidence, 0, 10_000)));
        vm.prank(brain);
        try board.ruleAppeal(id, d) {
            bondSum -= board.appealOf(id).bond;
            appealsRuled += 1;
            ruledToPay[id] = board.get(id).status == TaskBoard.Status.Paid;
            _afterSettle(id);
        } catch {}
    }

    function finalize(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        bool appealed = board.get(id).status == TaskBoard.Status.Appealed;
        try board.finalize(id) {
            if (appealed) bondSum -= board.appealOf(id).bond;
            _afterSettle(id);
        } catch {}
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    function _afterSettle(uint256 id) private {
        TaskBoard.Task memory task = board.get(id);
        if (task.status != TaskBoard.Status.Paid && task.status != TaskBoard.Status.Refunded) return;
        openSum -= task.bounty;
        // A payout needs an accepted grade, or a ruling (which has its own threshold).
        if (task.status == TaskBoard.Status.Paid && !ruledToPay[id] && !everAccepted[id]) {
            paidWithoutAcceptedGrade += 1;
        }
    }
}

contract TaskBoardInvariants is StdInvariant, Test {
    TaskBoard internal board;
    MockERC20 internal usdg;
    TaskBoardHandler internal handler;

    function setUp() public {
        address brain = makeAddr("brain");
        usdg = new MockERC20();
        DecisionLog decisionLog = new DecisionLog(address(this), brain);
        ModelRegistry registry = new ModelRegistry(address(this));
        bytes32[2] memory modelIds = [keccak256("claude"), keccak256("gpt")];
        address[2] memory accounts = [makeAddr("claude"), makeAddr("gpt")];
        registry.setModel(modelIds[0], accounts[0], 1, true);
        registry.setModel(modelIds[1], accounts[1], 1, true);
        board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(this),
            makeAddr("guardian"),
            TaskBoard.Config({
                hireThresholdBps: 7_000,
                gradeThresholdBps: 7_000,
                ruleThresholdBps: 7_000,
                minDuration: 1 hours,
                maxDuration: 7 days,
                gradeWindow: 6 hours,
                disputeWindow: 1 hours,
                ruleWindow: 6 hours,
                minBounty: 1e6
            })
        );
        board.setAppealConfig(TaskBoard.AppealConfig({window: 1 days, bondBps: 2_500}));
        handler = new TaskBoardHandler(board, decisionLog, usdg, brain, modelIds, accounts);
        targetContract(address(handler));
    }

    function invariant_boardHoldsExactlyTheUnsettledBountiesAndBonds() public view {
        assertEq(usdg.balanceOf(address(board)), handler.openSum() + handler.bondSum());
    }

    /// The handler reaches the appeal steps the invariants are meant to cover.
    function test_handlerAppealsAndRulesAgain() public {
        handler.disputeAndRule(5e6, 0, false, false, false, 9_000);
        handler.appeal(0);
        handler.ruleAppeal(0, true, 9_000);
        assertEq(handler.appealsOpened(), 1);
        assertEq(handler.appealsRuled(), 1);
        invariant_boardHoldsExactlyTheUnsettledBountiesAndBonds();
        invariant_noPayoutWithoutAnAcceptedGradeOrRuling();
    }

    function invariant_noPayoutWithoutAnAcceptedGradeOrRuling() public view {
        assertEq(handler.paidWithoutAcceptedGrade(), 0);
    }
}
