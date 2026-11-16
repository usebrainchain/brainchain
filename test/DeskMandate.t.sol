// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeskMandate, IUniswapV3PoolLike, IAggregatorV3} from "../src/desks/DeskMandate.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockFeed, MockPool, MockStock, MockWETH} from "./MockVenues.sol";

/// A mandate with two listed stocks priced at their feeds: NVDA at $100 on a pool where the stock is
/// token0, SPY at $500 on one where USDG is. The fork suite runs the same contract against the real venues.
abstract contract DeskSetup is Test {
    address internal owner = makeAddr("safe");
    address internal operator = makeAddr("desk-key");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal usdg;
    MockWETH internal weth;
    MockPool internal wethPool;
    MockStock internal nvda;
    MockFeed internal nvdaFeed;
    MockPool internal nvdaPool;
    MockStock internal spy;
    MockFeed internal spyFeed;
    MockPool internal spyPool;
    DeskMandate internal mandate;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        usdg = new MockERC20();
        weth = new MockWETH();
        wethPool = new MockPool(address(weth), address(usdg), address(usdg), 3_000e6);
        nvda = new MockStock("NVDA");
        nvdaFeed = new MockFeed(100e8);
        nvdaPool = new MockPool(address(nvda), address(usdg), address(usdg), 100e6);
        spy = new MockStock("SPY");
        spyFeed = new MockFeed(500e8);
        spyPool = new MockPool(address(usdg), address(spy), address(usdg), 500e6);
        usdg.mint(address(wethPool), 1_000_000e6);
        usdg.mint(address(nvdaPool), 1_000_000e6);
        usdg.mint(address(spyPool), 1_000_000e6);
        nvda.mint(address(nvdaPool), 1_000_000e18);
        spy.mint(address(spyPool), 1_000_000e18);

        bytes32[5] memory models =
            [bytes32("claude"), bytes32("gpt"), bytes32("gemini"), bytes32("grok"), bytes32("deepseek")];
        mandate =
            new DeskMandate(IERC20(address(usdg)), IERC20(address(weth)), _pool(wethPool), owner, operator, models);
        vm.startPrank(owner);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), true);
        mandate.setVenue(address(spy), _pool(spyPool), _feed(spyFeed), true);
        vm.stopPrank();
    }

    function _pool(MockPool pool) internal pure returns (IUniswapV3PoolLike) {
        return IUniswapV3PoolLike(address(pool));
    }

    function _feed(MockFeed feed) internal pure returns (IAggregatorV3) {
        return IAggregatorV3(address(feed));
    }

    function _fund(uint8 desk, uint256 amount) internal {
        usdg.mint(owner, amount);
        vm.startPrank(owner);
        usdg.approve(address(mandate), amount);
        mandate.fund(desk, amount);
        vm.stopPrank();
    }

    function _trade(uint8 desk, address token, bool buy, uint256 amountIn) internal returns (uint256) {
        vm.prank(operator);
        return mandate.trade(desk, token, buy, amountIn, 0, keccak256("reasoning"));
    }

    function _usdgOf(uint8 desk) internal view returns (uint256 usdg_) {
        (, usdg_,,) = mandate.desks(desk);
    }
}

contract DeskMandateTest is DeskSetup {
    function test_aBuyAndASellMoveTheLedger() public {
        _fund(0, 1_000e6);
        vm.expectEmit(true, true, false, true, address(mandate));
        emit DeskMandate.Order(0, address(nvda), true, 200e6, 2e18, 100e6, keccak256("reasoning"));
        assertEq(_trade(0, address(nvda), true, 200e6), 2e18);
        assertEq(mandate.holdings(0, address(nvda)), 2e18);
        (,, uint64 lastOrderAt, uint32 orders) = mandate.desks(0);
        assertEq(_usdgOf(0), 800e6);
        assertEq(lastOrderAt, block.timestamp);
        assertEq(orders, 1);
        assertEq(mandate.equity(0), 1_000e6);

        vm.warp(block.timestamp + 1 hours);
        assertEq(_trade(0, address(nvda), false, 1e18), 100e6);
        assertEq(mandate.holdings(0, address(nvda)), 1e18);
        assertEq(_usdgOf(0), 900e6);
        assertEq(nvda.balanceOf(address(mandate)), 1e18);
        assertEq(usdg.balanceOf(address(mandate)), 900e6);

        // The same on a pool where USDG is token0.
        _fund(1, 1_000e6);
        assertEq(_trade(1, address(spy), true, 500e6), 1e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_trade(1, address(spy), false, 1e18), 500e6);
        assertEq(_usdgOf(1), 1_000e6);
    }

    function test_aBuyMayNotPayMoreThanTheFeedPlusThePremium() public {
        _fund(0, 1_000e6);
        // 100 USDG at $100 buys one token by the feed; the 2% premium sets the floor at 0.98.
        nvdaPool.setPrice(103e6);
        uint256 out = uint256(100e6) * 1e18 / 103e6;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OffPrice.selector, out, 0.98e18));
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);

        nvdaPool.setPrice(102e6);
        assertEq(_trade(0, address(nvda), true, 100e6), uint256(100e6) * 1e18 / 102e6);
    }

    function test_aSellMayNotTakeLessThanTheFeedLessThePremium() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6);
        vm.warp(block.timestamp + 1 hours);
        nvdaPool.setPrice(97e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OffPrice.selector, 97e6, 98e6));
        mandate.trade(0, address(nvda), false, 1e18, 0, 0);

        nvdaPool.setPrice(98e6);
        assertEq(_trade(0, address(nvda), false, 1e18), 98e6, "a fill at the floor goes through");
    }

    function test_theModelsOwnFloorAppliesWhenItIsHigher() public {
        _fund(0, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OffPrice.selector, 1e18, 1.5e18));
        mandate.trade(0, address(nvda), true, 100e6, 1.5e18, 0);
    }

    function test_aBuySpendsAtMostTheCapAndASellAtMostTheHolding() public {
        _fund(0, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OverCap.selector, 500e6 + 1, 500e6));
        mandate.trade(0, address(nvda), true, 500e6 + 1, 0, 0);
        _trade(0, address(nvda), true, 500e6);

        vm.warp(block.timestamp + 1 hours);
        // The cap is a share of what the desk holds now.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OverCap.selector, 250e6 + 1, 250e6));
        mandate.trade(0, address(nvda), true, 250e6 + 1, 0, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.Short.selector, 5e18 + 1, 5e18));
        mandate.trade(0, address(nvda), false, 5e18 + 1, 0, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.Short.selector, 1, 0));
        mandate.trade(0, address(spy), false, 1, 0, 0);
    }

    function test_oneOrderPerDeskPerInterval() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        _trade(0, address(nvda), true, 100e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.TooSoon.selector, uint8(0)));
        mandate.trade(0, address(spy), true, 100e6, 0, 0);
        _trade(1, address(nvda), true, 100e6);

        vm.warp(block.timestamp + 1 hours - 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.TooSoon.selector, uint8(0)));
        mandate.trade(0, address(nvda), false, 1e18, 0, 0);
        vm.warp(block.timestamp + 1);
        _trade(0, address(nvda), false, 1e18);
    }

    function test_aStaleFeedRefusesBuysSellsAndValuation() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 100e6);
        uint256 updatedAt = nvdaFeed.updatedAt();

        vm.warp(updatedAt + 3 days);
        assertEq(mandate.price(address(nvda)), 100e6, "a feed exactly maxFeedAge old still prices");
        vm.warp(updatedAt + 3 days + 1);
        bytes memory stale = abi.encodeWithSelector(DeskMandate.StaleFeed.selector, address(nvdaFeed), updatedAt);
        vm.prank(operator);
        vm.expectRevert(stale);
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);
        vm.prank(operator);
        vm.expectRevert(stale);
        mandate.trade(0, address(nvda), false, 1e18, 0, 0);
        vm.expectRevert(stale);
        mandate.equity(0);
        vm.expectRevert(stale);
        mandate.price(address(nvda));
        vm.prank(owner);
        vm.expectRevert(stale);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), true);

        // A token with a fresh feed still trades, and a fresh answer reopens the stale one.
        spyFeed.set(500e8, block.timestamp);
        _fund(1, 1_000e6);
        _trade(1, address(spy), true, 500e6);
        nvdaFeed.set(100e8, block.timestamp);
        _trade(0, address(nvda), false, 1e18);
    }

    function test_aZeroOrNegativeAnswerRefuses() public {
        _fund(0, 1_000e6);
        bytes memory bad = abi.encodeWithSelector(DeskMandate.BadFeed.selector, address(nvdaFeed));
        nvdaFeed.set(0, block.timestamp);
        vm.prank(operator);
        vm.expectRevert(bad);
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);
        nvdaFeed.set(-1, block.timestamp);
        vm.expectRevert(bad);
        mandate.price(address(nvda));
    }

    function test_thePriceIsTheFeedTimesTheShareMultiplier() public {
        assertEq(mandate.price(address(nvda)), 100e6);
        nvda.setMultiplier(1.5e18);
        assertEq(mandate.price(address(nvda)), 150e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.NotListed.selector, address(weth)));
        mandate.price(address(weth));
    }

    function test_onlyTheOperatorTradesAndOnlyWhileUnpaused() public {
        _fund(0, 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(DeskMandate.NotOperator.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);
        vm.prank(owner);
        vm.expectRevert(DeskMandate.NotOperator.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);

        vm.startPrank(operator);
        vm.expectRevert(DeskMandate.NoDesk.selector);
        mandate.trade(5, address(nvda), true, 100e6, 0, 0);
        vm.expectRevert(DeskMandate.ZeroAmount.selector);
        mandate.trade(0, address(nvda), true, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.NotListed.selector, address(weth)));
        mandate.trade(0, address(weth), true, 100e6, 0, 0);
        vm.stopPrank();

        vm.prank(owner);
        mandate.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(DeskMandate.IsPaused.selector);
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);
        vm.prank(owner);
        mandate.setPaused(false);

        vm.prank(owner);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.NotListed.selector, address(nvda)));
        mandate.trade(0, address(nvda), true, 100e6, 0, 0);
    }

    function test_theSwapCallbackPaysOnlyThePoolOfTheSwapInProgress() public {
        _fund(0, 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.WrongPool.selector, stranger));
        mandate.uniswapV3SwapCallback(1_000e6, 0, abi.encode(address(usdg)));
        // A listed pool outside a swap is a stranger too.
        vm.prank(address(nvdaPool));
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.WrongPool.selector, address(nvdaPool)));
        mandate.uniswapV3SwapCallback(0, 1_000e6, abi.encode(address(usdg)));
        assertEq(usdg.balanceOf(address(mandate)), 1_000e6);
    }

    function test_recallSendsTheDeskToTheOwnerAndLeavesTheOthers() public {
        _fund(0, 1_000e6);
        _fund(1, 1_000e6);
        _trade(0, address(nvda), true, 200e6);
        vm.warp(block.timestamp + 1 hours);
        _trade(0, address(spy), true, 400e6);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.recall(0);

        vm.expectEmit(true, true, false, true, address(mandate));
        emit DeskMandate.Recalled(0, owner, 400e6);
        vm.prank(owner);
        mandate.recall(0);
        assertEq(usdg.balanceOf(owner), 400e6);
        assertEq(nvda.balanceOf(owner), 2e18);
        assertEq(spy.balanceOf(owner), 0.8e18);
        assertEq(_usdgOf(0), 0);
        assertEq(mandate.holdings(0, address(nvda)), 0);
        assertEq(mandate.holdings(0, address(spy)), 0);
        assertEq(mandate.equity(0), 0);
        assertEq(_usdgOf(1), 1_000e6);
        assertEq(usdg.balanceOf(address(mandate)), 1_000e6);

        vm.prank(owner);
        vm.expectRevert(DeskMandate.NoDesk.selector);
        mandate.recall(5);
    }

    function test_ethFundingSplitsTheProceedsAcrossTheDesks() public {
        // 3,000.000003 USDG for one ether, so the split leaves a remainder for desk 0.
        wethPool.setPrice(3_000_000_003);
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OffPrice.selector, 3_000_000_003, 3_001e6));
        mandate.fundWithEth{value: 1 ether}(3_001e6);
        vm.prank(owner);
        mandate.fundWithEth{value: 1 ether}(3_000e6);
        assertEq(_usdgOf(0), 600_000_003);
        for (uint8 i = 1; i < 5; i++) {
            assertEq(_usdgOf(i), 600e6);
        }
        assertEq(usdg.balanceOf(address(mandate)), 3_000_000_003);
        assertEq(weth.balanceOf(address(wethPool)), 1 ether);

        vm.prank(owner);
        vm.expectRevert(DeskMandate.ZeroAmount.selector);
        mandate.fundWithEth{value: 0}(0);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.fundWithEth{value: 1 ether}(0);
    }

    function test_venuesPairWithUsdgAndPriceAtListing() public {
        MockStock tsla = new MockStock("TSLA");
        MockFeed tslaFeed = new MockFeed(300e8);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.PoolMismatch.selector, address(nvdaPool), address(tsla)));
        mandate.setVenue(address(tsla), _pool(nvdaPool), _feed(tslaFeed), true);
        vm.expectRevert(DeskMandate.ZeroAddress.selector);
        mandate.setVenue(address(tsla), IUniswapV3PoolLike(address(0)), _feed(tslaFeed), true);
        vm.expectRevert(DeskMandate.ZeroAddress.selector);
        mandate.setVenue(address(tsla), _pool(nvdaPool), IAggregatorV3(address(0)), true);
        vm.expectRevert(DeskMandate.ZeroAddress.selector);
        mandate.setVenue(address(0), _pool(nvdaPool), _feed(nvdaFeed), false);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setVenue(address(tsla), _pool(nvdaPool), _feed(tslaFeed), false);

        // The WETH pool must be WETH/USDG in that order.
        bytes32[5] memory models;
        MockPool reversed = new MockPool(address(usdg), address(weth), address(usdg), 3_000e6);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.PoolMismatch.selector, address(reversed), address(weth)));
        new DeskMandate(IERC20(address(usdg)), IERC20(address(weth)), _pool(reversed), owner, operator, models);
        vm.expectRevert(DeskMandate.ZeroAddress.selector);
        new DeskMandate(IERC20(address(usdg)), IERC20(address(weth)), _pool(wethPool), owner, address(0), models);
    }

    function test_boundsAreTheOwnersAndCapped() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OverCap.selector, 10_001, 10_000));
        mandate.setBounds(1 hours, 10_001, 5_000, 3 days);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OverCap.selector, 10_001, 10_000));
        mandate.setBounds(1 hours, 200, 10_001, 3 days);
        // No premium and the whole desk per order.
        mandate.setBounds(2 hours, 0, 10_000, 1 days);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mandate.setBounds(1 hours, 200, 5_000, 3 days);

        _fund(0, 1_000e6);
        nvdaPool.setPrice(100.01e6);
        uint256 out = uint256(1_000e6) * 1e18 / 100.01e6;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OffPrice.selector, out, 10e18));
        mandate.trade(0, address(nvda), true, 1_000e6, 0, 0);
        nvdaPool.setPrice(100e6);
        _trade(0, address(nvda), true, 1_000e6);
        assertEq(_usdgOf(0), 0);
    }

    /// Known behaviour of the deployed contract: `setVenue` pushes a token every time it goes from
    /// unlisted to listed, so a token delisted and listed again sits in `tokens` twice and `equity`
    /// counts its holding twice. Recall still pays it out once.
    function test_known_relistingATokenPushesItAgainAndEquityCountsItTwice() public {
        _fund(0, 1_000e6);
        _trade(0, address(nvda), true, 200e6);
        assertEq(mandate.tokenCount(), 2);
        assertEq(mandate.equity(0), 1_000e6);

        vm.startPrank(owner);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), false);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), true);
        vm.stopPrank();
        assertEq(mandate.tokenCount(), 3);
        assertEq(mandate.tokens(2), address(nvda));
        assertEq(mandate.equity(0), 1_200e6, "the 200 USDG of NVDA is counted twice");

        vm.prank(owner);
        mandate.recall(0);
        assertEq(nvda.balanceOf(owner), 2e18);
        assertEq(usdg.balanceOf(owner), 800e6);
    }

    /// Known behaviour of the deployed contract: `trade` books the full `amountIn` whatever the pool
    /// took, so on a partial fill the desk's ledger moves by more than the swap did. What the pool did
    /// not take stays in the contract outside every desk's ledger, and `recall` does not return it.
    function test_known_aPartialFillBooksTheFullOrderSize() public {
        _fund(0, 1_000e6);
        // The pool takes half of a 100 USDG buy, at a price good enough to clear the feed floor.
        nvdaPool.setPrice(50e6);
        nvdaPool.setFill(5_000);
        assertEq(_trade(0, address(nvda), true, 100e6), 1e18);
        assertEq(_usdgOf(0), 900e6, "the ledger books 100 USDG spent");
        assertEq(usdg.balanceOf(address(mandate)), 950e6, "the pool took 50");

        // A sell the pool half fills books the whole holding as sold.
        vm.warp(block.timestamp + 1 hours);
        nvdaPool.setPrice(200e6);
        assertEq(_trade(0, address(nvda), false, 1e18), 100e6);
        assertEq(mandate.holdings(0, address(nvda)), 0);
        assertEq(nvda.balanceOf(address(mandate)), 0.5e18);

        vm.prank(owner);
        mandate.recall(0);
        assertEq(usdg.balanceOf(owner), 1_000e6);
        assertEq(nvda.balanceOf(owner), 0);
        assertEq(usdg.balanceOf(address(mandate)), 50e6, "unbooked USDG stays behind");
        assertEq(nvda.balanceOf(address(mandate)), 0.5e18, "unbooked tokens stay behind");
    }
}
