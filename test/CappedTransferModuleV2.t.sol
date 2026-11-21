// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISafeModuleCall} from "../src/safe/CappedTransferModule.sol";
import {CappedTransferModuleV2, ISafeModuleExec} from "../src/safe/CappedTransferModuleV2.sol";
import {FalseToken, SilentToken} from "./CappedTransferModule.t.sol";
import {MockERC20} from "./MockERC20.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

/// Takes no ETH.
contract Refuser {}

/// Operator and recipient at once: on receiving ETH it calls `send` again, as the operator.
contract Reentrant {
    CappedTransferModuleV2 public module;
    uint256 public again;
    bool public swallow;
    bytes public refusal;

    function arm(CappedTransferModuleV2 module_, uint256 again_, bool swallow_) external {
        module = module_;
        again = again_;
        swallow = swallow_;
    }

    function send(uint256 amount) external {
        module.send(amount);
    }

    receive() external payable {
        uint256 amount = again;
        if (amount == 0) return;
        again = 0;
        if (!swallow) {
            module.send(amount);
            return;
        }
        try module.send(amount) {}
        catch (bytes memory reason) {
            refusal = reason;
        }
    }
}

contract CappedTransferModuleV2Test is Test {
    uint128 constant DAY_CAP = 0.008 ether;
    uint128 constant WINDOW_CAP = 12 * DAY_CAP;
    // 2026-11-15 00:00 UTC
    uint256 constant MIDNIGHT = 1_794_700_800;

    address operator = makeAddr("operator");
    address keeper = makeAddr("gas keeper");
    address stranger = makeAddr("stranger");

    SafeStandIn safe;
    MockERC20 usdg;
    CappedTransferModuleV2 module;

    mapping(uint256 day => uint256) ledger;

    event Sent(address indexed recipient, uint256 amount, uint256 spentToday, uint256 spentInWindow);
    event RecipientSet(address indexed recipient);
    event CapsSet(uint256 dailyCap, uint256 windowCap);
    event OperatorSet(address indexed operator);

    function setUp() public {
        vm.warp(MIDNIGHT + 9 hours);
        safe = new SafeStandIn();
        vm.deal(address(safe), 10 ether);
        usdg = new MockERC20();
        usdg.mint(address(safe), 1_000e6);
        module = _module(address(0), DAY_CAP, WINDOW_CAP);
    }

    function _module(address token, uint128 dailyCap, uint128 windowCap) internal returns (CappedTransferModuleV2 m) {
        m = new CappedTransferModuleV2(ISafeModuleExec(address(safe)), token, operator);
        vm.startPrank(address(safe));
        safe.enableModule(address(m));
        m.setRecipient(keeper);
        m.setCaps(dailyCap, windowCap);
        vm.stopPrank();
    }

    function _send(uint256 amount) internal {
        vm.prank(operator);
        module.send(amount);
    }

    function _refuse(uint256 amount, bytes memory reason) internal {
        vm.prank(operator);
        vm.expectRevert(reason);
        module.send(amount);
    }

    function _overDay(uint256 amount, uint256 left) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CappedTransferModuleV2.OverDailyCap.selector, amount, left);
    }

    function _overWindow(uint256 amount, uint256 left) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CappedTransferModuleV2.OverWindowCap.selector, amount, left);
    }

    function _caps(uint128 dailyCap, uint128 windowCap) internal {
        vm.prank(address(safe));
        module.setCaps(dailyCap, windowCap);
    }

    /// 09:00 UTC on the given day, counted from the first.
    function _day(uint256 day) internal {
        vm.warp(MIDNIGHT + day * 1 days + 9 hours);
    }

    function test_fixesSafeAndAssetAndStartsWithTheOperator() public {
        assertEq(address(module.SAFE()), address(safe));
        assertEq(module.TOKEN(), address(0));
        assertEq(module.operator(), operator);
        assertEq(module.recipient(), keeper);
        assertEq(module.dailyCap(), DAY_CAP);
        assertEq(module.windowCap(), WINDOW_CAP);
        assertEq(module.WINDOW_DAYS(), 30);

        vm.expectEmit();
        emit OperatorSet(operator);
        CappedTransferModuleV2 bare =
            new CappedTransferModuleV2(ISafeModuleExec(address(safe)), address(usdg), operator);
        assertEq(bare.TOKEN(), address(usdg));
        assertEq(bare.recipient(), address(0));
        assertEq(bare.dailyCap(), 0);
        assertEq(bare.windowCap(), 0);
        assertEq(bare.left(), 0);
    }

    function test_constructorRefusals() public {
        ISafeModuleExec s = ISafeModuleExec(address(safe));
        vm.expectRevert(CappedTransferModuleV2.ZeroAddress.selector);
        new CappedTransferModuleV2(ISafeModuleExec(address(0)), address(0), operator);
        vm.expectRevert(CappedTransferModuleV2.ZeroAddress.selector);
        new CappedTransferModuleV2(s, address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModuleV2.NotASafe.selector, stranger));
        new CappedTransferModuleV2(ISafeModuleExec(stranger), address(0), operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModuleV2.NotAToken.selector, stranger));
        new CappedTransferModuleV2(s, stranger, operator);
        vm.expectRevert(CappedTransferModuleV2.SafeIsToken.selector);
        new CappedTransferModuleV2(s, address(safe), operator);
        vm.expectRevert(CappedTransferModuleV2.SafeIsOperator.selector);
        new CappedTransferModuleV2(s, address(0), address(safe));
    }

    function test_onlyTheSafeChangesSettings() public {
        address[3] memory others = [operator, stranger, keeper];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(CappedTransferModuleV2.NotSafe.selector);
            module.setRecipient(stranger);
            vm.expectRevert(CappedTransferModuleV2.NotSafe.selector);
            module.setCaps(type(uint128).max, type(uint128).max);
            vm.expectRevert(CappedTransferModuleV2.NotSafe.selector);
            module.setOperator(stranger);
            vm.stopPrank();
        }

        address desk = makeAddr("desk");
        address next = makeAddr("next operator");
        vm.startPrank(address(safe));
        vm.expectEmit(address(module));
        emit RecipientSet(desk);
        module.setRecipient(desk);
        vm.expectEmit(address(module));
        emit CapsSet(0.01 ether, 0.2 ether);
        module.setCaps(0.01 ether, 0.2 ether);
        vm.expectEmit(address(module));
        emit OperatorSet(next);
        module.setOperator(next);

        vm.expectRevert(CappedTransferModuleV2.ZeroAddress.selector);
        module.setRecipient(address(0));
        vm.expectRevert(CappedTransferModuleV2.ZeroAddress.selector);
        module.setOperator(address(0));
        vm.expectRevert(CappedTransferModuleV2.SafeIsOperator.selector);
        module.setOperator(address(safe));
        vm.stopPrank();

        assertEq(module.recipient(), desk);
        assertEq(module.dailyCap(), 0.01 ether);
        assertEq(module.windowCap(), 0.2 ether);
        assertEq(module.operator(), next);
    }

    function test_onlyTheOperatorSends() public {
        address[3] memory others = [stranger, keeper, address(safe)];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(CappedTransferModuleV2.NotOperator.selector);
            module.send(1e15);
        }
        assertEq(address(safe).balance, 10 ether);
    }

    function test_refusesZeroAndNoRecipient() public {
        _refuse(0, abi.encodeWithSelector(CappedTransferModuleV2.ZeroAmount.selector));

        CappedTransferModuleV2 bare = new CappedTransferModuleV2(ISafeModuleExec(address(safe)), address(0), operator);
        vm.startPrank(address(safe));
        safe.enableModule(address(bare));
        bare.setCaps(DAY_CAP, WINDOW_CAP);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(CappedTransferModuleV2.NoRecipient.selector);
        bare.send(1);
    }

    function test_sendsEthWithEmptyCalldata() public {
        vm.expectCall(
            address(safe), abi.encodeCall(ISafeModuleExec.execTransactionFromModule, (keeper, 0.005 ether, "", 0))
        );
        vm.expectCall(keeper, 0.005 ether, "");
        vm.expectEmit(address(module));
        emit Sent(keeper, 0.005 ether, 0.005 ether, 0.005 ether);
        _send(0.005 ether);
        assertEq(keeper.balance, 0.005 ether);
        assertEq(address(safe).balance, 10 ether - 0.005 ether);
        assertEq(module.spentToday(), 0.005 ether);
        assertEq(module.spentInWindow(), 0.005 ether);
        assertEq(module.leftToday(), 0.003 ether);
        assertEq(module.leftInWindow(), WINDOW_CAP - 0.005 ether);
        assertEq(module.left(), 0.003 ether);
    }

    function test_sendsTokensThroughTransfer() public {
        module = _module(address(usdg), 10e6, 120e6);
        vm.expectCall(
            address(safe),
            abi.encodeCall(
                ISafeModuleCall.execTransactionFromModuleReturnData,
                (address(usdg), 0, abi.encodeCall(IERC20.transfer, (keeper, 4e6)), 0)
            )
        );
        vm.expectEmit(address(module));
        emit Sent(keeper, 4e6, 4e6, 4e6);
        _send(4e6);
        assertEq(usdg.balanceOf(keeper), 4e6);
        assertEq(usdg.balanceOf(address(safe)), 996e6);
        assertEq(address(safe).balance, 10 ether);
        assertEq(module.left(), 6e6);
    }

    function test_refusesAboveWhatIsLeftToday() public {
        _send(0.007 ether);
        _refuse(0.001 ether + 1, _overDay(0.001 ether + 1, 0.001 ether));
        _send(0.001 ether);
        assertEq(module.leftToday(), 0);
        _refuse(1, _overDay(1, 0));
        _refuse(DAY_CAP + 1, _overDay(DAY_CAP + 1, 0));
        assertEq(keeper.balance, DAY_CAP);
    }

    function test_dailyCapRenewsAtUtcMidnight() public {
        vm.warp(MIDNIGHT + 1 days - 1);
        _send(DAY_CAP);
        _refuse(1, _overDay(1, 0));

        vm.warp(MIDNIGHT + 1 days);
        assertEq(module.spentToday(), 0);
        assertEq(module.leftToday(), DAY_CAP);
        assertEq(module.spentInWindow(), DAY_CAP);
        vm.expectEmit(address(module));
        emit Sent(keeper, DAY_CAP, DAY_CAP, 2 * DAY_CAP);
        _send(DAY_CAP);
        assertEq(keeper.balance, 2 * DAY_CAP);
    }

    function test_refusesAboveWhatIsLeftInTheWindow() public {
        _caps(10e15, 25e15);
        _send(10e15);
        _day(1);
        _send(10e15);
        _day(2);
        assertEq(module.leftToday(), 10e15);
        assertEq(module.leftInWindow(), 5e15);
        assertEq(module.left(), 5e15);
        _refuse(6e15, _overWindow(6e15, 5e15));
        _send(5e15);
        assertEq(module.left(), 0);
        _refuse(1, _overWindow(1, 0));

        // Over both caps, the daily one is named.
        _day(3);
        _refuse(10e15 + 1, _overDay(10e15 + 1, 10e15));
        assertEq(keeper.balance, 25e15);
    }

    function test_windowRollsOverDayByDay() public {
        _caps(type(uint128).max, type(uint128).max);
        for (uint256 i; i <= 40; i++) {
            if (i > 0) {
                vm.warp(MIDNIGHT + i * 1 days - 1);
                assertEq(module.spentInWindow(), _sentOver(i < 30 ? 0 : i - 30, i), "last second of the day before");
            }
            vm.warp(MIDNIGHT + i * 1 days);
            assertEq(module.spentToday(), 0);
            assertEq(module.spentInWindow(), _sentOver(i < 29 ? 0 : i - 29, i), "first second of the day");
            _send(_sentOn(i));
            assertEq(module.spentToday(), _sentOn(i));
            assertEq(module.spentInWindow(), _sentOver(i < 29 ? 0 : i - 29, i + 1));
        }
        assertEq(keeper.balance, _sentOver(0, 41));
    }

    function _sentOn(uint256 day) internal pure returns (uint256) {
        return (day + 1) * 1e15;
    }

    function _sentOver(uint256 from, uint256 to) internal pure returns (uint256 total) {
        for (uint256 day = from; day < to; day++) {
            total += _sentOn(day);
        }
    }

    function test_windowCapHoldsUntilItsOldestDayLeaves() public {
        for (uint256 day; day < 12; day++) {
            _day(day);
            _send(DAY_CAP);
        }
        assertEq(module.spentInWindow(), WINDOW_CAP);
        for (uint256 day = 12; day < 30; day++) {
            _day(day);
            assertEq(module.leftToday(), DAY_CAP);
            assertEq(module.leftInWindow(), 0);
            assertEq(module.left(), 0);
            _refuse(1, _overWindow(1, 0));
        }

        vm.warp(MIDNIGHT + 30 days - 1);
        _refuse(1, _overWindow(1, 0));
        for (uint256 day = 30; day < 42; day++) {
            vm.warp(MIDNIGHT + day * 1 days);
            assertEq(module.leftInWindow(), DAY_CAP, "the day 30 days back has left");
            _send(DAY_CAP);
            assertEq(module.spentInWindow(), WINDOW_CAP);
            _refuse(1, _overDay(1, 0));
        }
        assertEq(keeper.balance, 24 * DAY_CAP);
    }

    function test_aLongGapEmptiesTheWindow() public {
        _send(0.003 ether);
        _day(29);
        assertEq(module.spentInWindow(), 0.003 ether);
        _send(0.005 ether);
        assertEq(module.spentInWindow(), 0.008 ether);
        _day(30);
        assertEq(module.spentInWindow(), 0.005 ether);
        _day(59);
        assertEq(module.spentInWindow(), 0);

        _day(400);
        assertEq(module.spentInWindow(), 0);
        assertEq(module.left(), DAY_CAP);
        _send(DAY_CAP);
        _day(401);
        assertEq(module.spentInWindow(), DAY_CAP);
        assertEq(module.left(), DAY_CAP);
    }

    function test_lowerCapsApplyAtOnce() public {
        _send(0.006 ether);
        _caps(0.005 ether, WINDOW_CAP);
        assertEq(module.leftToday(), 0);
        _refuse(1, _overDay(1, 0));

        _caps(DAY_CAP, 0.004 ether);
        assertEq(module.leftToday(), 0.002 ether);
        assertEq(module.leftInWindow(), 0);
        _refuse(1, _overWindow(1, 0));

        _caps(DAY_CAP, 0.007 ether);
        assertEq(module.left(), 0.001 ether);
        _send(0.001 ether);
        assertEq(module.left(), 0);
    }

    function test_zeroCapsStopSends() public {
        _caps(0, WINDOW_CAP);
        _refuse(1, _overDay(1, 0));
        _caps(DAY_CAP, 0);
        _refuse(1, _overWindow(1, 0));
    }

    function test_theSafeReplacesTheOperator() public {
        _send(0.005 ether);
        address next = makeAddr("next operator");
        vm.prank(address(safe));
        module.setOperator(next);

        vm.prank(operator);
        vm.expectRevert(CappedTransferModuleV2.NotOperator.selector);
        module.send(1);

        vm.prank(next);
        module.send(0.003 ether);
        assertEq(module.spentToday(), DAY_CAP, "what the old operator sent still counts");
        vm.prank(next);
        vm.expectRevert(_overDay(1, 0));
        module.send(1);

        _day(1);
        vm.prank(operator);
        vm.expectRevert(CappedTransferModuleV2.NotOperator.selector);
        module.send(1);
        vm.prank(next);
        module.send(DAY_CAP);
        assertEq(module.spentInWindow(), 2 * DAY_CAP);
        assertEq(keeper.balance, 2 * DAY_CAP);
    }

    function test_theSafeReplacesTheRecipient() public {
        _send(0.005 ether);
        address brainKeys = makeAddr("brain keys");
        vm.prank(address(safe));
        module.setRecipient(brainKeys);
        _send(0.003 ether);
        assertEq(keeper.balance, 0.005 ether);
        assertEq(brainKeys.balance, 0.003 ether);
        _refuse(1, _overDay(1, 0));
    }

    function test_refusedWhileNotEnabled() public {
        CappedTransferModuleV2 tokens = _module(address(usdg), 10e6, 120e6);
        vm.startPrank(address(safe));
        safe.disableModule(address(module));
        safe.disableModule(address(tokens));
        vm.stopPrank();

        _refuse(1e15, "GS104");
        vm.prank(operator);
        vm.expectRevert("GS104");
        tokens.send(1e6);
        assertEq(module.spentToday(), 0);
        assertEq(module.spentInWindow(), 0);
        assertEq(tokens.spentToday(), 0);
        assertEq(address(safe).balance, 10 ether);
        assertEq(usdg.balanceOf(address(safe)), 1_000e6);
    }

    function test_failedEthTransferRevertsAndSpendsNothing() public {
        _caps(type(uint128).max, type(uint128).max);
        _refuse(10 ether + 1, abi.encodeWithSelector(CappedTransferModuleV2.TransferFailed.selector));

        address refuser = address(new Refuser());
        vm.prank(address(safe));
        module.setRecipient(refuser);
        _refuse(1e15, abi.encodeWithSelector(CappedTransferModuleV2.TransferFailed.selector));
        assertEq(module.spentToday(), 0);
        assertEq(module.spentInWindow(), 0);
        assertEq(address(safe).balance, 10 ether);
    }

    function test_failedTokenTransferRevertsAndSpendsNothing() public {
        module = _module(address(usdg), type(uint128).max, type(uint128).max);
        _refuse(1_000e6 + 1, abi.encodeWithSelector(CappedTransferModuleV2.TransferFailed.selector));
        assertEq(module.spentToday(), 0);
    }

    function test_falseFromTheTokenReverts() public {
        FalseToken token = new FalseToken();
        token.mint(address(safe), 100e6);
        module = _module(address(token), 10e6, 120e6);
        _refuse(1e6, abi.encodeWithSelector(CappedTransferModuleV2.TransferFailed.selector));
        assertEq(module.spentToday(), 0);
    }

    function test_aTokenThatReturnsNothingWorks() public {
        SilentToken token = new SilentToken();
        token.mint(address(safe), 100e6);
        module = _module(address(token), 10e6, 120e6);
        _send(3e6);
        assertEq(token.balanceOf(keeper), 3e6);
    }

    function test_aReentrantSendFromAnEthRecipientIsRefused() public {
        Reentrant r = new Reentrant();
        vm.startPrank(address(safe));
        module.setOperator(address(r));
        module.setRecipient(address(r));
        vm.stopPrank();

        // Passed on, the refusal fails the transfer and nothing moves.
        r.arm(module, 0.001 ether, false);
        vm.expectRevert(CappedTransferModuleV2.TransferFailed.selector);
        r.send(0.002 ether);
        assertEq(address(r).balance, 0);
        assertEq(module.spentToday(), 0);

        // Caught, only the outer send goes through.
        r.arm(module, 0.001 ether, true);
        r.send(0.002 ether);
        assertEq(r.refusal(), abi.encodeWithSelector(CappedTransferModuleV2.Reentered.selector));
        assertEq(address(r).balance, 0.002 ether);
        assertEq(module.spentToday(), 0.002 ether);
        assertEq(module.spentInWindow(), 0.002 ether);

        // A recipient that is not the operator is refused like anyone else.
        vm.prank(address(safe));
        module.setOperator(operator);
        r.arm(module, 0.001 ether, true);
        _send(0.001 ether);
        assertEq(r.refusal(), abi.encodeWithSelector(CappedTransferModuleV2.NotOperator.selector));
        _send(0.001 ether);
        assertEq(address(r).balance, 0.004 ether);
        assertEq(module.spentToday(), 0.004 ether);
    }

    function test_operatorCannotCallTheSafeAsAModule() public {
        vm.startPrank(operator);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(stranger, 1 ether, "", 0);
        vm.expectRevert("GS104");
        safe.execTransactionFromModuleReturnData(stranger, 1 ether, "", 0);
        vm.stopPrank();
    }

    function test_noOtherEntryPoint() public {
        bytes[4] memory calls = [
            abi.encodeWithSignature("send(address,uint256)", stranger, 1e15),
            abi.encodeWithSignature("execute(address,uint256,bytes)", stranger, 1e15, ""),
            abi.encodeWithSignature("transfer(address,uint256)", stranger, 1e15),
            bytes("")
        ];
        vm.deal(operator, 1);
        for (uint256 i; i < calls.length; i++) {
            vm.prank(operator);
            (bool ok,) = address(module).call{value: i == 3 ? 1 : 0}(calls[i]);
            assertFalse(ok);
        }
        assertEq(address(safe).balance, 10 ether);
        assertEq(address(module).balance, 0);
    }

    function testFuzz_sendsExactlyUpToTheDailyCap(uint256 first, uint256 second, uint32 later) public {
        first = bound(first, 1, DAY_CAP);
        second = bound(second, 1, 2 * DAY_CAP);
        later = uint32(bound(later, 0, 1 days - 9 hours - 1));
        _send(first);
        vm.warp(block.timestamp + later);
        if (first + second > DAY_CAP) {
            _refuse(second, _overDay(second, DAY_CAP - first));
            assertEq(keeper.balance, first);
        } else {
            _send(second);
            assertEq(keeper.balance, first + second);
        }
        assertLe(keeper.balance, DAY_CAP);
    }

    /// Each step moves on by a fuzzed number of days (mostly none or one, sometimes a month or more), at a fuzzed time
    /// of day, sometimes changes the caps, and asks for a fuzzed amount. The module must accept and refuse exactly as a
    /// ledger of every day's outflow says, summed over the last 30 days the slow way.
    function testFuzz_matchesADayByDayLedger(uint256[32] calldata steps) public {
        _caps(DAY_CAP, 4 * DAY_CAP);
        uint256 sent;
        for (uint256 i; i < steps.length; i++) {
            uint256 step = steps[i];
            uint256 roll = uint8(step);
            uint256 gap = roll < 112 ? 0 : roll < 208 ? 1 : roll < 240 ? 2 + roll % 5 : 25 + roll % 21;
            uint256 next = (block.timestamp / 1 days + gap) * 1 days + (step >> 8) % 1 days;
            vm.warp(next > block.timestamp ? next : block.timestamp);

            if ((step >> 32) % 8 == 0) {
                uint128 dailyCap = uint128(bound(uint64(step >> 40), 0, 2 * DAY_CAP));
                uint128 windowCap = uint128(bound(uint64(step >> 104), 0, 8 * DAY_CAP));
                _caps(dailyCap, windowCap);
            }

            uint256 today = block.timestamp / 1 days;
            uint256 window;
            for (uint256 back; back < 30; back++) {
                window += ledger[today - back];
            }
            uint256 dayLeft = module.dailyCap() > ledger[today] ? module.dailyCap() - ledger[today] : 0;
            uint256 windowLeft = module.windowCap() > window ? module.windowCap() - window : 0;
            assertEq(module.spentToday(), ledger[today]);
            assertEq(module.spentInWindow(), window);
            assertEq(module.leftToday(), dayLeft);
            assertEq(module.leftInWindow(), windowLeft);

            uint256 amount = bound(step >> 168, 1, uint256(module.dailyCap()) * 3 / 2 + 1);
            if (amount > dayLeft) {
                _refuse(amount, _overDay(amount, dayLeft));
            } else if (amount > windowLeft) {
                _refuse(amount, _overWindow(amount, windowLeft));
            } else {
                _send(amount);
                ledger[today] += amount;
                sent += amount;
            }
            assertEq(keeper.balance, sent);
        }
    }
}
