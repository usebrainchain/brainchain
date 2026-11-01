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

/// The brain records Change decisions on a small menu of calls (in bounds, out
/// of bounds and forbidden) and queues them with the latest decision or any
/// other; the guardian vetoes, anyone executes, the admin rotates the guardian
/// and the brain, and everyone else tries to.
contract ExecutorHandler is Test {
    bytes32 internal constant YES = bytes32(uint256(1));
    uint256 internal constant PAYMENT = 1e6;

    DecisionExecutor public immutable executor;
    DecisionLog public immutable decisionLog;
    TaskBoard public immutable board;
    ModelRegistry public immutable registry;
    address public immutable admin;
    address public immutable stranger;
    address[3] public guardians;
    address[2] public brains;

    address public expectedGuardian;
    address public expectedBrain;
    uint256 public transferred;
    uint256 public outsideWindow;
    uint256 public ranAfterVeto;
    uint256 public ranTwice;
    uint256 public badQueue;
    uint256 public requeuedAfterVeto;

    mapping(uint256 => uint256) public runs;
    mapping(uint256 => bool) public vetoed;
    mapping(uint256 => uint256) internal _eta;
    mapping(uint256 => uint256) internal _payment;
    mapping(uint256 => bool) internal _decisionQueued;
    mapping(bytes32 => bool) internal _callVetoed;
    mapping(bytes32 => uint256[]) internal _decisionsAbout;

    constructor(
        DecisionExecutor executor_,
        DecisionLog decisionLog_,
        TaskBoard board_,
        ModelRegistry registry_,
        address admin_,
        address[3] memory guardians_,
        address[2] memory brains_
    ) {
        executor = executor_;
        decisionLog = decisionLog_;
        board = board_;
        registry = registry_;
        admin = admin_;
        guardians = guardians_;
        brains = brains_;
        stranger = makeAddr("stranger");
        expectedGuardian = guardians_[0];
        expectedBrain = brains_[0];
    }

    function _call(uint256 seed) internal view returns (address, bytes memory) {
        // Fuzzed seeds cluster on round numbers, which would pick the same entry every time.
        uint256 k = uint256(keccak256(abi.encode(seed))) % 16;
        if (k < 8) {
            uint16[8] memory thresholds = [uint16(5_000), 6_000, 10_000, 4_999, 10_001, 6_000, 6_000, 6_000];
            uint64[8] memory locks =
                [uint64(1 hours), 48 hours, 1 hours, 48 hours, 48 hours, 30 days + 1, 59 minutes, 48 hours];
            uint128 maxBounty = k == 7 ? 11e6 : 2e6;
            return (
                address(executor),
                abi.encodeCall(DecisionExecutor.setParameters, (thresholds[k], locks[k], 5, maxBounty, 10e6))
            );
        }
        if (k == 8) return (address(executor), abi.encodeCall(DecisionExecutor.transfer, (stranger, PAYMENT)));
        if (k == 9) return (address(board), abi.encodeCall(TaskBoard.setFee, (300, stranger)));
        if (k == 10) {
            return (address(registry), abi.encodeCall(ModelRegistry.setModel, (keccak256("claude"), stranger, 1, true)));
        }
        if (k == 11) return (address(executor), abi.encodeCall(DecisionExecutor.setGuardian, (stranger)));
        if (k == 12) return (address(board), abi.encodeCall(TaskBoard.setGuardian, (stranger)));
        if (k == 13) return (address(board), abi.encodeCall(TaskBoard.setOwner, (stranger)));
        if (k == 14) return (address(registry), abi.encodeCall(ModelRegistry.setOwner, (stranger)));
        return (address(decisionLog), abi.encodeCall(DecisionLog.setBrain, (stranger)));
    }

    function _record(DecisionLog.Kind kind, address target, bytes memory data, bool yes, uint16 confidence)
        internal
        returns (uint256)
    {
        bytes32 subject = executor.changeSubject(target, data);
        vm.prank(decisionLog.brain());
        uint256 id = decisionLog.record(kind, subject, 0, yes ? YES : bytes32(0), confidence, 0, "");
        _decisionsAbout[subject].push(id);
        return id;
    }

    function _allowed(address target, bytes memory data) internal view returns (bool) {
        bytes4 selector = bytes4(data);
        return (target == address(executor) || target == address(board) || target == address(registry))
            && selector != DecisionExecutor.setGuardian.selector && selector != TaskBoard.setOwner.selector;
    }

    function _adopted(uint256 decisionId, address target, bytes memory data, uint16 threshold)
        internal
        view
        returns (bool)
    {
        bytes32 subject = executor.changeSubject(target, data);
        DecisionLog.Decision memory d = decisionLog.get(decisionId);
        return d.kind == DecisionLog.Kind.Change && d.subject == subject && d.answer == YES
            && d.confidenceBps >= threshold && decisionLog.latestOf(subject, DecisionLog.Kind.Change) == decisionId;
    }

    function _queue(address target, bytes memory data, uint256 decisionId, bool staleBrain) internal {
        uint16 threshold = executor.changeThresholdBps();
        uint256 lock = executor.timelock();
        address brain = decisionLog.brain();
        vm.prank(staleBrain ? (brain == brains[0] ? brains[1] : brains[0]) : brain);
        try executor.queue(decisionId, target, data) returns (uint256 id) {
            if (
                staleBrain || _decisionQueued[decisionId] || !_allowed(target, data)
                    || !_adopted(decisionId, target, data, threshold)
            ) badQueue++;
            if (_callVetoed[keccak256(abi.encode(target, data))]) requeuedAfterVeto++;
            _decisionQueued[decisionId] = true;
            _eta[id] = block.timestamp + lock;
            if (target == address(executor) && bytes4(data) == DecisionExecutor.transfer.selector) {
                _payment[id] = PAYMENT;
            }
        } catch {}
    }

    function decide(uint256 callSeed, bool yes, uint16 confidence, bool otherKind) external {
        (address target, bytes memory data) = _call(callSeed);
        DecisionLog.Kind kind = otherKind ? DecisionLog.Kind.Grade : DecisionLog.Kind.Change;
        _record(kind, target, data, yes, uint16(bound(confidence, 0, 10_000)));
    }

    /// Queues with the latest Change decision on the call, any earlier decision on it, or any decision at all.
    function queue(uint256 callSeed, uint256 decisionSeed, uint8 pick, bool staleBrain) external {
        (address target, bytes memory data) = _call(callSeed);
        bytes32 subject = executor.changeSubject(target, data);
        uint256[] storage history = _decisionsAbout[subject];
        uint256 decisionId;
        if (pick % 3 == 0) decisionId = decisionLog.latestOf(subject, DecisionLog.Kind.Change);
        else if (pick % 3 == 1 && history.length > 0) decisionId = history[decisionSeed % history.length];
        else decisionId = bound(decisionSeed, 0, decisionLog.count() + 1);
        _queue(target, data, decisionId, staleBrain);
    }

    /// Jev adopts a call, then decides on it again; the brain tries the superseded adoption.
    function reconsider(uint256 callSeed, bool yes, uint16 confidence) external {
        (address target, bytes memory data) = _call(callSeed);
        uint256 first = _record(DecisionLog.Kind.Change, target, data, true, 10_000);
        _record(DecisionLog.Kind.Change, target, data, yes, uint16(bound(confidence, 0, 10_000)));
        _queue(target, data, first, false);
    }

    /// Jev adopts the call of an earlier change again, vetoed or not.
    function readopt(uint256 seed, uint16 confidence) external {
        uint256 n = executor.changeCount();
        if (n == 0) return;
        DecisionExecutor.Change memory c = executor.getChange(bound(seed, 1, n));
        uint256 d = _record(DecisionLog.Kind.Change, c.target, c.data, true, uint16(bound(confidence, 0, 10_000)));
        _queue(c.target, c.data, d, false);
    }

    function adopt(uint256 callSeed, uint16 confidence) external {
        (address target, bytes memory data) = _call(callSeed);
        uint256 d = _record(DecisionLog.Kind.Change, target, data, true, uint16(bound(confidence, 0, 10_000)));
        _queue(target, data, d, false);
    }

    function adoptParameters(uint16 threshold, uint64 lock, uint128 maxBounty, uint128 spend) external {
        spend = uint128(bound(spend, 0, 20e6));
        bytes memory data = abi.encodeCall(
            DecisionExecutor.setParameters,
            (
                uint16(bound(threshold, 4_000, 10_500)),
                uint64(bound(lock, 0, 4 days)),
                5,
                uint128(bound(maxBounty, 0, uint256(spend) + 1e6)),
                spend
            )
        );
        uint256 d = _record(DecisionLog.Kind.Change, address(executor), data, true, 10_000);
        _queue(address(executor), data, d, false);
    }

    /// Moves to an edge of a change's window (a second early, its eta, the
    /// last second of grace, a second late) and executes there.
    function executeAtEdge(uint256 seed, uint8 edge) external {
        uint256 n = executor.changeCount();
        if (n == 0) return;
        uint256 eta = executor.getChange(bound(seed, 1, n)).eta;
        uint256 grace = executor.GRACE_PERIOD();
        uint256[4] memory edges = [eta - 1, eta, eta + grace, eta + grace + 1];
        uint256 at = edges[edge % 4];
        if (at > block.timestamp) vm.warp(at);
        execute();
    }

    /// Tries every change, whether early, ready, expired, vetoed or done.
    function execute() public {
        for (uint256 id = 1; id <= executor.changeCount(); id++) {
            try executor.execute(id) {
                if (++runs[id] > 1) ranTwice++;
                if (vetoed[id]) ranAfterVeto++;
                if (block.timestamp < _eta[id] || block.timestamp > _eta[id] + executor.GRACE_PERIOD()) {
                    outsideWindow++;
                }
                transferred += _payment[id];
            } catch {}
        }
    }

    function veto(uint256 seed) external {
        uint256 n = executor.changeCount();
        // A guardian that vetoed everything would leave nothing to execute.
        if (n == 0 || seed % 4 != 0) return;
        uint256 id = bound(seed, 1, n);
        vm.prank(executor.guardian());
        try executor.veto(id) {
            vetoed[id] = true;
            DecisionExecutor.Change memory c = executor.getChange(id);
            _callVetoed[keccak256(abi.encode(c.target, c.data))] = true;
        } catch {}
    }

    function rotateGuardian(uint256 seed) external {
        address next = guardians[seed % 3];
        vm.prank(admin);
        executor.setGuardian(next);
        expectedGuardian = next;
    }

    function rotateBrain(uint256 seed) external {
        address next = brains[seed % 2];
        vm.prank(admin);
        decisionLog.setBrain(next);
        expectedBrain = next;
    }

    /// The brain, the guardian and a stranger each try every direct route to the guardian or the brain.
    function grab(uint256 callerSeed, uint256 seed) external {
        address[3] memory callers = [decisionLog.brain(), executor.guardian(), stranger];
        address caller = callers[callerSeed % 3];
        vm.startPrank(caller);
        try executor.setGuardian(guardians[seed % 3]) {} catch {}
        try board.setGuardian(caller) {} catch {}
        try decisionLog.setBrain(caller) {} catch {}
        vm.stopPrank();
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 3 days));
    }
}

contract ExecutorInvariants is StdInvariant, Test {
    uint256 internal constant FUNDED = 1e12;
    uint16 internal constant THRESHOLD_FLOOR = 5_000;

    ExecutorHandler internal h;
    MockERC20 internal usdg;
    DecisionLog internal decisionLog;
    DecisionExecutor internal executor;
    TaskBoard internal board;
    ModelRegistry internal registry;
    address internal admin = makeAddr("admin");

    function setUp() public {
        address[3] memory guardians = [makeAddr("guardian"), makeAddr("guardian-2"), makeAddr("guardian-3")];
        address[2] memory brains = [makeAddr("brain"), makeAddr("brain-2")];
        usdg = new MockERC20();
        decisionLog = new DecisionLog(admin, brains[0]);
        executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardians[0], 6_000, 48 hours, 5, 2e6, 10e6);
        registry = new ModelRegistry(address(this));
        registry.setModel(keccak256("claude"), makeAddr("claude"), 0.4e6, true);
        board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            address(this),
            guardians[0],
            TaskBoard.Config(1_500, 7_000, 7_000, 30 minutes, 3 days, 6 hours, 6 hours, 6 hours, 1e6)
        );
        board.setOwner(address(executor));
        registry.setOwner(address(executor));
        vm.prank(guardians[0]);
        executor.bindBoard(board);
        usdg.mint(address(executor), FUNDED);

        h = new ExecutorHandler(executor, decisionLog, board, registry, admin, guardians, brains);
        targetContract(address(h));
    }

    function invariant_noChangeRunsBeforeItsDelayOrAfterItsGrace() public view {
        assertEq(h.outsideWindow(), 0);
    }

    function invariant_aVetoedChangeNeverRuns() public view {
        assertEq(h.ranAfterVeto(), 0);
        for (uint256 id = 1; id <= executor.changeCount(); id++) {
            DecisionExecutor.Change memory c = executor.getChange(id);
            assertFalse(c.executed && c.vetoed);
            assertEq(c.vetoed, h.vetoed(id));
        }
    }

    function invariant_aChangeRunsAtMostOnce() public view {
        assertEq(h.ranTwice(), 0);
        for (uint256 id = 1; id <= executor.changeCount(); id++) {
            assertEq(executor.getChange(id).executed, h.runs(id) == 1);
        }
        assertEq(usdg.balanceOf(address(executor)), FUNDED - h.transferred());
    }

    function invariant_onlyAConfidentAdoptionQueuesACall() public view {
        assertEq(h.badQueue(), 0);
    }

    function invariant_aVetoedCallIsNeverQueuedAgain() public view {
        assertEq(h.requeuedAfterVeto(), 0);
    }

    function invariant_parametersStayInBounds() public view {
        assertGe(executor.changeThresholdBps(), THRESHOLD_FLOOR);
        assertLe(executor.changeThresholdBps(), 10_000);
        assertGe(executor.timelock(), executor.MIN_TIMELOCK());
        assertLe(executor.timelock(), executor.MAX_TIMELOCK());
        assertLe(executor.maxHouseBounty(), executor.houseSpendPerDay());
    }

    function invariant_guardianAndBrainMoveOnlyThroughTheAdmin() public view {
        assertEq(executor.guardian(), h.expectedGuardian());
        assertEq(board.guardian(), h.expectedGuardian());
        assertEq(decisionLog.brain(), h.expectedBrain());
        assertEq(decisionLog.owner(), admin);
        assertEq(board.owner(), address(executor));
        assertEq(registry.owner(), address(executor));
    }
}
