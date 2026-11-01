// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {MockERC20} from "./MockERC20.sol";

/// Three staked workers stake, unstake and withdraw while the brain hires,
/// grades and rules on their tasks; workers and posters dispute, so a worker
/// that disputes and loses gets slashed by the board. The admin retunes the
/// stake minimum, cooldown and slash share mid-flight, and everyone but the
/// board tries to slash.
contract StakingHandler is Test {
    bytes32 internal constant YES = bytes32(uint256(1));

    WorkerStaking public immutable staking;
    TaskBoard public immutable board;
    DecisionLog public immutable decisionLog;
    MockERC20 public immutable token;
    address public immutable admin;
    address public immutable brain;
    address public immutable poster;
    address[3] public workers;
    uint256[] public ids;

    uint256 public cooldown;
    uint256 public slashBps;
    uint256 public burned;
    uint256 public slashes;
    uint256 public slashOffShare;
    uint256 public straySlash;
    uint256 public badWithdraw;
    uint256 public withdrawals;

    mapping(address => uint256) public staked;
    mapping(address => uint256) public unstaking;
    mapping(address => uint256) public unlocksAt;

    constructor(
        WorkerStaking staking_,
        TaskBoard board_,
        DecisionLog decisionLog_,
        MockERC20 token_,
        MockERC20 usdg,
        address admin_,
        address brain_,
        address[3] memory workers_
    ) {
        staking = staking_;
        board = board_;
        decisionLog = decisionLog_;
        token = token_;
        admin = admin_;
        brain = brain_;
        workers = workers_;
        cooldown = staking_.cooldown();
        slashBps = staking_.slashBps();
        poster = makeAddr("poster");
        usdg.mint(poster, type(uint96).max);
        vm.prank(poster);
        usdg.approve(address(board_), type(uint256).max);
        for (uint256 i; i < 3; i++) {
            vm.prank(workers_[i]);
            staking_.stake(1_000_000e18, 0.2e6);
            staked[workers_[i]] = 1_000_000e18;
        }
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

    /// Tasks the worker was hired for that have not settled.
    function _inFlight(address w) internal view returns (uint256 n) {
        bytes32 workerId = staking.idOf(w);
        for (uint256 i; i < ids.length; i++) {
            TaskBoard.Task memory t = board.get(ids[i]);
            if (
                t.model == workerId && t.status != TaskBoard.Status.Open && t.status != TaskBoard.Status.Paid
                    && t.status != TaskBoard.Status.Refunded
            ) n++;
        }
    }

    function stake(uint256 who, uint128 amount, uint128 price) external {
        address w = workers[who % 3];
        amount = uint128(bound(amount, 1, 2_000_000e18));
        vm.prank(w);
        staking.stake(amount, price);
        staked[w] += amount;
    }

    function requestUnstake(uint256 who, uint128 amount) external {
        address w = workers[who % 3];
        amount = uint128(bound(amount, 0, staked[w] + 1));
        vm.prank(w);
        try staking.requestUnstake(amount) {
            staked[w] -= amount;
            unstaking[w] += amount;
            unlocksAt[w] = block.timestamp + cooldown;
        } catch {}
    }

    function withdraw(uint256 who) public {
        address w = workers[who % 3];
        uint256 before = token.balanceOf(w);
        vm.prank(w);
        try staking.withdraw() {
            if (block.timestamp < unlocksAt[w] || _inFlight(w) > 0 || token.balanceOf(w) - before != unstaking[w]) {
                badWithdraw++;
            }
            withdrawals++;
            unstaking[w] = 0;
        } catch {}
    }

    /// Withdraws a second before the unlock or right at it.
    function withdrawAtUnlock(uint256 who, bool early) external {
        uint256 unlock = unlocksAt[workers[who % 3]];
        if (unlock == 0) return;
        uint256 at = early ? unlock - 1 : unlock;
        if (at > block.timestamp) vm.warp(at);
        withdraw(who);
    }

    function post(uint128 bounty, uint64 duration) external {
        bounty = uint128(bound(bounty, 1e6, 1e9));
        duration = uint64(bound(duration, 30 minutes, 3 days));
        vm.prank(poster);
        try board.post(bounty, uint64(block.timestamp) + duration, 0, "") returns (uint256 id) {
            ids.push(id);
        } catch {}
    }

    function hire(uint256 seed, uint256 who, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        uint256 d = _decide(DecisionLog.Kind.Hire, id, staking.idOf(workers[who % 3]), confidence);
        vm.prank(brain);
        try board.hire(id, d) {} catch {}
    }

    function submit(uint256 seed) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        bytes32 model = board.get(id).model;
        if (model == bytes32(0)) return;
        vm.prank(address(uint160(uint256(model))));
        try board.submit(id, keccak256("r"), "") {} catch {}
    }

    function grade(uint256 seed, bool yes, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        uint256 d = _decide(DecisionLog.Kind.Grade, id, yes ? YES : bytes32(0), confidence);
        vm.prank(brain);
        try board.grade(id, d) {} catch {}
    }

    function dispute(uint256 seed, bool byWorker) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        TaskBoard.Task memory t = board.get(id);
        address who = byWorker ? t.payee : t.poster;
        if (who == address(0)) return;
        vm.prank(who);
        try board.dispute(id) {} catch {}
    }

    /// A task runs to its grade in one go: posted, hired, delivered and graded.
    function deliver(uint256 who, bool accept, uint16 confidence) external {
        address w = workers[who % 3];
        vm.prank(poster);
        uint256 id = board.post(10e6, uint64(block.timestamp) + 1 days, 0, "");
        ids.push(id);
        uint256 d = _decide(DecisionLog.Kind.Hire, id, staking.idOf(w), 10_000);
        vm.prank(brain);
        try board.hire(id, d) {}
        catch {
            return;
        }
        vm.prank(w);
        board.submit(id, keccak256("r"), "");
        d = _decide(DecisionLog.Kind.Grade, id, accept ? YES : bytes32(0), confidence);
        vm.prank(brain);
        board.grade(id, d);
    }

    /// The worker disputes its grade and the brain rules on the dispute.
    function contest(uint256 seed, bool pay, uint16 confidence) external {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        address payee = board.get(id).payee;
        if (payee == address(0)) return;
        vm.prank(payee);
        try board.dispute(id) {
            rule(seed, pay, confidence);
        } catch {}
    }

    function rule(uint256 seed, bool pay, uint16 confidence) public {
        if (ids.length == 0) return;
        uint256 id = _id(seed);
        address w = address(uint160(uint256(board.get(id).model)));
        uint256 fromStaked = (staked[w] * slashBps) / 10_000;
        uint256 fromUnstaking = (unstaking[w] * slashBps) / 10_000;
        uint256 burnBefore = token.balanceOf(staking.BURN());
        uint256 d = _decide(DecisionLog.Kind.Ruling, id, pay ? YES : bytes32(0), confidence);
        vm.prank(brain);
        try board.rule(id, d) {
            TaskBoard.Task memory t = board.get(id);
            if (t.status == TaskBoard.Status.Refunded && t.disputedByModel) {
                staked[w] -= fromStaked;
                unstaking[w] -= fromUnstaking;
                burned += fromStaked + fromUnstaking;
                slashes++;
                if (token.balanceOf(staking.BURN()) - burnBefore != fromStaked + fromUnstaking) slashOffShare++;
            } else if (token.balanceOf(staking.BURN()) != burnBefore) {
                slashOffShare++;
            }
        } catch {}
    }

    function finalize(uint256 seed) external {
        if (ids.length == 0) return;
        try board.finalize(_id(seed)) {} catch {}
    }

    function setConfig(uint128 minStake, uint64 cooldown_, uint16 bps) external {
        minStake = uint128(bound(minStake, 1, 2_000_000e18));
        cooldown_ = uint64(bound(cooldown_, 1, 7 days));
        bps = uint16(bound(bps, 0, 10_000));
        vm.prank(admin);
        staking.setConfig(minStake, cooldown_, bps);
        cooldown = cooldown_;
        slashBps = bps;
    }

    /// Every party but the board tries to slash directly.
    function slashDirectly(uint256 who, uint256 callerSeed) external {
        address[5] memory callers = [workers[who % 3], admin, brain, poster, board.guardian()];
        vm.prank(callers[callerSeed % 5]);
        try staking.slash(workers[who % 3]) {
            straySlash++;
        } catch {}
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 1 days));
    }
}

contract StakingInvariants is StdInvariant, Test {
    StakingHandler internal h;
    WorkerStaking internal staking;
    MockERC20 internal token;
    address[3] internal workers = [makeAddr("worker-0"), makeAddr("worker-1"), makeAddr("worker-2")];

    function setUp() public {
        address admin = makeAddr("admin");
        address brain = makeAddr("brain");
        MockERC20 usdg = new MockERC20();
        token = new MockERC20();
        DecisionLog decisionLog = new DecisionLog(admin, brain);
        staking = new WorkerStaking(IERC20(address(token)), admin, 1_000_000e18, 3 days, 2_000);
        TaskBoard board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            new ModelRegistry(admin),
            staking,
            admin,
            makeAddr("guardian"),
            TaskBoard.Config(1_500, 7_000, 7_000, 30 minutes, 3 days, 6 hours, 6 hours, 6 hours, 1e6)
        );
        vm.startPrank(admin);
        staking.setSlasher(address(board));
        for (uint256 i; i < 3; i++) {
            board.setWorkerAllowed(workers[i], true);
        }
        vm.stopPrank();
        for (uint256 i; i < 3; i++) {
            token.mint(workers[i], 1e30);
            vm.prank(workers[i]);
            token.approve(address(staking), type(uint256).max);
        }
        h = new StakingHandler(staking, board, decisionLog, token, usdg, admin, brain, workers);
        targetContract(address(h));
    }

    function invariant_holdsExactlyWhatIsAtStake() public view {
        uint256 total;
        for (uint256 i; i < 3; i++) {
            WorkerStaking.Worker memory w = staking.get(workers[i]);
            total += uint256(w.staked) + w.unstaking;
        }
        assertEq(token.balanceOf(address(staking)), total);
    }

    function invariant_stakeMovesOnlyByItsWorkerOrALostDispute() public view {
        assertEq(h.straySlash(), 0);
        for (uint256 i; i < 3; i++) {
            WorkerStaking.Worker memory w = staking.get(workers[i]);
            assertEq(w.staked, h.staked(workers[i]));
            assertEq(w.unstaking, h.unstaking(workers[i]));
        }
    }

    function invariant_aSlashTakesItsShareAndNoMore() public view {
        assertEq(h.slashOffShare(), 0);
        assertEq(token.balanceOf(staking.BURN()), h.burned());
    }

    function invariant_withdrawalsWaitForTheCooldownAndOpenTasks() public view {
        assertEq(h.badWithdraw(), 0);
    }
}
