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
    uint256 public paidWithoutAcceptedGrade;
    mapping(uint256 => bool) public everAccepted;

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
    }

    function _pick(uint256 seed) private view returns (uint256) {
        return ids[seed % ids.length];
    }

    function _decide(DecisionLog.Kind kind, uint256 id, bytes32 answer, uint16 confidence) private returns (uint256) {
        vm.prank(brain);
        return decisionLog.record(kind, bytes32(id), 0, answer, confidence, 0, "");
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
            _afterSettle(id, true);
        } catch {}
    }

    function finalize(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _pick(seed);
        try board.finalize(id) {
            _afterSettle(id, false);
        } catch {}
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    function _afterSettle(uint256 id, bool ruled) private {
        TaskBoard.Task memory task = board.get(id);
        openSum -= task.bounty;
        // A payout needs an accepted grade, or a ruling (which has its own threshold).
        if (task.status == TaskBoard.Status.Paid && !ruled && !everAccepted[id]) paidWithoutAcceptedGrade += 1;
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
        handler = new TaskBoardHandler(board, decisionLog, usdg, brain, modelIds, accounts);
        targetContract(address(handler));
    }

    function invariant_boardHoldsExactlyTheUnsettledBounties() public view {
        assertEq(usdg.balanceOf(address(board)), handler.openSum());
    }

    function invariant_noPayoutWithoutAnAcceptedGradeOrRuling() public view {
        assertEq(handler.paidWithoutAcceptedGrade(), 0);
    }
}
