// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BrainChainSetup} from "./BrainChain.t.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {PayoutPreferences} from "../src/PayoutPreferences.sol";
import {TaskBoard} from "../src/TaskBoard.sol";

contract PaidInStocksTest is BrainChainSetup {
    address internal house = makeAddr("house");
    address internal nvda = makeAddr("nvda");
    address internal claudeOnParent = makeAddr("claude-on-parent");
    PayoutPreferences internal payouts;

    function setUp() public override {
        super.setUp();
        payouts = new PayoutPreferences();
        vm.prank(address(executor));
        board.setPayouts(payouts, house);
    }

    function _delivered() internal returns (uint256 id) {
        id = postTask();
        uint256 hireId = decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        vm.prank(brain);
        board.hire(id, hireId);
        vm.prank(claudeAccount);
        board.submit(id, keccak256("r"), "");
    }

    function _graded(uint256 id, bool yes) internal {
        uint256 d = decide(DecisionLog.Kind.Grade, board.subjectOf(id), yes ? YES : NO, 9_000);
        vm.prank(brain);
        board.grade(id, d);
    }

    function test_defaultPayGoesToTheWorker() public {
        uint256 id = _delivered();
        _graded(id, true);
        vm.warp(block.timestamp + 2 hours);
        board.finalize(id);
        assertEq(usdg.balanceOf(claudeAccount), BOUNTY);
        assertEq(usdg.balanceOf(house), 0);
    }

    function test_stockPreferenceRoutesPayToTheHouse() public {
        vm.prank(claudeAccount);
        payouts.set(nvda, claudeOnParent);
        uint256 id = _delivered();
        assertEq(board.get(id).payee, house);
        _graded(id, true);
        vm.warp(block.timestamp + 2 hours);
        vm.expectEmit(true, true, true, true);
        emit TaskBoard.BountyPaid(id, CLAUDE, house, BOUNTY, 0);
        board.finalize(id);
        assertEq(usdg.balanceOf(house), BOUNTY);
        assertEq(usdg.balanceOf(claudeAccount), 0);
    }

    function test_workerStillDisputesWhenPaidThroughTheHouse() public {
        vm.prank(claudeAccount);
        payouts.set(nvda, claudeOnParent);
        uint256 id = _delivered();
        _graded(id, false);
        vm.prank(house);
        board.dispute(id);
        TaskBoard.Task memory t = board.get(id);
        assertTrue(t.disputed);
        assertTrue(t.disputedByModel);

        uint256 other = _delivered();
        _graded(other, false);
        vm.prank(claudeAccount);
        board.dispute(other);
        assertTrue(board.get(other).disputedByModel);

        uint256 third = _delivered();
        _graded(third, false);
        vm.prank(gptAccount);
        vm.expectRevert(TaskBoard.NotDisputant.selector);
        board.dispute(third);
    }

    function test_preferenceIsReadAtDeliveryAndNeedsARecipient() public {
        uint256 id = _delivered();
        vm.prank(claudeAccount);
        payouts.set(nvda, claudeOnParent);
        assertEq(board.get(id).payee, claudeAccount, "set after delivery: this task still pays the worker");

        vm.prank(claudeAccount);
        vm.expectRevert(PayoutPreferences.NoRecipient.selector);
        payouts.set(nvda, address(0));

        vm.prank(claudeAccount);
        payouts.set(address(0), address(0));
        assertFalse(payouts.inStock(claudeAccount));
    }

    function test_onlyTheOwnerSetsPayoutsAndAHouseIsRequired() public {
        vm.prank(poster);
        vm.expectRevert(TaskBoard.NotOwner.selector);
        board.setPayouts(payouts, house);
        vm.prank(address(executor));
        vm.expectRevert(TaskBoard.BadPayouts.selector);
        board.setPayouts(payouts, address(0));
        vm.prank(address(executor));
        board.setPayouts(PayoutPreferences(address(0)), address(0));
        vm.prank(claudeAccount);
        payouts.set(nvda, claudeOnParent);
        uint256 id = _delivered();
        assertEq(board.get(id).payee, claudeAccount, "no registry on the board: the worker is paid");
    }
}
