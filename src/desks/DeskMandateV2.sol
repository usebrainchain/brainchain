// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IAggregatorV3, IStockToken} from "./DeskMandate.sol";

interface IAllowanceHolder {
    function exec(address operator, address token, uint256 amount, address payable target, bytes calldata data)
        external
        payable
        returns (bytes memory);
}

/// @dev 0x's Settler deployer: an ERC-721 whose token id per feature is owned by the live Settler.
interface ISettlerRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
    function prev(uint128 featureId) external view returns (address);
}

/// @notice Five mandates, one per house model, trading listed tokens against USDG on Robinhood Chain
/// through 0x, with every bound enforced here and every order a public record.
///
/// The operator (the brain's desk key) places orders the models decide, each with the 0x calldata
/// fetched for exactly that order. The contract calls nothing but 0x's AllowanceHolder, approves it
/// for the order's amount alone, and accepts only a Settler that 0x's registry lists for taker
/// flows. Whatever the calldata does, the order is judged by this contract's own balances: it must
/// spend exactly the order's amount of the sold token and receive at least the feed price less
/// `premiumBps`. What orders receive under the feed value of what they give is also summed per desk
/// per UTC day, and may not pass `budgetBps` of the desk's value at the day's first order. A desk
/// never borrows and never shorts, one order per desk per `interval`, a buy spends at most
/// `maxBuyBps` of the desk's USDG, and a stock token is not traded while its share multiplier is
/// changing. Each order carries the hash of the model's reasoning and the SHA-256 of 0x's signed
/// quote body, and no two orders carry the same digest.
///
/// The owner (the treasury Safe) funds, pauses, tunes the bounds and keeps the allowlist. It brings
/// a desk's USDG and each of its positions home one at a time, so a token that refuses to move holds
/// back nothing else; clears from the books a position the issuer burned; and sweeps what arrived
/// outside the books. Ownership cannot be renounced.
contract DeskMandateV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant DESKS = 5;
    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_PREMIUM_BPS = 200;
    uint16 public constant MAX_BUDGET_BPS = 500;
    /// @notice The most tokens ever listed. It bounds every walk over the list.
    uint256 public constant MAX_TOKENS = 16;
    /// @notice How long after a share multiplier change takes effect its token stays closed to orders.
    uint256 public constant SPLIT_GUARD = 1 hours;
    /// @notice The registry's feature id for the Settler that takes taker-submitted (AllowanceHolder) calls.
    uint128 public constant TAKER_SETTLER = 2;

    struct Venue {
        IAggregatorV3 feed;
        bool scaled;
        bool live;
    }

    struct Desk {
        bytes32 model;
        uint256 usdg;
        uint64 lastOrderAt;
        uint32 orders;
        // For the UTC day (days since 1970) of the desk's last order: its value at the feeds before that
        // day's first order, and what the day's orders received under the feed value they gave. They share
        // the slot every order writes anyway.
        uint32 day;
        uint64 dayEquity;
        uint64 dayShortfall;
    }

    // Kept in one struct so trade stays under the stack limit.
    struct Fill {
        uint256 mark;
        uint256 floor;
        address settler;
    }

    IERC20 public immutable USDG;
    address public immutable ALLOWANCE_HOLDER;
    ISettlerRegistry public immutable SETTLERS;

    address public operator;
    bool public paused;
    uint64 public interval = 1 hours;
    uint16 public premiumBps = 100;
    uint16 public maxBuyBps = 5_000;
    uint16 public budgetBps = 100;
    uint64 public maxFeedAge = 3 days;

    Desk[DESKS] public desks;
    mapping(uint8 desk => mapping(address token => uint256)) public holdings;
    mapping(address token => Venue) public venues;
    address[] public tokens;
    mapping(address token => bool) private _seen;
    mapping(bytes32 quote => bool) public quoteUsed;

    event Order(
        uint8 indexed desk,
        address indexed token,
        bool buy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feedPrice,
        uint256 floor,
        uint256 minOut,
        bytes32 reasoning,
        bytes32 indexed quote,
        address settler
    );
    event Funded(uint8 indexed desk, address indexed token, uint256 amount);
    event Recalled(uint8 indexed desk, address indexed token, address indexed to, uint256 amount);
    event WrittenOff(uint8 indexed desk, address indexed token, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event VenueSet(address indexed token, address feed, bool scaled, bool live);
    event OperatorSet(address indexed operator);
    event PausedSet(bool paused);
    event BoundsSet(uint64 interval, uint16 premiumBps, uint16 maxBuyBps, uint64 maxFeedAge, uint16 budgetBps);

    error NotOperator();
    error IsPaused();
    error NoDesk();
    error NotListed(address token);
    error TooSoon(uint8 desk);
    error OverCap(uint256 amount, uint256 cap);
    error Short(uint256 amount, uint256 held);
    error StaleFeed(address feed, uint256 updatedAt);
    error BadFeed(address feed);
    error ZeroPrice(address token);
    error Splitting(address token);
    error UsdgNotAVenue();
    error ListFull();
    error BadDecimals(address token, address feed);
    error OffPrice(uint256 amountOut, uint256 floor);
    error OverBudget(uint256 dayShortfall, uint256 budget);
    error NoQuote();
    error QuoteUsed(bytes32 quote);
    error NotExec(bytes4 selector);
    error WrongSell(address token, uint256 amount);
    error NotSettler(address operator, address target);
    error WrongSpend(uint256 spent, uint256 amountIn);
    error NoRenounce();
    error ZeroAddress();
    error ZeroAmount();

    constructor(
        IERC20 usdg,
        address allowanceHolder,
        ISettlerRegistry settlers,
        address owner_,
        address operator_,
        bytes32[DESKS] memory models
    ) Ownable(owner_) {
        if (
            address(usdg) == address(0) || allowanceHolder == address(0) || address(settlers) == address(0)
                || operator_ == address(0)
        ) revert ZeroAddress();
        USDG = usdg;
        ALLOWANCE_HOLDER = allowanceHolder;
        SETTLERS = settlers;
        operator = operator_;
        for (uint8 i = 0; i < DESKS; i++) {
            desks[i].model = models[i];
        }
        emit OperatorSet(operator_);
    }

    // Orders

    /// @notice One order for one desk. `buy` spends `amountIn` USDG on `token`; otherwise it sells
    /// `amountIn` of `token` for USDG. `swap` is the `transaction.data` of a 0x AllowanceHolder quote
    /// for exactly this sale, with this contract as taker and recipient. `minOut` is the brain's own
    /// floor (the quote's `minBuyAmount`); the feed's floor applies too. `quote` is the SHA-256 of
    /// 0x's response body, the digest its signature covers, and is accepted once.
    function trade(
        uint8 desk,
        address token,
        bool buy,
        uint256 amountIn,
        uint256 minOut,
        bytes32 reasoning,
        bytes32 quote,
        bytes calldata swap
    ) external nonReentrant returns (uint256 amountOut) {
        if (msg.sender != operator) revert NotOperator();
        if (paused) revert IsPaused();
        if (desk >= DESKS) revert NoDesk();
        if (amountIn == 0) revert ZeroAmount();
        if (quote == bytes32(0)) revert NoQuote();
        if (quoteUsed[quote]) revert QuoteUsed(quote);
        quoteUsed[quote] = true;
        Fill memory fill;
        {
            Venue memory venue = venues[token];
            if (!venue.live) revert NotListed(token);
            if (block.timestamp < uint256(desks[desk].lastOrderAt) + interval) revert TooSoon(desk);
            fill.mark = _price(venue, token);
            fill.floor = Math.max(_floor(desk, token, buy, amountIn, fill.mark), minOut);
        }

        (amountOut, fill.settler) =
            buy ? _swap(USDG, IERC20(token), amountIn, swap) : _swap(IERC20(token), USDG, amountIn, swap);
        if (amountOut < fill.floor) revert OffPrice(amountOut, fill.floor);

        _book(desk, token, buy, amountIn, amountOut, fill.mark);
        emit Order(desk, token, buy, amountIn, amountOut, fill.mark, fill.floor, minOut, reasoning, quote, fill.settler);
    }

    // Money in and out, the owner's

    function fund(uint8 desk, uint256 usdg) external onlyOwner nonReentrant {
        if (desk >= DESKS) revert NoDesk();
        if (usdg == 0) revert ZeroAmount();
        USDG.safeTransferFrom(msg.sender, address(this), usdg);
        desks[desk].usdg += usdg;
        emit Funded(desk, address(USDG), usdg);
    }

    /// @notice Moves a position into a desk, as when a desk comes over from the first mandate with its
    /// book. The desk is credited what arrived, not what was sent.
    function fundHolding(uint8 desk, address token, uint256 amount) external onlyOwner nonReentrant {
        if (desk >= DESKS) revert NoDesk();
        if (amount == 0) revert ZeroAmount();
        if (!venues[token].live) revert NotListed(token);
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        holdings[desk][token] += received;
        emit Funded(desk, token, received);
    }

    /// @notice Sends all of a desk's USDG to the owner.
    function recallUsdg(uint8 desk) external onlyOwner nonReentrant returns (uint256 amount) {
        if (desk >= DESKS) revert NoDesk();
        amount = desks[desk].usdg;
        if (amount == 0) revert ZeroAmount();
        desks[desk].usdg = 0;
        USDG.safeTransfer(owner(), amount);
        emit Recalled(desk, address(USDG), owner(), amount);
    }

    /// @notice Sends all of a desk's position in `token` to the owner, listed or not.
    function recallToken(uint8 desk, address token) external onlyOwner nonReentrant returns (uint256 amount) {
        if (desk >= DESKS) revert NoDesk();
        amount = holdings[desk][token];
        if (amount == 0) revert ZeroAmount();
        holdings[desk][token] = 0;
        IERC20(token).safeTransfer(owner(), amount);
        emit Recalled(desk, token, owner(), amount);
    }

    /// @notice Clears `amount` of `token` (USDG included) from a desk's books when the contract holds less
    /// than the desks are booked, as after an issuer burns or seizes it. At most what is missing goes.
    function writeOff(uint8 desk, address token, uint256 amount) external onlyOwner nonReentrant {
        if (desk >= DESKS) revert NoDesk();
        if (amount == 0) revert ZeroAmount();
        uint256 total = _booked(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 missing = total > balance ? total - balance : 0;
        bool isUsdg = token == address(USDG);
        uint256 held = isUsdg ? desks[desk].usdg : holdings[desk][token];
        uint256 cap = Math.min(missing, held);
        if (amount > cap) revert OverCap(amount, cap);
        if (isUsdg) desks[desk].usdg = held - amount;
        else holdings[desk][token] = held - amount;
        emit WrittenOff(desk, token, amount);
    }

    /// @notice Sends `to` whatever the contract holds of `token` beyond what the desks are booked: a stray
    /// transfer or an airdrop. Desk money never moves this way.
    function sweep(address token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 total = _booked(token);
        if (balance <= total) revert ZeroAmount();
        amount = balance - total;
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // Settings, the owner's

    /// @notice Lists or delists a token. `feed` is a Chainlink USD feed with 8 decimals; `scaled` reads
    /// the token's `uiMultiplier` into its price, as the Robinhood stock tokens need.
    function setVenue(address token, IAggregatorV3 feed, bool scaled, bool live) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(USDG)) revert UsdgNotAVenue();
        Venue memory venue = Venue({feed: feed, scaled: scaled, live: live});
        if (live) {
            if (address(feed) == address(0)) revert ZeroAddress();
            // `_price` and `_floor` assume an 18-decimal token priced by an 8-decimal feed.
            if (feed.decimals() != 8 || IERC20Metadata(token).decimals() != 18) {
                revert BadDecimals(token, address(feed));
            }
            _price(venue, token);
            if (!_seen[token]) {
                if (tokens.length == MAX_TOKENS) revert ListFull();
                _seen[token] = true;
                tokens.push(token);
            }
        }
        venues[token] = venue;
        emit VenueSet(token, address(feed), scaled, live);
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

    /// @notice `premiumBps` stops at `MAX_PREMIUM_BPS` and `budgetBps` at `MAX_BUDGET_BPS`. A new
    /// `budgetBps` applies to the day's orders still to come, against the value the desk opened the day at.
    function setBounds(uint64 interval_, uint16 premiumBps_, uint16 maxBuyBps_, uint64 maxFeedAge_, uint16 budgetBps_)
        external
        onlyOwner
    {
        if (premiumBps_ > MAX_PREMIUM_BPS) revert OverCap(premiumBps_, MAX_PREMIUM_BPS);
        if (maxBuyBps_ > BPS) revert OverCap(maxBuyBps_, BPS);
        if (budgetBps_ > MAX_BUDGET_BPS) revert OverCap(budgetBps_, MAX_BUDGET_BPS);
        interval = interval_;
        premiumBps = premiumBps_;
        maxBuyBps = maxBuyBps_;
        maxFeedAge = maxFeedAge_;
        budgetBps = budgetBps_;
        emit BoundsSet(interval_, premiumBps_, maxBuyBps_, maxFeedAge_, budgetBps_);
    }

    /// @notice Always reverts. Only the owner can bring desk money home, so there is always an owner.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }

    // Views

    /// @notice A desk's worth in USDG at the feeds: its USDG plus each holding at the feed price.
    function equity(uint8 desk) external view returns (uint256 total) {
        if (desk >= DESKS) revert NoDesk();
        total = desks[desk].usdg;
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 held = holdings[desk][tokens[i]];
            if (held == 0) continue;
            total += held * _price(venues[tokens[i]], tokens[i]) / 1e18;
        }
    }

    /// @notice A desk's shortfall budget for the current UTC day in USDG, and how much of it the day's
    /// orders have used. Before the day's first order, the budget that order would open.
    function budgetOf(uint8 desk) external view returns (uint256 budget, uint256 used) {
        if (desk >= DESKS) revert NoDesk();
        Desk storage d = desks[desk];
        bool open = d.day == block.timestamp / 1 days;
        budget = (open ? d.dayEquity : _openingEquity(desk)) * budgetBps / BPS;
        used = open ? d.dayShortfall : 0;
    }

    /// @notice What the desks' books say the contract holds of `token`, USDG included.
    function booked(address token) external view returns (uint256) {
        return _booked(token);
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    /// @notice USDG (6 decimals) per whole token: the feed's USD price, times the share multiplier for a
    /// scaled token. Reverts with `Splitting` while that multiplier is changing.
    function price(address token) external view returns (uint256) {
        Venue memory venue = venues[token];
        if (!venue.live) revert NotListed(token);
        return _price(venue, token);
    }

    /// @notice The least an order may receive at the feed, before the brain's own `minOut`.
    function floorOf(uint8 desk, address token, bool buy, uint256 amountIn) external view returns (uint256) {
        if (desk >= DESKS) revert NoDesk();
        Venue memory venue = venues[token];
        if (!venue.live) revert NotListed(token);
        return _floor(desk, token, buy, amountIn, _price(venue, token));
    }

    // 0x

    // AllowanceHolder lets only the `exec` operator pull, only `sold`, only up to the amount and only inside
    // this call, and the ERC-20 approval is the same amount, cleared after. The balance checks hold whatever
    // the Settler's actions are.
    function _swap(IERC20 sold, IERC20 bought, uint256 amountIn, bytes calldata swap)
        private
        returns (uint256 amountOut, address settler)
    {
        if (bytes4(swap) != IAllowanceHolder.exec.selector) revert NotExec(bytes4(swap));
        (address execOperator, address token, uint256 amount, address target) =
            abi.decode(swap[4:], (address, address, uint256, address));
        if (token != address(sold) || amount != amountIn) revert WrongSell(token, amount);
        if (target != execOperator || !_isSettler(target)) revert NotSettler(execOperator, target);

        uint256 soldBefore = sold.balanceOf(address(this));
        uint256 boughtBefore = bought.balanceOf(address(this));
        sold.forceApprove(ALLOWANCE_HOLDER, amountIn);
        Address.functionCall(ALLOWANCE_HOLDER, swap);
        sold.forceApprove(ALLOWANCE_HOLDER, 0);

        uint256 spent = soldBefore - sold.balanceOf(address(this));
        if (spent != amountIn) revert WrongSpend(spent, amountIn);
        amountOut = bought.balanceOf(address(this)) - boughtBefore;
        settler = target;
    }

    // The live taker Settler, or the one before it while 0x's API still quotes for it after a new
    // deployment. A registry that reverts on `ownerOf` has paused Settler, and the order reverts with it.
    function _isSettler(address settler) private view returns (bool) {
        if (SETTLERS.ownerOf(TAKER_SETTLER) == settler) return true;
        try SETTLERS.prev(TAKER_SETTLER) returns (address previous) {
            return previous == settler;
        } catch {
            return false;
        }
    }

    // Books the order and charges its shortfall to the desk's day. The ledger has not moved since the order
    // began, so the day's opening value is the desk before this order.
    function _book(uint8 desk, address token, bool buy, uint256 amountIn, uint256 amountOut, uint256 mark) private {
        Desk storage d = desks[desk];
        uint32 today = uint32(block.timestamp / 1 days);
        uint256 dayEquity = d.dayEquity;
        uint256 dayShortfall = d.dayShortfall;
        if (d.day != today) {
            dayEquity = _openingEquity(desk);
            dayShortfall = 0;
        }
        // Received against the feed value of what was given, in USDG, rounded against the operator.
        uint256 gave = buy ? amountIn : Math.mulDiv(amountIn, mark, 1e18, Math.Rounding.Ceil);
        uint256 got = buy ? amountOut * mark / 1e18 : amountOut;
        if (gave > got) {
            dayShortfall += gave - got;
            uint256 budget = dayEquity * budgetBps / BPS;
            if (dayShortfall > budget) revert OverBudget(dayShortfall, budget);
        }

        if (buy) {
            d.usdg -= amountIn;
            holdings[desk][token] += amountOut;
        } else {
            holdings[desk][token] -= amountIn;
            d.usdg += amountOut;
        }
        d.lastOrderAt = uint64(block.timestamp);
        d.orders += 1;
        d.day = today;
        d.dayEquity = uint64(dayEquity);
        // Raised only up to the budget, which is at most a twentieth of a uint64.
        d.dayShortfall = uint64(dayShortfall);
    }

    // The desk's USDG plus its holdings at the feeds, capped to fit its slot. A holding the contract cannot
    // price now (a stale or broken feed, a multiplier mid-change, a delisted token) counts as nothing, so the
    // budget can come out smaller than the desk but never larger, and one bad feed stops no other order.
    function _openingEquity(uint8 desk) private view returns (uint256 total) {
        total = desks[desk].usdg;
        uint256 count = tokens.length;
        for (uint256 i = 0; i < count; i++) {
            address token = tokens[i];
            uint256 held = holdings[desk][token];
            if (held == 0) continue;
            (bool priced, bytes memory ret) = address(this).staticcall(abi.encodeCall(this.price, (token)));
            if (priced) total += held * abi.decode(ret, (uint256)) / 1e18;
        }
        if (total > type(uint64).max) total = type(uint64).max;
    }

    function _booked(address token) private view returns (uint256 total) {
        bool isUsdg = token == address(USDG);
        for (uint8 i = 0; i < DESKS; i++) {
            total += isUsdg ? desks[i].usdg : holdings[i][token];
        }
    }

    // Rounded up, so no order is let through for less than the feed allows, dust included.
    function _floor(uint8 desk, address token, bool buy, uint256 amountIn, uint256 mark)
        private
        view
        returns (uint256)
    {
        if (buy) {
            uint256 cap = desks[desk].usdg * maxBuyBps / BPS;
            if (amountIn > cap) revert OverCap(amountIn, cap);
            // Tokens the feed says this much USDG buys, less the premium allowed.
            return Math.mulDiv(amountIn, 1e18 * (BPS - premiumBps), mark * BPS, Math.Rounding.Ceil);
        }
        uint256 held = holdings[desk][token];
        if (amountIn > held) revert Short(amountIn, held);
        return Math.mulDiv(amountIn, mark * (BPS - premiumBps), 1e18 * BPS, Math.Rounding.Ceil);
    }

    function _price(Venue memory venue, address token) private view returns (uint256 mark) {
        (, int256 answer,, uint256 updatedAt,) = venue.feed.latestRoundData();
        if (answer <= 0) revert BadFeed(address(venue.feed));
        if (block.timestamp - updatedAt > maxFeedAge) revert StaleFeed(address(venue.feed), updatedAt);
        uint256 multiplier = 1e18;
        if (venue.scaled) {
            // A split or dividend steps the multiplier at `effectiveAt`, while the per-share feed moves only
            // when Chainlink next reports. Until both have settled, the mark can be off by the whole ratio.
            IStockToken stock = IStockToken(token);
            multiplier = stock.uiMultiplier();
            if (stock.newUIMultiplier() != multiplier || block.timestamp < stock.effectiveAt() + SPLIT_GUARD) {
                revert Splitting(token);
            }
        }
        // 8-decimal USD per share × 18-decimal shares per token, to 6-decimal USDG per token.
        mark = uint256(answer) * multiplier / 1e20;
        if (mark == 0) revert ZeroPrice(token);
    }
}
