// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DecisionLog} from "../src/DecisionLog.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {BrainChainSetup} from "./BrainChain.t.sol";

contract AppealsTest is BrainChainSetup {
    uint64 internal constant APPEAL_WINDOW = 1 days;
    uint128 internal constant BOND = BOUNTY / 4;

    address internal feeRouter = makeAddr("fee-router");

    function setUp() public override {
        super.setUp();
        vm.startPrank(address(executor));
        board.setAppealConfig(TaskBoard.AppealConfig({window: APPEAL_WINDOW, bondBps: 2_500}));
        board.setFee(300, feeRouter);
        vm.stopPrank();
        usdg.mint(claudeAccount, 100e6);
        vm.prank(claudeAccount);
        usdg.approve(address(board), type(uint256).max);
    }

    /// Posts, hires, delivers, grades as given, disputes by `opener` and rules as given.
    function ruled(bytes32 grade, address opener, bytes32 ruling, uint16 confidenceBps) internal returns (uint256 id) {
        id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, grade, 9_000);
        vm.prank(opener);
        board.dispute(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), ruling, confidenceBps);
        vm.prank(brain);
        board.rule(id, d);
    }

    function ruleAgain(uint256 id, bytes32 answer, uint16 confidenceBps) internal {
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), answer, confidenceBps);
        vm.prank(brain);
        board.ruleAppeal(id, d);
    }

    function status(uint256 id) internal view returns (TaskBoard.Status) {
        return board.get(id).status;
    }

    function test_termsAreFixedWhenTheTaskIsPosted() public {
        uint256 id = postTask();
        vm.prank(address(executor));
        board.setAppealConfig(TaskBoard.AppealConfig({window: 0, bondBps: 0}));
        TaskBoard.Appeal memory a = board.appealOf(id);
        assertEq(a.window, APPEAL_WINDOW);
        assertEq(a.bondBps, 2_500);
        assertEq(board.appealBond(id), BOND);
        assertEq(board.appealOf(postTask()).window, 0);
    }

    function test_aRulingWaitsForItsAppealWindow() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Ruled));
        assertEq(usdg.balanceOf(poster), 1_000e6 - BOUNTY);

        vm.warp(block.timestamp + APPEAL_WINDOW);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        vm.warp(block.timestamp + 1);
        board.finalize(id);
        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Refunded));
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_withoutAppealTermsTheRulingSettlesAtOnce() public {
        vm.prank(address(executor));
        board.setAppealConfig(TaskBoard.AppealConfig({window: 0, bondBps: 0}));
        uint256 id = ruled(NO, claudeAccount, YES, 9_000);
        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Paid));
    }

    function test_aBondThatRoundsToNothingSettlesAtOnce() public {
        TaskBoard.Config memory c = defaultConfig();
        c.minBounty = 1;
        vm.startPrank(address(executor));
        board.setConfig(c);
        board.setAppealConfig(TaskBoard.AppealConfig({window: APPEAL_WINDOW, bondBps: 1}));
        vm.stopPrank();
        vm.prank(poster);
        uint256 id = board.post(9_999, uint64(block.timestamp + DAY), keccak256("brief"), "ipfs://brief");
        assertEq(board.appealBond(id), 0);
        hireClaude(id);
        deliver(id);
        gradeAs(id, NO, 9_000);
        vm.prank(claudeAccount);
        board.dispute(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        board.rule(id, d);
        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Paid));
    }

    function test_onlyTheSideTheRulingWentAgainstAppeals() public {
        uint256 refunded = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(poster);
        vm.expectRevert(TaskBoard.NotAppellant.selector);
        board.appeal(refunded);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(TaskBoard.NotAppellant.selector);
        board.appeal(refunded);
        vm.prank(claudeAccount);
        board.appeal(refunded);

        uint256 paid = ruled(NO, claudeAccount, YES, 9_000);
        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.NotAppellant.selector);
        board.appeal(paid);
        vm.prank(poster);
        board.appeal(paid);
    }

    function test_appealTakesTheBondAndOnlyOnce() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        assertEq(usdg.balanceOf(claudeAccount), 100e6 - BOND);
        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Appealed));
        TaskBoard.Appeal memory a = board.appealOf(id);
        assertEq(a.appellant, claudeAccount);
        assertEq(a.bond, BOND);
        assertEq(a.appealedAt, block.timestamp);

        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.appeal(id);
    }

    function test_appealClosesWithItsWindow() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.warp(block.timestamp + APPEAL_WINDOW + 1);
        vm.prank(claudeAccount);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.appeal(id);
    }

    function test_appealWorksWhilePausedButTheSecondRulingWaits() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(guardian);
        board.setPaused(true);
        vm.prank(claudeAccount);
        board.appeal(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.ruleAppeal(id, d);
    }

    function test_aConfidentReversalSettlesTheOtherWayAndReturnsTheBond() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        ruleAgain(id, YES, 9_000);

        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Paid));
        uint128 fee = BOUNTY * 300 / 10_000;
        assertEq(usdg.balanceOf(claudeAccount), 100e6 + BOUNTY - fee);
        assertEq(usdg.balanceOf(feeRouter), fee);
    }

    function test_aConfidentAgreementKeepsTheBondForTheFeeRouter() public {
        uint256 id = ruled(YES, poster, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        ruleAgain(id, NO, 9_500);

        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Refunded));
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(claudeAccount), 100e6 - BOND);
        assertEq(usdg.balanceOf(feeRouter), BOND);
    }

    function test_aKeptBondGoesToTheOtherSideWhenTheTaskHasNoFeeRecipient() public {
        vm.prank(address(executor));
        board.setFee(0, address(0));
        uint256 id = ruled(NO, claudeAccount, YES, 9_000);
        vm.prank(poster);
        board.appeal(id);
        ruleAgain(id, YES, 9_000);

        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Paid));
        assertEq(usdg.balanceOf(claudeAccount), 100e6 + BOUNTY + BOND);
        assertEq(usdg.balanceOf(poster), 1_000e6 - BOUNTY - BOND);
    }

    function test_anUnsureSecondRulingLeavesTheFirstAndReturnsTheBond() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        ruleAgain(id, YES, 6_000);

        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Refunded));
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(claudeAccount), 100e6);
    }

    function test_theRefundReasonFollowsTheStandingRuling() public {
        // Below threshold the first time, the grade stood: a refund for rejected work, not a ruling for the poster.
        uint256 id = ruled(NO, claudeAccount, YES, 5_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 6_000);
        vm.expectEmit(true, true, false, true, address(board));
        emit TaskBoard.BountyRefunded(id, poster, BOUNTY, TaskBoard.RefundReason.Rejected);
        vm.prank(brain);
        board.ruleAppeal(id, d);
    }

    function test_theSecondRulingMustBeRecordedAfterTheAppeal() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        uint256 early = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.warp(block.timestamp + 1);
        vm.prank(claudeAccount);
        board.appeal(id);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.ruleAppeal(id, early);
    }

    function test_theFirstRulingCannotBeAppliedTwice() public {
        uint256 id = postTask();
        hireClaude(id);
        deliver(id);
        gradeAs(id, NO, 9_000);
        vm.prank(claudeAccount);
        board.dispute(id);
        uint256 first = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), NO, 9_000);
        vm.prank(brain);
        board.rule(id, first);
        vm.prank(claudeAccount);
        board.appeal(id);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.DecisionUsed.selector);
        board.ruleAppeal(id, first);
    }

    function test_onlyTheBrainRulesOnAnAppeal() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.expectRevert(TaskBoard.NotBrain.selector);
        board.ruleAppeal(id, d);
    }

    function test_theSecondRulingClosesWithTheRuleWindow() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        vm.warp(block.timestamp + 6 hours + 1);
        uint256 d = decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.ruleAppeal(id, d);
    }

    function test_noSecondRulingInTimeSettlesTheFirstAndReturnsTheBond() public {
        uint256 id = ruled(NO, claudeAccount, NO, 9_000);
        vm.prank(claudeAccount);
        board.appeal(id);
        vm.warp(block.timestamp + 6 hours);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        vm.warp(block.timestamp + 1);
        board.finalize(id);

        assertEq(uint8(status(id)), uint8(TaskBoard.Status.Refunded));
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(claudeAccount), 100e6);
    }

    function test_onlyTheOwnerSetsAppealTerms() public {
        vm.expectRevert(TaskBoard.NotOwner.selector);
        board.setAppealConfig(TaskBoard.AppealConfig({window: 1 hours, bondBps: 2_500}));
    }

    function test_appealTermsAreBounded() public {
        vm.startPrank(address(executor));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setAppealConfig(TaskBoard.AppealConfig({window: 7 days + 1, bondBps: 2_500}));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setAppealConfig(TaskBoard.AppealConfig({window: 1 hours, bondBps: 10_001}));
        vm.expectRevert(TaskBoard.BadConfig.selector);
        board.setAppealConfig(TaskBoard.AppealConfig({window: 1 hours, bondBps: 0}));
        board.setAppealConfig(TaskBoard.AppealConfig({window: 0, bondBps: 0}));
        vm.stopPrank();
    }
}
