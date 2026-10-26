// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DecisionLog} from "./DecisionLog.sol";
import {ModelRegistry} from "./ModelRegistry.sol";
import {TaskBoard} from "./TaskBoard.sol";

/// @notice Owns BrainChain's parameters, the task board, the model registry and
/// the house treasury. A change runs only after Jev adopted it above the change
/// threshold and a timelock passed; the guardian can veto during the timelock,
/// and a vetoed call can never be queued again. Changes may only call this
/// contract, the board or the registry, and can never replace the guardian:
/// that power belongs to the admin, the timelock that owns the DecisionLog.
/// The brain can also post house tasks from the treasury, within daily caps on
/// both the number of tasks and the amount spent.
contract DecisionExecutor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Change {
        address target;
        bytes data;
        uint64 eta;
        bool executed;
        bool vetoed;
    }

    error NotBrain();
    error NotGuardian();
    error NotAdmin();
    error NotSelf();
    error ZeroAddress();
    error BadBoard();
    error BadDecision();
    error StaleDecision();
    error DecisionUsed();
    error BelowThreshold();
    error ForbiddenTarget();
    error ForbiddenCall();
    error VetoedCall();
    error UnknownChange();
    error NotReady();
    error Expired();
    error Closed();
    error CallFailed(bytes reason);
    error BadConfig();
    error HouseCapReached();
    error HouseSpendReached();
    error OverHouseBounty();

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
    event BoardBound(address indexed board, address indexed models);
    event Transferred(address indexed to, uint256 amount);

    bytes32 private constant YES = bytes32(uint256(1));

    uint64 public constant MIN_TIMELOCK = 1 hours;
    uint64 public constant MAX_TIMELOCK = 30 days;
    /// @notice A queued change that is not executed within this long after its
    /// eta expires, so a stale change cannot run months later.
    uint64 public constant GRACE_PERIOD = 14 days;

    DecisionLog public immutable decisions;
    IERC20 public immutable token;
    TaskBoard public board;
    ModelRegistry public models;

    address public guardian;
    uint16 public changeThresholdBps;
    uint64 public timelock;
    uint32 public houseTasksPerDay;
    uint128 public maxHouseBounty;
    uint128 public houseSpendPerDay;

    uint256 public changeCount;
    mapping(uint256 => Change) private _changes;
    mapping(uint256 => bool) public decisionUsed;
    mapping(bytes32 => bool) public vetoedCall;
    mapping(uint256 => uint32) public houseTasksOnDay;
    mapping(uint256 => uint128) public houseSpentOnDay;

    constructor(
        DecisionLog decisions_,
        IERC20 token_,
        address guardian_,
        uint16 changeThresholdBps_,
        uint64 timelock_,
        uint32 houseTasksPerDay_,
        uint128 maxHouseBounty_,
        uint128 houseSpendPerDay_
    ) {
        if (address(decisions_) == address(0) || address(token_) == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        decisions = decisions_;
        token = token_;
        guardian = guardian_;
        _setParameters(changeThresholdBps_, timelock_, houseTasksPerDay_, maxHouseBounty_, houseSpendPerDay_);
        emit GuardianSet(guardian_);
    }

    /// @notice One-time binding to the task board, which is deployed after
    /// this contract because it names this contract as its owner.
    function bindBoard(TaskBoard board_) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (address(board) != address(0)) revert Closed();
        if (address(board_) == address(0)) revert ZeroAddress();
        if (board_.decisions() != decisions || board_.token() != token) revert BadBoard();
        board = board_;
        models = board_.models();
        emit BoardBound(address(board_), address(models));
    }

    /// @notice What a Change decision must name as its subject: this exact call,
    /// through this executor, on this chain.
    function changeSubject(address target, bytes calldata data) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), target, data));
    }

    /// @notice Queues a call adopted by Jev in the latest Change decision about it.
    function queue(uint256 decisionId, address target, bytes calldata data) external returns (uint256 changeId) {
        if (msg.sender != decisions.brain()) revert NotBrain();
        if (target == address(0)) revert ZeroAddress();
        if (target != address(this) && target != address(board) && target != address(models)) revert ForbiddenTarget();
        // TaskBoard and this contract share the setGuardian selector; neither may be reached by a change.
        if (data.length < 4 || bytes4(data[:4]) == this.setGuardian.selector) revert ForbiddenCall();
        if (vetoedCall[keccak256(abi.encode(target, data))]) revert VetoedCall();
        if (decisionUsed[decisionId]) revert DecisionUsed();

        bytes32 subject = changeSubject(target, data);
        DecisionLog.Decision memory d = decisions.get(decisionId);
        if (d.kind != DecisionLog.Kind.Change || d.subject != subject) revert BadDecision();
        if (decisions.latestOf(subject, DecisionLog.Kind.Change) != decisionId) revert StaleDecision();
        if (d.answer != YES || d.confidenceBps < changeThresholdBps) revert BelowThreshold();
        decisionUsed[decisionId] = true;

        changeId = ++changeCount;
        uint64 eta = uint64(block.timestamp) + timelock;
        _changes[changeId] = Change(target, data, eta, false, false);
        emit Queued(changeId, decisionId, target, data, eta);
    }

    function execute(uint256 changeId) external nonReentrant {
        Change storage change = _changes[changeId];
        if (change.target == address(0)) revert UnknownChange();
        if (change.executed || change.vetoed) revert Closed();
        if (block.timestamp < change.eta) revert NotReady();
        if (block.timestamp > uint256(change.eta) + GRACE_PERIOD) revert Expired();

        change.executed = true;
        (bool ok, bytes memory reason) = change.target.call(change.data);
        if (!ok) revert CallFailed(reason);
        emit Executed(changeId);
    }

    /// @notice Cancels a queued change and blocks that exact call for good.
    function veto(uint256 changeId) external {
        if (msg.sender != guardian) revert NotGuardian();
        Change storage change = _changes[changeId];
        if (change.target == address(0)) revert UnknownChange();
        if (change.executed || change.vetoed) revert Closed();
        change.vetoed = true;
        vetoedCall[keccak256(abi.encode(change.target, change.data))] = true;
        emit Vetoed(changeId);
    }

    function getChange(uint256 changeId) external view returns (Change memory) {
        return _changes[changeId];
    }

    /// @notice Posts a house task from the treasury so the loop runs before
    /// public demand arrives. Capped per UTC day in count and in total bounty,
    /// and per task.
    function postHouseTask(uint128 bounty, uint64 deadline, bytes32 briefHash, string calldata briefURI)
        external
        nonReentrant
        returns (uint256 taskId)
    {
        if (msg.sender != decisions.brain()) revert NotBrain();
        if (bounty > maxHouseBounty) revert OverHouseBounty();
        uint256 day = block.timestamp / 1 days;
        if (houseTasksOnDay[day] >= houseTasksPerDay) revert HouseCapReached();
        if (uint256(houseSpentOnDay[day]) + bounty > houseSpendPerDay) revert HouseSpendReached();
        houseTasksOnDay[day] += 1;
        houseSpentOnDay[day] += bounty;

        token.forceApprove(address(board), bounty);
        taskId = board.post(bounty, deadline, briefHash, briefURI);
        token.forceApprove(address(board), 0);
        emit HouseTaskPosted(taskId, bounty);
    }

    /// @notice Only reachable through a queued change.
    function setParameters(
        uint16 changeThresholdBps_,
        uint64 timelock_,
        uint32 houseTasksPerDay_,
        uint128 maxHouseBounty_,
        uint128 houseSpendPerDay_
    ) external {
        if (msg.sender != address(this)) revert NotSelf();
        _setParameters(changeThresholdBps_, timelock_, houseTasksPerDay_, maxHouseBounty_, houseSpendPerDay_);
    }

    /// @notice Replaces the guardian here and on the board. Only the admin can,
    /// so the brain can never remove the key that vetoes its changes.
    function setGuardian(address guardian_) external {
        if (msg.sender != decisions.owner()) revert NotAdmin();
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        if (address(board) != address(0) && board.owner() == address(this)) board.setGuardian(guardian_);
        emit GuardianSet(guardian_);
    }

    /// @notice Only reachable through a queued change, so treasury movements are
    /// decided by Jev and visible for the whole timelock.
    function transfer(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Transferred(to, amount);
    }

    function _setParameters(uint16 threshold, uint64 lock, uint32 perDay, uint128 maxBounty, uint128 spendPerDay)
        private
    {
        if (
            threshold > 10_000 || threshold < 5_000 || lock < MIN_TIMELOCK || lock > MAX_TIMELOCK
                || maxBounty > spendPerDay
        ) revert BadConfig();
        changeThresholdBps = threshold;
        timelock = lock;
        houseTasksPerDay = perDay;
        maxHouseBounty = maxBounty;
        houseSpendPerDay = spendPerDay;
        emit ParametersSet(threshold, lock, perDay, maxBounty, spendPerDay);
    }
}
