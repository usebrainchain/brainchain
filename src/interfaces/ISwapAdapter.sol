// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swaps one token for another at a venue chosen by the chain's settings.
interface ISwapAdapter {
    /// @dev Pulls `amountIn` of `tokenIn` from the caller and sends at least `minOut` of `tokenOut` to `recipient`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);
}
