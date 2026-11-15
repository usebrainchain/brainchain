// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CappedTransferModule, ISafeModuleCall} from "../src/safe/CappedTransferModule.sol";
import {MockERC20} from "./MockERC20.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

/// Answers false and moves nothing.
contract FalseToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// Moves the amount and returns nothing, as some older tokens do.
contract SilentToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract CappedTransferModuleTest is Test {
    uint256 constant CAP = 10e6;
    // 2026-11-15 00:00 UTC
    uint256 constant MIDNIGHT = 1_794_700_800;

    address operator = makeAddr("operator");
    address desk = makeAddr("desk");
    address stranger = makeAddr("stranger");

    SafeStandIn safe;
    MockERC20 usdg;
    CappedTransferModule module;

    event Sent(address indexed recipient, uint256 amount, uint256 spentToday, uint256 cap);
    event RecipientSet(address indexed recipient);
    event CapSet(uint256 cap);

    function setUp() public {
        vm.warp(MIDNIGHT + 9 hours);
        safe = new SafeStandIn();
        usdg = new MockERC20();
        usdg.mint(address(safe), 1_000e6);
        module = _module(address(usdg));
    }

    function _module(address token) internal returns (CappedTransferModule m) {
        m = new CappedTransferModule(ISafeModuleCall(address(safe)), IERC20(token), operator);
        vm.startPrank(address(safe));
        safe.enableModule(address(m));
        m.setRecipient(desk);
        m.setCap(CAP);
        vm.stopPrank();
    }

    function _send(uint256 amount) internal {
        vm.prank(operator);
        module.send(amount);
    }

    function test_fixesSafeTokenAndOperator() public view {
        assertEq(address(module.SAFE()), address(safe));
        assertEq(address(module.TOKEN()), address(usdg));
        assertEq(module.OPERATOR(), operator);
        assertEq(module.recipient(), desk);
        assertEq(module.cap(), CAP);
    }

    function test_constructorRefusesZeroAndCodelessToken() public {
        vm.expectRevert(CappedTransferModule.ZeroAddress.selector);
        new CappedTransferModule(ISafeModuleCall(address(0)), IERC20(address(usdg)), operator);
        vm.expectRevert(CappedTransferModule.ZeroAddress.selector);
        new CappedTransferModule(ISafeModuleCall(address(safe)), IERC20(address(usdg)), address(0));
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.NotAToken.selector, stranger));
        new CappedTransferModule(ISafeModuleCall(address(safe)), IERC20(stranger), operator);
    }

    function test_onlyTheSafeSetsRecipientAndCap() public {
        address[3] memory others = [operator, stranger, desk];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(CappedTransferModule.NotSafe.selector);
            module.setRecipient(stranger);
            vm.expectRevert(CappedTransferModule.NotSafe.selector);
            module.setCap(type(uint256).max);
            vm.stopPrank();
        }

        address newDesk = makeAddr("new desk");
        vm.startPrank(address(safe));
        vm.expectEmit(address(module));
        emit RecipientSet(newDesk);
        module.setRecipient(newDesk);
        vm.expectEmit(address(module));
        emit CapSet(25e6);
        module.setCap(25e6);
        vm.expectRevert(CappedTransferModule.ZeroAddress.selector);
        module.setRecipient(address(0));
        vm.stopPrank();
        assertEq(module.recipient(), newDesk);
        assertEq(module.cap(), 25e6);
    }

    function test_onlyTheOperatorSends() public {
        address[3] memory others = [stranger, desk, address(safe)];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(CappedTransferModule.NotOperator.selector);
            module.send(1e6);
        }
        assertEq(usdg.balanceOf(address(safe)), 1_000e6);
    }

    function test_sendsToTheRecipient() public {
        vm.expectEmit(address(module));
        emit Sent(desk, 4e6, 4e6, CAP);
        _send(4e6);
        assertEq(usdg.balanceOf(desk), 4e6);
        assertEq(usdg.balanceOf(address(safe)), 996e6);
        assertEq(module.spentToday(), 4e6);
        assertEq(module.left(), 6e6);
    }

    function test_refusesAboveWhatIsLeftToday() public {
        _send(7e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 3e6 + 1, 3e6));
        module.send(3e6 + 1);

        _send(3e6);
        assertEq(module.left(), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 1, 0));
        module.send(1);
        assertEq(usdg.balanceOf(desk), CAP);
    }

    function test_refusesAboveTheCapInOneSend() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, CAP + 1, CAP));
        module.send(CAP + 1);
    }

    function test_capRenewsAtUtcMidnight() public {
        vm.warp(MIDNIGHT + 1 days - 1);
        _send(CAP);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 1, 0));
        module.send(1);

        vm.warp(MIDNIGHT + 1 days);
        assertEq(module.spentToday(), 0);
        assertEq(module.left(), CAP);
        vm.expectEmit(address(module));
        emit Sent(desk, CAP, CAP, CAP);
        _send(CAP);
        assertEq(usdg.balanceOf(desk), 2 * CAP);
    }

    function test_aLowerCapAppliesToTheRestOfTheDay() public {
        _send(6e6);
        vm.prank(address(safe));
        module.setCap(5e6);
        assertEq(module.left(), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 1, 0));
        module.send(1);

        vm.prank(address(safe));
        module.setCap(8e6);
        assertEq(module.left(), 2e6);
        _send(2e6);
    }

    function test_zeroCapStopsSends() public {
        vm.prank(address(safe));
        module.setCap(0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 1, 0));
        module.send(1);
    }

    function test_aNewRecipientSharesTheDaysCap() public {
        _send(6e6);
        address newDesk = makeAddr("new desk");
        vm.prank(address(safe));
        module.setRecipient(newDesk);
        _send(4e6);
        assertEq(usdg.balanceOf(desk), 6e6);
        assertEq(usdg.balanceOf(newDesk), 4e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 1, 0));
        module.send(1);
    }

    function test_refusesZeroAndNoRecipient() public {
        vm.prank(operator);
        vm.expectRevert(CappedTransferModule.ZeroAmount.selector);
        module.send(0);

        CappedTransferModule bare = new CappedTransferModule(ISafeModuleCall(address(safe)), IERC20(usdg), operator);
        vm.prank(address(safe));
        safe.enableModule(address(bare));
        vm.prank(operator);
        vm.expectRevert(CappedTransferModule.NoRecipient.selector);
        bare.send(1);
    }

    function test_refusedWhileNotEnabled() public {
        vm.prank(address(safe));
        safe.disableModule(address(module));
        vm.prank(operator);
        vm.expectRevert("GS104");
        module.send(1e6);
        assertEq(module.spentToday(), 0);
        assertEq(usdg.balanceOf(address(safe)), 1_000e6);
    }

    function test_failedTransferRevertsAndSpendsNothing() public {
        vm.prank(address(safe));
        module.setCap(type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(CappedTransferModule.TransferFailed.selector);
        module.send(1_000e6 + 1);
        assertEq(module.spentToday(), 0);
    }

    function test_falseFromTheTokenReverts() public {
        FalseToken token = new FalseToken();
        token.mint(address(safe), 100e6);
        module = _module(address(token));
        vm.prank(operator);
        vm.expectRevert(CappedTransferModule.TransferFailed.selector);
        module.send(1e6);
        assertEq(module.spentToday(), 0);
    }

    function test_aTokenThatReturnsNothingWorks() public {
        SilentToken token = new SilentToken();
        token.mint(address(safe), 100e6);
        module = _module(address(token));
        _send(3e6);
        assertEq(token.balanceOf(desk), 3e6);
    }

    function test_operatorCannotCallTheSafeAsAModule() public {
        vm.prank(operator);
        vm.expectRevert("GS104");
        safe.execTransactionFromModuleReturnData(address(usdg), 0, abi.encodeCall(IERC20.transfer, (stranger, 1e6)), 0);
    }

    function test_noOtherEntryPoint() public {
        bytes[4] memory calls = [
            abi.encodeWithSignature("send(address,uint256)", stranger, 1e6),
            abi.encodeWithSignature("execute(address,uint256,bytes)", address(usdg), 0, ""),
            abi.encodeWithSignature("transfer(address,uint256)", stranger, 1e6),
            bytes("")
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(operator);
            (bool ok,) = address(module).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(usdg.balanceOf(address(safe)), 1_000e6);
    }

    function testFuzz_sendsExactlyUpToTheCap(uint256 first, uint256 second, uint32 later) public {
        first = bound(first, 1, CAP);
        second = bound(second, 1, 2 * CAP);
        later = uint32(bound(later, 0, 1 days - 9 hours - 1));
        _send(first);
        vm.warp(block.timestamp + later);
        vm.prank(operator);
        if (first + second > CAP) {
            vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, second, CAP - first));
            module.send(second);
            assertEq(usdg.balanceOf(desk), first);
        } else {
            module.send(second);
            assertEq(usdg.balanceOf(desk), first + second);
        }
        assertLe(usdg.balanceOf(desk), CAP);
    }
}
