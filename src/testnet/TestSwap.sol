// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Testnet swap venue for buybacks: sells test BRAIN from its reserve
/// at a fixed rate. Mainnet uses an adapter for a real $BRAIN market instead.
contract TestSwap is ISwapAdapter {
    using SafeERC20 for IERC20;

    error WrongPair();
    error Slippage();

    IERC20 public immutable tokenIn;
    IERC20 public immutable tokenOut;
    /// @notice tokenOut base units per tokenIn base unit.
    uint256 public immutable rate;

    constructor(IERC20 tokenIn_, IERC20 tokenOut_, uint256 rate_) {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        rate = rate_;
    }

    function swap(address in_, address out_, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        if (in_ != address(tokenIn) || out_ != address(tokenOut)) revert WrongPair();
        amountOut = amountIn * rate;
        if (amountOut < minOut) revert Slippage();
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(recipient, amountOut);
    }
}
