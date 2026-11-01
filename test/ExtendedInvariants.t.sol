// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {MockERC20} from "./MockERC20.sol";

/// Fees on and changing mid-flight, live config changes, payee rotation, two
/// posters, house tasks through the executor, and a staked worker that disputes
/// and gets slashed.
contract ExtendedHandler is Test {
    bytes32 constant YES = bytes32(uint256(1));

    TaskBoard public board;
    DecisionLog public decisionLog;
    MockERC20 public usdg;
    ModelRegistry public registry;
    DecisionExecutor public executor;
    WorkerStaking public staking;
    address public brain;
    address public feeTo;
    address[2] public posters;
    bytes32[3] public workerIds;
    address[4] public payees;
    uint256[] public ids;

    uint256 public openSum;
    uint256 public posted;
    uint256 public settledGross;
    uint256 public doubleSettle;
    uint256 public expectedFees;
    uint256 public payeeMismatch;
    mapping(uint256 => uint256) public settledTimes;
    mapping(uint256 => address) public submitter;

    constructor(
        TaskBoard board_,
        DecisionLog decisionLog_,
        MockERC20 usdg_,
        ModelRegistry registry_,
        DecisionExecutor executor_,
        WorkerStaking staking_,
        address brain_,
        address feeTo_,
        address[4] memory payees_,
        bytes32 stakedId
    ) {
        board = board_;
        decisionLog = decisionLog_;
        usdg = usdg_;
        registry = registry_;
        executor = executor_;
        staking = staking_;
        brain = brain_;
        feeTo = feeTo_;
        payees = payees_;
        posters = [makeAddr("p0"), makeAddr("p1")];
        workerIds = [keccak256("claude"), keccak256("gpt"), stakedId];
        for (uint256 i; i < 2; i++) {
            usdg_.mint(posters[i], type(uint96).max);
            vm.prank(posters[i]);
            usdg_.approve(address(board_), type(uint256).max);
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 n = ids.length < 3 ? ids.length : 3;
        return ids[ids.length - 1 - (seed % n)];
    }

    function _decide(DecisionLog.Kind kind, uint256 id, bytes32 answer, uint16 confidence) internal returns (uint256) {
        bytes32 subject = board.subjectOf(id);
        uint16 bps = uint16(bound(confidence, 0, 10_000));
        vm.prank(brain);
        return decisionLog.record(kind, subject, 0, answer, bps, 0, "");
    }

    function _account(bytes32 model) internal view returns (address) {
        if (model == bytes32(0)) return address(0);
        if (staking.isWorkerId(model)) return address(uint160(uint256(model)));
        return registry.get(model).account;
    }

    function post(uint128 bounty, uint64 duration, bool second) external {
        bounty = uint128(bound(bounty, 1e6, 1e12));
        (,,, uint64 minD, uint64 maxD,,,,) = board.config();
        duration = uint64(bound(duration, minD, maxD));
        vm.prank(posters[second ? 1 : 0]);
        try board.post(bounty, uint64(block.timestamp) + duration, 0, "") returns (uint256 id) {
            ids.push(id);
            openSum += bounty;
            posted += bounty;
        } catch {}
    }

    function houseTask(uint128 bounty) external {
        bounty = uint128(bound(bounty, 1e6, 1e10));
        usdg.mint(address(executor), bounty);
        (,,, uint64 minD,,,,,) = board.config();
        vm.prank(brain);
        try executor.postHouseTask(bounty, uint64(block.timestamp) + minD + 1, 0, "") returns (uint256 id) {
            ids.push(id);
            openSum += bounty;
            posted += bounty;
        } catch {}
    }

    function hire(uint256 seed, uint256 model, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        uint256 d = _decide(DecisionLog.Kind.Hire, id, workerIds[model % 3], confidence);
        vm.prank(brain);
        try board.hire(id, d) {} catch {}
    }

    function submit(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        address account = _account(board.get(id).model);
        if (account == address(0)) return;
        vm.prank(account);
        try board.submit(id, keccak256("r"), "") {
            submitter[id] = account;
        } catch {}
    }

    /// A task runs to its grade in one go: posted, hired, delivered and graded.
    function deliver(uint128 bounty, uint256 model, bool yes, uint16 confidence) external {
        bounty = uint128(bound(bounty, 1e6, 1e12));
        vm.prank(posters[model % 2]);
        try board.post(bounty, uint64(block.timestamp) + 1 days, 0, "") returns (uint256 id) {
            ids.push(id);
            openSum += bounty;
            posted += bounty;
            uint256 d = _decide(DecisionLog.Kind.Hire, id, workerIds[model % 3], 10_000);
            vm.prank(brain);
            try board.hire(id, d) {}
            catch {
                return;
            }
            address account = _account(workerIds[model % 3]);
            vm.prank(account);
            board.submit(id, keccak256("r"), "");
            submitter[id] = account;
            d = _decide(DecisionLog.Kind.Grade, id, yes ? YES : bytes32(0), confidence);
            vm.prank(brain);
            board.grade(id, d);
        } catch {}
    }

    function grade(uint256 seed, bool yes, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        uint256 d = _decide(DecisionLog.Kind.Grade, id, yes ? YES : bytes32(0), confidence);
        vm.prank(brain);
        try board.grade(id, d) {} catch {}
    }

    function dispute(uint256 seed, bool byPoster) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        TaskBoard.Task memory t = board.get(id);
        address who = byPoster ? t.poster : t.payee;
        if (who == address(0)) return;
        vm.prank(who);
        try board.dispute(id) {} catch {}
    }

    function rule(uint256 seed, bool yes, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        uint256 d = _decide(DecisionLog.Kind.Ruling, id, yes ? YES : bytes32(0), confidence);
        vm.prank(brain);
        try board.rule(id, d) {
            _settled(id);
        } catch {}
    }

    function finalize(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        try board.finalize(id) {
            _settled(id);
        } catch {}
    }

    function setFee(uint16 bps) external {
        vm.prank(address(executor));
        board.setFee(uint16(bound(bps, 0, 1_000)), feeTo);
    }

    function setWindows(uint64 g, uint64 d, uint64 r, uint16 gradeBps) external {
        TaskBoard.Config memory c = TaskBoard.Config(
            1_500,
            uint16(bound(gradeBps, 0, 10_000)),
            7_000,
            30 minutes,
            3 days,
            uint64(bound(g, 1, 2 days)),
            uint64(bound(d, 1, 2 days)),
            uint64(bound(r, 1, 2 days)),
            1e6
        );
        vm.prank(address(executor));
        board.setConfig(c);
    }

    function rotate(uint256 model, uint256 payee) external {
        vm.prank(address(executor));
        registry.setModel(workerIds[model % 2], payees[payee % 4], 1, true);
    }

    function pause(bool paused) external {
        vm.prank(address(executor));
        board.setPaused(paused);
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 1 days));
    }

    function _settled(uint256 id) internal {
        TaskBoard.Task memory t = board.get(id);
        openSum -= t.bounty;
        settledGross += t.bounty;
        if (++settledTimes[id] > 1) doubleSettle++;
        if (t.status == TaskBoard.Status.Paid) {
            expectedFees += (uint256(t.bounty) * t.feeBps) / 10_000;
            if (t.payee != submitter[id]) payeeMismatch++;
        }
    }

    /// Hired, submitted, graded or disputed tasks of the staked worker.
    function stakedInFlight() external view returns (uint256 n) {
        for (uint256 i; i < ids.length; i++) {
            TaskBoard.Task memory t = board.get(ids[i]);
            if (
                t.model == workerIds[2] && t.status != TaskBoard.Status.Paid && t.status != TaskBoard.Status.Refunded
                    && t.status != TaskBoard.Status.Open
            ) n++;
        }
    }
}

contract ExtendedInvariants is StdInvariant, Test {
    ExtendedHandler internal h;
    MockERC20 internal usdg;
    TaskBoard internal board;
    DecisionExecutor internal executor;
    WorkerStaking internal staking;
    address internal feeTo = makeAddr("fee-to");
    address internal stakedWorker = makeAddr("staked");

    function setUp() public {
        address brain = makeAddr("brain");
        address guardian = makeAddr("guardian");
        usdg = new MockERC20();
        MockERC20 brainToken = new MockERC20();
        DecisionLog decisionLog = new DecisionLog(address(this), brain);
        ModelRegistry registry = new ModelRegistry(address(this));
        address[4] memory payees = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        registry.setModel(keccak256("claude"), payees[0], 1, true);
        registry.setModel(keccak256("gpt"), payees[1], 1, true);
        executor = new DecisionExecutor(
            decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 days, type(uint32).max, 1e10, 1e15
        );
        staking = new WorkerStaking(IERC20(address(brainToken)), address(this), 500e18, 3 days, 2_000);
        board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            staking,
            address(executor),
            guardian,
            TaskBoard.Config(1_500, 7_000, 7_000, 30 minutes, 3 days, 6 hours, 6 hours, 6 hours, 1e6)
        );
        vm.prank(guardian);
        executor.bindBoard(board);
        staking.setSlasher(address(board));
        registry.setOwner(address(executor));
        vm.prank(address(executor));
        board.setWorkerAllowed(stakedWorker, true);
        brainToken.mint(stakedWorker, 1e30);
        vm.startPrank(stakedWorker);
        brainToken.approve(address(staking), type(uint256).max);
        staking.stake(1e24, 0);
        vm.stopPrank();

        h = new ExtendedHandler(
            board, decisionLog, usdg, registry, executor, staking, brain, feeTo, payees, staking.idOf(stakedWorker)
        );
        targetContract(address(h));
    }

    function invariant_boardHoldsExactlyTheOpenEscrows() public view {
        assertEq(usdg.balanceOf(address(board)), h.openSum());
    }

    function invariant_moneyIsConserved() public view {
        assertEq(h.posted(), h.openSum() + h.settledGross());
    }

    function invariant_nothingSettlesTwice() public view {
        assertEq(h.doubleSettle(), 0);
    }

    function invariant_feesFollowEachTasksTerms() public view {
        assertEq(usdg.balanceOf(feeTo), h.expectedFees());
    }

    function invariant_paysTheAccountThatSubmitted() public view {
        assertEq(h.payeeMismatch(), 0);
    }

    function invariant_stakeIsHeldForEveryTaskInFlight() public view {
        assertEq(staking.held(stakedWorker), h.stakedInFlight());
    }

    function invariant_houseSpendStaysUnderTheCap() public view {
        assertLe(executor.houseSpentOnDay(block.timestamp / 1 days), executor.houseSpendPerDay());
    }
}
