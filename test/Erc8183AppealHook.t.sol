// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IERC8183, IERC8183Hook} from "../src/interfaces/IERC8183.sol";
import {Erc8183AppealHook} from "../src/evaluators/Erc8183AppealHook.sol";
import {Erc8183Evaluator} from "../src/evaluators/Erc8183Evaluator.sol";
import {ERC8183} from "./erc8183/ERC8183.sol";
import {Erc8183Setup} from "./Erc8183Evaluator.t.sol";

/// Keeps a cut of every transfer once switched on.
contract SkimmingToken is ERC20 {
    bool public skim;

    constructor() ERC20("Skimming", "SKIM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setSkim(bool skim_) external {
        skim = skim_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (skim && from != address(0)) {
            super._update(from, address(0xdead), value / 10);
            value -= value / 10;
        }
        super._update(from, to, value);
    }
}

contract Erc8183AppealHookTest is Erc8183Setup {
    /// A decided job whose first decision went against `appellant`, appealed by it.
    function appealed(bool completes, address appellant) internal returns (uint256 id) {
        id = submittedJob();
        decide(id, completes, 9_000);
        vm.prank(appellant);
        hook.appeal(id);
    }

    function test_termsAreFixedWhenTheJobIsFunded() public {
        uint256 id = createJob(address(evaluator), address(hook));
        fundJob(id);
        vm.startPrank(safe);
        hook.setBond(address(usdc), 1);
        hook.setTerms(1 hours, 1 hours);
        vm.stopPrank();

        Erc8183AppealHook.Hold memory h = hook.holdOf(id);
        assertEq(uint8(h.stage), uint8(Erc8183AppealHook.Stage.Funded));
        assertEq(h.bond, BOND);
        assertEq(h.window, WINDOW);
        assertEq(h.rulingPeriod, RULING);
        assertEq(h.token, address(usdc));

        submitJob(id);
        assertEq(hook.deliverableOf(id), DELIVERABLE);
        decide(id, false, 9_000);
        vm.prank(provider);
        hook.appeal(id);
        assertEq(usdc.balanceOf(address(hook)), BOND);
    }

    function test_fundingRefusesAJobForAnotherEvaluator() public {
        uint256 id = createJob(makeAddr("other-evaluator"), address(hook));
        vm.prank(provider);
        acp.setBudget(id, address(usdc), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.WrongEvaluator.selector);
        acp.fund(id, address(usdc), BUDGET, "");
    }

    function test_fundingRefusesATokenWithoutABond() public {
        vm.prank(safe);
        hook.setBond(address(usdc), 0);
        uint256 id = createJob(address(evaluator), address(hook));
        vm.prank(provider);
        acp.setBudget(id, address(usdc), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.TokenNotServed.selector);
        acp.fund(id, address(usdc), BUDGET, "");
    }

    function test_fundingRefusesAnExpiryTooCloseForAnAppeal() public {
        vm.prank(client);
        uint256 id = acp.createJob(
            provider, address(evaluator), uint48(block.timestamp + WINDOW + RULING - 1), "brief", address(hook), 0
        );
        vm.prank(provider);
        acp.setBudget(id, address(usdc), BUDGET, "");
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.NoTimeToAppeal.selector);
        acp.fund(id, address(usdc), BUDGET, "");
    }

    function test_aSubmissionMustFollowFundingThroughTheHook() public {
        uint256 id = createJob(address(evaluator), address(hook));
        vm.prank(provider);
        vm.expectRevert(Erc8183AppealHook.NotFunded.selector);
        acp.submit(id, DELIVERABLE, "");
    }

    function test_anUnfundedJobCanStillBeRejectedByItsClient() public {
        uint256 id = createJob(address(evaluator), address(hook));
        vm.prank(client);
        acp.reject(id, bytes32(0), "");
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));
        assertEq(uint8(stage(id)), uint8(Erc8183AppealHook.Stage.None));
    }

    function test_theHookAnswersOnlyItsJobContractAndEvaluator() public {
        vm.expectRevert(Erc8183AppealHook.NotJobContract.selector);
        hook.beforeAction(1, IERC8183.complete.selector, "");
        vm.expectRevert(Erc8183AppealHook.NotJobContract.selector);
        hook.afterAction(1, IERC8183.complete.selector, "");
        vm.expectRevert(Erc8183AppealHook.NotEvaluator.selector);
        hook.onDecision(1, true);

        uint256 id = createJob(address(evaluator), address(hook));
        fundJob(id);
        vm.prank(address(evaluator));
        vm.expectRevert(Erc8183AppealHook.NotSubmitted.selector);
        hook.onDecision(id, true);
    }

    function test_onlyTheLosingSideAppeals() public {
        uint256 completed = submittedJob();
        decide(completed, true, 9_000);
        vm.prank(provider);
        vm.expectRevert(Erc8183AppealHook.NotLosingSide.selector);
        hook.appeal(completed);
        vm.prank(stranger);
        vm.expectRevert(Erc8183AppealHook.NotLosingSide.selector);
        hook.appeal(completed);
        vm.prank(client);
        hook.appeal(completed);

        uint256 rejected = submittedJob();
        decide(rejected, false, 9_000);
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.NotLosingSide.selector);
        hook.appeal(rejected);
        vm.prank(provider);
        hook.appeal(rejected);
    }

    function test_anAppealTakesTheBondAndOnlyOnce() public {
        uint256 id = submittedJob();
        vm.prank(provider);
        vm.expectRevert(Erc8183AppealHook.NotDecided.selector);
        hook.appeal(id);

        decide(id, false, 9_000);
        vm.expectEmit(address(hook));
        emit Erc8183AppealHook.Appealed(id, provider, BOND);
        vm.prank(provider);
        hook.appeal(id);
        assertEq(usdc.balanceOf(provider), 10_000e6 - BOND);
        assertEq(usdc.balanceOf(address(hook)), BOND);
        Erc8183AppealHook.Hold memory h = hook.holdOf(id);
        assertEq(uint8(h.stage), uint8(Erc8183AppealHook.Stage.Appealed));
        assertEq(h.appellant, provider);
        assertEq(h.appealedAt, block.timestamp);

        vm.prank(provider);
        vm.expectRevert(Erc8183AppealHook.AlreadyAppealed.selector);
        hook.appeal(id);
    }

    function test_anAppealOutsideTheWindowReverts() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        vm.warp(block.timestamp + WINDOW);
        uint256 snapshot = vm.snapshotState();
        vm.prank(client);
        hook.appeal(id);
        vm.revertToState(snapshot);

        vm.warp(block.timestamp + 1);
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.AppealClosed.selector);
        hook.appeal(id);
        evaluator.finalize(address(acp), id);
        vm.prank(client);
        vm.expectRevert(Erc8183AppealHook.NotDecided.selector);
        hook.appeal(id);
    }

    function test_anAppealHoldsTheFirstDecisionUntilItsRuling() public {
        uint256 id = appealed(true, client);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.expectRevert(Erc8183AppealHook.RulingOpen.selector);
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Submitted));
    }

    function test_aConfirmedAppealOfACompletionPaysTheBondToTheProvider() public {
        uint256 id = appealed(true, client);
        Erc8183Evaluator.Decision memory d = decision(id, true, true, 9_000);
        bytes memory signature = sign(BRAIN_KEY, d);
        vm.expectEmit(address(evaluator));
        emit Erc8183Evaluator.Settled(address(acp), id, d.decisionId, true);
        vm.expectEmit(address(hook));
        emit Erc8183AppealHook.BondSettled(id, provider, BOND);
        evaluator.decide(d, signature);

        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        assertEq(uint8(stage(id)), uint8(Erc8183AppealHook.Stage.Settled));
        assertEq(usdc.balanceOf(provider), 10_000e6 + net() + BOND);
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET - BOND);
        assertEq(usdc.balanceOf(address(hook)), 0);
    }

    function test_aConfirmedAppealOfARejectionPaysTheBondToTheClient() public {
        uint256 id = appealed(false, provider);
        rule(id, false, 9_000);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), 10_000e6 + BOND);
        assertEq(usdc.balanceOf(provider), 10_000e6 - BOND);
        assertEq(usdc.balanceOf(address(hook)), 0);
    }

    function test_aReversedAppealOfACompletionRefundsTheClientAndReturnsTheBond() public {
        uint256 id = appealed(true, client);
        Erc8183Evaluator.Decision memory d = rule(id, false, 9_000);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(provider), 10_000e6);
        assertEq(usdc.balanceOf(address(hook)), 0);
        assertFalse(evaluator.judgmentOf(address(acp), id).completes == d.accept);
    }

    function test_aReversedAppealOfARejectionPaysTheProviderAndReturnsTheBond() public {
        uint256 id = appealed(false, provider);
        rule(id, true, 9_000);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(provider), 10_000e6 + net());
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET);
        assertEq(usdc.balanceOf(address(hook)), 0);
    }

    function test_anUnsureRulingLeavesTheFirstDecisionAndReturnsTheBond() public {
        uint256 id = appealed(false, provider);
        rule(id, true, BAR - 1);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Rejected));
        assertEq(usdc.balanceOf(provider), 10_000e6);
        assertEq(usdc.balanceOf(client), 10_000e6);

        uint256 completed = appealed(true, client);
        rule(completed, false, 0);
        assertEq(uint8(status(completed)), uint8(IERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET);
    }

    function test_withoutARulingInTimeTheFirstDecisionStandsAndTheBondReturns() public {
        uint256 id = appealed(true, client);
        vm.warp(block.timestamp + RULING + 1);
        Erc8183Evaluator.Decision memory late = decision(id, true, false, 9_000);
        decideReverts(late, Erc8183AppealHook.RulingClosed.selector);

        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET);
        assertEq(usdc.balanceOf(provider), 10_000e6 + net());
    }

    function test_aRulingWithoutAnAppealReverts() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        Erc8183Evaluator.Decision memory d = decision(id, true, false, 9_000);
        decideReverts(d, Erc8183AppealHook.NotAppealed.selector);
    }

    function test_aSecondRulingReverts() public {
        uint256 id = appealed(true, client);
        rule(id, true, 9_000);
        Erc8183Evaluator.Decision memory again = decision(id, true, false, 9_000);
        decideReverts(again, Erc8183Evaluator.NotSubmitted.selector);
    }

    function test_aBondReturnsWhenTheJobExpiresUnderAppeal() public {
        uint256 id = appealed(true, client);
        vm.expectRevert(Erc8183AppealHook.JobOpen.selector);
        hook.releaseBond(id);

        vm.warp(acp.getJob(id).expiredAt + acp.EVALUATION_GRACE_PERIOD());
        acp.claimRefund(id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Expired));
        vm.prank(stranger);
        hook.releaseBond(id);
        assertEq(usdc.balanceOf(client), 10_000e6);
        assertEq(usdc.balanceOf(address(hook)), 0);
        vm.expectRevert(Erc8183AppealHook.NotAppealed.selector);
        hook.releaseBond(id);
    }

    function test_releaseBondNeedsAnAppeal() public {
        uint256 id = submittedJob();
        decide(id, true, 9_000);
        vm.expectRevert(Erc8183AppealHook.NotAppealed.selector);
        hook.releaseBond(id);
    }

    function test_aDetachedHookEndsTheHoldAndReturnsTheBond() public {
        uint256 id = appealed(true, client);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(admin);
        acp.batchDetachHook(ids);

        Erc8183Evaluator.Decision memory d = decision(id, true, false, 9_000);
        decideReverts(d, Erc8183Evaluator.WrongHook.selector);
        evaluator.finalize(address(acp), id);
        assertEq(uint8(status(id)), uint8(IERC8183.JobStatus.Completed));
        hook.releaseBond(id);
        assertEq(usdc.balanceOf(client), 10_000e6 - BUDGET);
    }

    function test_anAppealRefusesATokenThatSkims() public {
        SkimmingToken skimming = new SkimmingToken();
        vm.prank(safe);
        hook.setBond(address(skimming), BOND);
        vm.prank(admin);
        acp.setPaymentTokenAllowed(address(skimming), true);
        skimming.mint(client, BUDGET);
        skimming.mint(provider, BOND);
        vm.prank(client);
        skimming.approve(address(acp), BUDGET);
        vm.prank(provider);
        skimming.approve(address(hook), BOND);

        uint256 id = createJob(address(evaluator), address(hook));
        vm.prank(provider);
        acp.setBudget(id, address(skimming), BUDGET, "");
        vm.prank(client);
        acp.fund(id, address(skimming), BUDGET, "");
        submitJob(id);
        decide(id, false, 9_000);
        skimming.setSkim(true);
        vm.prank(provider);
        vm.expectRevert(Erc8183AppealHook.TransferMismatch.selector);
        hook.appeal(id);
    }

    function test_ownerSetsBondsAndTerms() public {
        vm.startPrank(stranger);
        vm.expectRevert(Erc8183AppealHook.NotOwner.selector);
        hook.setBond(address(usdc), 1);
        vm.expectRevert(Erc8183AppealHook.NotOwner.selector);
        hook.setTerms(1 hours, 1 hours);
        vm.stopPrank();

        vm.startPrank(safe);
        vm.expectRevert(Erc8183AppealHook.ZeroAddress.selector);
        hook.setBond(address(0), 1);
        vm.expectRevert(Erc8183AppealHook.BadTerms.selector);
        hook.setTerms(0, 1 hours);
        vm.expectRevert(Erc8183AppealHook.BadTerms.selector);
        hook.setTerms(1 hours, 0);
        vm.expectRevert(Erc8183AppealHook.BadTerms.selector);
        hook.setTerms(30 days + 1, 1 hours);
        vm.expectRevert(Erc8183AppealHook.BadTerms.selector);
        hook.setTerms(1 hours, 30 days + 1);
        hook.setTerms(30 days, 30 days);
        hook.setBond(address(usdc), 7);
        vm.stopPrank();
        assertEq(hook.window(), 30 days);
        assertEq(hook.rulingPeriod(), 30 days);
        assertEq(hook.bondOf(address(usdc)), 7);
    }

    function test_hookConstructorAndOwnership() public {
        vm.expectRevert(Erc8183AppealHook.ZeroAddress.selector);
        new Erc8183AppealHook(IERC8183(address(0)), address(evaluator), safe, WINDOW, RULING);
        vm.expectRevert(Erc8183AppealHook.ZeroAddress.selector);
        new Erc8183AppealHook(acp, address(0), safe, WINDOW, RULING);
        vm.expectRevert(Erc8183AppealHook.ZeroAddress.selector);
        new Erc8183AppealHook(acp, address(evaluator), address(0), WINDOW, RULING);
        vm.expectRevert(Erc8183AppealHook.BadTerms.selector);
        new Erc8183AppealHook(acp, address(evaluator), safe, 0, RULING);

        address next = makeAddr("next-safe");
        vm.prank(stranger);
        vm.expectRevert(Erc8183AppealHook.NotOwner.selector);
        hook.transferOwnership(next);
        vm.prank(safe);
        vm.expectRevert(Erc8183AppealHook.ZeroAddress.selector);
        hook.transferOwnership(address(0));
        vm.prank(safe);
        hook.transferOwnership(next);
        vm.prank(stranger);
        vm.expectRevert(Erc8183AppealHook.NotPendingOwner.selector);
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        assertEq(hook.pendingOwner(), address(0));
    }

    function test_theHookAdvertisesTheReferenceInterface() public view {
        assertTrue(hook.supportsInterface(type(IERC8183Hook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(0xffffffff));
        assertEq(
            type(IERC8183Hook).interfaceId,
            bytes4(keccak256("beforeAction(uint256,bytes4,bytes)"))
                ^ bytes4(keccak256("afterAction(uint256,bytes4,bytes)"))
        );
        assertEq(IERC8183.fund.selector, bytes4(keccak256("fund(uint256,address,uint256,bytes)")));
        assertEq(ERC8183.complete.selector, IERC8183.complete.selector);
    }
}

/// The hook on its own, with a stand-in evaluator that calls the job contract
/// directly, so its gate is tested against settlements the real evaluator never sends.
contract Erc8183AppealHookGateTest is Erc8183Setup {
    address internal judge = makeAddr("judge");
    Erc8183AppealHook internal gate;

    function setUp() public override {
        super.setUp();
        gate = new Erc8183AppealHook(acp, judge, safe, WINDOW, RULING);
        vm.prank(safe);
        gate.setBond(address(usdc), BOND);
        vm.prank(admin);
        acp.setHookWhitelist(address(gate), true);
        vm.prank(client);
        usdc.approve(address(gate), type(uint256).max);
    }

    function gatedJob() internal returns (uint256 id) {
        id = createJob(judge, address(gate));
        fundJob(id);
        submitJob(id);
    }

    function test_settlementBeforeAFirstDecisionReverts() public {
        uint256 id = gatedJob();
        vm.startPrank(judge);
        vm.expectRevert(Erc8183AppealHook.NotDecided.selector);
        acp.reject(id, 0, abi.encode(false, false));
        vm.expectRevert(Erc8183AppealHook.NotAppealed.selector);
        acp.complete(id, 0, abi.encode(true, false));
        vm.stopPrank();
    }

    function test_settlementMustMatchTheFirstDecision() public {
        uint256 id = gatedJob();
        vm.prank(judge);
        gate.onDecision(id, true);
        vm.warp(block.timestamp + WINDOW + 1);
        vm.prank(judge);
        vm.expectRevert(Erc8183AppealHook.WrongOutcome.selector);
        acp.reject(id, 0, abi.encode(false, false));
        vm.prank(judge);
        acp.complete(id, 0, abi.encode(false, false));
        assertEq(uint8(acp.getJob(id).status), uint8(IERC8183.JobStatus.Completed));
    }

    function test_aRulingThatKeepsTheBondMustConfirm() public {
        uint256 id = gatedJob();
        vm.prank(judge);
        gate.onDecision(id, true);
        vm.prank(client);
        gate.appeal(id);
        vm.prank(judge);
        vm.expectRevert(Erc8183AppealHook.WrongOutcome.selector);
        acp.reject(id, 0, abi.encode(true, true));
        vm.prank(judge);
        acp.reject(id, 0, abi.encode(true, false));
        assertEq(usdc.balanceOf(client), 10_000e6);
    }

    function test_theEvaluatorCannotRejectAFundedJobUnderTheHook() public {
        uint256 id = createJob(judge, address(gate));
        fundJob(id);
        vm.prank(judge);
        vm.expectRevert(Erc8183AppealHook.NotDecided.selector);
        acp.reject(id, 0, abi.encode(false, false));
    }
}
