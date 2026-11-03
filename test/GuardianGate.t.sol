// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GuardianGate, IGuardedExecutor, IGuardedBoard} from "../src/GuardianGate.sol";

contract RecordingGuarded is IGuardedExecutor, IGuardedBoard {
    uint256 public vetoed;
    bool public paused;
    address public lastCaller;

    function veto(uint256 changeId) external {
        vetoed = changeId;
        lastCaller = msg.sender;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
        lastCaller = msg.sender;
    }
}

contract GuardianGateTest is Test {
    RecordingGuarded internal target;
    GuardianGate internal gate;
    address internal safe = makeAddr("safe");
    address internal watcher = makeAddr("watcher");

    function setUp() public {
        target = new RecordingGuarded();
        gate = new GuardianGate(safe, target, target, watcher);
    }

    function test_theWatcherVetoesAndPausesButCannotUnpause() public {
        vm.startPrank(watcher);
        gate.veto(7, "change threshold below the constitution's floor");
        assertEq(target.vetoed(), 7);
        assertEq(target.lastCaller(), address(gate));
        gate.setPaused(true, "a queued change drains the house treasury");
        assertTrue(target.paused());
        vm.expectRevert(GuardianGate.NotAllowed.selector);
        gate.setPaused(false, "");
        vm.stopPrank();
        vm.prank(safe);
        gate.setPaused(false, "reviewed");
        assertFalse(target.paused());
    }

    function test_onlyTheSafeReplacesTheWatcher() public {
        address next = makeAddr("next");
        vm.prank(watcher);
        vm.expectRevert(GuardianGate.NotSafe.selector);
        gate.setWatcher(next);
        vm.prank(safe);
        gate.setWatcher(next);
        vm.prank(watcher);
        vm.expectRevert(GuardianGate.NotAllowed.selector);
        gate.veto(1, "");
        vm.prank(next);
        gate.veto(1, "");
        assertEq(target.vetoed(), 1);
    }

    function test_strangersCanDoNothing() public {
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(GuardianGate.NotAllowed.selector);
        gate.veto(1, "");
        vm.expectRevert(GuardianGate.NotAllowed.selector);
        gate.setPaused(true, "");
        vm.stopPrank();
    }
}
