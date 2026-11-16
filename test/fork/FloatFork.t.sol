// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Float, IMorpho, IUniswapV3PoolLike} from "../../src/float/Float.sol";

interface IPoolPrice {
    function token0() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool);
}

// Lends the float on the real Morpho market and the real WETH/USDG pool on a fork of Robinhood Chain.
// Skipped without a fork:
//   forge test --match-path test/fork/FloatFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract FloatForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant WETH_USDG_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    // USDG lent against USDe at 91.5%: the largest USDG market on the chain.
    bytes32 constant USDE_MARKET = 0xc845da65a020ddca5f132efa8fea79676d8edfdea504226a4c01e7a9e34cddd6;
    // Collateral is not USDG here: a market the float must refuse.
    bytes32 constant NVDA_MARKET = 0x8b16891f032a93b771347c9cb470a780e6699dd701553d3402aa3cdba6189c3e;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address desk = makeAddr("desk");
    Float float;

    function setUp() public {
        if (block.chainid != 4663) return;
        float = new Float(
            IERC20(USDG),
            IMorpho(MORPHO),
            IERC20(WETH),
            IUniswapV3PoolLike(WETH_USDG_POOL),
            owner,
            operator,
            desk,
            1_000e6
        );
        vm.prank(owner);
        float.allow(USDE_MARKET, true);
        vm.prank(WETH_USDG_POOL);
        IERC20(USDG).transfer(address(float), 1_200e6);
    }

    modifier onFork() {
        vm.skip(block.chainid != 4663);
        _;
    }

    /// What `amountIn` of `tokenIn` is worth at the pool's current price, before the fee and price impact.
    function _atPoolPrice(address pool, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IPoolPrice(pool).slot0();
        uint256 priceX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        return IPoolPrice(pool).token0() == tokenIn
            ? Math.mulDiv(amountIn, priceX96, 1 << 96)
            : Math.mulDiv(amountIn, 1 << 96, priceX96);
    }

    function test_lendsUnderTheCapAndComesBack() public onFork {
        vm.prank(operator);
        float.supply(USDE_MARKET, 600e6);
        assertApproxEqAbs(float.suppliedIn(USDE_MARKET), 600e6, 2);
        assertEq(float.idle(), 600e6);
        assertApproxEqAbs(float.total(), 1_200e6, 2);

        vm.prank(operator);
        vm.expectPartialRevert(Float.OverCap.selector);
        float.supply(USDE_MARKET, 500e6);

        vm.warp(block.timestamp + 7 days);
        IMorpho(MORPHO).accrueInterest(IMorpho(MORPHO).idToMarketParams(USDE_MARKET));
        assertGt(float.suppliedIn(USDE_MARKET), 600e6 + 100_000, "a week of interest at a few percent");

        vm.prank(operator);
        float.withdraw(USDE_MARKET, 100e6);
        assertEq(float.idle(), 700e6);

        vm.prank(operator);
        uint256 back = float.withdrawAll(USDE_MARKET);
        assertGt(back, 500e6);
        assertEq(float.suppliedIn(USDE_MARKET), 0);
        assertEq(float.idle(), 700e6 + back);
    }

    function test_releaseGoesToTheDeskOnly() public onFork {
        vm.prank(operator);
        float.release(50e6);
        assertEq(IERC20(USDG).balanceOf(desk), 50e6);
        vm.prank(desk);
        vm.expectRevert(Float.NotOperator.selector);
        float.release(1e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.NotAllowed.selector, NVDA_MARKET));
        float.supply(NVDA_MARKET, 1e6);
    }

    function test_ownerGatesMarketsPausesAndSweeps() public onFork {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        float.allow(NVDA_MARKET, true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Float.NotUsdgMarket.selector, bytes32(uint256(1))));
        float.allow(bytes32(uint256(1)), true);

        vm.prank(owner);
        float.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(Float.Paused.selector);
        float.supply(USDE_MARKET, 1e6);

        vm.prank(owner);
        float.sweep(owner, 1_200e6);
        assertEq(IERC20(USDG).balanceOf(owner), 1_200e6);
        assertEq(float.idle(), 0);
    }

    function test_fundWithEthSwapsOnThePool() public onFork {
        // The floor comes from the pool's own price, so the test holds at any ETH price.
        uint256 fair = _atPoolPrice(WETH_USDG_POOL, WETH, 0.05 ether);
        uint256 floor = fair * 98 / 100;
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        float.fundWithEth{value: 0.05 ether}(floor);
        uint256 got = float.idle() - 1_200e6;
        assertGe(got, floor, "within 2% of the pool price");
        assertLe(got, fair, "no better than the pool price");
        vm.prank(owner);
        vm.expectPartialRevert(Float.OffPrice.selector);
        float.fundWithEth{value: 0.05 ether}(fair + 1);
    }
}
