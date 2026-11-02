// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGuardedExecutor {
    function veto(uint256 changeId) external;
}

interface IGuardedBoard {
    function setPaused(bool paused) external;
}

/// @title GuardianGate
/// @notice Sits in the guardian seat of the decision executor and the task
/// board, so the guardian's powers can be split: the owners' Safe keeps all of
/// them, and a watcher (an agent with its own key) can only veto a queued
/// change and pause new posts. The watcher cannot unpause, cannot move funds,
/// and is replaced by the Safe at any time. Replacing the gate itself stays
/// with the admin timelock, as for any guardian.
contract GuardianGate {
    error NotSafe();
    error NotAllowed();
    error ZeroAddress();

    event WatcherSet(address indexed watcher);
    event Vetoed(uint256 indexed changeId, address indexed by, string reason);
    event Paused(bool paused, address indexed by, string reason);

    address public immutable safe;
    IGuardedExecutor public immutable executor;
    IGuardedBoard public immutable board;
    address public watcher;

    constructor(address safe_, IGuardedExecutor executor_, IGuardedBoard board_, address watcher_) {
        if (safe_ == address(0) || address(executor_) == address(0) || address(board_) == address(0)) {
            revert ZeroAddress();
        }
        safe = safe_;
        executor = executor_;
        board = board_;
        watcher = watcher_;
        emit WatcherSet(watcher_);
    }

    /// @notice Vetoes a queued change; the reason is published with it.
    function veto(uint256 changeId, string calldata reason) external {
        if (msg.sender != safe && msg.sender != watcher) revert NotAllowed();
        executor.veto(changeId);
        emit Vetoed(changeId, msg.sender, reason);
    }

    /// @notice The watcher may pause; only the Safe may unpause.
    function setPaused(bool paused, string calldata reason) external {
        if (msg.sender != safe && !(paused && msg.sender == watcher)) revert NotAllowed();
        board.setPaused(paused);
        emit Paused(paused, msg.sender, reason);
    }

    function setWatcher(address watcher_) external {
        if (msg.sender != safe) revert NotSafe();
        watcher = watcher_;
        emit WatcherSet(watcher_);
    }
}
