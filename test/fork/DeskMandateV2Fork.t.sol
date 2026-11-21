// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeskMandate, IAggregatorV3} from "../../src/desks/DeskMandate.sol";
import {DeskMandateV2, IAllowanceHolder, ISettlerRegistry} from "../../src/desks/DeskMandateV2.sol";
import {DeployDeskMandateV2} from "../../script/DeployDeskMandateV2.s.sol";

// A block between the two reads of the first mandate's books (119,503,194 and 119,528,980), which found them the
// same: desk 4 holds 79.92 USDG and 0.1496 NVDA here.
uint256 constant BOOKS_BLOCK = 119_514_831;

interface IWETH {
    function deposit() external payable;
}

interface IRhStock {
    function adminBurn(address from, uint256 amount) external;
    function updateMultiplier(uint256 newMultiplier, uint256 effectiveAt) external;
    function uiMultiplier() external view returns (uint256);
}

interface IRhRegistry {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function isBlocked(address account) external view returns (bool);
}

// The Settler's `execute` call and its positive-slippage action, which pays the fill above an amount to a recipient.
bytes4 constant SETTLER_EXECUTE = bytes4(keccak256("execute((address,address,uint256),bytes[],bytes32)"));
bytes4 constant POSITIVE_SLIPPAGE = bytes4(keccak256("POSITIVE_SLIPPAGE(address,address,uint256,uint256,uint256)"));

// The Settler's `execute` slippage argument.
struct Slippage {
    address recipient;
    address buyToken;
    uint256 minAmountOut;
}

// DeskMandateV2 against 0x's live AllowanceHolder, Settler and registry, the real USDG, WETH and NVDA and
// their Chainlink feeds on a fork of Robinhood Chain (chain 4663), executing firm quotes 0x signed on
// 2026-11-21 (test/fixtures/zerox). The quotes were bought with `taker` set to the address the contract
// takes when a fresh deployer creates it first, and each test rolls the fork to the block its quote was
// priced at, so the run is the same every time. That needs an RPC that serves state from then (the public
// RPC keeps only recent blocks). Skipped without a fork:
//   forge test --match-path test/fork/DeskMandateV2Fork.t.sol --fork-url <RPC with history> -vv
// Add --isolate for gas figures that include the transaction's intrinsic and calldata cost.
contract DeskMandateV2ForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ETH_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant SETTLERS = 0x00000000000004533Fe15556B1E086BB1A72cEae;
    address constant FIRST_MANDATE = 0xA76916D1b75a82776779fb9d7EB156A4E4a55099;
    address constant FIRST_OPERATOR = 0x97D558417c3D61f1074422AD843e1Db1E565b952;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    // The taker in every quote: the first contract `deployer` creates.
    address constant TAKER = 0x4522d47dA5929B75263d7A64FEe5A67cB3b58D73;
    // The brain's fallback gas limit: 0x's estimate, plus this, plus this much per position the desk holds.
    uint256 constant GAS_HEADROOM = 150_000;
    uint256 constant GAS_PER_POSITION = 30_000;
    // EIP-3529: a transaction gets back at most a fifth of the gas it used.
    uint256 constant MAX_REFUND_QUOTIENT = 5;

    struct Quote {
        string name;
        bytes32 digest;
        uint256 blockNumber;
        bytes data;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 minBuyAmount;
        uint256 gas;
    }

    DeskMandateV2 mandate;
    // The quotes were bought for TAKER, the first contract this deployer creates, with this operator as txOrigin:
    // change a label and the taker address and every recorded quote stop matching.
    address deployer = makeAddr("zx-desks fork deployer");
    address operator = makeAddr("zx-desks fork operator");
    address stranger = makeAddr("zx-desks fork stranger");
    address owner = makeAddr("safe");

    modifier onFork() {
        vm.skip(block.chainid != 4663);
        // Ekubo's pools on Robinhood Chain, where 0x routes NVDA, use Osaka opcodes the repo's cancun default lacks.
        vm.setEvmVersion("osaka");
        _;
    }

    /// A quote as 0x returned it, checked against what the brain must check before it calls.
    function _quote(string memory name) internal view returns (Quote memory q) {
        string memory body = vm.readFile(string.concat("test/fixtures/zerox/", name, ".json"));
        q.name = name;
        q.digest = sha256(bytes(body));
        q.blockNumber = vm.parseJsonUint(body, ".blockNumber");
        q.data = vm.parseJsonBytes(body, ".transaction.data");
        q.sellAmount = vm.parseJsonUint(body, ".sellAmount");
        q.buyAmount = vm.parseJsonUint(body, ".buyAmount");
        q.minBuyAmount = vm.parseJsonUint(body, ".minBuyAmount");
        q.gas = vm.parseJsonUint(body, ".transaction.gas");
        assertEq(vm.parseJsonAddress(body, ".transaction.to"), ALLOWANCE_HOLDER, "the quote targets AllowanceHolder");
        assertEq(vm.parseJsonUint(body, ".transaction.value"), 0, "the quote sends no ether");
        assertEq(
            vm.parseJsonAddress(body, ".allowanceTarget"), ALLOWANCE_HOLDER, "the approval goes to AllowanceHolder"
        );
        string memory signed = vm.readFile("test/fixtures/zerox/signatures.json");
        assertEq(
            vm.parseJsonString(signed, string.concat(".quotes['", name, "']['content-digest']")),
            string.concat("sha-256=:", vm.toBase64(abi.encodePacked(q.digest)), ":"),
            "the commitment is the digest 0x signed"
        );
    }

    function _deployAt(uint256 blockNumber) internal {
        vm.rollFork(blockNumber);
        bytes32[5] memory models =
            [bytes32("claude"), bytes32("gpt"), bytes32("gemini"), bytes32("grok"), bytes32("deepseek")];
        vm.prank(deployer);
        mandate = new DeskMandateV2(IERC20(USDG), ALLOWANCE_HOLDER, ISettlerRegistry(SETTLERS), owner, operator, models);
        assertEq(address(mandate), TAKER, "the contract sits at the quotes' taker");
        deal(USDG, owner, 500e6);
        vm.startPrank(owner);
        mandate.setVenue(WETH, IAggregatorV3(ETH_FEED), false, true);
        IERC20(USDG).approve(address(mandate), 500e6);
        for (uint8 i = 0; i < 5; i++) {
            mandate.fund(i, 100e6);
        }
        vm.stopPrank();
    }

    function _trade(uint8 desk, address token, bool buy, uint256 amountIn, uint256 minOut, Quote memory q)
        internal
        returns (uint256)
    {
        vm.prank(operator, operator);
        return mandate.trade(desk, token, buy, amountIn, minOut, keccak256(bytes(q.name)), q.digest, q.data);
    }

    /// The last call's gas net of refunds, as a receipt would show it under --isolate. `lastFrameGas` is
    /// read by hand: forge 1.8.1 returns one field fewer than forge-std's `Gas` declares.
    function _gasUsed() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastFrameGas()"));
        require(ok);
        (, uint64 used,, int64 refunded) = abi.decode(ret, (uint64, uint64, uint64, int64));
        uint256 refund = refunded > 0 ? uint256(int256(refunded)) : 0;
        uint256 cap = used / MAX_REFUND_QUOTIENT;
        return used - (refund > cap ? cap : refund);
    }

    function _settler() internal view returns (address) {
        return ISettlerRegistry(SETTLERS).ownerOf(mandate.TAKER_SETTLER());
    }

    function _assertOrderLog(Quote memory q, uint256 got, uint256 feedFloor) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory order;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(mandate) && logs[i].topics[0] == DeskMandateV2.Order.selector) {
                order = logs[i];
            }
        }
        assertEq(order.topics[1], bytes32(uint256(0)));
        assertEq(order.topics[2], bytes32(uint256(uint160(WETH))));
        assertEq(order.topics[3], q.digest, "the order carries the quote's digest");
        (bool buy, uint256 amountIn, uint256 amountOut, uint256 feedPrice, uint256 floor, uint256 minOut,,) =
            abi.decode(order.data, (bool, uint256, uint256, uint256, uint256, uint256, bytes32, address));
        assertTrue(buy);
        assertEq(amountIn, q.sellAmount);
        assertEq(amountOut, got);
        assertEq(feedPrice, mandate.price(WETH));
        assertEq(floor, feedFloor > q.minBuyAmount ? feedFloor : q.minBuyAmount, "the floor the order had to clear");
        assertEq(minOut, q.minBuyAmount);
        (,,,,,, bytes32 reasoning, address settler) =
            abi.decode(order.data, (bool, uint256, uint256, uint256, uint256, uint256, bytes32, address));
        assertEq(reasoning, keccak256(bytes(q.name)));
        assertEq(settler, _settler());
    }

    function test_aRealQuoteBuysWethForADesk() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        uint256 floor = mandate.floorOf(0, WETH, true, q.sellAmount);
        assertGe(q.buyAmount, floor, "0x's expected fill clears the feed floor");

        vm.recordLogs();
        uint256 got = _trade(0, WETH, true, q.sellAmount, q.minBuyAmount, q);
        uint256 gasUsed = _gasUsed();
        assertGe(got, q.minBuyAmount);
        assertApproxEqRel(got, q.buyAmount, 0.001e18, "the fill is the quote");
        assertEq(mandate.holdings(0, WETH), got);
        assertEq(IERC20(WETH).balanceOf(address(mandate)), got);
        (, uint256 usdg,, uint32 orders,,,) = mandate.desks(0);
        assertEq(usdg, 100e6 - q.sellAmount);
        assertEq(orders, 1);
        assertEq(IERC20(USDG).balanceOf(address(mandate)), 500e6 - q.sellAmount);
        assertEq(IERC20(USDG).allowance(address(mandate), ALLOWANCE_HOLDER), 0);

        _assertOrderLog(q, got, floor);

        console.log("buy: 5 USDG for WETH wei", got);
        console.log("  feed floor", floor, "quote minBuyAmount", q.minBuyAmount);
        console.log("  gas", gasUsed, "0x's own estimate", q.gas);
    }

    function _listNvda() internal {
        vm.prank(owner);
        mandate.setVenue(NVDA, IAggregatorV3(NVDA_FEED), true, true);
    }

    function test_aRealQuoteBuysNvdaForADesk() public onFork {
        Quote memory q = _quote("buy-usdg-nvda");
        _deployAt(q.blockNumber);
        _listNvda();
        uint256 floor = mandate.floorOf(0, NVDA, true, q.sellAmount);
        assertGe(q.buyAmount, floor, "0x's expected fill clears the feed floor");
        // 0x's 1% slippage reaches under a 1% premium, so the mandate's floor is the one that binds.
        assertLt(q.minBuyAmount, floor);

        uint256 got = _trade(0, NVDA, true, q.sellAmount, q.minBuyAmount, q);
        uint256 gasUsed = _gasUsed();
        assertGe(got, q.minBuyAmount);
        assertApproxEqRel(got, q.buyAmount, 0.001e18, "the fill is the quote");
        assertEq(mandate.holdings(0, NVDA), got);
        assertEq(IERC20(NVDA).balanceOf(address(mandate)), got);
        assertEq(IERC20(USDG).allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        // Priced at the feed, the shares bought are worth what was paid, less 0x's fee and the route's spread.
        assertApproxEqRel(got * mandate.price(NVDA) / 1e18, q.sellAmount, 0.01e18);
        console.log("buy: 5 USDG for NVDA wei", got);
        console.log("  feed floor", floor, "quote minBuyAmount", q.minBuyAmount);
        console.log("  gas", gasUsed, "0x's own estimate", q.gas);

        // The same quote ten minutes later, on another desk.
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.QuoteUsed.selector, q.digest));
        mandate.trade(1, NVDA, true, q.sellAmount, q.minBuyAmount, bytes32(0), q.digest, q.data);
    }

    /// Both stock quotes were bought seconds apart for the same taker, so the round trip runs at the later
    /// block with the interval set to zero; waiting out the hour would also outlast the quotes.
    function test_aDeskBuysNvdaAndSellsSomeBack() public onFork {
        Quote memory buyQuote = _quote("buy-usdg-nvda");
        Quote memory sellQuote = _quote("sell-nvda-usdg");
        _deployAt(sellQuote.blockNumber);
        _listNvda();
        vm.prank(owner);
        mandate.setBounds(0, 100, 5_000, 3 days, 100);

        uint256 bought = _trade(0, NVDA, true, buyQuote.sellAmount, buyQuote.minBuyAmount, buyQuote);
        assertGe(bought, buyQuote.minBuyAmount);
        assertGe(bought, sellQuote.sellAmount);
        uint256 back = _trade(0, NVDA, false, sellQuote.sellAmount, sellQuote.minBuyAmount, sellQuote);
        uint256 gasUsed = _gasUsed();
        assertGe(back, sellQuote.minBuyAmount);
        assertApproxEqRel(back, sellQuote.buyAmount, 0.001e18, "the fill is the quote");

        assertEq(mandate.holdings(0, NVDA), bought - sellQuote.sellAmount);
        (, uint256 usdg,, uint32 orders,,,) = mandate.desks(0);
        assertEq(usdg, 100e6 - buyQuote.sellAmount + back);
        assertEq(orders, 2);
        assertEq(IERC20(NVDA).balanceOf(address(mandate)), bought - sellQuote.sellAmount);
        assertEq(IERC20(USDG).balanceOf(address(mandate)), 500e6 - buyQuote.sellAmount + back);
        assertEq(IERC20(NVDA).allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        assertEq(IERC20(USDG).allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        console.log("sell back: 0.02 NVDA for USDG", back, "gas", gasUsed);
    }

    function test_aRealQuoteSellsADesksWeth() public onFork {
        Quote memory q = _quote("sell-weth-usdg");
        _deployAt(q.blockNumber);
        vm.deal(owner, 1 ether);
        vm.startPrank(owner);
        IWETH(WETH).deposit{value: q.sellAmount}();
        IERC20(WETH).approve(address(mandate), q.sellAmount);
        mandate.fundHolding(1, WETH, q.sellAmount);
        vm.stopPrank();

        uint256 floor = mandate.floorOf(1, WETH, false, q.sellAmount);
        assertGe(q.buyAmount, floor, "0x's expected fill clears the feed floor");
        uint256 got = _trade(1, WETH, false, q.sellAmount, q.minBuyAmount, q);
        uint256 gasUsed = _gasUsed();
        assertGe(got, q.minBuyAmount);
        assertApproxEqRel(got, q.buyAmount, 0.001e18, "the fill is the quote");
        assertEq(mandate.holdings(1, WETH), 0);
        (, uint256 usdg,,,,,) = mandate.desks(1);
        assertEq(usdg, 100e6 + got);
        assertEq(IERC20(USDG).balanceOf(address(mandate)), 500e6 + got);
        assertEq(IERC20(WETH).balanceOf(address(mandate)), 0);
        assertEq(IERC20(WETH).allowance(address(mandate), ALLOWANCE_HOLDER), 0);
        console.log("sell: 0.001 WETH for USDG", got);
        console.log("  feed floor", floor, "quote minBuyAmount", q.minBuyAmount);
        console.log("  gas", gasUsed, "0x's own estimate", q.gas);
    }

    /// A desk's first order of a UTC day prices its whole book to set the day's budget, about 30,000 gas a
    /// position. With a position in all seven stock tokens and WETH listed too, the NVDA buy stays inside
    /// the brain's fallback gas limit: 0x's estimate plus 150,000, plus 30,000 for each position held.
    function test_theDaysFirstOrderOnAFullBookFitsTheBrainsGasLimit() public onFork {
        Quote memory q = _quote("buy-usdg-nvda");
        _deployAt(q.blockNumber);
        DeskMandate first = DeskMandate(FIRST_MANDATE);
        vm.startPrank(owner);
        for (uint256 i = 0; i < first.tokenCount(); i++) {
            address token = first.tokens(i);
            (, IAggregatorV3 feed,) = first.venues(token);
            mandate.setVenue(token, feed, true, true);
            deal(token, owner, 0.01e18);
            IERC20(token).approve(address(mandate), 0.01e18);
            mandate.fundHolding(0, token, 0.01e18);
        }
        vm.stopPrank();
        (uint256 budget,) = mandate.budgetOf(0);
        assertEq(budget, mandate.equity(0) / 100, "every position counts");

        _trade(0, NVDA, true, q.sellAmount, q.minBuyAmount, q);
        uint256 gasUsed = _gasUsed();
        console.log("day's first NVDA buy on a book of 8 tokens, 7 held: gas", gasUsed);
        assertLt(gasUsed, q.gas + GAS_HEADROOM + 7 * GAS_PER_POSITION);
    }

    /// The same calldata run straight from the contract's address, to separate 0x's gas from the mandate's.
    function test_theBrainsGasLimitCoversTheOrder() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        uint256 snapshot = vm.snapshotState();
        _trade(0, WETH, true, q.sellAmount, q.minBuyAmount, q);
        uint256 viaMandate = _gasUsed();
        vm.revertToState(snapshot);

        vm.prank(address(mandate));
        IERC20(USDG).approve(ALLOWANCE_HOLDER, q.sellAmount);
        vm.prank(address(mandate), operator);
        (bool ok,) = ALLOWANCE_HOLDER.call(q.data);
        uint256 bare = _gasUsed();
        assertTrue(ok);
        console.log("gas through the mandate", viaMandate, "bare AllowanceHolder call", bare);
        console.log("  mandate overhead", viaMandate - bare);
        assertLt(viaMandate, q.gas + GAS_HEADROOM, "the brain's gas limit covers the order");
    }

    function test_aRealQuoteThatPaysSomeoneElseIsRefused() public onFork {
        Quote memory q = _quote("buy-usdg-weth-to-stranger");
        _deployAt(q.blockNumber);
        uint256 floor = mandate.floorOf(0, WETH, true, q.sellAmount);
        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, 0, floor));
        mandate.trade(0, WETH, true, q.sellAmount, 0, bytes32(0), q.digest, q.data);

        // The calldata itself is good: run straight, it pays the stranger.
        vm.prank(address(mandate));
        IERC20(USDG).approve(ALLOWANCE_HOLDER, q.sellAmount);
        vm.prank(address(mandate), operator);
        (bool ok,) = ALLOWANCE_HOLDER.call(q.data);
        assertTrue(ok);
        assertEq(IERC20(WETH).balanceOf(stranger), q.buyAmount);
    }

    function test_aRealQuoteForAnotherOrderOrAnotherSettlerIsRefused() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        address settler = _settler();

        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.WrongSell.selector, USDG, q.sellAmount));
        mandate.trade(0, WETH, true, q.sellAmount - 1, 0, bytes32(0), q.digest, q.data);

        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.Short.selector, q.sellAmount, 0));
        mandate.trade(0, WETH, false, q.sellAmount, 0, bytes32(0), q.digest, q.data);

        // The operator word rewritten to an address of the caller's choosing.
        bytes memory tampered = bytes.concat(q.data);
        address other = stranger;
        assembly ("memory-safe") {
            mstore(add(tampered, 0x24), other)
        }
        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, stranger, settler));
        mandate.trade(0, WETH, true, q.sellAmount, 0, bytes32(0), q.digest, tampered);

        // A registry that no longer lists the quote's Settler, now or as the one before.
        uint128 feature = mandate.TAKER_SETTLER();
        vm.mockCall(SETTLERS, abi.encodeCall(ISettlerRegistry.ownerOf, (feature)), abi.encode(stranger));
        vm.mockCall(SETTLERS, abi.encodeCall(ISettlerRegistry.prev, (feature)), abi.encode(stranger));
        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.NotSettler.selector, settler, settler));
        mandate.trade(0, WETH, true, q.sellAmount, 0, bytes32(0), q.digest, q.data);
    }

    function test_theFeedFloorBindsOnARealQuote() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        // With no premium allowed, 0x's 15 bps fee alone puts the fill under the feed.
        vm.prank(owner);
        mandate.setBounds(1 hours, 0, 5_000, 3 days, 100);
        uint256 floor = mandate.floorOf(0, WETH, true, q.sellAmount);
        assertGt(floor, q.buyAmount);
        vm.prank(operator, operator);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OffPrice.selector, q.buyAmount, floor));
        mandate.trade(0, WETH, true, q.sellAmount, 0, bytes32(0), q.digest, q.data);
    }

    /// A desk key that edits a signed quote can point 0x's surplus action at itself and keep everything above
    /// the floor: 1.9% of each fill at a 2% premium. At 1% it keeps under 1%, and the daily budget stops such
    /// orders once they have taken 1% of the desk.
    function test_theDeskKeyKeepsNoMoreThanThePremiumOrTheDaysBudget() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        uint256 mark = mandate.price(WETH);
        uint256 floor = mandate.floorOf(0, WETH, true, q.sellAmount);
        bytes memory skim = _payKeyAbove(q.data, floor);
        (uint256 budget,) = mandate.budgetOf(0);
        assertEq(budget, 1e6, "1% of the desk's 100 USDG");

        vm.prank(operator, operator);
        uint256 got = mandate.trade(0, WETH, true, q.sellAmount, 0, bytes32(0), q.digest, skim);
        uint256 kept = IERC20(WETH).balanceOf(operator);
        assertEq(got, floor);
        assertGt(kept, 0);
        assertLt(kept * mark / 1e18, q.sellAmount / 100, "under 1% of the order");
        uint256 shortfall = q.sellAmount - got * mark / 1e18;
        (, uint256 used) = mandate.budgetOf(0);
        assertEq(used, shortfall, "the whole shortfall is charged to the day");
        console.log("skim: desk got", got, "key kept (WETH wei)", kept);
        console.log("  key's share of the fill in bps", kept * mandate.BPS() / (got + kept));

        // Replayed in the same block with more money in the desk. Each replay names a digest of its own: the
        // contract cannot tie a digest to the calldata, so only the budget stops this. The day's budget stays
        // what the desk opened the day at.
        deal(USDG, owner, 1_000e6);
        vm.startPrank(owner);
        IERC20(USDG).approve(address(mandate), 1_000e6);
        mandate.fund(0, 1_000e6);
        mandate.setBounds(0, 100, 5_000, 3 days, 100);
        vm.stopPrank();
        uint256 orders = 1 + _replayUntilOverBudget(q, skim, shortfall);
        (, used) = mandate.budgetOf(0);
        kept = IERC20(WETH).balanceOf(operator);
        assertLe(used, budget);
        assertLe(kept * mark / 1e18, budget, "all the key kept that day is within the budget");
        assertEq(orders, budget / shortfall);
        console.log("  orders before the budget stopped them", orders, "key kept in USDG", kept * mark / 1e18);
    }

    function _replayUntilOverBudget(Quote memory q, bytes memory swap, uint256 shortfall)
        internal
        returns (uint256 orders)
    {
        while (true) {
            (uint256 budget, uint256 used) = mandate.budgetOf(0);
            vm.prank(operator, operator);
            try mandate.trade(
                0, WETH, true, q.sellAmount, 0, bytes32(0), keccak256(abi.encode(q.digest, orders)), swap
            ) {
                orders++;
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(DeskMandateV2.OverBudget.selector, used + shortfall, budget));
                return orders;
            }
        }
    }

    /// The quote with its last action, 0x's surplus over `buyAmount`, paid to the desk key instead for
    /// everything over `floor`, and its final check lowered to `floor`.
    function _payKeyAbove(bytes memory data, uint256 floor) internal view returns (bytes memory) {
        (address op, address token, uint256 amount, address target, bytes memory inner) =
            abi.decode(_tail(data, 4), (address, address, uint256, address, bytes));
        (Slippage memory slippage, bytes[] memory actions, bytes32 zid) =
            abi.decode(_tail(inner, 4), (Slippage, bytes[], bytes32));
        actions[actions.length - 1] = abi.encodeWithSelector(POSITIVE_SLIPPAGE, operator, WETH, floor, 1e6, 1e6);
        slippage.minAmountOut = floor;
        return abi.encodeWithSelector(
            IAllowanceHolder.exec.selector,
            op,
            token,
            amount,
            target,
            abi.encodeWithSelector(SETTLER_EXECUTE, slippage, actions, zid)
        );
    }

    function _tail(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = b[i + from];
        }
    }

    /// The stock tokens need no new code: listed with their feeds and `scaled`, they price exactly as the
    /// first mandate prices them.
    function test_theSevenStockTokensPriceAsTheFirstMandatePricesThem() public onFork {
        Quote memory q = _quote("buy-usdg-weth");
        _deployAt(q.blockNumber);
        DeskMandate first = DeskMandate(FIRST_MANDATE);
        uint256 count = first.tokenCount();
        assertEq(count, 7);
        for (uint256 i = 0; i < count; i++) {
            address token = first.tokens(i);
            (, IAggregatorV3 feed,) = first.venues(token);
            vm.prank(owner);
            mandate.setVenue(token, feed, true, true);
            assertEq(mandate.price(token), first.price(token), "same price as the first mandate");
        }
        assertEq(mandate.tokenCount(), 8);
    }

    /// The first mandate buying the same 5 USDG of NVDA on its fixed pool at the same block, for the gas comparison.
    function test_gas_firstMandateNvdaBuy() public onFork {
        Quote memory q = _quote("buy-usdg-nvda");
        vm.rollFork(q.blockNumber);
        DeskMandate first = DeskMandate(FIRST_MANDATE);
        vm.prank(FIRST_OPERATOR, FIRST_OPERATOR);
        uint256 got = first.trade(0, NVDA, true, q.sellAmount, 0, keccak256("gas"));
        console.log("first mandate: 5 USDG for NVDA wei", got, "gas", _gasUsed());
        console.log("  0x quoted", q.buyAmount);
    }
}

/// The real NVDA token on a fork of Robinhood Chain: what its issuer can do to a desk's position, and what the
/// owner can still do about it. Desk 4 holds the first mandate's desk 4 book at BOOKS_BLOCK: 79.92 USDG and 0.1496 NVDA.
contract DeskMandateV2StockForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    address constant SETTLERS = 0x00000000000004533Fe15556B1E086BB1A72cEae;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    // The stock tokens' beacon and access registry.
    address constant REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;
    // NVDA's `tokenPaused` flag is byte 0 of this slot.
    bytes32 constant NVDA_TOKEN_PAUSED = 0x8d25ea8ee309999a79f0af498fbab0e424669497170669bd9e93b81a62babc01;
    uint256 constant DESK_USDG = 79_922_317;
    uint256 constant DESK_NVDA = 149589722238654020;

    DeskMandateV2 mandate;
    address safe = makeAddr("stock fork safe");
    address operator = makeAddr("stock fork operator");
    address issuer = makeAddr("stock fork issuer");

    function setUp() public {
        vm.skip(block.chainid != 4663);
        vm.rollFork(BOOKS_BLOCK);
        bytes32[5] memory models;
        mandate = new DeskMandateV2(IERC20(USDG), ALLOWANCE_HOLDER, ISettlerRegistry(SETTLERS), safe, operator, models);
        deal(USDG, safe, DESK_USDG);
        deal(NVDA, safe, DESK_NVDA);
        vm.startPrank(safe);
        mandate.setVenue(NVDA, IAggregatorV3(NVDA_FEED), true, true);
        IERC20(USDG).approve(address(mandate), DESK_USDG);
        IERC20(NVDA).approve(address(mandate), DESK_NVDA);
        mandate.fund(4, DESK_USDG);
        mandate.fundHolding(4, NVDA, DESK_NVDA);
        vm.stopPrank();
    }

    function _asIssuer() internal {
        vm.mockCall(REGISTRY, abi.encodeWithSelector(IRhRegistry.hasRole.selector), abi.encode(true));
        vm.prank(issuer);
    }

    function test_aPausedStockTokenHoldsBackOnlyItself() public {
        bytes32 flags = vm.load(NVDA, NVDA_TOKEN_PAUSED);
        vm.store(NVDA, NVDA_TOKEN_PAUSED, flags | bytes32(uint256(1)));
        vm.startPrank(safe);
        vm.expectRevert();
        mandate.recallToken(4, NVDA);
        assertEq(mandate.recallUsdg(4), DESK_USDG);
        vm.stopPrank();
        assertEq(IERC20(USDG).balanceOf(safe), DESK_USDG);
        assertEq(IERC20(USDG).balanceOf(address(mandate)), 0);

        vm.store(NVDA, NVDA_TOKEN_PAUSED, flags);
        vm.prank(safe);
        mandate.recallToken(4, NVDA);
        assertEq(IERC20(NVDA).balanceOf(safe), DESK_NVDA);
    }

    function test_aBlockedMandateStillBringsItsUsdgHome() public {
        vm.mockCall(REGISTRY, abi.encodeCall(IRhRegistry.isBlocked, (address(mandate))), abi.encode(true));
        vm.startPrank(safe);
        vm.expectRevert();
        mandate.recallToken(4, NVDA);
        assertEq(mandate.recallUsdg(4), DESK_USDG);
        vm.stopPrank();
        assertEq(mandate.holdings(4, NVDA), DESK_NVDA, "booked until the block lifts or the owner writes it off");
    }

    /// The issuer burns part of the position: what is left comes home once the burned part is off the books.
    function test_anIssuerBurnIsWrittenOffAndTheRestComesHome() public {
        uint256 burned = 0.1e18;
        _asIssuer();
        IRhStock(NVDA).adminBurn(address(mandate), burned);
        vm.clearMockedCalls();
        assertEq(IERC20(NVDA).balanceOf(address(mandate)), DESK_NVDA - burned);

        vm.startPrank(safe);
        vm.expectRevert();
        mandate.recallToken(4, NVDA);
        vm.expectRevert(abi.encodeWithSelector(DeskMandateV2.OverCap.selector, burned + 1, burned));
        mandate.writeOff(4, NVDA, burned + 1);
        mandate.writeOff(4, NVDA, burned);
        assertEq(mandate.recallToken(4, NVDA), DESK_NVDA - burned);
        assertEq(mandate.recallUsdg(4), DESK_USDG);
        vm.stopPrank();
        assertEq(mandate.equity(4), 0);
        assertEq(mandate.booked(NVDA), 0);
        assertEq(IERC20(NVDA).balanceOf(safe), DESK_NVDA - burned);
    }

    /// The issuer schedules multiplier changes about ten minutes ahead (each stock token's last one on chain
    /// was). A 10:1 step on the unmoved per-share feed would cut the buy floor tenfold; instead NVDA takes no
    /// orders from the schedule until an hour after the step, by when Chainlink has reported the new price.
    function test_aMultiplierChangeClosesNvdaUntilAnHourAfterItTakesEffect() public {
        uint256 before = mandate.floorOf(4, NVDA, true, 10e6);
        uint256 multiplier = IRhStock(NVDA).uiMultiplier();
        uint256 effective = block.timestamp + 10 minutes;
        _asIssuer();
        IRhStock(NVDA).updateMultiplier(multiplier * 10, effective);
        vm.clearMockedCalls();
        bytes memory splitting = abi.encodeWithSelector(DeskMandateV2.Splitting.selector, NVDA);

        vm.expectRevert(splitting);
        mandate.floorOf(4, NVDA, true, 10e6);
        vm.warp(effective);
        assertEq(IRhStock(NVDA).uiMultiplier(), multiplier * 10, "in force at effectiveAt");
        vm.expectRevert(splitting);
        mandate.floorOf(4, NVDA, true, 10e6);
        vm.expectRevert(splitting);
        mandate.price(NVDA);
        vm.warp(effective + 1 hours - 1);
        vm.expectRevert(splitting);
        mandate.floorOf(4, NVDA, true, 10e6);

        vm.warp(effective + 1 hours);
        (uint80 round, int256 answer,,,) = IAggregatorV3(NVDA_FEED).latestRoundData();
        vm.mockCall(
            NVDA_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(round + 1, answer / 10, block.timestamp, block.timestamp, round + 1)
        );
        assertApproxEqRel(mandate.floorOf(4, NVDA, true, 10e6), before, 1e12, "the split-adjusted feed");
    }
}

/// The deploy script on a fork: the first mandate's models and venues, a pending handover to the treasury
/// Safe, and the refusals that keep a broadcast from landing anywhere but the planned address.
contract DeployDeskMandateV2ForkTest is Test {
    address constant SAFE = 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d;
    address constant DESK_KEY = 0x97D558417c3D61f1074422AD843e1Db1E565b952;
    DeskMandate constant FIRST = DeskMandate(0xA76916D1b75a82776779fb9d7EB156A4E4a55099);

    function test_theScriptCopiesTheFirstMandateAndHandsOverToTheSafe() public {
        vm.skip(block.chainid != 4663);
        vm.rollFork(BOOKS_BLOCK);
        // The script reads the process environment, which every test shares, so every case runs in this one test.
        vm.setEnv("DEPLOY_DESK_MANDATE_V2", "true");
        vm.setEnv("OPERATOR", vm.toString(DESK_KEY));
        vm.setEnv("SAFE", vm.toString(makeAddr("owner-key")));
        vm.setEnv("EXPECT", vm.toString(address(0)));
        DeployDeskMandateV2 script = new DeployDeskMandateV2();
        vm.expectRevert(bytes("SAFE has no code: it should be the treasury Safe"));
        script.run();

        vm.setEnv("SAFE", vm.toString(SAFE));
        DeskMandateV2 mandate = script.run();
        assertEq(mandate.pendingOwner(), SAFE);
        assertEq(mandate.operator(), DESK_KEY);
        assertEq(mandate.tokenCount(), 7);
        for (uint8 i = 0; i < 5; i++) {
            (bytes32 model,,,) = FIRST.desks(i);
            (bytes32 copied,,,,,,) = mandate.desks(i);
            assertEq(copied, model);
        }
        for (uint256 i = 0; i < 7; i++) {
            address token = FIRST.tokens(i);
            assertEq(mandate.price(token), FIRST.price(token));
        }
        assertEq(mandate.premiumBps(), 100);
        assertEq(mandate.budgetBps(), 100);
        assertEq(mandate.maxFeedAge(), 25 hours);
        vm.expectRevert(bytes("the Safe is not the owner"));
        script.check(mandate);

        // Until the Safe accepts, the deployer is still the owner. Whatever it changes in that window,
        // the check after acceptOwnership refuses.
        address deployer = mandate.owner();
        _tampered(
            script,
            mandate,
            deployer,
            abi.encodeCall(DeskMandateV2.setOperator, (deployer)),
            "the operator is not OPERATOR"
        );
        _tampered(
            script,
            mandate,
            deployer,
            abi.encodeCall(DeskMandateV2.setBounds, (0, 200, 10_000, type(uint64).max, 500)),
            "the bounds are not the deploy's"
        );
        _tampered(
            script,
            mandate,
            deployer,
            abi.encodeCall(DeskMandateV2.setVenue, (FIRST.tokens(0), IAggregatorV3(address(1)), true, false)),
            "a venue is not the first mandate's"
        );
        _tampered(script, mandate, deployer, abi.encodeCall(DeskMandateV2.setPaused, (true)), "paused");

        vm.prank(SAFE);
        mandate.acceptOwnership();
        assertEq(mandate.owner(), SAFE);
        script.check(mandate);

        // Last, because the refusal comes inside the broadcast and leaves it open.
        vm.setEnv("EXPECT", vm.toString(makeAddr("planned")));
        vm.expectRevert(
            bytes("the deployer would not land at EXPECT: use a fresh key and make this its first transaction")
        );
        script.run();
    }

    function _tampered(
        DeployDeskMandateV2 script,
        DeskMandateV2 mandate,
        address deployer,
        bytes memory change,
        string memory refusal
    ) internal {
        uint256 snapshot = vm.snapshotState();
        vm.prank(deployer);
        (bool ok,) = address(mandate).call(change);
        assertTrue(ok);
        vm.prank(SAFE);
        mandate.acceptOwnership();
        vm.expectRevert(bytes(refusal));
        script.check(mandate);
        vm.revertToState(snapshot);
    }
}
