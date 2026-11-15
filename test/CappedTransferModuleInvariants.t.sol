// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CappedTransferModule, ISafeModuleCall} from "../src/safe/CappedTransferModule.sol";
import {MockERC20} from "./MockERC20.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

contract CappedTransferHandler is Test {
    SafeStandIn internal immutable safe;
    MockERC20 internal immutable usdg;
    CappedTransferModule internal immutable module;
    address internal immutable operator;
    address[3] internal desks;

    mapping(uint256 day => uint256) public outflow;
    mapping(uint256 day => uint256) public highestCap;
    uint256 public overCapDays;
    uint256 public refusedWithinCap;
    uint256 public movedByOthers;

    constructor(SafeStandIn safe_, MockERC20 usdg_, CappedTransferModule module_, address operator_) {
        safe = safe_;
        usdg = usdg_;
        module = module_;
        operator = operator_;
        desks = [makeAddr("desk 0"), makeAddr("desk 1"), makeAddr("desk 2")];
    }

    function recipients() external view returns (address[3] memory) {
        return desks;
    }

    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function _noteCap() internal {
        if (module.cap() > highestCap[_today()]) highestCap[_today()] = module.cap();
    }

    function send(uint256 amount) external {
        amount = bound(amount, 1, module.cap() + module.cap() / 2 + 1);
        uint256 left = module.left();
        uint256 before = usdg.balanceOf(address(safe));
        vm.prank(operator);
        try module.send(amount) {} catch {}
        uint256 fell = before - usdg.balanceOf(address(safe));
        if (fell == 0 && amount <= left && amount <= before) refusedWithinCap++;
        outflow[_today()] += fell;
        if (outflow[_today()] > highestCap[_today()]) overCapDays++;
    }

    function sendAsAnother(uint256 amount, uint256 who) external {
        address[3] memory others = [address(safe), desks[who % 3], makeAddr("stranger")];
        uint256 before = usdg.balanceOf(address(safe));
        vm.prank(others[who % 3]);
        try module.send(bound(amount, 1, 1_000e6)) {} catch {}
        if (usdg.balanceOf(address(safe)) != before) movedByOthers++;
    }

    function callSafeDirectly(uint256 amount) external {
        uint256 before = usdg.balanceOf(address(safe));
        vm.prank(operator);
        try safe.execTransactionFromModuleReturnData(
            address(usdg), 0, abi.encodeCall(IERC20.transfer, (operator, bound(amount, 1, 1_000e6))), 0
        ) {}
            catch {}
        if (usdg.balanceOf(address(safe)) != before) movedByOthers++;
    }

    function setCap(uint256 cap) external {
        vm.prank(address(safe));
        module.setCap(bound(cap, 0, 50e6));
        _noteCap();
    }

    function setRecipient(uint256 which) external {
        vm.prank(address(safe));
        module.setRecipient(desks[which % 3]);
    }

    function wait(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 30 hours));
        _noteCap();
    }
}

contract CappedTransferModuleInvariants is Test {
    uint256 constant FUNDED = 10_000e6;

    SafeStandIn safe;
    MockERC20 usdg;
    CappedTransferModule module;
    CappedTransferHandler handler;

    function setUp() public {
        vm.warp(1_794_700_800);
        address operator = makeAddr("operator");
        safe = new SafeStandIn();
        usdg = new MockERC20();
        usdg.mint(address(safe), FUNDED);
        module = new CappedTransferModule(ISafeModuleCall(address(safe)), IERC20(address(usdg)), operator);
        handler = new CappedTransferHandler(safe, usdg, module, operator);
        vm.prank(address(safe));
        safe.enableModule(address(module));
        handler.setRecipient(0);
        handler.setCap(10e6);
        targetContract(address(handler));
    }

    function invariant_safeFallsByNoMoreThanTheCapInADay() public view {
        assertEq(handler.overCapDays(), 0);
        assertLe(handler.outflow(block.timestamp / 1 days), handler.highestCap(block.timestamp / 1 days));
    }

    function invariant_spentTodayIsTheSafesOutflowToday() public view {
        assertEq(module.spentToday(), handler.outflow(block.timestamp / 1 days));
    }

    function invariant_onlyTheOperatorMovesFunds() public view {
        assertEq(handler.movedByOthers(), 0);
    }

    function invariant_sendsWithinTheCapGoThrough() public view {
        assertEq(handler.refusedWithinCap(), 0);
    }

    function invariant_fundsGoOnlyToRecipients() public view {
        address[3] memory desks = handler.recipients();
        uint256 received;
        for (uint256 i; i < desks.length; i++) {
            received += usdg.balanceOf(desks[i]);
        }
        assertEq(usdg.balanceOf(address(safe)) + received, FUNDED);
    }
}
