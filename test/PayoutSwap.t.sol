// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DeskMandate} from "../src/desks/DeskMandate.sol";
import {IDeskVenues, PayoutSwap} from "../src/desks/PayoutSwap.sol";
import {DeskSetup} from "./DeskMandate.t.sol";

/// PayoutSwap reading the venues and feed prices of a DeskMandate, as on Robinhood Chain: a 2% premium
/// and a daily cap of 100 USDG.
contract PayoutSwapTest is DeskSetup {
    PayoutSwap internal payouts;
    address internal worker = makeAddr("worker");
    bytes32 internal constant TASK = keccak256("task 42");

    function setUp() public override {
        super.setUp();
        payouts = new PayoutSwap(IERC20(address(usdg)), IDeskVenues(address(mandate)), owner, operator, 200, 100e6);
        usdg.mint(operator, 1_000e6);
        vm.prank(operator);
        usdg.approve(address(payouts), type(uint256).max);
    }

    function _pay(address token, uint256 usdgIn) internal returns (uint256) {
        vm.prank(operator);
        return payouts.pay(token, usdgIn, worker, TASK);
    }

    function test_payBuysTheTokenForTheWorker() public {
        vm.expectEmit(true, true, true, true, address(payouts));
        emit PayoutSwap.Paid(TASK, worker, address(nvda), 10e6, 0.1e18, 100e6);
        assertEq(_pay(address(nvda), 10e6), 0.1e18);
        assertEq(nvda.balanceOf(worker), 0.1e18);
        assertEq(usdg.balanceOf(operator), 990e6);
        // A pool where USDG is token0.
        assertEq(_pay(address(spy), 50e6), 0.1e18);
        assertEq(spy.balanceOf(worker), 0.1e18);
        assertEq(usdg.balanceOf(address(payouts)), 0);
        assertEq(nvda.balanceOf(address(payouts)), 0);
    }

    function test_theDayIsCappedAndTheCapResetsAtUtcMidnight() public {
        _pay(address(nvda), 60e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OverCap.selector, 110e6, 100e6));
        payouts.pay(address(nvda), 50e6, worker, TASK);
        _pay(address(nvda), 40e6);
        assertEq(payouts.spentToday(), 100e6, "the cap itself can be reached");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OverCap.selector, 100e6 + 1, 100e6));
        payouts.pay(address(nvda), 1, worker, TASK);

        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _pay(address(nvda), 100e6);
        assertEq(payouts.day(), block.timestamp / 1 days);
        assertEq(payouts.spentToday(), 100e6);

        vm.prank(owner);
        payouts.setBounds(200, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OverCap.selector, 1, 0));
        payouts.pay(address(nvda), 1, worker, TASK);
    }

    function test_aFillWorseThanTheFeedLessThePremiumRefuses() public {
        // 10 USDG at $100 is 0.1 token by the feed; 2% under that is the least the worker may get.
        nvdaPool.setPrice(103e6);
        uint256 out = uint256(10e6) * 1e18 / 103e6;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OffPrice.selector, out, 0.098e18));
        payouts.pay(address(nvda), 10e6, worker, TASK);
        assertEq(payouts.spentToday(), 0, "a refused payout spends none of the day");
        assertEq(usdg.balanceOf(operator), 1_000e6);

        nvdaPool.setPrice(102e6);
        assertEq(_pay(address(nvda), 10e6), uint256(10e6) * 1e18 / 102e6);
    }

    function test_paymentNeedsALiveVenueAndAFreshFeed() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.NoVenue.selector, address(weth)));
        payouts.pay(address(weth), 10e6, worker, TASK);

        vm.prank(owner);
        mandate.setVenue(address(nvda), _pool(nvdaPool), _feed(nvdaFeed), false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.NoVenue.selector, address(nvda)));
        payouts.pay(address(nvda), 10e6, worker, TASK);

        uint256 updatedAt = spyFeed.updatedAt();
        vm.warp(updatedAt + 3 days + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.StaleFeed.selector, address(spyFeed), updatedAt));
        payouts.pay(address(spy), 10e6, worker, TASK);
    }

    function test_onlyTheOperatorPaysAndOnlyWhileUnpaused() public {
        vm.prank(stranger);
        vm.expectRevert(PayoutSwap.NotOperator.selector);
        payouts.pay(address(nvda), 10e6, worker, TASK);
        vm.prank(operator);
        vm.expectRevert(PayoutSwap.ZeroAmount.selector);
        payouts.pay(address(nvda), 0, worker, TASK);

        vm.prank(owner);
        payouts.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(PayoutSwap.Paused.selector);
        payouts.pay(address(nvda), 10e6, worker, TASK);
    }

    function test_theOwnerSetsTheBoundsWithinTenPercent() public {
        vm.startPrank(owner);
        vm.expectRevert(PayoutSwap.BadBounds.selector);
        payouts.setBounds(1_001, 100e6);
        payouts.setBounds(1_000, 500e6);
        vm.stopPrank();
        assertEq(payouts.premiumBps(), 1_000);
        assertEq(payouts.dailyCap(), 500e6);
        vm.expectRevert(PayoutSwap.BadBounds.selector);
        new PayoutSwap(IERC20(address(usdg)), IDeskVenues(address(mandate)), owner, operator, 1_001, 100e6);

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        payouts.setBounds(200, 100e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        payouts.setOperator(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        payouts.sweep(IERC20(address(usdg)), stranger, 1);
        vm.stopPrank();
    }

    function test_theOwnerSweepsWhatIsLeft() public {
        usdg.mint(address(payouts), 5e6);
        vm.prank(owner);
        payouts.sweep(IERC20(address(usdg)), owner, 5e6);
        assertEq(usdg.balanceOf(owner), 5e6);
    }

    function test_theSwapCallbackPaysOnlyThePoolOfTheSwapInProgress() public {
        usdg.mint(address(payouts), 5e6);
        vm.prank(address(nvdaPool));
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.WrongPool.selector, address(nvdaPool)));
        payouts.uniswapV3SwapCallback(0, 5e6, abi.encode(address(usdg)));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.WrongPool.selector, stranger));
        payouts.uniswapV3SwapCallback(5e6, 0, abi.encode(address(usdg)));
        assertEq(usdg.balanceOf(address(payouts)), 5e6);
    }
}
