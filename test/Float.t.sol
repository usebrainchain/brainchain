// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Float, IMorpho, IUniswapV3PoolLike, MarketParams} from "../src/float/Float.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPool, MockStock, MockWETH} from "./MockVenues.sol";

/// Morpho Blue's supply side: market ids, share accounting with virtual shares, and interest the test adds.
contract MockMorpho {
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
    }

    mapping(bytes32 => MarketParams) private _params;
    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => mapping(address => uint256)) private _shares;

    function createMarket(MarketParams memory params) external returns (bytes32 id) {
        id = keccak256(abi.encode(params));
        _params[id] = params;
    }

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory) {
        return _params[id];
    }

    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Market memory m = _markets[id];
        return (m.totalSupplyAssets, m.totalSupplyShares, 0, 0, 0, 0);
    }

    function position(bytes32 id, address user) external view returns (uint256, uint128, uint128) {
        return (_shares[id][user], 0, 0);
    }

    function supply(MarketParams calldata params, uint256 assets, uint256, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256 shares)
    {
        bytes32 id = keccak256(abi.encode(params));
        Market storage m = _markets[id];
        shares = assets * (m.totalSupplyShares + 1e6) / (m.totalSupplyAssets + 1);
        m.totalSupplyAssets += uint128(assets);
        m.totalSupplyShares += uint128(shares);
        _shares[id][onBehalf] += shares;
        IERC20(params.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }

    function withdraw(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(msg.sender == onBehalf, "unauthorized");
        bytes32 id = keccak256(abi.encode(params));
        Market storage m = _markets[id];
        uint256 a = m.totalSupplyAssets + 1;
        uint256 s = m.totalSupplyShares + 1e6;
        if (assets > 0) shares = (assets * s + a - 1) / a;
        else assets = shares * a / s;
        _shares[id][onBehalf] -= shares;
        m.totalSupplyShares -= uint128(shares);
        m.totalSupplyAssets -= uint128(assets);
        IERC20(params.loanToken).transfer(receiver, assets);
        return (assets, shares);
    }

    function accrueInterest(MarketParams calldata) external {}

    /// Interest earned by every supplier of the market; the test mints the USDG behind it.
    function accrue(bytes32 id, uint256 assets) external {
        _markets[id].totalSupplyAssets += uint128(assets);
    }
}

contract FloatTest is Test {
    address internal owner = makeAddr("safe");
    address internal operator = makeAddr("float-key");
    address internal desk = makeAddr("desk");
    address internal stranger = makeAddr("stranger");

    MockERC20 internal usdg;
    MockWETH internal weth;
    MockPool internal wethPool;
    MockMorpho internal morpho;
    Float internal float;
    bytes32 internal market;
    bytes32 internal second;
    bytes32 internal notUsdg;

    function setUp() public {
        usdg = new MockERC20();
        weth = new MockWETH();
        wethPool = new MockPool(address(weth), address(usdg), address(usdg), 3_000e6);
        usdg.mint(address(wethPool), 1_000_000e6);
        morpho = new MockMorpho();
        MockStock collateral = new MockStock("NVDA");
        market = morpho.createMarket(
            MarketParams(address(usdg), address(collateral), makeAddr("oracle"), makeAddr("irm"), 0.77e18)
        );
        second = morpho.createMarket(
            MarketParams(address(usdg), address(collateral), makeAddr("oracle"), makeAddr("irm"), 0.86e18)
        );
        notUsdg = morpho.createMarket(
            MarketParams(address(collateral), address(usdg), makeAddr("oracle"), makeAddr("irm"), 0.86e18)
        );
        float = new Float(
            IERC20(address(usdg)),
            IMorpho(address(morpho)),
            IERC20(address(weth)),
            IUniswapV3PoolLike(address(wethPool)),
            owner,
            operator,
            desk,
            1_000e6
        );
        vm.startPrank(owner);
        float.allow(market, true);
        float.allow(second, true);
        vm.stopPrank();
        usdg.mint(address(float), 2_000e6);
    }

    function _supply(bytes32 id, uint256 amount) internal {
        vm.prank(operator);
        float.supply(id, amount);
    }

    function test_supplyLendsUnderTheCapAcrossMarkets() public {
        _supply(market, 600e6);
        _supply(second, 400e6);
        assertEq(float.suppliedIn(market), 600e6);
        assertEq(float.supplied(), 1_000e6);
        assertEq(float.idle(), 1_000e6);
        assertEq(float.total(), 2_000e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.OverCap.selector, 1_000e6 + 1, 1_000e6));
        float.supply(market, 1);

        vm.prank(owner);
        float.setCap(1_500e6);
        _supply(market, 500e6);
        assertEq(float.supplied(), 1_500e6);
    }

    function test_interestCountsTowardTheCap() public {
        _supply(market, 900e6);
        usdg.mint(address(morpho), 90e6);
        morpho.accrue(market, 90e6);
        uint256 lent = float.supplied();
        assertApproxEqAbs(lent, 990e6, 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.OverCap.selector, lent + 11e6, 1_000e6));
        float.supply(market, 11e6);
        _supply(market, 9e6);
    }

    function test_onlyUsdgMarketsTheOwnerAllowed() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Float.NotUsdgMarket.selector, notUsdg));
        float.allow(notUsdg, true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Float.NotUsdgMarket.selector, bytes32(uint256(1))));
        float.allow(bytes32(uint256(1)), true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        float.allow(market, false);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.NotAllowed.selector, notUsdg));
        float.supply(notUsdg, 1e6);
    }

    function test_aDisallowedMarketTakesNoMoreButCanBeEmptied() public {
        _supply(market, 300e6);
        vm.prank(owner);
        float.allow(market, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.NotAllowed.selector, market));
        float.supply(market, 1e6);
        assertEq(float.supplied(), 300e6, "still counted while lent");

        vm.prank(operator);
        float.withdraw(market, 100e6);
        assertEq(float.suppliedIn(market), 200e6);
        vm.prank(operator);
        assertEq(float.withdrawAll(market), 200e6);
        assertEq(float.suppliedIn(market), 0);
        assertEq(float.idle(), 2_000e6);
    }

    function test_withdrawAllTakesBackInterestAndReturnsZeroWhenEmpty() public {
        _supply(market, 500e6);
        usdg.mint(address(morpho), 50e6);
        morpho.accrue(market, 50e6);
        vm.prank(operator);
        uint256 back = float.withdrawAll(market);
        assertApproxEqAbs(back, 550e6, 1);
        assertEq(float.idle(), 1_500e6 + back);
        (uint256 shares,,) = morpho.position(market, address(float));
        assertEq(shares, 0);

        vm.prank(operator);
        assertEq(float.withdrawAll(market), 0);
    }

    function test_releasePaysTheDeskOnly() public {
        vm.expectEmit(true, false, false, true, address(float));
        emit Float.Released(desk, 25e6);
        vm.prank(operator);
        float.release(25e6);
        assertEq(usdg.balanceOf(desk), 25e6);
        vm.prank(owner);
        float.release(5e6);
        assertEq(usdg.balanceOf(desk), 30e6);

        vm.prank(operator);
        vm.expectRevert(Float.ZeroAmount.selector);
        float.release(0);
        vm.prank(stranger);
        vm.expectRevert(Float.NotOperator.selector);
        float.release(1e6);
        vm.prank(owner);
        float.setDesk(address(0));
        vm.prank(operator);
        vm.expectRevert(Float.NoDesk.selector);
        float.release(1e6);
    }

    function test_aPauseStopsLendingButNotWithdrawals() public {
        _supply(market, 100e6);
        vm.prank(owner);
        float.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(Float.Paused.selector);
        float.supply(market, 1e6);
        vm.prank(operator);
        float.withdrawAll(market);
        vm.prank(operator);
        float.release(1e6);
        assertEq(float.supplied(), 0);
    }

    function test_onlyTheOperatorOrTheOwnerMovesTheFloat() public {
        vm.startPrank(stranger);
        vm.expectRevert(Float.NotOperator.selector);
        float.supply(market, 1e6);
        vm.expectRevert(Float.NotOperator.selector);
        float.withdraw(market, 1e6);
        vm.expectRevert(Float.NotOperator.selector);
        float.withdrawAll(market);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        float.sweep(stranger, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        float.setCap(type(uint256).max);
        vm.stopPrank();

        vm.prank(owner);
        float.supply(market, 1e6);
        vm.startPrank(operator);
        vm.expectRevert(Float.ZeroAmount.selector);
        float.supply(market, 0);
        vm.expectRevert(Float.ZeroAmount.selector);
        float.withdraw(market, 0);
        vm.stopPrank();
    }

    function test_anyoneFundsAndOnlyTheOwnerSweeps() public {
        usdg.mint(stranger, 10e6);
        vm.startPrank(stranger);
        usdg.approve(address(float), 10e6);
        vm.expectRevert(Float.ZeroAmount.selector);
        float.fund(0);
        float.fund(10e6);
        vm.stopPrank();
        assertEq(float.idle(), 2_010e6);

        vm.prank(owner);
        float.sweep(owner, 2_010e6);
        assertEq(usdg.balanceOf(owner), 2_010e6);
    }

    function test_ethFundingSwapsOnTheWethPool() public {
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Float.OffPrice.selector, 3_000e6, 3_001e6));
        float.fundWithEth{value: 1 ether}(3_001e6);
        vm.prank(owner);
        float.fundWithEth{value: 1 ether}(3_000e6);
        assertEq(float.idle(), 5_000e6);
        vm.prank(owner);
        vm.expectRevert(Float.ZeroAmount.selector);
        float.fundWithEth{value: 0}(0);

        vm.prank(address(wethPool));
        vm.expectRevert(abi.encodeWithSelector(Float.WrongPool.selector, address(wethPool)));
        float.uniswapV3SwapCallback(0, 1e6, abi.encode(address(usdg)));
    }

    /// Known behaviour of the deployed contract: `allow(id, true)` pushes a market that is not allowed
    /// at that moment, so a market disallowed and allowed again sits in `markets` twice. `supplied`, and
    /// with it `total` and the cap check, then count its position twice.
    function test_known_reallowingAMarketListsItTwiceAndCountsItTwice() public {
        _supply(market, 300e6);
        vm.startPrank(owner);
        float.allow(market, false);
        float.allow(market, true);
        vm.stopPrank();
        assertEq(float.marketCount(), 3);
        assertEq(float.markets(2), market);
        assertEq(float.supplied(), 600e6, "300 lent, counted twice");
        assertEq(float.total(), 1_700e6 + 600e6);

        // 300 lent and a cap of 1,000 should leave room for 700; the double count leaves 400.
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Float.OverCap.selector, 600e6 + 401e6, 1_000e6));
        float.supply(second, 401e6);
        _supply(second, 400e6);
    }
}
