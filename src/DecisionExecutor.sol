// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DecisionLog} from "./DecisionLog.sol";
import {TaskBoard} from "./TaskBoard.sol";

/// @notice Owns BrainChain's parameters and the house treasury. A change runs
/// only after Jev adopted it above the change threshold and a timelock passed;
/// the guardian can veto during the timelock. The brain can also post house
/// tasks from the treasury, within a daily cap.
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
    error NotSelf();
    error ZeroAddress();
    error BadDecision();
    error DecisionUsed();
    error BelowThreshold();
    error UnknownChange();
    error NotReady();
    error Closed();
    error CallFailed(bytes reason);
    error BadConfig();
    error HouseCapReached();

    event Queued(uint256 indexed changeId, uint256 indexed decisionId, address indexed target, bytes data, uint64 eta);
    event Executed(uint256 indexed changeId);
    event Vetoed(uint256 indexed changeId);
    event HouseTaskPosted(uint256 indexed taskId, uint128 bounty);
    event ParametersSet(uint16 changeThresholdBps, uint64 timelock, uint32 houseTasksPerDay);
    event GuardianSet(address indexed guardian);

    bytes32 private constant YES = bytes32(uint256(1));

    DecisionLog public immutable decisions;
    IERC20 public immutable token;
    TaskBoard public board;

    address public guardian;
    uint16 public changeThresholdBps;
    uint64 public timelock;
    uint32 public houseTasksPerDay;

    uint256 public changeCount;
    mapping(uint256 => Change) private _changes;
    mapping(uint256 => bool) public decisionUsed;
    mapping(uint256 => uint32) public houseTasksOnDay;

    constructor(
        DecisionLog decisions_,
        IERC20 token_,
        address guardian_,
        uint16 changeThresholdBps_,
        uint64 timelock_,
        uint32 houseTasksPerDay_
    ) {
        if (address(decisions_) == address(0) || address(token_) == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        decisions = decisions_;
        token = token_;
        guardian = guardian_;
        _setParameters(changeThresholdBps_, timelock_, houseTasksPerDay_);
        emit GuardianSet(guardian_);
    }

    /// @notice One-time binding to the task board, which is deployed after
    /// this contract because it names this contract as its owner.
    function bindBoard(TaskBoard board_) external {
        if (msg.sender != guardian) revert NotGuardian();
        if (address(board) != address(0)) revert Closed();
        if (address(board_) == address(0)) revert ZeroAddress();
        board = board_;
    }

    // ---------------------------------------------------------------- changes

    /// @notice Queues a call adopted by Jev. The decision's subject must be the
    /// hash of exactly this target and calldata.
    function queue(uint256 decisionId, address target, bytes calldata data) external returns (uint256 changeId) {
        if (msg.sender != decisions.brain()) revert NotBrain();
        if (target == address(0)) revert ZeroAddress();
        if (decisionUsed[decisionId]) revert DecisionUsed();
        DecisionLog.Decision memory d = decisions.get(decisionId);
        if (d.kind != DecisionLog.Kind.Change || d.subject != keccak256(abi.encode(target, data))) {
            revert BadDecision();
        }
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

        change.executed = true;
        (bool ok, bytes memory reason) = change.target.call(change.data);
        if (!ok) revert CallFailed(reason);
        emit Executed(changeId);
    }

    function veto(uint256 changeId) external {
        if (msg.sender != guardian) revert NotGuardian();
        Change storage change = _changes[changeId];
        if (change.target == address(0)) revert UnknownChange();
        if (change.executed || change.vetoed) revert Closed();
        change.vetoed = true;
        emit Vetoed(changeId);
    }

    function getChange(uint256 changeId) external view returns (Change memory) {
        return _changes[changeId];
    }

    // ------------------------------------------------------------- house tasks

    /// @notice Posts a house task from the treasury so the loop runs before
    /// public demand arrives. Capped per UTC day.
    function postHouseTask(uint128 bounty, uint64 deadline, bytes32 briefHash, string calldata briefURI)
        external
        nonReentrant
        returns (uint256 taskId)
    {
        if (msg.sender != decisions.brain()) revert NotBrain();
        uint256 day = block.timestamp / 1 days;
        if (houseTasksOnDay[day] >= houseTasksPerDay) revert HouseCapReached();
        houseTasksOnDay[day] += 1;

        token.forceApprove(address(board), bounty);
        taskId = board.post(bounty, deadline, briefHash, briefURI);
        token.forceApprove(address(board), 0);
        emit HouseTaskPosted(taskId, bounty);
    }

    // ---------------------------------------------------- self-governed config

    /// @notice Only reachable through a queued change.
    function setParameters(uint16 changeThresholdBps_, uint64 timelock_, uint32 houseTasksPerDay_) external {
        if (msg.sender != address(this)) revert NotSelf();
        _setParameters(changeThresholdBps_, timelock_, houseTasksPerDay_);
    }

    /// @notice Only reachable through a queued change.
    function setGuardian(address guardian_) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// @notice Only reachable through a queued change, so treasury movements are
    /// decided by Jev and visible for the whole timelock.
    function transfer(address to, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
    }

    function _setParameters(uint16 threshold, uint64 lock, uint32 perDay) private {
        if (threshold > 10_000 || threshold < 5_000 || lock < 1 hours) revert BadConfig();
        changeThresholdBps = threshold;
        timelock = lock;
        houseTasksPerDay = perDay;
        emit ParametersSet(threshold, lock, perDay);
    }
}
