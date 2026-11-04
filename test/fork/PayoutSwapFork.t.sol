// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PayoutSwap, IDeskVenues} from "../../src/desks/PayoutSwap.sol";

// Pays stock through the live DeskMandate venues on a fork of Robinhood Chain. Skipped without a fork:
//   forge test --match-path test/fork/PayoutSwapFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract PayoutSwapForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant MANDATE = 0xA76916D1b75a82776779fb9d7EB156A4E4a55099;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    address owner = makeAddr("owner");
    address worker = makeAddr("worker-on-parent");
    PayoutSwap swap;

    modifier onFork() {
        if (block.chainid != 4663) return;
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        swap = new PayoutSwap(IERC20(USDG), IDeskVenues(MANDATE), owner, address(this), 200, 500e6);
        vm.prank(WETH_USDG_POOL);
        IERC20(USDG).transfer(address(this), 1_000e6);
        IERC20(USDG).approve(address(swap), type(uint256).max);
    }

    function test_paysNvdaNearTheFeed() public onFork {
        uint256 mark = IDeskVenues(MANDATE).price(NVDA);
        uint256 out = swap.pay(NVDA, 20e6, worker, keccak256("task 1"));
        assertEq(IERC20(NVDA).balanceOf(worker), out);
        assertGe(out, 20e6 * 1e18 * 9_800 / (mark * 10_000), "within 2% of the feed");
        assertLe(out, 20e6 * 1e18 * 10_200 / (mark * 10_000));
        assertEq(IERC20(USDG).balanceOf(address(swap)), 0, "no usdg left behind");
        assertEq(swap.spentToday(), 20e6);
    }

    function test_capAndGates() public onFork {
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OverCap.selector, 600e6, 500e6));
        swap.pay(SPY, 600e6, worker, keccak256("too big"));
        swap.pay(SPY, 300e6, worker, keccak256("a"));
        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.OverCap.selector, 600e6, 500e6));
        swap.pay(SPY, 300e6, worker, keccak256("b"));
        vm.warp(block.timestamp + 1 days);
        swap.pay(SPY, 100e6, worker, keccak256("c"));

        vm.expectRevert(abi.encodeWithSelector(PayoutSwap.NoVenue.selector, USDG));
        swap.pay(USDG, 1e6, worker, keccak256("d"));
        vm.prank(worker);
        vm.expectRevert(PayoutSwap.NotOperator.selector);
        swap.pay(NVDA, 1e6, worker, keccak256("e"));
        vm.prank(owner);
        swap.setPaused(true);
        vm.expectRevert(PayoutSwap.Paused.selector);
        swap.pay(NVDA, 1e6, worker, keccak256("f"));
    }
}
