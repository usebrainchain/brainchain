// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeSplitter, IFeeEscrow, IPonsCurve} from "../../src/rewards/FeeSplitter.sol";

// The FeeSplitter against the real Pons contracts on a fork of Robinhood Chain
// (chain 4663). Skipped without a fork:
//   anvil --fork-url https://robinhood.drpc.org --port 8547
//   forge test --match-path test/fork/PonsLifecycle.t.sol --fork-url http://127.0.0.1:8547 -vv

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

struct Socials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

struct TokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    Socials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics;
    bytes32 salt;
}

struct LaunchedToken {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase;
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

interface IPonsFactory {
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function launchFee() external view returns (uint256);
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function createGraduatedPool(address token) external returns (uint256);
    function owner() external view returns (address);
    function poolManager() external view returns (address);
    function setCreatorFeeRecipient(address token, address newRecipient) external;
    function executeCreatorFeeRecipientChange(address token) external;
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

interface ICurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256);
    function sweepFees(uint256) external;
    function quoteFeeBalance() external view returns (uint256);
    function creatorTaxBalance() external view returns (uint256);
    function buybackQuoteBalance() external view returns (uint256);
    function graduated() external view returns (bool);
    function deployer() external view returns (address);
    function feeEscrow() external view returns (address);
}

interface IEscrow {
    function balanceOf(address) external view returns (uint256);
    function balanceOfToken(address, address) external view returns (uint256);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function sync(address currency) external;
    function take(address currency, address to, uint256 amount) external;
}

interface IHook {
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
    function pendingFees(bytes32, address) external view returns (uint256);
    function pendingCreatorTax(bytes32, address) external view returns (uint256);
    function feeSweepOperator() external view returns (address);
    function owner() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function rescuePoolFees(bytes32 poolId) external returns (uint256, uint256);
}

interface IVault {
    function release(address token) external returns (uint256);
    function vestingTerms(address token) external view returns (address, address, uint16);
    function totalLocked(address token) external view returns (uint256);
}

/// Trades on the curve and in the graduated V4 pool from its own balances.
contract Trader {
    IPoolManager public immutable pm;
    uint160 constant MIN_SQRT = 4295128739 + 1;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342 - 1;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    receive() external payable {}

    function curveBuy(address curve, uint256 amount) external returns (uint256) {
        return ICurve(curve).buy{value: amount}(amount, 0, address(this));
    }

    function curveBuyToken(address curve, address quote, uint256 amount) external returns (uint256) {
        IERC20Min(quote).approve(curve, amount);
        return ICurve(curve).buy(amount, 0, address(this));
    }

    function curveSell(address curve, address token, uint256 amount) external returns (uint256) {
        IERC20Min(token).approve(curve, amount);
        return ICurve(curve).sell(amount, 0, address(this));
    }

    function v4Swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external returns (int256) {
        return abi.decode(pm.unlock(abi.encode(key, zeroForOne, amountSpecified)), (int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified) = abi.decode(data, (PoolKey, bool, int256));
        int256 delta = pm.swap(key, SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_SQRT : MAX_SQRT), "");
        _settle(key.currency0, int128(delta >> 128));
        _settle(key.currency1, int128(delta));
        return abi.encode(delta);
    }

    function _settle(address c, int128 amt) internal {
        if (amt < 0) {
            uint256 owed = uint256(uint128(-amt));
            pm.sync(c);
            if (c == address(0)) {
                pm.settle{value: owed}();
            } else {
                IERC20Min(c).transfer(address(pm), owed);
                pm.settle();
            }
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

contract PonsLifecycleForkTest is Test {
    IPonsFactory constant FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    IEscrow constant ESCROW = IEscrow(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e);
    IHook constant HOOK = IHook(0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044);
    IVault constant VAULT = IVault(0x42df2a798f82289E177311362e8f5ccC45c1219c);
    address constant DISTRIBUTOR = 0x83b31D99Fa31a9e5257955A737eF34c40f1c57bf;
    address constant TREASURY = 0x57BF4f61e27d6C2bD7938d49308104f15736Fdf5;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address launcher = makeAddr("launcher");
    address owner = makeAddr("owner");
    Trader trader;
    Trader trader2;
    uint256 nonce;

    function setUp() public {
        if (block.chainid != 4663) vm.skip(true);
        IPoolManager pm = IPoolManager(FACTORY.poolManager());
        trader = new Trader(pm);
        trader2 = new Trader(pm);
        vm.deal(address(trader), 100 ether);
        vm.deal(address(trader2), 100 ether);
        vm.deal(launcher, 10 ether);
    }

    // ------------------------------------------------------------ helpers

    function _launch(address recipient, bool buyback, address pair) internal returns (address token, address curve) {
        TokenParams memory p = TokenParams({
            name: "Review Fork",
            symbol: "RVW",
            logo: "",
            description: "",
            socials: Socials("", "", "", "", ""),
            creatorFeeRecipient: recipient,
            creatorTaxBps: 200,
            buybackEnabled: buyback,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode("review", ++nonce))
        });
        uint256 fee = FACTORY.launchFee();
        vm.prank(launcher);
        (token, curve) = FACTORY.launchToken{value: fee}(p, 0, pair);
        vm.warp(block.timestamp + 60); // past the snipe-tax window
    }

    function _expectedCreator(address curve) internal view returns (uint256) {
        uint256 pending = ICurve(curve).quoteFeeBalance();
        uint256 tax = ICurve(curve).creatorTaxBalance();
        return pending - (pending * 3000) / 10_000 + tax;
    }

    function _key(address token) internal pure returns (PoolKey memory) {
        return PoolKey(address(0), token, 0, 200, address(HOOK));
    }

    function _graduate(address token, address curve) internal {
        trader2.curveBuy(curve, 6 ether); // crosses the 4.2 ETH threshold; excess refunded
        assertEq(FACTORY.getLaunchedToken(token).phase, 1, "Swept after crossing buy");
        assertTrue(ICurve(curve).graduated());
        FACTORY.createGraduatedPool(token);
        assertEq(FACTORY.getLaunchedToken(token).phase, 2, "PoolCreated");
    }

    function _v4Trades(address token) internal {
        PoolKey memory key = _key(token);
        trader.v4Swap(key, true, -1 ether); // exact-in buy: hook fee taken in the memecoin
        trader.v4Swap(key, false, -int256(IERC20Min(token).balanceOf(address(trader)) / 3)); // exact-in sell: fee in ETH
        trader2.v4Swap(key, true, int256(1_000_000 ether)); // exact-out buy: fee in ETH
    }

    function _log(string memory what, uint256 v) internal pure {
        console2.log(what, v);
    }

    uint256 d0;
    uint256 t0;
    FeeSplitter sp;
    address tok;
    address crv;

    function _splitter() internal returns (FeeSplitter) {
        return new FeeSplitter(IFeeEscrow(address(ESCROW)), DISTRIBUTOR, TREASURY, owner);
    }

    function _split() internal view returns (uint256) {
        return (DISTRIBUTOR.balance - d0) + (TREASURY.balance - t0);
    }

    function _phase0(FeeSplitter splitter) internal {
        sp = splitter;
        d0 = DISTRIBUTOR.balance;
        t0 = TREASURY.balance;
        (tok, crv) = _launch(address(splitter), false, address(0));
        LaunchedToken memory lt = FACTORY.getLaunchedToken(tok);
        assertEq(lt.curve, crv);
        assertEq(lt.creatorFeeRecipient, address(splitter));
        assertEq(lt.pairToken, address(0));
        splitter.bindCurve(IPonsCurve(crv));
        assertEq(splitter.launchToken(), tok);
        assertEq(address(splitter.factory()), address(FACTORY));
    }

    function _phase1() internal {
        trader.curveBuy(crv, 0.5 ether);
        trader2.curveBuy(crv, 0.8 ether);
        trader.curveSell(crv, tok, IERC20Min(tok).balanceOf(address(trader)) / 2);
        uint256 expected = _expectedCreator(crv);
        sp.claimAndSplit();
        _log("curve: creator fees expected (wei)", expected);
        _log("curve: split by one claimAndSplit (wei)", _split());
        assertEq(_split(), expected, "one call sweeps, claims and splits");
        assertEq(ICurve(crv).quoteFeeBalance() + ICurve(crv).creatorTaxBalance(), 0);
    }

    function _phase2() internal {
        trader.curveBuy(crv, 0.3 ether);
        uint256 pendingBeforeCross = _expectedCreator(crv);
        _graduate(tok, crv);
        uint256 credited = ESCROW.balanceOf(address(sp));
        _log("graduation: escrow credit for the splitter (wei)", credited);
        assertGt(credited, pendingBeforeCross, "graduation swept the curve's last fees");
        uint256 before = _split();
        sp.claimAndSplit(); // graduated: no sweep attempted
        assertEq(_split() - before, credited);
        assertEq(ESCROW.balanceOf(address(sp)), 0);
    }

    function _phase3() internal {
        _v4Trades(tok);
        bytes32 poolId = keccak256(abi.encode(_key(tok)));
        uint256 before = _split();
        sp.claimAndSplit();
        assertEq(_split(), before, "nothing reaches the splitter before the operator sweep");

        vm.recordLogs();
        vm.prank(HOOK.feeSweepOperator());
        HOOK.sweepPoolFees(poolId, 1, 1);
        uint256 creatorAmount = _sweptCreator(vm.getRecordedLogs());
        assertEq(ESCROW.balanceOf(address(sp)), creatorAmount, "creator share credited in ETH");
        before = _split();
        sp.claimAndSplit();
        assertEq(_split() - before, creatorAmount);
    }

    function _sweptCreator(Vm.Log[] memory logs) internal pure returns (uint256 creatorAmount) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("PoolFeesSwept(bytes32,uint256,uint256,uint256,uint256)")) {
                (,, uint256 c,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                creatorAmount = c;
                _log("operator sweep: creator", c);
            }
        }
    }

    function _assertNothingStuck() internal view {
        bytes32 poolId = keccak256(abi.encode(_key(tok)));
        assertEq(address(sp).balance, 0, "splitter ETH");
        assertEq(ESCROW.balanceOf(address(sp)), 0, "escrow ETH credit");
        assertEq(ESCROW.balanceOfToken(address(sp), tok), 0, "escrow token credit");
        assertEq(IERC20Min(tok).balanceOf(address(sp)), 0, "token held by the splitter");
        assertEq(HOOK.pendingFees(poolId, address(0)) + HOOK.pendingCreatorTax(poolId, address(0)), 0);
        assertEq(HOOK.pendingFees(poolId, tok) + HOOK.pendingCreatorTax(poolId, tok), 0);
        assertEq(DISTRIBUTOR.balance - d0 + (TREASURY.balance - t0), _split());
        _log("total to the RewardDistributor (wei)", DISTRIBUTOR.balance - d0);
        _log("total to the treasury (wei)", TREASURY.balance - t0);
    }

    /// ETH pair, buyback off: every wei from curve trades, graduation and V4 trades is split.
    function test_lifecycleSplitsEveryWei() public {
        _phase0(_splitter());
        _phase1();
        _phase2();
        _phase3();
        _assertNothingStuck();
    }

    /// v2 had no token path: the buyback slice vested as tokens it could never claim.
    function test_buybackTokensReachTheTreasury() public {
        FeeSplitter s = _splitter();
        (address token, address curve) = _launch(address(s), true, address(0));
        s.bindCurve(IPonsCurve(curve));
        trader.curveBuy(curve, 1 ether);

        vm.recordLogs();
        s.claimAndSplit();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool reported;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(s) && logs[i].topics[0] == FeeSplitter.SweepFailed.selector) {
                reported = true;
            }
        }
        assertTrue(reported, "the operator-only sweep is reported, not hidden");

        vm.prank(HOOK.feeSweepOperator());
        ICurve(curve).sweepFees(1);
        s.claimAndSplit();
        vm.warp(block.timestamp + 365 days);
        (, address protocolRecipient,) = VAULT.vestingTerms(token);
        vm.prank(protocolRecipient);
        VAULT.release(token);
        uint256 credited = ESCROW.balanceOfToken(address(s), token);
        assertGt(credited, 0);
        uint256 before = IERC20Min(token).balanceOf(TREASURY);
        s.claimToken(token);
        assertEq(IERC20Min(token).balanceOf(TREASURY) - before, credited);
        assertEq(ESCROW.balanceOfToken(address(s), token), 0);
    }

    /// v2 stranded every fee of an ERC-20 pair in the escrow.
    function test_erc20PairFeesReachTheTreasury() public {
        FeeSplitter s = _splitter();
        (, address curve) = _launch(address(s), false, USDG);
        s.bindCurve(IPonsCurve(curve));
        deal(USDG, address(trader), 1_000e6);
        trader.curveBuyToken(curve, USDG, 1_000e6);
        s.claimAndSplit();
        uint256 credited = ESCROW.balanceOfToken(address(s), USDG);
        assertGt(credited, 0);
        uint256 before = IERC20Min(USDG).balanceOf(TREASURY);
        s.claimToken(USDG);
        assertEq(IERC20Min(USDG).balanceOf(TREASURY) - before, credited);
    }

    /// v2: tokens pushed by Pons's pool fee rescue had no way out.
    function test_rescuedTokensReachTheTreasury() public {
        FeeSplitter s = _splitter();
        (address token, address curve) = _launch(address(s), false, address(0));
        s.bindCurve(IPonsCurve(curve));
        _graduate(token, curve);
        trader.v4Swap(_key(token), true, -1 ether);
        vm.prank(HOOK.owner());
        HOOK.rescuePoolFees(keccak256(abi.encode(_key(token))));
        uint256 held = IERC20Min(token).balanceOf(address(s));
        assertGt(held, 0);
        s.sweepToken(IERC20(token));
        assertEq(IERC20Min(token).balanceOf(TREASURY), held);
    }

    /// v2 could not move its own fee stream; only Pons's owner could.
    function test_ownerMovesTheFeeStreamAfterThreeDays() public {
        FeeSplitter s = _splitter();
        (address token, address curve) = _launch(address(s), false, address(0));
        s.bindCurve(IPonsCurve(curve));
        address next = makeAddr("next-recipient");
        vm.prank(owner);
        s.proposeRecipient(next);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NotReady.selector);
        s.executeRecipient();
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        s.executeRecipient();
        assertEq(FACTORY.getLaunchedToken(token).creatorFeeRecipient, next);
    }

    /// v2 accepted the token pasted instead of the curve, for good.
    function test_wrongBindIsRejected() public {
        FeeSplitter s = _splitter();
        (address token, address curve) = _launch(address(s), false, address(0));
        vm.expectRevert();
        s.bindCurve(IPonsCurve(token));
        FeeSplitter other = _splitter();
        vm.expectRevert(FeeSplitter.BadCurve.selector);
        other.bindCurve(IPonsCurve(curve)); // a curve that pays someone else
        s.bindCurve(IPonsCurve(curve));
    }

    /// v2 skipped the claim silently in a band of gas limits.
    function test_noGasLimitSkipsTheClaimSilently() public {
        FeeSplitter s = _splitter();
        (, address curve) = _launch(address(s), false, address(0));
        s.bindCurve(IPonsCurve(curve));
        trader.curveBuy(curve, 1 ether);
        for (uint256 g = 60_000; g <= 260_000; g += 500) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(s).call{gas: g}(abi.encodeCall(FeeSplitter.claimAndSplit, ()));
            if (ok) assertEq(ESCROW.balanceOf(address(s)), 0, "a successful call leaves nothing claimable");
            vm.revertToState(snap);
        }
    }
}
