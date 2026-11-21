// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DeskMandateV2, IAllowanceHolder, IPriceFeed, ISettlerRegistry} from "../src/desks/DeskMandateV2.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockFeed, MockStock, MockWETH} from "./MockVenues.sol";
import {
    IAllowanceHolderPull,
    MockFeeToken,
    MockSettler,
    MockSettlerRegistry,
    MockStickyAllowanceToken
} from "./MockZeroEx.sol";

/// A mandate with two listed stocks priced at their feeds, NVDA at $100 and SPY at $500, behind 0x's real
/// AllowanceHolder (its code read from Robinhood Chain) and a Settler the test drives. The fork suite runs
/// the same contract against 0x's live contracts with real quotes.
abstract contract DeskV2Setup is Test {
    address internal constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    bytes32 internal constant QUOTE = keccak256("0x response body");
    bytes32 internal constant REASONING = keccak256("reasoning");

    address internal owner = makeAddr("safe");
    address internal operator = makeAddr("desk-key");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal usdg;
    MockStock internal nvda;
    MockFeed internal nvdaFeed;
    MockStock internal spy;
    MockFeed internal spyFeed;
    MockSettlerRegistry internal registry;
    MockSettler internal settler;
    DeskMandateV2 internal mandate;
    uint256 internal _quotes;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.etch(ALLOWANCE_HOLDER, vm.parseJsonBytes(vm.readFile("test/fixtures/allowance-holder-4663.json"), ".code"));
        usdg = new MockERC20();
        nvda = new MockStock("NVDA");
        nvdaFeed = new MockFeed(100e8);
        spy = new MockStock("SPY");
        spyFeed = new MockFeed(500e8);
        registry = new MockSettlerRegistry();
        settler = new MockSettler();
        registry.set(address(settler), address(0));

        bytes32[5] memory models =
            [bytes32("claude"), bytes32("gpt"), bytes32("gemini"), bytes32("grok"), bytes32("deepseek")];
        mandate = new DeskMandateV2(
            IERC20(address(usdg)), ALLOWANCE_HOLDER, ISettlerRegistry(address(registry)), owner, operator, models
        );
        vm.startPrank(owner);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, true);
        mandate.setVenue(address(spy), _feed(spyFeed), true, true);
        vm.stopPrank();
        _stock(address(settler));
    }

    function _stock(address s) internal {
        usdg.mint(s, 1_000_000e6);
        nvda.mint(s, 1_000_000e18);
        spy.mint(s, 1_000_000e18);
    }

    function _feed(MockFeed feed) internal pure returns (IPriceFeed) {
        return IPriceFeed(address(feed));
    }

    function _fund(uint8 desk, uint256 amount) internal {
        usdg.mint(owner, amount);
        vm.startPrank(owner);
        usdg.approve(address(mandate), amount);
        mandate.fund(desk, amount);
        vm.stopPrank();
    }

    /// AllowanceHolder calldata whose Settler `via` runs `data`.
    function _exec(address via, address sold, uint256 amount, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeCall(IAllowanceHolder.exec, (via, sold, amount, payable(via), data));
    }

    /// An honest 0x route: the Settler takes `amount` of `sold` and pays `out` of `bought` to the mandate.
    function _swap(address sold, uint256 amount, address bought, uint256 out) internal view returns (bytes memory) {
        return _exec(
            address(settler),
            sold,
            amount,
            abi.encodeCall(MockSettler.fill, (sold, amount, bought, out, address(mandate)))
        );
    }

    function _trade(uint8 desk, address token, bool buy, uint256 amountIn, uint256 out) internal returns (uint256) {
        bytes memory swap =
            buy ? _swap(address(usdg), amountIn, token, out) : _swap(token, amountIn, address(usdg), out);
        vm.prank(operator);
        return mandate.trade(desk, token, buy, amountIn, 0, REASONING, _freshQuote(), swap);
    }

    /// Every order needs a quote of its own.
    function _freshQuote() internal returns (bytes32) {
        return keccak256(abi.encode(QUOTE, _quotes++));
    }

    function _usdgOf(uint8 desk) internal view returns (uint256 usdg_) {
        (, usdg_,,,,,) = mandate.desks(desk);
    }
}

contract DeskMandateV2Test is DeskV2Setup {
    function test_aBuyAndASellMoveTheLedger() public {
        _fund(0, 1_000e6);
        vm.expectEmit(true, true, true, true, address(mandate));
        emit DeskMandateV2.Order(
            0, address(nvda), true, 200e6, 2e18, 100e6, 1.98e18, 0, REASONING, QUOTE, address(settler)
        );
        vm.prank(operator);
        mandate.trade(
            0, address(nvda), true, 200e6, 0, REASONING, QUOTE, _swap(address(usdg), 200e6, address(nvda), 2e18)
        );
        assertEq(mandate.holdings(0, address(nvda)), 2e18);
        (,, uint64 lastOrderAt, uint32 orders,,,) = mandate.desks(0);
        assertEq(_usdgOf(0), 800e6);
        assertEq(lastOrderAt, block.timestamp);
        assertEq(orders, 1);
        assertEq(mandate.equity(0), 1_000e6);

        vm.warp(block.timestamp + 1 hours);
        assertEq(_trade(0, address(nvda), false, 1e18, 100e6), 100e6);
        assertEq(mandate.holdings(0, address(nvda)), 1e18);
        assertEq(_usdgOf(0), 900e6);
        assertEq(nvda.balanceOf(address(mandate)), 1e18);
        assertEq(usdg.balanceOf(address(mandate)), 900e6);
        assertEq(usdg.allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        assertEq(nvda.allowance(address(mandate), ALLOWANCE_HOLDER), 0);
    }

    function test_aBuyMayNotPayMoreThanTheFeedPlusThePremium() public {
        _fund(0, 1_000e6);
        // 100 USDG at $100 buys one token by the feed; the 1% premium sets the floor at 0.99.
        uint256 out = uint256(100e6) * 1e18 / 102e6;
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), out);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, out, 0.99e18));
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);

        assertEq(_trade(0, address(nvda), true, 100e6, 0.99e18), 0.99e18, "a fill at the floor goes through");
    }

    function test_aSellMayNotTakeLessThanTheFeedLessThePremium() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6, 1e18);
        vm.warp(block.timestamp + 1 hours);
        bytes memory swap = _swap(address(nvda), 1e18, address(usdg), 98e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 98e6, 99e6));
        mandate.trade(0, address(nvda), false, 1e18, 0, REASONING, QUOTE, swap);

        assertEq(_trade(0, address(nvda), false, 1e18, 99e6), 99e6, "a fill at the floor goes through");
    }

    function test_theBrainsOwnFloorAppliesWhenItIsHigher() public {
        _fund(0, 1_000e6);
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 1e18, 1.5e18));
        mandate.trade(0, address(nvda), true, 100e6, 1.5e18, REASONING, QUOTE, swap);
    }

    /// A quote fills once: sent again ten minutes later on another desk, or on the same one, it is refused.
    /// An order that reverts leaves its quote unused.
    function test_aQuoteFillsOnce() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 0.9e18, 0.99e18));
        mandate.trade(
            0, address(nvda), true, 100e6, 0, REASONING, QUOTE, _swap(address(usdg), 100e6, address(nvda), 0.9e18)
        );
        assertFalse(mandate.quoteUsed(QUOTE));

        vm.prank(operator);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        assertTrue(mandate.quoteUsed(QUOTE));
        bytes memory used = abi.encodeWithSelector(DeskMandateV2.QuoteUsed.selector, QUOTE);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(operator);
        vm.expectRevert(used);
        mandate.trade(1, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(used);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        assertEq(mandate.holdings(1, address(nvda)), 0);
        assertEq(mandate.holdings(0, address(nvda)), 1e18);
    }

    function test_aBuySpendsAtMostTheCapAndASellAtMostTheHolding() public {
        _fund(0, 1_000e6);
        bytes memory swap = _swap(address(usdg), 500e6 + 1, address(nvda), 5e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 500e6 + 1, 500e6));
        mandate.trade(0, address(nvda), true, 500e6 + 1, 0, REASONING, QUOTE, swap);
        _trade(0, address(nvda), true, 500e6, 5e18);

        vm.warp(block.timestamp + 1 hours);
        // The cap is a share of what the desk holds now.
        swap = _swap(address(usdg), 250e6 + 1, address(nvda), 2.5e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 250e6 + 1, 250e6));
        mandate.trade(0, address(nvda), true, 250e6 + 1, 0, REASONING, QUOTE, swap);
        swap = _swap(address(nvda), 5e18 + 1, address(usdg), 500e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Short.selector, 5e18 + 1, 5e18));
        mandate.trade(0, address(nvda), false, 5e18 + 1, 0, REASONING, QUOTE, swap);
        swap = _swap(address(spy), 1, address(usdg), 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Short.selector, 1, 0));
        mandate.trade(0, address(spy), false, 1, 0, REASONING, QUOTE, swap);
    }

    function test_oneOrderPerDeskPerInterval() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        _trade(0, address(nvda), true, 100e6, 1e18);
        bytes memory swap = _swap(address(usdg), 100e6, address(spy), 0.2e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.TooSoon.selector, uint8(0)));
        mandate.trade(0, address(spy), true, 100e6, 0, REASONING, QUOTE, swap);
        _trade(1, address(nvda), true, 100e6, 1e18);

        vm.warp(block.timestamp + 1 hours - 1);
        swap = _swap(address(nvda), 1e18, address(usdg), 100e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.TooSoon.selector, uint8(0)));
        mandate.trade(0, address(nvda), false, 1e18, 0, REASONING, QUOTE, swap);
        vm.warp(block.timestamp + 1);
        _trade(0, address(nvda), false, 1e18, 100e6);
    }

    function test_aStaleFeedRefusesBuysSellsAndValuation() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6, 1e18);
        uint256 updatedAt = nvdaFeed.updatedAt();

        vm.warp(updatedAt + 3 days);
        assertEq(mandate.price(address(nvda)), 100e6, "a feed exactly maxFeedAge old still prices");
        vm.warp(updatedAt + 3 days + 1);
        bytes memory stale = abi.encodeWithSelector(DeskMandateV2.StaleFeed.selector, address(nvdaFeed), updatedAt);
        bytes memory buy = _swap(address(usdg), 100e6, address(nvda), 1e18);
        bytes memory sell = _swap(address(nvda), 1e18, address(usdg), 100e6);
        vm.prank(operator);
        vm.expectRevert(stale);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, buy);
        vm.prank(operator);
        vm.expectRevert(stale);
        mandate.trade(0, address(nvda), false, 1e18, 0, REASONING, QUOTE, sell);
        vm.expectRevert(stale);
        mandate.equity(0);
        vm.expectRevert(stale);
        mandate.price(address(nvda));
        vm.expectRevert(stale);
        mandate.floorOf(0, address(nvda), false, 1e18);
        vm.prank(owner);
        vm.expectRevert(stale);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, true);

        // A token with a fresh feed still trades, and a fresh answer reopens the stale one.
        spyFeed.set(500e8, block.timestamp);
        _fund(1, 1_000e6);
        _trade(1, address(spy), true, 500e6, 1e18);
        nvdaFeed.set(100e8, block.timestamp);
        _trade(0, address(nvda), false, 1e18, 100e6);
    }

    function test_aZeroOrNegativeAnswerRefuses() public {
        _fund(0, 1_000e6);
        bytes memory bad = abi.encodeWithSelector(DeskMandateV2.BadFeed.selector, address(nvdaFeed));
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        nvdaFeed.set(0, block.timestamp);
        vm.prank(operator);
        vm.expectRevert(bad);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        nvdaFeed.set(-1, block.timestamp);
        vm.expectRevert(bad);
        mandate.price(address(nvda));
    }

    function test_aScaledTokenIsPricedAtTheFeedTimesItsMultiplierAnUnscaledOneAtTheFeed() public {
        assertEq(mandate.price(address(nvda)), 100e6);
        nvda.updateMultiplier(1.5e18, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        nvdaFeed.set(100e8, block.timestamp);
        assertEq(mandate.price(address(nvda)), 150e6);

        MockWETH weth = new MockWETH();
        MockFeed ethFeed = new MockFeed(3_000e8);
        vm.prank(owner);
        mandate.setVenue(address(weth), _feed(ethFeed), false, true);
        assertEq(mandate.price(address(weth)), 3_000e6, "WETH has no multiplier and is not asked for one");

        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotListed.selector, address(usdg)));
        mandate.price(address(usdg));
    }

    function test_onlyTheOperatorTradesAndOnlyWhileUnpaused() public {
        _fund(0, 1_000e6);
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.prank(stranger);
        vm.expectRevert(DeskMandateV2.NotOperator.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        vm.prank(owner);
        vm.expectRevert(DeskMandateV2.NotOperator.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);

        vm.startPrank(operator);
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.trade(5, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.trade(0, address(nvda), true, 0, 0, REASONING, QUOTE, swap);
        vm.expectRevert(DeskMandateV2.NoQuote.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, bytes32(0), swap);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotListed.selector, stranger));
        mandate.trade(0, stranger, true, 100e6, 0, REASONING, QUOTE, swap);
        vm.stopPrank();

        vm.prank(owner);
        mandate.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(DeskMandateV2.IsPaused.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);
        vm.prank(owner);
        mandate.setPaused(false);

        vm.prank(owner);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotListed.selector, address(nvda)));
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap);

        vm.prank(owner);
        mandate.setOperator(stranger);
        vm.prank(stranger);
        mandate.trade(
            0, address(spy), true, 100e6, 0, REASONING, QUOTE, _swap(address(usdg), 100e6, address(spy), 0.2e18)
        );
    }

    function test_eachAssetOfADeskComesHomeOnItsOwnAndTheOtherDesksStay() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        vm.warp(block.timestamp + 1 hours);
        _trade(0, address(spy), true, 400e6, 0.8e18);

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.recallUsdg(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.recallToken(0, address(nvda));
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(mandate));
        emit DeskMandateV2.Recalled(0, address(usdg), owner, 400e6);
        assertEq(mandate.recallUsdg(0), 400e6);
        vm.expectEmit(true, true, true, true, address(mandate));
        emit DeskMandateV2.Recalled(0, address(nvda), owner, 2e18);
        assertEq(mandate.recallToken(0, address(nvda)), 2e18);
        // A delisted token still comes home.
        mandate.setVenue(address(spy), _feed(spyFeed), true, false);
        assertEq(mandate.recallToken(0, address(spy)), 0.8e18);

        // Nothing left to move is a mistake, not a silent success.
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.recallUsdg(0);
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.recallToken(0, address(nvda));
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.recallToken(0, address(usdg));
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.recallUsdg(5);
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.recallToken(5, address(nvda));
        vm.stopPrank();

        assertEq(usdg.balanceOf(owner), 400e6);
        assertEq(nvda.balanceOf(owner), 2e18);
        assertEq(spy.balanceOf(owner), 0.8e18);
        assertEq(_usdgOf(0), 0);
        assertEq(mandate.holdings(0, address(nvda)), 0);
        assertEq(mandate.holdings(0, address(spy)), 0);
        assertEq(mandate.equity(0), 0);
        assertEq(_usdgOf(1), 1_000e6);
        assertEq(usdg.balanceOf(address(mandate)), 1_000e6);
    }

    /// A token that will not move (paused by its issuer, or the mandate blocked) holds back only itself.
    function test_aTokenThatWillNotMoveHoldsBackNothingElse() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        vm.warp(block.timestamp + 1 hours);
        _trade(0, address(spy), true, 400e6, 0.8e18);
        vm.mockCallRevert(address(nvda), abi.encodeWithSelector(IERC20.transfer.selector), "paused");

        vm.startPrank(owner);
        vm.expectRevert("paused");
        mandate.recallToken(0, address(nvda));
        mandate.recallUsdg(0);
        mandate.recallToken(0, address(spy));
        vm.stopPrank();
        assertEq(usdg.balanceOf(owner), 400e6);
        assertEq(spy.balanceOf(owner), 0.8e18);
        assertEq(mandate.holdings(0, address(nvda)), 2e18, "the paused position stays booked");

        vm.clearMockedCalls();
        vm.prank(owner);
        mandate.recallToken(0, address(nvda));
        assertEq(nvda.balanceOf(owner), 2e18);
    }

    function test_aPositionCanBeMovedIntoADeskAndIsCreditedWhatArrives() public {
        nvda.mint(owner, 3e18);
        vm.startPrank(owner);
        nvda.approve(address(mandate), 3e18);
        vm.expectEmit(true, true, false, true, address(mandate));
        emit DeskMandateV2.Funded(3, address(nvda), 3e18);
        mandate.fundHolding(3, address(nvda), 3e18);
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.fundHolding(5, address(nvda), 1);
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.fundHolding(3, address(nvda), 0);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotListed.selector, address(usdg)));
        mandate.fundHolding(3, address(usdg), 1);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.fundHolding(3, address(nvda), 1);

        assertEq(mandate.holdings(3, address(nvda)), 3e18);
        assertEq(mandate.equity(3), 300e6);
        assertEq(_trade(3, address(nvda), false, 3e18, 300e6), 300e6, "the moved book sells like any other");
        assertEq(_usdgOf(3), 300e6);

        // A token that takes a fee on transfer credits the desk what landed.
        MockFeeToken fee = new MockFeeToken();
        MockFeed feeFeed = new MockFeed(1e8);
        fee.mint(owner, 100e18);
        fee.setFee(100, false);
        vm.startPrank(owner);
        mandate.setVenue(address(fee), _feed(feeFeed), false, true);
        fee.approve(address(mandate), 100e18);
        mandate.fundHolding(2, address(fee), 100e18);
        vm.stopPrank();
        assertEq(mandate.holdings(2, address(fee)), 99e18);
        assertEq(fee.balanceOf(address(mandate)), 99e18);
    }

    function test_venuesAreUsdgPairsWithEightDecimalFeedsAndEighteenDecimalTokens() public {
        MockStock tsla = new MockStock("TSLA");
        MockFeed tslaFeed = new MockFeed(300e8);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotListed.selector, address(usdg)));
        mandate.setVenue(address(usdg), _feed(tslaFeed), false, true);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        mandate.setVenue(address(tsla), IPriceFeed(address(0)), true, true);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        mandate.setVenue(address(0), _feed(tslaFeed), true, false);
        tslaFeed.setDecimals(18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.BadDecimals.selector, address(tsla)));
        mandate.setVenue(address(tsla), _feed(tslaFeed), true, true);
        tslaFeed.setDecimals(8);
        MockERC20 sixDecimals = new MockERC20();
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.BadDecimals.selector, address(sixDecimals)));
        mandate.setVenue(address(sixDecimals), _feed(tslaFeed), false, true);
        vm.expectEmit(true, false, false, true, address(mandate));
        emit DeskMandateV2.VenueSet(address(tsla), address(tslaFeed), true, true);
        mandate.setVenue(address(tsla), _feed(tslaFeed), true, true);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setVenue(address(tsla), _feed(tslaFeed), true, false);

        bytes32[5] memory models;
        ISettlerRegistry reg = ISettlerRegistry(address(registry));
        IERC20 u = IERC20(address(usdg));
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        new DeskMandateV2(IERC20(address(0)), ALLOWANCE_HOLDER, reg, owner, operator, models);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        new DeskMandateV2(u, address(0), reg, owner, operator, models);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        new DeskMandateV2(u, ALLOWANCE_HOLDER, ISettlerRegistry(address(0)), owner, operator, models);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        new DeskMandateV2(u, ALLOWANCE_HOLDER, reg, owner, address(0), models);
    }

    function test_relistingATokenKeepsOneEntryAndEquityCountsItOnce() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        vm.startPrank(owner);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, false);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, true);
        vm.stopPrank();
        assertEq(mandate.tokenCount(), 2);
        assertEq(mandate.equity(0), 1_000e6);
    }

    function test_boundsAreTheOwnersAndCapped() public {
        assertEq(mandate.premiumBps(), 100);
        assertEq(mandate.budgetBps(), 100);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 201, 200));
        mandate.setBounds(1 hours, 201, 5_000, 3 days, 100);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 10_001, 10_000));
        mandate.setBounds(1 hours, 100, 10_001, 3 days, 100);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 501, 500));
        mandate.setBounds(1 hours, 100, 5_000, 3 days, 501);
        mandate.setBounds(1 hours, 200, 5_000, 3 days, 500);
        vm.expectEmit(false, false, false, true, address(mandate));
        emit DeskMandateV2.BoundsSet(2 hours, 0, 10_000, 1 days, 0);
        // No premium, no shortfall at all, and the whole desk per order.
        mandate.setBounds(2 hours, 0, 10_000, 1 days, 0);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setBounds(1 hours, 100, 5_000, 3 days, 100);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setOperator(stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setPaused(true);
        vm.prank(owner);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        mandate.setOperator(address(0));

        _fund(0, 1_000e6);
        uint256 out = uint256(1_000e6) * 1e18 / 100.01e6;
        bytes memory swap = _swap(address(usdg), 1_000e6, address(nvda), out);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, out, 10e18));
        mandate.trade(0, address(nvda), true, 1_000e6, 0, REASONING, QUOTE, swap);
        _trade(0, address(nvda), true, 1_000e6, 10e18);
        assertEq(_usdgOf(0), 0);
    }

    function test_theFloorViewIsTheGuard() public {
        _fund(0, 1_000e6);
        assertEq(mandate.floorOf(0, address(nvda), true, 100e6), 0.99e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 600e6, 500e6));
        mandate.floorOf(0, address(nvda), true, 600e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Short.selector, 1e18, 0));
        mandate.floorOf(0, address(nvda), false, 1e18);
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.floorOf(5, address(nvda), true, 1);
        _trade(0, address(nvda), true, 100e6, 1e18);
        assertEq(mandate.floorOf(0, address(nvda), false, 1e18), 99e6);
    }

    /// A 10:1 split on NVDA ($100 a token, one share each). The issuer schedules the multiplier ten minutes
    /// ahead and the per-share feed follows when Chainlink next reports. Until both have moved, the mark is
    /// off by the ratio, so the token takes no orders from the schedule until an hour after the step.
    function test_aMultiplierChangeClosesTheTokenUntilAnHourAfterItTakesEffect() public {
        _fund(0, 1_000e6);
        uint256 effective = block.timestamp + 10 minutes;
        nvda.updateMultiplier(10e18, effective);
        bytes memory splitting = abi.encodeWithSelector(DeskMandateV2.Splitting.selector, address(nvda));
        // A tenth of the fair amount less the premium: what the stepped multiplier on the old feed would pass.
        bytes memory tenth = _swap(address(usdg), 100e6, address(nvda), 0.099e18);
        vm.expectRevert(splitting);
        mandate.price(address(nvda));

        vm.warp(effective);
        assertEq(nvda.uiMultiplier(), 10e18, "in force, with the feed still at $100 a share");
        vm.prank(operator);
        vm.expectRevert(splitting);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, tenth);
        vm.expectRevert(splitting);
        mandate.floorOf(0, address(nvda), true, 100e6);
        _trade(0, address(spy), true, 100e6, 0.2e18);

        vm.warp(effective + 20 minutes);
        nvdaFeed.set(10e8, block.timestamp);
        vm.warp(effective + 1 hours - 1);
        vm.expectRevert(splitting);
        mandate.price(address(nvda));
        vm.warp(effective + 1 hours);
        assertEq(mandate.price(address(nvda)), 100e6, "ten shares at $10: $100 a token again");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 0.099e18, 0.99e18));
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, tenth);
        assertEq(_trade(0, address(nvda), true, 100e6, 1e18), 1e18);
    }

    /// The feed can move first: SPY's 2:1 split reported at $250 a share while the multiplier still counts
    /// one share a token. A sell at half its worth would clear that floor; the pending step refuses it.
    function test_aFeedThatMovesBeforeTheMultiplierIsRefusedToo() public {
        _fund(0, 1_000e6);
        _trade(0, address(spy), true, 500e6, 1e18);
        vm.warp(block.timestamp + 1 hours);
        uint256 effective = block.timestamp + 10 minutes;
        spy.updateMultiplier(2e18, effective);
        spyFeed.set(250e8, block.timestamp);
        bytes memory splitting = abi.encodeWithSelector(DeskMandateV2.Splitting.selector, address(spy));
        bytes memory half = _swap(address(spy), 1e18, address(usdg), 250e6);
        vm.expectRevert(splitting);
        mandate.floorOf(0, address(spy), false, 1e18);
        vm.prank(operator);
        vm.expectRevert(splitting);
        mandate.trade(0, address(spy), false, 1e18, 0, REASONING, QUOTE, half);

        vm.warp(effective + 1 hours);
        assertEq(mandate.floorOf(0, address(spy), false, 1e18), 495e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 250e6, 495e6));
        mandate.trade(0, address(spy), false, 1e18, 0, REASONING, QUOTE, half);
    }

    function test_aPriceThatRoundsToZeroIsRefused() public {
        bytes memory zero = abi.encodeWithSelector(DeskMandateV2.ZeroPrice.selector, address(nvda));
        // Under a cent of a USDG unit a share.
        nvdaFeed.set(99, block.timestamp);
        vm.expectRevert(zero);
        mandate.price(address(nvda));
        nvdaFeed.set(100e8, block.timestamp);
        nvda.setMultiplier(1);
        vm.expectRevert(zero);
        mandate.price(address(nvda));
        vm.prank(owner);
        vm.expectRevert(zero);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, true);
        _fund(0, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(zero);
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, _swap(address(usdg), 100e6, address(nvda), 1));
    }

    function test_ownershipCannotBeRenounced() public {
        _fund(0, 1_000e6);
        vm.prank(owner);
        vm.expectRevert(DeskMandateV2.NoRenounce.selector);
        mandate.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(DeskMandateV2.NoRenounce.selector);
        mandate.renounceOwnership();
        assertEq(mandate.owner(), owner);
        vm.prank(owner);
        mandate.recallUsdg(0);
        assertEq(usdg.balanceOf(owner), 1_000e6);
    }

    /// The floor rounds up, so even a sell too small to be worth one USDG unit must receive one.
    function test_aDustSellMustReceiveSomething() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6, 1e18);
        vm.warp(block.timestamp + 1 hours);
        uint256 dust = 1e10 - 1;
        assertEq(mandate.floorOf(0, address(nvda), false, dust), 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 0, 1));
        mandate.trade(0, address(nvda), false, dust, 0, REASONING, QUOTE, _swap(address(nvda), dust, address(usdg), 0));
        assertEq(_trade(0, address(nvda), false, dust, 1), 1);
    }

    function test_theTokenListStopsAtItsCap() public {
        MockFeed feed = new MockFeed(1e8);
        vm.startPrank(owner);
        for (uint256 i = mandate.tokenCount(); i < mandate.MAX_TOKENS(); i++) {
            mandate.setVenue(address(new MockStock("X")), _feed(feed), false, true);
        }
        address extra = address(new MockStock("X"));
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 17, 16));
        mandate.setVenue(extra, _feed(feed), false, true);
        // Delisting and relisting a token already counted still works.
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, false);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, true);
        vm.stopPrank();
        assertEq(mandate.tokenCount(), 16);
    }

    /// Whatever fills the Settler gives, desk ledgers add up to the contract's balances, no approval is left
    /// and no desk's day goes over its budget. A day and an hour of orders, so each budget opens twice.
    function testFuzz_theLedgersAlwaysAddUpToTheBalances(uint256 seed) public {
        for (uint8 i = 0; i < 5; i++) {
            _fund(i, 1_000e6);
        }
        for (uint256 step = 0; step < 25; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint8 desk = uint8(r % 5);
            bool buy = (r >> 8) % 3 != 0;
            // Fills from 2% under to 2% over the feed, so some clear the 1% guard and some do not.
            uint256 fillBps = 9_800 + (r >> 16) % 401;
            uint256 amountIn;
            uint256 out;
            if (buy) {
                amountIn = 1 + (r >> 32) % (_usdgOf(desk) / 2 + 1);
                out = amountIn * 1e12 / 100 * fillBps / 10_000;
            } else {
                uint256 held = mandate.holdings(desk, address(nvda));
                if (held == 0) continue;
                amountIn = 1 + (r >> 32) % held;
                out = amountIn / 1e10 * fillBps / 10_000;
            }
            bytes memory swap = buy
                ? _swap(address(usdg), amountIn, address(nvda), out)
                : _swap(address(nvda), amountIn, address(usdg), out);
            vm.prank(operator);
            try mandate.trade(desk, address(nvda), buy, amountIn, 0, REASONING, _freshQuote(), swap) {} catch {}
            vm.warp(block.timestamp + 1 hours);

            uint256 ledgerUsdg;
            uint256 ledgerNvda;
            for (uint8 d = 0; d < 5; d++) {
                ledgerUsdg += _usdgOf(d);
                ledgerNvda += mandate.holdings(d, address(nvda));
            }
            assertEq(ledgerUsdg, usdg.balanceOf(address(mandate)));
            assertEq(ledgerNvda, nvda.balanceOf(address(mandate)));
            (,,,,, uint64 dayEquity, uint64 dayShortfall) = mandate.desks(desk);
            assertLe(dayShortfall, uint256(dayEquity) * mandate.budgetBps() / 10_000, "never over the budget");
            assertEq(usdg.allowance(address(mandate), ALLOWANCE_HOLDER), 0);
            assertEq(nvda.allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        }
        uint256 orders;
        for (uint8 d = 0; d < 5; d++) {
            (,,, uint32 n,,,) = mandate.desks(d);
            orders += n;
        }
        assertGt(orders, 0, "some orders went through");
    }
}

/// What the 0x calldata may and may not do. Each case is calldata a buggy or hostile quote could carry.
contract DeskMandateV2ZeroExTest is DeskV2Setup {
    function setUp() public override {
        super.setUp();
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
    }

    function _attempt(uint8 desk, address token, bool buy, uint256 amountIn, bytes memory swap) internal {
        vm.prank(operator);
        mandate.trade(desk, token, buy, amountIn, 0, REASONING, QUOTE, swap);
    }

    function test_theOnlyCallIsAllowanceHolderExec() public {
        bytes4 pull = IAllowanceHolderPull.transferFrom.selector;
        bytes memory steal = abi.encodeWithSelector(pull, address(usdg), address(mandate), stranger, 100e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotExec.selector, pull));
        _attempt(0, address(nvda), true, 100e6, steal);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotExec.selector, bytes4(0)));
        _attempt(0, address(nvda), true, 100e6, "");
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotExec.selector, bytes4(0x2213bc00)));
        _attempt(0, address(nvda), true, 100e6, hex"2213bc");
        // The selector alone, or its head cut short, does not decode.
        vm.expectRevert();
        _attempt(0, address(nvda), true, 100e6, abi.encodePacked(IAllowanceHolder.exec.selector, bytes32(0)));
        assertEq(usdg.balanceOf(address(mandate)), 2_000e6);
    }

    function test_execMustSellTheOrdersTokenAndExactlyItsAmount() public {
        _trade(1, address(nvda), true, 100e6, 1e18);
        bytes memory otherToken = _exec(
            address(settler),
            address(nvda),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(nvda), 1e18, address(nvda), 0, address(mandate)))
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.WrongSell.selector, address(nvda), 100e6));
        _attempt(0, address(nvda), true, 100e6, otherToken);

        bytes memory more = _swap(address(usdg), 100e6 + 1, address(nvda), 1e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.WrongSell.selector, address(usdg), 100e6 + 1));
        _attempt(0, address(nvda), true, 100e6, more);

        bytes memory less = _swap(address(usdg), 100e6 - 1, address(nvda), 1e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.WrongSell.selector, address(usdg), 100e6 - 1));
        _attempt(0, address(nvda), true, 100e6, less);
    }

    function test_theOperatorAndTargetMustBeTheRegistrysSettler() public {
        MockSettler rogue = new MockSettler();
        _stock(address(rogue));
        bytes memory fill =
            abi.encodeCall(MockSettler.fill, (address(usdg), 100e6, address(nvda), 1e18, address(mandate)));

        bytes memory viaRogue = _exec(address(rogue), address(usdg), 100e6, fill);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, address(rogue), address(rogue)));
        _attempt(0, address(nvda), true, 100e6, viaRogue);

        bytes memory rogueTarget = abi.encodeCall(
            IAllowanceHolder.exec, (address(settler), address(usdg), 100e6, payable(address(rogue)), fill)
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, address(settler), address(rogue)));
        _attempt(0, address(nvda), true, 100e6, rogueTarget);

        bytes memory rogueOperator = abi.encodeCall(
            IAllowanceHolder.exec, (address(rogue), address(usdg), 100e6, payable(address(settler)), fill)
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, address(rogue), address(settler)));
        _attempt(0, address(nvda), true, 100e6, rogueOperator);

        // An ERC-20 as the target is refused here and by AllowanceHolder's own confused-deputy check.
        bytes memory tokenTarget = abi.encodeCall(
            IAllowanceHolder.exec,
            (
                address(usdg),
                address(usdg),
                100e6,
                payable(address(usdg)),
                abi.encodeCall(IERC20.transfer, (stranger, 100e6))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, address(usdg), address(usdg)));
        _attempt(0, address(nvda), true, 100e6, tokenTarget);
    }

    function test_thePreviousSettlerTradesWhileTheApiDwells() public {
        MockSettler next = new MockSettler();
        _stock(address(next));
        registry.set(address(next), address(settler));
        _trade(0, address(nvda), true, 100e6, 1e18);

        registry.set(address(next), address(0));
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, address(settler), address(settler)));
        _attempt(0, address(nvda), true, 100e6, swap);

        bytes memory viaNext = _exec(
            address(next),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(usdg), 100e6, address(nvda), 1e18, address(mandate)))
        );
        vm.prank(operator);
        vm.expectEmit(true, true, true, true, address(mandate));
        emit DeskMandateV2.Order(
            0, address(nvda), true, 100e6, 1e18, 100e6, 0.99e18, 0, REASONING, QUOTE, address(next)
        );
        mandate.trade(0, address(nvda), true, 100e6, 0, REASONING, QUOTE, viaNext);
    }

    function test_aPausedSettlerStopsEveryOrder() public {
        registry.setPaused(true);
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.expectRevert(MockSettlerRegistry.SettlerPaused.selector);
        _attempt(0, address(nvda), true, 100e6, swap);
    }

    function test_theApprovalIsTheOrderAndIsGoneAfter() public {
        _trade(0, address(nvda), true, 100e6, 1e18);
        assertEq(settler.allowanceSeen(), 100e6, "AllowanceHolder may pull the order's amount and no more");
        assertEq(usdg.allowance(address(mandate), ALLOWANCE_HOLDER), 0);

        // Nothing is left to pull once the order is done, by the Settler or anyone.
        vm.prank(address(settler));
        vm.expectRevert(stdError.arithmeticError);
        IAllowanceHolderPull(ALLOWANCE_HOLDER).transferFrom(address(usdg), address(mandate), stranger, 1);

        // A token whose transferFrom leaves the allowance standing still ends at zero.
        MockStickyAllowanceToken sticky = new MockStickyAllowanceToken();
        MockFeed stickyFeed = new MockFeed(1e8);
        sticky.mint(owner, 10e18);
        vm.startPrank(owner);
        mandate.setVenue(address(sticky), _feed(stickyFeed), false, true);
        sticky.approve(address(mandate), 10e18);
        mandate.fundHolding(1, address(sticky), 10e18);
        vm.stopPrank();
        _trade(1, address(sticky), false, 10e18, 10e6);
        assertEq(sticky.allowance(address(mandate), ALLOWANCE_HOLDER), 0);
    }

    function test_aSettlerCannotPullMoreThanTheOrderNorAnotherToken() public {
        bytes memory more = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(usdg), 100e6 + 1, address(nvda), 1e18, address(mandate)))
        );
        vm.expectRevert(stdError.arithmeticError);
        _attempt(0, address(nvda), true, 100e6, more);

        // Desk 1 holds NVDA in the same contract; a USDG buy's Settler cannot reach it.
        _trade(1, address(nvda), true, 100e6, 1e18);
        bytes memory other = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(nvda), 1e18, address(nvda), 1e18, address(mandate)))
        );
        vm.expectRevert(stdError.arithmeticError);
        _attempt(0, address(nvda), true, 100e6, other);
        assertEq(nvda.balanceOf(address(mandate)), 1e18);
    }

    function test_aSettlerThatTakesLessThanTheOrderIsRefused() public {
        bytes memory short = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(usdg), 100e6 - 1, address(nvda), 1e18, address(mandate)))
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Spent.selector, 100e6 - 1, 100e6));
        _attempt(0, address(nvda), true, 100e6, short);
    }

    function test_calldataThatPaysSomeoneElseIsRefused() public {
        bytes memory elsewhere = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fill, (address(usdg), 100e6, address(nvda), 1e18, stranger))
        );
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 0, 0.99e18));
        _attempt(0, address(nvda), true, 100e6, elsewhere);
        assertEq(nvda.balanceOf(stranger), 0);
        assertEq(usdg.balanceOf(address(mandate)), 2_000e6);
    }

    function test_noEtherMovesInOrOut() public {
        vm.deal(address(settler), 1 ether);
        bytes memory inEth = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.fillInEth, (address(usdg), 100e6, 1 ether))
        );
        vm.expectRevert(Address.FailedInnerCall.selector);
        _attempt(0, address(nvda), true, 100e6, inEth);

        vm.deal(operator, 1 ether);
        bytes memory swap = _swap(address(usdg), 100e6, address(nvda), 1e18);
        vm.prank(operator);
        (bool sent,) = address(mandate).call{value: 1}(
            abi.encodeCall(DeskMandateV2.trade, (0, address(nvda), true, 100e6, 0, REASONING, QUOTE, swap))
        );
        assertFalse(sent, "trade takes no value");
        vm.prank(operator);
        (sent,) = address(mandate).call{value: 1}("");
        assertFalse(sent, "the mandate takes no ether");
    }

    function test_theSettlerCannotReenter() public {
        bytes memory inner = _swap(address(usdg), 100e6, address(nvda), 1e18);
        bytes memory reenterTrade = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(
                MockSettler.reenter,
                (abi.encodeCall(DeskMandateV2.trade, (1, address(nvda), true, 100e6, 0, REASONING, QUOTE, inner)))
            )
        );
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        _attempt(0, address(nvda), true, 100e6, reenterTrade);

        bytes memory reenterRecall = _exec(
            address(settler),
            address(usdg),
            100e6,
            abi.encodeCall(MockSettler.reenter, (abi.encodeCall(DeskMandateV2.recallUsdg, (1))))
        );
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(settler)));
        _attempt(0, address(nvda), true, 100e6, reenterRecall);
    }

    function test_aFeeOnTheBoughtTokenIsBookedNetAndHeldToTheFloor() public {
        MockFeeToken fee = new MockFeeToken();
        MockFeed feeFeed = new MockFeed(1e8);
        fee.mint(address(settler), 1_000e18);
        vm.prank(owner);
        mandate.setVenue(address(fee), _feed(feeFeed), false, true);

        // 100 USDG at $1 a token: the floor is 99 tokens. A 1% fee lands 99; a 3% fee lands 97.
        fee.setFee(100, false);
        assertEq(_trade(0, address(fee), true, 100e6, 100e18), 99e18);
        assertEq(mandate.holdings(0, address(fee)), 99e18);
        assertEq(fee.balanceOf(address(mandate)), 99e18);

        fee.setFee(300, false);
        bytes memory swap = _swap(address(usdg), 100e6, address(fee), 100e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 97e18, 99e18));
        _attempt(1, address(fee), true, 100e6, swap);
    }

    function test_aFeeTheSellerPaysOnTopIsRefused() public {
        MockFeeToken fee = new MockFeeToken();
        MockFeed feeFeed = new MockFeed(1e8);
        fee.mint(owner, 20e18);
        vm.startPrank(owner);
        mandate.setVenue(address(fee), _feed(feeFeed), false, true);
        fee.approve(address(mandate), 20e18);
        mandate.fundHolding(0, address(fee), 10e18);
        mandate.fundHolding(1, address(fee), 10e18);
        vm.stopPrank();

        fee.setFee(100, true);
        bytes memory swap = _swap(address(fee), 10e18, address(usdg), 10e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Spent.selector, 10.1e18, 10e18));
        _attempt(0, address(fee), false, 10e18, swap);
    }
}

/// The day's shortfall budget: what orders received under the feed value of what they gave, summed per desk
/// per UTC day, against `budgetBps` of the desk's value before the day's first order.
contract DeskMandateV2BudgetTest is DeskV2Setup {
    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _nextDay() internal {
        vm.warp((_today() + 1) * 1 days + 1 hours);
        nvdaFeed.set(100e8, block.timestamp);
        spyFeed.set(500e8, block.timestamp);
    }

    function _budget(uint8 desk) internal view returns (uint256 budget) {
        (budget,) = mandate.budgetOf(desk);
    }

    function _used(uint8 desk) internal view returns (uint256 used) {
        (, used) = mandate.budgetOf(desk);
    }

    /// Every order may take the whole premium, but the day's orders together may take only the budget:
    /// 1% of the desk, 10 USDG on 1,000, however the shortfall is spread.
    function test_aDaysShortfallStopsAtTheBudget() public {
        _fund(0, 1_000e6);
        uint256 day = _today();
        (uint256 budget, uint256 used) = mandate.budgetOf(0);
        assertEq(budget, 10e6);
        assertEq(used, 0);

        // Over the feed earns nothing back.
        _trade(0, address(nvda), true, 100e6, 1.01e18);
        assertEq(_used(0), 0);
        vm.warp(block.timestamp + 1 hours);
        // At the floor, a buy gives up 1% of what it spends and a sell 1% of what it sells.
        _trade(0, address(nvda), true, 400e6, 3.96e18);
        assertEq(_used(0), 4e6);
        vm.warp(block.timestamp + 1 hours);
        _trade(0, address(nvda), false, 4.97e18, 492.03e6);
        assertEq(_used(0), 8.97e6);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverBudget.selector, 10.97e6, 10e6));
        mandate.trade(
            0, address(nvda), true, 200e6, 0, REASONING, QUOTE, _swap(address(usdg), 200e6, address(nvda), 1.98e18)
        );
        // Up to the budget exactly, then only fills at or over the feed.
        _trade(0, address(nvda), true, 200e6, 1.9897e18);
        assertEq(_used(0), 10e6);
        vm.warp(block.timestamp + 1 hours);
        _trade(0, address(nvda), true, 100e6, 1e18);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverBudget.selector, 10e6 + 1, 10e6));
        mandate.trade(
            0, address(nvda), true, 100e6, 0, REASONING, QUOTE, _swap(address(usdg), 100e6, address(nvda), 1e18 - 1e10)
        );
        assertEq(_today(), day, "all on one UTC day");

        // A new day opens a new budget on what the desk is worth then.
        _nextDay();
        assertEq(_budget(0), mandate.equity(0) / 100);
        assertEq(_used(0), 0);
        _trade(0, address(nvda), true, 100e6, 0.99e18);
        assertEq(_used(0), 1e6);
    }

    function test_theBudgetIsTheDesksValueAtTheDaysFirstOrder() public {
        _fund(2, 500e6);
        spy.mint(owner, 1e18);
        vm.startPrank(owner);
        spy.approve(address(mandate), 1e18);
        mandate.fundHolding(2, address(spy), 1e18);
        vm.stopPrank();
        assertEq(_budget(2), 10e6, "500 USDG and one SPY at $500");

        _trade(2, address(nvda), true, 100e6, 1e18);
        (,,,, uint32 day, uint64 dayEquity, uint64 dayShortfall) = mandate.desks(2);
        assertEq(day, _today());
        assertEq(dayEquity, 1_000e6);
        assertEq(dayShortfall, 0);

        // Neither new money nor a rising price raises today's budget.
        _fund(2, 1_000e6);
        spyFeed.set(1_000e8, block.timestamp);
        assertEq(_budget(2), 10e6);

        _nextDay();
        spyFeed.set(1_000e8, block.timestamp);
        assertEq(_budget(2), 25e6, "1,400 USDG, one NVDA at $100 and one SPY at $1,000");
    }

    /// A holding the contract cannot price counts as nothing toward the budget, and stops no other order.
    function test_aHoldingThatCannotBePricedCountsAsNothing() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        _nextDay();
        assertEq(_budget(0), 10e6);

        nvdaFeed.set(100e8, block.timestamp - 3 days - 1);
        assertEq(_budget(0), 8e6, "a stale feed");
        vm.expectRevert(
            abi.encodeWithSelector(DeskMandateV2.StaleFeed.selector, address(nvdaFeed), block.timestamp - 3 days - 1)
        );
        mandate.equity(0);
        nvdaFeed.set(100e8, block.timestamp);
        nvda.updateMultiplier(2e18, block.timestamp + 10 minutes);
        assertEq(_budget(0), 8e6, "a multiplier mid-change");
        vm.startPrank(owner);
        mandate.setVenue(address(nvda), _feed(nvdaFeed), true, false);
        assertEq(_budget(0), 8e6, "delisted");
        vm.stopPrank();

        _trade(0, address(spy), true, 100e6, 0.2e18);
        (,,,,, uint64 dayEquity,) = mandate.desks(0);
        assertEq(dayEquity, 800e6);
    }

    /// The owner can tighten the budget mid-day; it applies at once against the day's opening value.
    function test_aNewBudgetAppliesToTheRestOfTheDay() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6, 0.99e18);
        vm.prank(owner);
        mandate.setBounds(1 hours, 100, 5_000, 3 days, 0);
        assertEq(_budget(0), 0);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverBudget.selector, 2e6, 0));
        mandate.trade(
            0, address(nvda), true, 100e6, 0, REASONING, QUOTE, _swap(address(usdg), 100e6, address(nvda), 0.99e18)
        );
        assertEq(_trade(0, address(nvda), true, 100e6, 1e18), 1e18, "a fill at the feed still goes through");
        assertEq(_used(0), 1e6, "over the new budget, and no order adds to it");

        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.budgetOf(5);
    }
}

/// The owner's ways to put the books right: write off what an issuer took, sweep what arrived outside them.
contract DeskMandateV2BooksTest is DeskV2Setup {
    function test_aDirectTransferComesOutBySweepAndDeskMoneyDoesNot() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        usdg.mint(owner, 50e6);
        vm.prank(owner);
        usdg.transfer(address(mandate), 50e6); // a Safe batch that transfers instead of approve + fund
        nvda.mint(address(mandate), 0.5e18);
        MockERC20 airdrop = new MockERC20();
        airdrop.mint(address(mandate), 7e6);
        assertEq(mandate.booked(address(usdg)), 800e6);
        assertEq(mandate.booked(address(nvda)), 2e18);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.sweep(address(usdg), stranger);
        vm.startPrank(owner);
        vm.expectRevert(DeskMandateV2.ZeroAddress.selector);
        mandate.sweep(address(usdg), address(0));
        vm.expectEmit(true, true, false, true, address(mandate));
        emit DeskMandateV2.Swept(address(usdg), owner, 50e6);
        assertEq(mandate.sweep(address(usdg), owner), 50e6);
        assertEq(mandate.sweep(address(nvda), owner), 0.5e18);
        assertEq(mandate.sweep(address(airdrop), stranger), 7e6);
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.sweep(address(usdg), owner);
        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.sweep(address(nvda), owner);
        vm.stopPrank();

        assertEq(usdg.balanceOf(address(mandate)), 800e6, "the desk's USDG stays");
        assertEq(nvda.balanceOf(address(mandate)), 2e18, "and so does its position");
        assertEq(airdrop.balanceOf(stranger), 7e6);
        vm.startPrank(owner);
        mandate.recallUsdg(0);
        mandate.recallToken(0, address(nvda));
        vm.stopPrank();
        assertEq(usdg.balanceOf(owner), 850e6);
        assertEq(nvda.balanceOf(owner), 2.5e18);
    }

    /// An issuer burns three of the four NVDA two desks hold. The owner decides whose books carry it, and can
    /// clear no more than went missing.
    function test_aBurnedPositionIsWrittenOffUpToWhatIsMissing() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        _trade(0, address(nvda), true, 200e6, 2e18);
        _trade(1, address(nvda), true, 200e6, 2e18);
        deal(address(nvda), address(mandate), 1e18);

        vm.startPrank(owner);
        vm.expectRevert();
        mandate.recallToken(0, address(nvda));
        mandate.recallUsdg(0);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 2e18 + 1, 2e18));
        mandate.writeOff(0, address(nvda), 2e18 + 1);
        vm.expectEmit(true, true, false, true, address(mandate));
        emit DeskMandateV2.WrittenOff(0, address(nvda), 2e18);
        mandate.writeOff(0, address(nvda), 2e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 1e18 + 1, 1e18));
        mandate.writeOff(1, address(nvda), 1e18 + 1);
        mandate.writeOff(1, address(nvda), 1e18);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 1, 0));
        mandate.writeOff(1, address(nvda), 1);
        assertEq(mandate.recallToken(1, address(nvda)), 1e18);

        // USDG taken from the contract comes off the books the same way.
        deal(address(usdg), address(mandate), 790e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, 10e6 + 1, 10e6));
        mandate.writeOff(1, address(usdg), 10e6 + 1);
        mandate.writeOff(1, address(usdg), 10e6);
        assertEq(mandate.booked(address(usdg)), 790e6);
        assertEq(mandate.recallUsdg(1), 790e6);

        vm.expectRevert(DeskMandateV2.ZeroAmount.selector);
        mandate.writeOff(1, address(nvda), 0);
        vm.expectRevert(DeskMandateV2.NoDesk.selector);
        mandate.writeOff(5, address(nvda), 1);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.writeOff(1, address(nvda), 1);

        assertEq(mandate.equity(0), 0);
        assertEq(mandate.equity(1), 0);
        assertEq(nvda.balanceOf(owner), 1e18);
    }
}
