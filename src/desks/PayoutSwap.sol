// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPayoutPool {
    function token0() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @dev The DeskMandate's venue list and feed price: one allowlist for the desks and for payouts.
interface IDeskVenues {
    function venues(address token) external view returns (address pool, address feed, bool live);
    function price(address token) external view returns (uint256);
}

/// @notice Pays a worker in a Robinhood stock token: USDG from the operator is swapped on the venue the
/// desks trade and sent on, with the fill held within `premiumBps` of the Chainlink price and the day's
/// total under `dailyCap`. Every payout is an event carrying the task it pays for.
contract PayoutSwap is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IERC20 public immutable USDG;
    IDeskVenues public immutable MANDATE;

    address public operator;
    uint16 public premiumBps;
    uint256 public dailyCap;
    uint64 public day;
    uint256 public spentToday;
    bool public paused;

    address private _expectedPool;

    event Paid(bytes32 indexed taskRef, address indexed to, address indexed token, uint256 usdgIn, uint256 tokensOut, uint256 feedPrice);
    event OperatorSet(address operator);
    event BoundsSet(uint16 premiumBps, uint256 dailyCap);
    event PausedSet(bool paused);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error NotOperator();
    error Paused();
    error ZeroAmount();
    error NoVenue(address token);
    error OverCap(uint256 wouldBe, uint256 cap);
    error OffPrice(uint256 out, uint256 minOut);
    error WrongPool(address caller);
    error BadBounds();

    constructor(IERC20 usdg, IDeskVenues mandate, address owner_, address operator_, uint16 premiumBps_, uint256 dailyCap_)
        Ownable(owner_)
    {
        if (premiumBps_ > 1_000) revert BadBounds();
        USDG = usdg;
        MANDATE = mandate;
        operator = operator_;
        premiumBps = premiumBps_;
        dailyCap = dailyCap_;
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setBounds(uint16 premiumBps_, uint256 dailyCap_) external onlyOwner {
        if (premiumBps_ > 1_000) revert BadBounds();
        premiumBps = premiumBps_;
        dailyCap = dailyCap_;
        emit BoundsSet(premiumBps_, dailyCap_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function sweep(IERC20 token, address to, uint256 amount) external onlyOwner {
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
    }

    /// @notice `usdgIn` from the operator becomes `token` for `to`, at no worse than the feed less `premiumBps`.
    function pay(address token, uint256 usdgIn, address to, bytes32 taskRef) external nonReentrant returns (uint256 out) {
        if (msg.sender != operator) revert NotOperator();
        if (paused) revert Paused();
        if (usdgIn == 0) revert ZeroAmount();
        (address pool,, bool live) = MANDATE.venues(token);
        if (!live) revert NoVenue(token);

        uint64 today = uint64(block.timestamp / 1 days);
        if (today != day) {
            day = today;
            spentToday = 0;
        }
        if (spentToday + usdgIn > dailyCap) revert OverCap(spentToday + usdgIn, dailyCap);
        spentToday += usdgIn;

        USDG.safeTransferFrom(msg.sender, address(this), usdgIn);
        out = _swap(IPayoutPool(pool), address(USDG), usdgIn);
        uint256 mark = MANDATE.price(token);
        uint256 minOut = usdgIn * 1e18 * (BPS - premiumBps) / (mark * BPS);
        if (out < minOut) revert OffPrice(out, minOut);
        IERC20(token).safeTransfer(to, out);
        emit Paid(taskRef, to, token, usdgIn, out, mark);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _expectedPool) revert WrongPool(msg.sender);
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    function _swap(IPayoutPool pool, address tokenIn, uint256 amountIn) private returns (uint256 amountOut) {
        bool zeroForOne = pool.token0() == tokenIn;
        _expectedPool = address(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, abi.encode(tokenIn)
        );
        _expectedPool = address(0);
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }
}
