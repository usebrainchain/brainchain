// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

interface IStockToken {
    function uiMultiplier() external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
}

/// @notice Five mandates, one per house model, trading Robinhood stock tokens against USDG on
/// Robinhood Chain with every bound enforced here and every order a public record.
///
/// The operator (the brain's desk key) places orders the models decide. The owner (the Safe)
/// funds, pauses, tunes the bounds, keeps the allowlist and can recall any desk to itself. A desk
/// holds USDG and allowlisted tokens only, trades on a fixed Uniswap v3 pool per token, never
/// borrows and never shorts. A buy may not pay more than the Chainlink price plus `premiumBps`, a
/// sell may not take less than the price minus it, one order per desk per `interval`, and a buy
/// spends at most `maxBuyBps` of the desk's USDG. Each order carries the hash of the model's
/// reasoning, which the brain keeps content addressed.
contract DeskMandate is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant DESKS = 5;
    uint256 public constant BPS = 10_000;
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    struct Venue {
        IUniswapV3PoolLike pool;
        IAggregatorV3 feed;
        bool live;
    }

    struct Desk {
        bytes32 model;
        uint256 usdg;
        uint64 lastOrderAt;
        uint32 orders;
    }

    IERC20 public immutable USDG;
    IERC20 public immutable WETH;
    IUniswapV3PoolLike public immutable WETH_POOL;

    address public operator;
    bool public paused;
    uint64 public interval = 1 hours;
    uint16 public premiumBps = 200;
    uint16 public maxBuyBps = 5_000;
    uint256 public maxFeedAge = 3 days;

    Desk[DESKS] public desks;
    mapping(uint8 desk => mapping(address token => uint256)) public holdings;
    mapping(address token => Venue) public venues;
    address[] public tokens;

    address private _expectedPool;

    event Order(
        uint8 indexed desk,
        address indexed token,
        bool buy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feedPrice,
        bytes32 reasoning
    );
    event Funded(uint8 indexed desk, uint256 usdg);
    event Recalled(uint8 indexed desk, address indexed to, uint256 usdg);
    event VenueSet(address indexed token, address pool, address feed, bool live);
    event OperatorSet(address indexed operator);
    event PausedSet(bool paused);
    event BoundsSet(uint64 interval, uint16 premiumBps, uint16 maxBuyBps, uint256 maxFeedAge);

    error NotOperator();
    error IsPaused();
    error NoDesk();
    error NotListed(address token);
    error TooSoon(uint8 desk);
    error OverCap(uint256 amount, uint256 cap);
    error Short(uint256 amount, uint256 held);
    error StaleFeed(address feed, uint256 updatedAt);
    error BadFeed(address feed);
    error OffPrice(uint256 amountOut, uint256 floor);
    error WrongPool(address pool);
    error PoolMismatch(address pool, address token);
    error ZeroAddress();
    error ZeroAmount();

    constructor(
        IERC20 usdg,
        IERC20 weth,
        IUniswapV3PoolLike wethPool,
        address owner_,
        address operator_,
        bytes32[DESKS] memory models
    ) Ownable(owner_) {
        if (address(usdg) == address(0) || address(weth) == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        if (wethPool.token0() != address(weth) || wethPool.token1() != address(usdg)) {
            revert PoolMismatch(address(wethPool), address(weth));
        }
        USDG = usdg;
        WETH = weth;
        WETH_POOL = wethPool;
        operator = operator_;
        for (uint8 i = 0; i < DESKS; i++) {
            desks[i].model = models[i];
        }
        emit OperatorSet(operator_);
    }

    // Orders

    /// @notice One order for one desk. `buy` spends `amountIn` USDG on `token`; otherwise it sells
    /// `amountIn` of `token` for USDG. `minOut` is the model's own floor; the feed's floor applies too.
    function trade(uint8 desk, address token, bool buy, uint256 amountIn, uint256 minOut, bytes32 reasoning)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != operator) revert NotOperator();
        if (paused) revert IsPaused();
        if (desk >= DESKS) revert NoDesk();
        if (amountIn == 0) revert ZeroAmount();
        Venue memory venue = venues[token];
        if (!venue.live) revert NotListed(token);
        Desk storage d = desks[desk];
        if (block.timestamp < uint256(d.lastOrderAt) + interval) revert TooSoon(desk);

        uint256 mark = _price(venue.feed, token);
        uint256 floor;
        if (buy) {
            uint256 cap = d.usdg * maxBuyBps / BPS;
            if (amountIn > cap) revert OverCap(amountIn, cap);
            // Tokens the feed says this much USDG buys, less the premium allowed.
            floor = amountIn * 1e18 / mark * (BPS - premiumBps) / BPS;
        } else {
            if (amountIn > holdings[desk][token]) revert Short(amountIn, holdings[desk][token]);
            floor = amountIn * mark / 1e18 * (BPS - premiumBps) / BPS;
        }
        if (minOut > floor) floor = minOut;

        amountOut = _swap(venue.pool, buy ? address(USDG) : token, amountIn);
        if (amountOut < floor) revert OffPrice(amountOut, floor);

        if (buy) {
            d.usdg -= amountIn;
            holdings[desk][token] += amountOut;
        } else {
            holdings[desk][token] -= amountIn;
            d.usdg += amountOut;
        }
        d.lastOrderAt = uint64(block.timestamp);
        d.orders += 1;
        emit Order(desk, token, buy, amountIn, amountOut, mark, reasoning);
    }

    // Money in and out, the owner's

    /// @notice Turns ETH into USDG on the WETH/USDG pool and credits the five desks equally.
    function fundWithEth(uint256 minOut) external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        IWETH9(address(WETH)).deposit{value: msg.value}();
        uint256 out = _swap(WETH_POOL, address(WETH), msg.value);
        if (out < minOut) revert OffPrice(out, minOut);
        uint256 each = out / DESKS;
        for (uint8 i = 0; i < DESKS; i++) {
            uint256 share = i == 0 ? out - each * (DESKS - 1) : each;
            desks[i].usdg += share;
            emit Funded(i, share);
        }
    }

    function fund(uint8 desk, uint256 usdg) external onlyOwner {
        if (desk >= DESKS) revert NoDesk();
        if (usdg == 0) revert ZeroAmount();
        USDG.safeTransferFrom(msg.sender, address(this), usdg);
        desks[desk].usdg += usdg;
        emit Funded(desk, usdg);
    }

    /// @notice Everything a desk holds goes to the owner; the desk stops with an empty book.
    function recall(uint8 desk) external onlyOwner nonReentrant {
        if (desk >= DESKS) revert NoDesk();
        Desk storage d = desks[desk];
        uint256 usdg = d.usdg;
        d.usdg = 0;
        if (usdg != 0) USDG.safeTransfer(owner(), usdg);
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 held = holdings[desk][tokens[i]];
            if (held == 0) continue;
            holdings[desk][tokens[i]] = 0;
            IERC20(tokens[i]).safeTransfer(owner(), held);
        }
        emit Recalled(desk, owner(), usdg);
    }

    // Settings, the owner's

    function setVenue(address token, IUniswapV3PoolLike pool, IAggregatorV3 feed, bool live) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (live) {
            if (address(pool) == address(0) || address(feed) == address(0)) revert ZeroAddress();
            bool pairs = (pool.token0() == token && pool.token1() == address(USDG))
                || (pool.token0() == address(USDG) && pool.token1() == token);
            if (!pairs) revert PoolMismatch(address(pool), token);
            _price(feed, token);
        }
        if (!venues[token].live && live) tokens.push(token);
        venues[token] = Venue({pool: pool, feed: feed, live: live});
        emit VenueSet(token, address(pool), address(feed), live);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setBounds(uint64 interval_, uint16 premiumBps_, uint16 maxBuyBps_, uint256 maxFeedAge_)
        external
        onlyOwner
    {
        if (premiumBps_ > BPS || maxBuyBps_ > BPS) {
            revert OverCap(premiumBps_ > BPS ? premiumBps_ : maxBuyBps_, BPS);
        }
        interval = interval_;
        premiumBps = premiumBps_;
        maxBuyBps = maxBuyBps_;
        maxFeedAge = maxFeedAge_;
        emit BoundsSet(interval_, premiumBps_, maxBuyBps_, maxFeedAge_);
    }

    // Views

    /// @notice A desk's worth in USDG at the feeds: its USDG plus each holding at feed × multiplier.
    function equity(uint8 desk) external view returns (uint256 total) {
        if (desk >= DESKS) revert NoDesk();
        total = desks[desk].usdg;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 held = holdings[desk][tokens[i]];
            if (held == 0) continue;
            total += held * _price(venues[tokens[i]].feed, tokens[i]) / 1e18;
        }
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @notice USDG (6 decimals) per whole token: the feed's USD price times the token's share multiplier.
    function price(address token) external view returns (uint256) {
        Venue memory venue = venues[token];
        if (!venue.live) revert NotListed(token);
        return _price(venue.feed, token);
    }

    // Uniswap v3

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _expectedPool) revert WrongPool(msg.sender);
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    function _swap(IUniswapV3PoolLike pool, address tokenIn, uint256 amountIn) private returns (uint256 amountOut) {
        bool zeroForOne = pool.token0() == tokenIn;
        _expectedPool = address(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        _expectedPool = address(0);
        int256 out = zeroForOne ? amount1 : amount0;
        amountOut = uint256(-out);
    }

    function _price(IAggregatorV3 feed, address token) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0) revert BadFeed(address(feed));
        if (block.timestamp - updatedAt > maxFeedAge) revert StaleFeed(address(feed), updatedAt);
        // 8-decimal USD per share × 18-decimal shares per token, to 6-decimal USDG per token.
        return uint256(answer) * IStockToken(token).uiMultiplier() / 1e20;
    }
}
