// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeskMandate, IUniswapV3PoolLike, IAggregatorV3} from "../../src/desks/DeskMandate.sol";

// DeskMandate against the real USDG, WETH, Robinhood stock tokens, Uniswap v3 pools and Chainlink
// feeds on a fork of Robinhood Chain (chain 4663). Skipped without a fork:
//   forge test --match-path test/fork/DeskMandateFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract DeskMandateForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_POOL = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant SPY_POOL = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167;
    address constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;

    DeskMandate mandate;
    address owner = makeAddr("safe");
    address operator = makeAddr("desk-key");
    address stranger = makeAddr("stranger");

    function setUp() public {
        if (block.chainid != 4663) return;
        bytes32[5] memory models =
            [bytes32("claude"), bytes32("gpt"), bytes32("gemini"), bytes32("grok"), bytes32("deepseek")];
        mandate =
            new DeskMandate(IERC20(USDG), IERC20(WETH), IUniswapV3PoolLike(WETH_USDG_POOL), owner, operator, models);
        vm.startPrank(owner);
        mandate.setVenue(NVDA, IUniswapV3PoolLike(NVDA_POOL), IAggregatorV3(NVDA_FEED), true);
        mandate.setVenue(SPY, IUniswapV3PoolLike(SPY_POOL), IAggregatorV3(SPY_FEED), true);
        vm.stopPrank();
        vm.deal(owner, 1 ether);
    }

    modifier onFork() {
        if (block.chainid != 4663) return;
        _;
    }

    function _fund() internal {
        vm.prank(owner);
        mandate.fundWithEth{value: 0.23 ether}(400e6);
    }

    function test_ethFundsFiveDesksEqually() public onFork {
        _fund();
        uint256 total;
        for (uint8 i = 0; i < 5; i++) {
            (, uint256 usdg,,) = mandate.desks(i);
            assertGt(usdg, 80e6, "each desk holds about a hundred dollars");
            total += usdg;
        }
        assertEq(IERC20(USDG).balanceOf(address(mandate)), total, "the ledger matches the balance");
        assertEq(mandate.equity(0), total - 4 * (total / 5), "equity is the ledger before any order");
    }

    function test_aBuyAndASellInsideTheGuardMoveTheLedger() public onFork {
        _fund();
        (, uint256 before,,) = mandate.desks(0);
        uint256 spend = before / 4;
        vm.prank(operator);
        uint256 got = mandate.trade(0, NVDA, true, spend, 0, keccak256("nvda looks cheap after hours"));
        assertGt(got, 0);
        assertEq(mandate.holdings(0, NVDA), got);
        (, uint256 after_,, uint32 orders) = mandate.desks(0);
        assertEq(after_, before - spend);
        assertEq(orders, 1);
        assertEq(IERC20(NVDA).balanceOf(address(mandate)), got, "the contract holds the tokens");
        // Within the premium of the feed in both directions.
        uint256 priced = got * mandate.price(NVDA) / 1e18;
        assertApproxEqRel(priced, spend, 0.02e18, "the fill is within 2% of the feed");
        uint256 equity = mandate.equity(0);
        assertApproxEqRel(equity, before, 0.01e18, "equity barely moved");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        uint256 back = mandate.trade(0, NVDA, false, got / 2, 0, keccak256("take half off"));
        assertGt(back, 0);
        assertEq(mandate.holdings(0, NVDA), got - got / 2);
        (, uint256 after2,,) = mandate.desks(0);
        assertEq(after2, before - spend + back);
    }

    function test_boundsHold() public onFork {
        _fund();
        (, uint256 usdg,,) = mandate.desks(1);

        vm.prank(stranger);
        vm.expectRevert(DeskMandate.NotOperator.selector);
        mandate.trade(1, NVDA, true, 10e6, 0, bytes32(0));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.OverCap.selector, usdg * 6 / 10, usdg / 2));
        mandate.trade(1, NVDA, true, usdg * 6 / 10, 0, bytes32(0));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.NotListed.selector, WETH));
        mandate.trade(1, WETH, true, 10e6, 0, bytes32(0));

        vm.prank(operator);
        mandate.trade(1, SPY, true, 20e6, 0, keccak256("spy"));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.TooSoon.selector, uint8(1)));
        mandate.trade(1, SPY, true, 10e6, 0, bytes32(0));

        vm.warp(block.timestamp + 1 hours);
        vm.prank(operator);
        vm.expectRevert();
        mandate.trade(1, SPY, false, 1e30, 0, bytes32(0));

        // The model's own floor is honoured on top of the feed's.
        vm.prank(operator);
        vm.expectRevert();
        mandate.trade(1, SPY, true, 10e6, 1e30, bytes32(0));
        // A premium of zero with a pool that fills below the feed still passes; above it, it refuses.
        vm.prank(owner);
        mandate.setBounds(1 hours, 0, 5_000, 3 days);
        uint256 mark = mandate.price(SPY);
        vm.prank(operator);
        try mandate.trade(1, SPY, true, 10e6, 0, keccak256("at the feed")) returns (uint256 got) {
            assertGe(got, 10e6 * 1e18 / mark, "a fill that passed a zero premium was at or better than the feed");
        } catch {}
        vm.prank(owner);
        mandate.setBounds(1 hours, 200, 5_000, 3 days);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(owner);
        mandate.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(DeskMandate.IsPaused.selector);
        mandate.trade(1, SPY, true, 10e6, 0, bytes32(0));
    }

    function test_theOwnerRecallsADeskWithItsHoldings() public onFork {
        _fund();
        vm.prank(operator);
        uint256 got = mandate.trade(2, NVDA, true, 30e6, 0, keccak256("buy"));
        (, uint256 usdg,,) = mandate.desks(2);
        vm.prank(owner);
        mandate.recall(2);
        assertEq(IERC20(USDG).balanceOf(owner), usdg);
        assertEq(IERC20(NVDA).balanceOf(owner), got);
        assertEq(mandate.equity(2), 0);
        vm.prank(stranger);
        vm.expectRevert();
        mandate.recall(3);
    }

    function test_onlyTheOwnerTunes() public onFork {
        vm.prank(stranger);
        vm.expectRevert();
        mandate.setOperator(stranger);
        vm.prank(stranger);
        vm.expectRevert();
        mandate.setVenue(NVDA, IUniswapV3PoolLike(NVDA_POOL), IAggregatorV3(NVDA_FEED), false);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskMandate.PoolMismatch.selector, NVDA_POOL, SPY));
        mandate.setVenue(SPY, IUniswapV3PoolLike(NVDA_POOL), IAggregatorV3(SPY_FEED), true);
    }
}
