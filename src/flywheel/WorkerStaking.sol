// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Open worker registration: any agent stakes $BRAIN to be hireable.
/// A worker's id is its account, left-padded to 32 bytes, so it can never
/// collide with a house model id (a keccak256 hash). Losing a dispute burns part of
/// the stake; unstaking waits out a cooldown so a worker cannot leave just
/// before a dispute is decided.
contract WorkerStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Worker {
        uint128 staked;
        uint128 unstaking;
        uint64 unlocksAt;
        uint128 price;
        bool registered;
    }

    error NotOwner();
    error NotSlasher();
    error ZeroAddress();
    error BadAmount();
    error BadConfig();
    error Locked();

    event Staked(address indexed account, uint256 amount, uint128 price);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 unlocksAt);
    event Withdrawn(address indexed account, uint256 amount);
    event Slashed(address indexed account, uint256 amount);
    event PriceSet(address indexed account, uint128 price);
    event ConfigSet(uint128 minStake, uint64 cooldown, uint16 slashBps);
    event SlasherSet(address indexed slasher);

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable token;
    address public owner;
    address public slasher;
    uint128 public minStake;
    uint64 public cooldown;
    uint16 public slashBps;

    mapping(address => Worker) private _workers;

    constructor(IERC20 token_, address owner_, uint128 minStake_, uint64 cooldown_, uint16 slashBps_) {
        if (address(token_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        token = token_;
        owner = owner_;
        _setConfig(minStake_, cooldown_, slashBps_);
    }

    function idOf(address account) public pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @notice True when `id` has the shape of a staked worker's id.
    function isWorkerId(bytes32 id) public pure returns (bool) {
        return uint256(id) >> 160 == 0 && id != bytes32(0);
    }

    /// @notice Stakes $BRAIN and sets the worker's price per task.
    function stake(uint128 amount, uint128 price) external nonReentrant {
        if (amount == 0) revert BadAmount();
        Worker storage w = _workers[msg.sender];
        w.staked += amount;
        w.price = price;
        w.registered = true;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, price);
    }

    function setPrice(uint128 price) external {
        _workers[msg.sender].price = price;
        emit PriceSet(msg.sender, price);
    }

    function requestUnstake(uint128 amount) external {
        Worker storage w = _workers[msg.sender];
        if (amount == 0 || amount > w.staked) revert BadAmount();
        w.staked -= amount;
        w.unstaking += amount;
        w.unlocksAt = uint64(block.timestamp) + cooldown;
        emit UnstakeRequested(msg.sender, amount, w.unlocksAt);
    }

    function withdraw() external nonReentrant {
        Worker storage w = _workers[msg.sender];
        if (block.timestamp < w.unlocksAt) revert Locked();
        uint256 amount = w.unstaking;
        if (amount == 0) revert BadAmount();
        w.unstaking = 0;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Burns `slashBps` of everything the worker has at stake,
    /// including stake waiting to unlock. Called by the task board when the
    /// worker loses a dispute it opened.
    function slash(address account) external nonReentrant returns (uint256 amount) {
        if (msg.sender != slasher) revert NotSlasher();
        Worker storage w = _workers[account];
        uint256 fromStaked = (uint256(w.staked) * slashBps) / 10_000;
        uint256 fromUnstaking = (uint256(w.unstaking) * slashBps) / 10_000;
        w.staked -= uint128(fromStaked);
        w.unstaking -= uint128(fromUnstaking);
        amount = fromStaked + fromUnstaking;
        if (amount > 0) token.safeTransfer(BURN, amount);
        emit Slashed(account, amount);
    }

    /// @notice How the task board sees a staked worker.
    function worker(bytes32 id) external view returns (address account, bool active, uint128 price) {
        if (!isWorkerId(id)) return (address(0), false, 0);
        account = address(uint160(uint256(id)));
        Worker storage w = _workers[account];
        active = w.registered && w.staked >= minStake;
        price = w.price;
    }

    function get(address account) external view returns (Worker memory) {
        return _workers[account];
    }

    function setSlasher(address slasher_) external {
        if (msg.sender != owner) revert NotOwner();
        if (slasher_ == address(0)) revert ZeroAddress();
        slasher = slasher_;
        emit SlasherSet(slasher_);
    }

    function setConfig(uint128 minStake_, uint64 cooldown_, uint16 slashBps_) external {
        if (msg.sender != owner) revert NotOwner();
        _setConfig(minStake_, cooldown_, slashBps_);
    }

    function setOwner(address owner_) external {
        if (msg.sender != owner) revert NotOwner();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    function _setConfig(uint128 minStake_, uint64 cooldown_, uint16 slashBps_) private {
        if (minStake_ == 0 || cooldown_ == 0 || slashBps_ > 10_000) revert BadConfig();
        minStake = minStake_;
        cooldown = cooldown_;
        slashBps = slashBps_;
        emit ConfigSet(minStake_, cooldown_, slashBps_);
    }
}
