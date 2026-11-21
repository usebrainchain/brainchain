// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CappedTransferModuleV2, ISafeModuleExec} from "../src/safe/CappedTransferModuleV2.sol";
import {SafeStandIn} from "./safe/SafeStandIn.sol";

contract CappedTransferV2Handler is Test {
    SafeStandIn internal immutable safe;
    CappedTransferModuleV2 internal immutable module;
    address[2] internal operators;
    address[3] internal desks;
    uint256 internal inOffice;

    mapping(uint256 day => uint256) public outflow;
    uint256 public overDailyCap;
    uint256 public overWindowCap;
    uint256 public refusedWithinCaps;
    uint256 public movedByOthers;

    constructor(SafeStandIn safe_, CappedTransferModuleV2 module_, address operator) {
        safe = safe_;
        module = module_;
        operators = [operator, makeAddr("next operator")];
        desks = [makeAddr("desk 0"), makeAddr("desk 1"), makeAddr("desk 2")];
    }

    function recipients() external view returns (address[3] memory) {
        return desks;
    }

    function windowOutflow() public view returns (uint256 total) {
        uint256 today = block.timestamp / 1 days;
        for (uint256 back; back < 30; back++) {
            total += outflow[today - back];
        }
    }

    function send(uint256 amount) external {
        amount = bound(amount, 1, uint256(module.dailyCap()) * 3 / 2 + 1);
        uint256 left = module.left();
        uint256 before = address(safe).balance;
        vm.prank(operators[inOffice]);
        try module.send(amount) {} catch {}
        uint256 fell = before - address(safe).balance;
        if (fell == 0 && amount <= left && amount <= before) refusedWithinCaps++;
        if (fell == 0) return;
        outflow[block.timestamp / 1 days] += fell;
        if (outflow[block.timestamp / 1 days] > module.dailyCap()) overDailyCap++;
        if (windowOutflow() > module.windowCap()) overWindowCap++;
    }

    function sendAsAnother(uint256 amount, uint256 who) external {
        address[4] memory others = [address(safe), desks[who % 3], operators[1 - inOffice], makeAddr("stranger")];
        uint256 before = address(safe).balance;
        vm.prank(others[who % 4]);
        try module.send(bound(amount, 1, 1 ether)) {} catch {}
        if (address(safe).balance != before) movedByOthers++;
    }

    function callSafeDirectly(uint256 amount) external {
        uint256 before = address(safe).balance;
        vm.prank(operators[inOffice]);
        try safe.execTransactionFromModule(operators[inOffice], bound(amount, 1, 1 ether), "", 0) {} catch {}
        if (address(safe).balance != before) movedByOthers++;
    }

    function setCaps(uint256 dailyCap, uint256 windowCap) external {
        vm.prank(address(safe));
        module.setCaps(uint128(bound(dailyCap, 0, 0.02 ether)), uint128(bound(windowCap, 0, 0.2 ether)));
    }

    function setRecipient(uint256 which) external {
        vm.prank(address(safe));
        module.setRecipient(desks[which % 3]);
    }

    function rotateOperator() external {
        inOffice = 1 - inOffice;
        vm.prank(address(safe));
        module.setOperator(operators[inOffice]);
    }

    function wait(uint256 secondsAhead) external {
        vm.warp(block.timestamp + bound(secondsAhead, 1, 30 hours));
    }

    function leap(uint256 daysAhead) external {
        vm.warp(block.timestamp + bound(daysAhead, 2, 45) * 1 days);
    }
}

contract CappedTransferModuleV2Invariants is Test {
    uint256 constant FUNDED = 100 ether;

    SafeStandIn safe;
    CappedTransferModuleV2 module;
    CappedTransferV2Handler handler;

    function setUp() public {
        vm.warp(1_794_700_800);
        address operator = makeAddr("operator");
        safe = new SafeStandIn();
        vm.deal(address(safe), FUNDED);
        module = new CappedTransferModuleV2(ISafeModuleExec(address(safe)), address(0), operator);
        handler = new CappedTransferV2Handler(safe, module, operator);
        vm.prank(address(safe));
        safe.enableModule(address(module));
        handler.setRecipient(0);
        handler.setCaps(0.008 ether, 0.04 ether);
        targetContract(address(handler));
    }

    function invariant_neitherCapIsPassed() public view {
        assertEq(handler.overDailyCap(), 0);
        assertEq(handler.overWindowCap(), 0);
    }

    function invariant_spentTodayIsTheSafesOutflowToday() public view {
        assertEq(module.spentToday(), handler.outflow(block.timestamp / 1 days));
    }

    function invariant_spentInWindowIsTheSafesOutflowOverThirtyDays() public view {
        assertEq(module.spentInWindow(), handler.windowOutflow());
    }

    function invariant_onlyTheOperatorInOfficeMovesFunds() public view {
        assertEq(handler.movedByOthers(), 0);
    }

    function invariant_sendsWithinBothCapsGoThrough() public view {
        assertEq(handler.refusedWithinCaps(), 0);
    }

    function invariant_fundsGoOnlyToRecipients() public view {
        address[3] memory desks = handler.recipients();
        uint256 received;
        for (uint256 i; i < desks.length; i++) {
            received += desks[i].balance;
        }
        assertEq(address(safe).balance + received, FUNDED);
    }
}
