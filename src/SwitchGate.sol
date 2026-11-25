// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISwitchTimelock {
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);

    function isOperationPending(bytes32 id) external view returns (bool);
}

interface ISwitchLog {
    function owner() external view returns (address);
}

/// @title SwitchGate
/// @notice Sits in an executor seat of the admin timelock, so a release the
/// owners' Safe scheduled takes effect when its delay has passed without both
/// owners at a keyboard. The operator (BrainChain's guard, with its own key)
/// can execute only the one batch the Safe has armed here, and only if it
/// allows or drops an enclave's app or OS image on the listed decision logs.
/// It cannot schedule, cannot change what a batch holds, cannot choose among
/// ready batches, and cannot reach roles, ownership or funds. The guardian
/// can pause it; only the Safe arms, unpauses, lists logs and replaces the
/// operator or the guardian. Removing the gate itself stays with the admin
/// timelock.
contract SwitchGate {
    error NotSafe();
    error NotAllowed();
    error ZeroAddress();
    error IsPaused();
    error BadBatch();
    error ForbiddenTarget(uint256 index);
    error ForbiddenCall(uint256 index);
    error NotArmed(bytes32 id);
    error NotPending(bytes32 id);
    error NotTimelockOwned(address log);

    event OperatorSet(address indexed operator);
    event GuardianSet(address indexed guardian);
    event LogSet(address indexed log, bool listed);
    event Paused(bool paused, address indexed by, string reason);
    event Armed(bytes32 indexed id);
    event Executed(bytes32 indexed id, address indexed by);

    bytes4 private constant ALLOW_APP = bytes4(keccak256("allowApp(bytes32,bool)"));
    bytes4 private constant ALLOW_IMAGE = bytes4(keccak256("allowImage(bytes32,bool)"));
    // A selector and two 32-byte words.
    uint256 private constant CALL_LENGTH = 68;

    address public immutable safe;
    ISwitchTimelock public immutable timelock;
    address public operator;
    address public guardian;
    bool public paused;
    mapping(address => bool) public isLog;
    /// @notice The one timelock operation the operator may execute; zero for none.
    bytes32 public armed;

    constructor(address safe_, ISwitchTimelock timelock_, address operator_, address guardian_, address[] memory logs) {
        if (safe_ == address(0) || address(timelock_) == address(0)) revert ZeroAddress();
        safe = safe_;
        timelock = timelock_;
        operator = operator_;
        guardian = guardian_;
        emit OperatorSet(operator_);
        emit GuardianSet(guardian_);
        for (uint256 i = 0; i < logs.length; i++) {
            _list(logs[i]);
        }
    }

    /// @notice Executes a scheduled release batch. The timelock itself checks
    /// that this exact batch was scheduled and that its delay has passed.
    function execute(address[] calldata targets, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt)
        external
    {
        if (msg.sender != operator && msg.sender != safe) revert NotAllowed();
        if (paused) revert IsPaused();
        uint256 count = targets.length;
        if (count == 0 || count != payloads.length) revert BadBatch();

        for (uint256 i = 0; i < count; i++) {
            if (!isLog[targets[i]]) revert ForbiddenTarget(i);
            bytes calldata call = payloads[i];
            if (call.length != CALL_LENGTH) revert ForbiddenCall(i);
            bytes4 selector = bytes4(call[:4]);
            if (selector != ALLOW_APP && selector != ALLOW_IMAGE) revert ForbiddenCall(i);
        }

        uint256[] memory values = new uint256[](count);
        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, predecessor, salt);
        if (id != armed) revert NotArmed(id);
        armed = bytes32(0);
        timelock.executeBatch(targets, values, payloads, predecessor, salt);
        emit Executed(id, msg.sender);
    }

    /// @notice The Safe names the scheduled batch the operator may execute;
    /// zero disarms. One at a time, so a leaked operator key can never choose
    /// among ready releases or run a superseded one.
    function arm(bytes32 id) external {
        if (msg.sender != safe) revert NotSafe();
        // A mistyped id would otherwise wait unnoticed until the switch.
        if (id != bytes32(0) && !timelock.isOperationPending(id)) revert NotPending(id);
        armed = id;
        emit Armed(id);
    }

    /// @notice The guardian may pause; only the Safe may unpause.
    function setPaused(bool paused_, string calldata reason) external {
        if (msg.sender != safe && !(paused_ && msg.sender == guardian)) revert NotAllowed();
        paused = paused_;
        emit Paused(paused_, msg.sender, reason);
    }

    function setOperator(address operator_) external {
        if (msg.sender != safe) revert NotSafe();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setGuardian(address guardian_) external {
        if (msg.sender != safe) revert NotSafe();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setLog(address log, bool listed) external {
        if (msg.sender != safe) revert NotSafe();
        if (listed) {
            _list(log);
        } else {
            isLog[log] = false;
            emit LogSet(log, false);
        }
    }

    // A call to an address without code succeeds silently, so a listed log
    // must be a contract the timelock owns.
    function _list(address log) private {
        if (log == address(0)) revert ZeroAddress();
        if (log.code.length == 0 || ISwitchLog(log).owner() != address(timelock)) revert NotTimelockOwned(log);
        isLog[log] = true;
        emit LogSet(log, true);
    }
}
