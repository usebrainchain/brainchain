// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Collects the protocol fee on paid bounties and turns it into $BRAIN:
/// part is burned and the rest goes to the house treasury. The $BRAIN address
/// is set once, at launch; until then fees accumulate here untouched. The
/// keeper picks the moment and the minimum output of each swap, but never
/// below the floor rate the owner (governance) sets, so a compromised keeper
/// cannot sell the fees at an arbitrary price.
contract FeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error NotKeeper();
    error ZeroAddress();
    error AlreadySet();
    error NotReady();
    error BadShare();
    error BelowFloor();
    error ShortSwap();

    event BrainSet(address indexed brain);
    event AdapterSet(address indexed adapter);
    event KeeperSet(address indexed keeper);
    event BurnShareSet(uint16 burnBps);
    event FloorRateSet(uint256 floorRate);
    event OwnerSet(address indexed owner);
    event BoughtBack(uint256 feeIn, uint256 brainOut, uint256 burned, uint256 toTreasury);

    /// @dev $BRAIN is burned by sending it here; works for any ERC-20.
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable feeToken;
    address public immutable treasury;
    address public owner;
    address public keeper;
    IERC20 public brain;
    ISwapAdapter public adapter;
    uint16 public burnBps;
    /// @notice Minimum $BRAIN out per unit of fee token, scaled by 1e18. Zero
    /// blocks buybacks until governance sets a floor.
    uint256 public floorRate;

    constructor(IERC20 feeToken_, address treasury_, address owner_, address keeper_, uint16 burnBps_) {
        if (
            address(feeToken_) == address(0) || treasury_ == address(0) || owner_ == address(0) || keeper_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (burnBps_ > 10_000) revert BadShare();
        feeToken = feeToken_;
        treasury = treasury_;
        owner = owner_;
        keeper = keeper_;
        burnBps = burnBps_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Sets the $BRAIN token once, when it launches.
    function setBrain(IERC20 brain_) external onlyOwner {
        if (address(brain) != address(0)) revert AlreadySet();
        if (address(brain_) == address(0)) revert ZeroAddress();
        brain = brain_;
        emit BrainSet(address(brain_));
    }

    function setAdapter(ISwapAdapter adapter_) external onlyOwner {
        if (address(adapter_) == address(0)) revert ZeroAddress();
        adapter = adapter_;
        emit AdapterSet(address(adapter_));
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setFloorRate(uint256 floorRate_) external onlyOwner {
        floorRate = floorRate_;
        emit FloorRateSet(floorRate_);
    }

    function setBurnShare(uint16 burnBps_) external onlyOwner {
        if (burnBps_ > 10_000) revert BadShare();
        burnBps = burnBps_;
        emit BurnShareSet(burnBps_);
    }

    /// @notice Swaps collected fees for $BRAIN, burns the burn share and sends
    /// the rest to the treasury. `minOut` protects against a bad price; the
    /// keeper sets it from the market price at the time, at or above the floor.
    function buyback(uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 brainOut) {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        if (address(brain) == address(0) || address(adapter) == address(0) || floorRate == 0) revert NotReady();
        if (amountIn > feeToken.balanceOf(address(this))) amountIn = feeToken.balanceOf(address(this));
        if (minOut < (amountIn * floorRate) / 1e18) revert BelowFloor();

        feeToken.forceApprove(address(adapter), amountIn);
        uint256 before = brain.balanceOf(address(this));
        adapter.swap(address(feeToken), address(brain), amountIn, minOut, address(this));
        feeToken.forceApprove(address(adapter), 0);
        brainOut = brain.balanceOf(address(this)) - before;
        if (brainOut < minOut) revert ShortSwap();

        uint256 burned = (brainOut * burnBps) / 10_000;
        brain.safeTransfer(BURN, burned);
        brain.safeTransfer(treasury, brainOut - burned);
        emit BoughtBack(amountIn, brainOut, burned, brainOut - burned);
    }

    function setOwner(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }
}
