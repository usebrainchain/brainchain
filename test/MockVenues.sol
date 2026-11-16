// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// A Robinhood stock token: 18 decimals, with the share multiplier the desks price by.
contract MockStock is ERC20 {
    uint256 public uiMultiplier = 1e18;

    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMultiplier(uint256 multiplier) external {
        uiMultiplier = multiplier;
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// A Chainlink feed with 8 decimals whose answer and update time the test sets.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 answer_) {
        set(answer_, block.timestamp);
    }

    function set(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A Uniswap v3 pool that fills at `usdgPerToken` (USDG, 6 decimals, per whole token of the other side)
/// and takes `fillBps` of the input it is offered, as a pool that runs out of liquidity at the price
/// limit would. It pays out first and checks it was paid in the callback, like the real pool.
contract MockPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable usdg;
    uint256 public usdgPerToken;
    uint256 public fillBps = 10_000;

    constructor(address token0_, address token1_, address usdg_, uint256 usdgPerToken_) {
        token0 = token0_;
        token1 = token1_;
        usdg = usdg_;
        usdgPerToken = usdgPerToken_;
    }

    function setPrice(uint256 usdgPerToken_) external {
        usdgPerToken = usdgPerToken_;
    }

    function setFill(uint256 fillBps_) external {
        fillBps = fillBps_;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        (address tokenIn, address tokenOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 amountIn = uint256(amountSpecified) * fillBps / 10_000;
        uint256 amountOut = tokenIn == usdg ? amountIn * 1e18 / usdgPerToken : amountIn * usdgPerToken / 1e18;
        IERC20(tokenOut).transfer(recipient, amountOut);
        (amount0, amount1) =
            zeroForOne ? (int256(amountIn), -int256(amountOut)) : (-int256(amountOut), int256(amountIn));
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}
