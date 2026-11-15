// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAuthCaptureEscrow, JudgedCapture} from "../src/escrow/JudgedCapture.sol";
import {MockERC3009} from "./MockERC3009.sol";

interface IEscrow is IAuthCaptureEscrow {
    function reclaim(PaymentInfo calldata paymentInfo) external;
    function getTokenStore(address operator) external view returns (address);
}

interface IERC3009Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// Payments, payer authorizations and brain decisions, for any token with ERC-3009.
abstract contract JudgedCaptureBase is Test {
    IEscrow internal constant ESCROW = IEscrow(0xf96815976523E00e65Be8f34cA5e64b4f41EB19c);
    address internal constant ERC3009_COLLECTOR = 0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88;
    address internal constant TOKEN_STORE = 0xe4be44B1505d29ae640748b4cce530ece6DcD450;
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    uint256 internal constant CAP = 25e6;
    uint16 internal constant BAR = 8_000;
    uint16 internal constant FEE_BPS = 300;
    /// The task deadline plus the grade, dispute, ruling and appeal windows.
    uint48 internal constant WINDOWS = 3 days;
    uint48 internal constant CAPTURE_MARGIN = 1 days;
    uint256 internal constant DECISION_ID = 4_242;

    JudgedCapture internal judged;
    address internal token;
    address internal owner = makeAddr("safe");
    address internal payee = makeAddr("payee");
    address internal feeRecipient = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");
    address internal decisionLog = makeAddr("l3-decision-log");
    uint256 internal brainKey = uint256(keccak256("brain key"));
    address internal brain = vm.addr(brainKey);
    uint256 internal payerKey = uint256(keccak256("payer key"));
    address internal payer = vm.addr(payerKey);

    function _terms(bytes32 task) internal view returns (JudgedCapture.Terms memory) {
        return JudgedCapture.Terms({task: task, barBps: BAR, windowsClose: uint48(block.timestamp) + WINDOWS});
    }

    function _payment(address from, uint120 amount, JudgedCapture.Terms memory terms)
        internal
        view
        returns (IAuthCaptureEscrow.PaymentInfo memory)
    {
        uint48 deadline = terms.windowsClose + CAPTURE_MARGIN;
        return IAuthCaptureEscrow.PaymentInfo({
            operator: address(judged),
            payer: from,
            receiver: payee,
            token: token,
            maxAmount: amount,
            preApprovalExpiry: uint48(block.timestamp) + 1 hours,
            authorizationExpiry: deadline,
            refundExpiry: deadline,
            minFeeBps: FEE_BPS,
            maxFeeBps: FEE_BPS,
            feeReceiver: feeRecipient,
            salt: judged.saltOf(terms)
        });
    }

    /// The payer's one signature: an ERC-3009 authorization to the collector, its nonce the payer-agnostic hash.
    function _authorization(uint256 key, IAuthCaptureEscrow.PaymentInfo memory p) internal view returns (bytes memory) {
        address from = p.payer;
        p.payer = address(0);
        bytes32 nonce = ESCROW.getHash(p);
        p.payer = from;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC3009Domain(p.token).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                        from,
                        ERC3009_COLLECTOR,
                        p.maxAmount,
                        0,
                        p.preApprovalExpiry,
                        nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authorize(uint256 key, IAuthCaptureEscrow.PaymentInfo memory p) internal {
        judged.authorize(p, p.maxAmount, ERC3009_COLLECTOR, _authorization(key, p));
    }

    function _decision(IAuthCaptureEscrow.PaymentInfo memory p, bytes32 task, bool accepted, uint16 confidenceBps)
        internal
        view
        returns (JudgedCapture.Decision memory)
    {
        return JudgedCapture.Decision({
            task: task,
            paymentInfoHash: ESCROW.getHash(p),
            accepted: accepted,
            confidenceBps: confidenceBps,
            decisionId: DECISION_ID,
            decisionLog: decisionLog
        });
    }

    function _sign(uint256 key, JudgedCapture.Decision memory decision) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, judged.digestOf(decision));
        return abi.encodePacked(r, s, v);
    }

    function _held(IAuthCaptureEscrow.PaymentInfo memory p) internal view returns (uint256 capturable) {
        (, capturable,) = ESCROW.paymentState(ESCROW.getHash(p));
    }
}

/// The real escrow, collector and token store code from Base, at their Base addresses, with a local ERC-3009 token.
abstract contract JudgedCaptureSetup is JudgedCaptureBase {
    MockERC3009 internal usdc;

    function setUp() public virtual {
        string memory json = vm.readFile("test/fixtures/commerce-payments-v1.1.0.json");
        vm.etch(address(ESCROW), vm.parseJsonBytes(json, ".AuthCaptureEscrow.code"));
        vm.etch(ERC3009_COLLECTOR, vm.parseJsonBytes(json, ".ERC3009PaymentCollector.code"));
        vm.etch(TOKEN_STORE, vm.parseJsonBytes(json, ".TokenStore.code"));
        usdc = new MockERC3009();
        token = address(usdc);
        judged = new JudgedCapture(ESCROW, token, owner, brain, CAP);
        usdc.mint(payer, 1_000e6);
    }
}

contract JudgedCaptureTest is JudgedCaptureSetup {
    bytes32 internal constant TASK = keccak256("order 1");
    bytes32 internal constant OTHER_TASK = keccak256("order 2");
    uint120 internal constant AMOUNT = 10e6;

    JudgedCapture.Terms internal terms;
    IAuthCaptureEscrow.PaymentInfo internal p;

    function setUp() public override {
        super.setUp();
        terms = _terms(TASK);
        p = _payment(payer, AMOUNT, terms);
    }

    function _accept() internal view returns (JudgedCapture.Decision memory) {
        return _decision(p, TASK, true, 9_000);
    }

    function _refuse() internal view returns (JudgedCapture.Decision memory) {
        return _decision(p, TASK, false, 9_000);
    }

    function _authorized() internal {
        vm.prank(stranger);
        _authorize(payerKey, p);
    }

    // Construction

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        new JudgedCapture(IAuthCaptureEscrow(address(0)), token, owner, brain, CAP);
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        new JudgedCapture(ESCROW, address(0), owner, brain, CAP);
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        new JudgedCapture(ESCROW, token, address(0), brain, CAP);
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        new JudgedCapture(ESCROW, token, owner, address(0), CAP);
    }

    function test_startsWithTheOwnerBrainAndCap() public view {
        assertEq(address(judged.escrow()), address(ESCROW));
        assertEq(judged.token(), token);
        assertEq(judged.owner(), owner);
        assertEq(judged.brain(), brain);
        assertEq(judged.cap(), 25e6, "25 USDC in 6-decimal units");
        assertEq(judged.DELAY(), 2 days);
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            judged.eip712Domain();
        assertEq(name, "JudgedCapture");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(judged));
    }

    function test_saltCommitsToEveryTerm() public view {
        assertEq(judged.saltOf(terms), uint256(keccak256(abi.encode(judged.TERMS_TYPEHASH(), terms))));
        JudgedCapture.Terms memory changed = terms;
        changed.barBps = BAR - 1;
        assertNotEq(judged.saltOf(changed), judged.saltOf(terms));
        changed = _terms(TASK);
        changed.windowsClose -= 1;
        assertNotEq(judged.saltOf(changed), judged.saltOf(terms));
        changed = _terms(OTHER_TASK);
        assertNotEq(judged.saltOf(changed), judged.saltOf(terms));
    }

    function test_digestIsTheEip712HashOfTheDecision() public view {
        JudgedCapture.Decision memory d = _accept();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("JudgedCapture"),
                keccak256("1"),
                block.chainid,
                address(judged)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Decision(bytes32 task,bytes32 paymentInfoHash,bool accepted,uint16 confidenceBps,uint256 decisionId,address decisionLog)"
                ),
                d.task,
                d.paymentInfoHash,
                d.accepted,
                d.confidenceBps,
                d.decisionId,
                d.decisionLog
            )
        );
        assertEq(judged.digestOf(d), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    // Authorize

    function test_anyoneSubmitsTheAuthorizationAndTheFullAmountIsHeld() public {
        _authorized();
        assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        assertEq(usdc.balanceOf(ESCROW.getTokenStore(address(judged))), AMOUNT);
        assertEq(_held(p), AMOUNT);
    }

    function test_authorizeRejectsAnotherToken() public {
        MockERC3009 other = new MockERC3009();
        p.token = address(other);
        vm.expectRevert(JudgedCapture.WrongToken.selector);
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, "");
    }

    function test_authorizeRejectsAPartialHold() public {
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.PartialHold.selector);
        judged.authorize(p, AMOUNT - 1, ERC3009_COLLECTOR, sig);
    }

    function test_authorizeHoldsUpToTheCapAndNoMore() public {
        p = _payment(payer, uint120(CAP), terms);
        _authorize(payerKey, p);
        assertEq(_held(p), CAP);

        p = _payment(payer, uint120(CAP + 1), _terms(OTHER_TASK));
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.OverCap.selector);
        judged.authorize(p, CAP + 1, ERC3009_COLLECTOR, sig);
    }

    function test_authorizeRejectsAFeeFloorWithNowhereToGo() public {
        p.feeReceiver = address(0);
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.NoFeeReceiver.selector);
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, sig);
    }

    function test_authorizeForAnotherOperatorFailsInTheEscrow() public {
        p.operator = stranger;
        bytes memory sig = _authorization(payerKey, p);
        vm.expectPartialRevert(bytes4(keccak256("InvalidSender(address,address)")));
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, sig);
    }

    function test_anAuthorizationCollectsOnce() public {
        bytes memory sig = _authorization(payerKey, p);
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, sig);
        vm.expectPartialRevert(bytes4(keccak256("PaymentAlreadyCollected(bytes32)")));
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, sig);
    }

    function test_authorizeFailsOnASignatureForOtherTerms() public {
        bytes memory sig = _authorization(payerKey, p);
        p.salt = judged.saltOf(_terms(OTHER_TASK));
        vm.expectRevert("invalid signature");
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, sig);
    }

    // Capture

    function test_captureAfterTheWindowsPaysThePayeeLessTheFee() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;

        vm.expectEmit(address(judged));
        emit JudgedCapture.Captured(ESCROW.getHash(p), TASK, DECISION_ID, decisionLog, AMOUNT, fee);
        vm.prank(stranger);
        judged.capture(p, terms, d, _sign(brainKey, d));

        assertEq(usdc.balanceOf(payee), AMOUNT - fee);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        assertEq(_held(p), 0);
    }

    function test_captureAtTheBarExactly() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR);
        judged.capture(p, terms, d, _sign(brainKey, d));
        assertEq(_held(p), 0);
    }

    function test_captureRefusesAnAcceptanceBelowTheBar() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.NotAccepted.selector);
        judged.capture(p, terms, d, sig);
    }

    function test_captureRefusesARefusal() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _refuse();
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.NotAccepted.selector);
        judged.capture(p, terms, d, sig);
    }

    function test_captureWaitsForTheWindows() public {
        _authorized();
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.warp(terms.windowsClose - 1);
        vm.expectRevert(JudgedCapture.WindowsOpen.selector);
        judged.capture(p, terms, d, sig);
        vm.warp(terms.windowsClose);
        judged.capture(p, terms, d, sig);
    }

    function test_captureEndsAtTheCaptureDeadline() public {
        _authorized();
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.warp(p.authorizationExpiry);
        vm.expectPartialRevert(bytes4(keccak256("AfterAuthorizationExpiry(uint48,uint48)")));
        judged.capture(p, terms, d, sig);
    }

    function test_theBarCannotBeLoweredAtCapture() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Terms memory lowered = terms;
        lowered.barBps = 5_000;
        JudgedCapture.Decision memory d = _decision(p, TASK, true, 6_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTerms.selector);
        judged.capture(p, lowered, d, sig);
    }

    function test_theWindowsCannotBeShortenedAtCapture() public {
        _authorized();
        JudgedCapture.Terms memory early = terms;
        early.windowsClose = uint48(block.timestamp);
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTerms.selector);
        judged.capture(p, early, d, sig);
    }

    function test_aDecisionForAnotherTaskDoesNotCapture() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, OTHER_TASK, true, 9_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.capture(p, terms, d, sig);
    }

    function test_aDecisionForAnotherPaymentDoesNotCapture() public {
        _authorized();
        IAuthCaptureEscrow.PaymentInfo memory second = _payment(payer, 5e6, terms);
        second.preApprovalExpiry += 1;
        _authorize(payerKey, second);
        vm.warp(terms.windowsClose);

        JudgedCapture.Decision memory d = _decision(second, TASK, true, 9_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongPayment.selector);
        judged.capture(p, terms, d, sig);
        judged.capture(second, terms, d, sig);
        assertEq(_held(p), AMOUNT, "the first payment is untouched");
    }

    function test_aDecisionForAnotherTasksPaymentDoesNotCapture() public {
        _authorized();
        JudgedCapture.Terms memory otherTerms = _terms(OTHER_TASK);
        IAuthCaptureEscrow.PaymentInfo memory other = _payment(payer, 5e6, otherTerms);
        _authorize(payerKey, other);
        vm.warp(terms.windowsClose);

        // Even a brain that pairs this task with the other task's payment cannot move it.
        JudgedCapture.Decision memory d = _decision(other, TASK, true, 9_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTerms.selector);
        judged.capture(other, terms, d, sig);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.capture(other, otherTerms, d, sig);
        assertEq(_held(other), 5e6);
    }

    function test_captureNeedsTheBrainKey() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(payerKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, terms, d, sig);
    }

    function test_aSignatureForAnotherDeploymentDoesNotCapture() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        JudgedCapture twin = new JudgedCapture(ESCROW, token, owner, brain, CAP);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(brainKey, twin.digestOf(d));
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, terms, d, abi.encodePacked(r, s, v));
    }

    function test_aChangedDecisionDoesNotVerify() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        bytes memory sig = _sign(brainKey, d);
        d.confidenceBps = 9_000;
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, terms, d, sig);
    }

    function test_aPaymentCapturesOnce() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        judged.capture(p, terms, d, sig);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        judged.capture(p, terms, d, sig);
    }

    function test_captureWithNoFeePaysThePayeeInFull() public {
        p.minFeeBps = 0;
        p.maxFeeBps = 0;
        p.feeReceiver = address(0);
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, terms, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_captureTakesTheFeeFloorOfARange() public {
        p.minFeeBps = 100;
        p.maxFeeBps = 1_000;
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, terms, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(feeRecipient), uint256(AMOUNT) / 100);
        assertEq(usdc.balanceOf(payee), AMOUNT - uint256(AMOUNT) / 100);
    }

    // Void

    function test_aRefusalReturnsTheFullAmountAtOnce() public {
        _authorized();
        JudgedCapture.Decision memory d = _refuse();
        vm.expectEmit(address(judged));
        emit JudgedCapture.Voided(ESCROW.getHash(p), TASK, DECISION_ID, decisionLog);
        vm.prank(stranger);
        judged.void(p, terms, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
        assertEq(usdc.balanceOf(payee), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(_held(p), 0);
    }

    function test_anAcceptanceBelowTheBarVoids() public {
        _authorized();
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        judged.void(p, terms, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    function test_anAcceptanceAtTheBarDoesNotVoid() public {
        _authorized();
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.Accepted.selector);
        judged.void(p, terms, d, sig);
    }

    function test_aRefusalDuringTheWindowsBeatsAnEarlierAcceptance() public {
        _authorized();
        JudgedCapture.Decision memory accepted = _accept();
        bytes memory acceptance = _sign(brainKey, accepted);
        JudgedCapture.Decision memory refused = _refuse();
        judged.void(p, terms, refused, _sign(brainKey, refused));
        vm.warp(terms.windowsClose);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        judged.capture(p, terms, accepted, acceptance);
    }

    function test_voidAfterCaptureFindsNothingHeld() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory accepted = _accept();
        judged.capture(p, terms, accepted, _sign(brainKey, accepted));
        JudgedCapture.Decision memory refused = _refuse();
        bytes memory sig = _sign(brainKey, refused);
        vm.expectPartialRevert(bytes4(keccak256("ZeroAuthorization(bytes32)")));
        judged.void(p, terms, refused, sig);
    }

    function test_voidStillWorksAfterTheDeadline() public {
        _authorized();
        vm.warp(p.authorizationExpiry + 1 days);
        JudgedCapture.Decision memory d = _refuse();
        judged.void(p, terms, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    function test_voidChecksTheTermsTaskPaymentAndKey() public {
        _authorized();
        JudgedCapture.Decision memory d = _refuse();
        bytes memory sig = _sign(brainKey, d);

        JudgedCapture.Terms memory wrong = terms;
        wrong.barBps = 10_000;
        vm.expectRevert(JudgedCapture.WrongTerms.selector);
        judged.void(p, wrong, d, sig);

        JudgedCapture.Decision memory otherTask = _decision(p, OTHER_TASK, false, 9_000);
        sig = _sign(brainKey, otherTask);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.void(p, terms, otherTask, sig);

        JudgedCapture.Decision memory otherPayment = _refuse();
        otherPayment.paymentInfoHash = keccak256("another payment");
        sig = _sign(brainKey, otherPayment);
        vm.expectRevert(JudgedCapture.WrongPayment.selector);
        judged.void(p, terms, otherPayment, sig);

        sig = _sign(payerKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, terms, d, sig);
    }

    function testFuzz_aDecisionCapturesOrVoidsByTheBar(bool accepted, uint16 confidence, uint16 bar) public {
        confidence = uint16(bound(confidence, 0, 10_000));
        bar = uint16(bound(bar, 0, 10_000));
        terms.barBps = bar;
        p = _payment(payer, AMOUNT, terms);
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, accepted, confidence);
        bytes memory sig = _sign(brainKey, d);

        if (accepted && confidence >= bar) {
            vm.expectRevert(JudgedCapture.Accepted.selector);
            judged.void(p, terms, d, sig);
            judged.capture(p, terms, d, sig);
            assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        } else {
            vm.expectRevert(JudgedCapture.NotAccepted.selector);
            judged.capture(p, terms, d, sig);
            judged.void(p, terms, d, sig);
            assertEq(usdc.balanceOf(payer), 1_000e6);
        }
        assertEq(_held(p), 0);
    }

    // Reclaim

    function test_thePayerReclaimsAfterTheDeadlineWithoutTheOperator() public {
        _authorized();
        vm.prank(payer);
        vm.expectPartialRevert(bytes4(keccak256("BeforeAuthorizationExpiry(uint48,uint48)")));
        ESCROW.reclaim(p);

        vm.warp(p.authorizationExpiry);
        vm.prank(payer);
        ESCROW.reclaim(p);
        assertEq(usdc.balanceOf(payer), 1_000e6);

        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        judged.capture(p, terms, d, sig);
    }

    function test_theOwnerCannotStopAReclaim() public {
        _authorized();
        vm.prank(owner);
        judged.revokeBrain();
        vm.warp(p.authorizationExpiry);
        vm.prank(payer);
        ESCROW.reclaim(p);
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    // Brain key

    function test_aNewBrainKeyTakesEffectAfterTheDelay() public {
        uint256 nextKey = uint256(keccak256("next brain key"));
        address next = vm.addr(nextKey);
        vm.expectEmit(address(judged));
        emit JudgedCapture.ChangeQueued(JudgedCapture.Setting.Brain, uint160(next), uint64(block.timestamp + 2 days));
        vm.prank(owner);
        judged.queueBrain(next);

        vm.warp(block.timestamp + 2 days - 1);
        vm.expectRevert(JudgedCapture.TooEarly.selector);
        judged.execute(JudgedCapture.Setting.Brain);

        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(judged));
        emit JudgedCapture.BrainSet(next);
        vm.prank(stranger);
        judged.execute(JudgedCapture.Setting.Brain);
        assertEq(judged.brain(), next);
        (, uint64 readyAt) = judged.pending(JudgedCapture.Setting.Brain);
        assertEq(readyAt, 0);

        terms = _terms(TASK);
        p = _payment(payer, AMOUNT, terms);
        _authorized();
        JudgedCapture.Decision memory d = _refuse();
        bytes memory old = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, terms, d, old);
        judged.void(p, terms, d, _sign(nextKey, d));
    }

    function test_onlyTheOwnerQueuesAndCancels() public {
        vm.startPrank(stranger);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.queueBrain(stranger);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.queueCap(1);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.cancel(JudgedCapture.Setting.Brain);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.revokeBrain();
        vm.stopPrank();
    }

    function test_queueBrainRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        judged.queueBrain(address(0));
    }

    function test_executeNeedsAQueuedChange() public {
        vm.expectRevert(JudgedCapture.NothingQueued.selector);
        judged.execute(JudgedCapture.Setting.Brain);
        vm.expectRevert(JudgedCapture.NothingQueued.selector);
        judged.execute(JudgedCapture.Setting.Cap);
    }

    function test_aCancelledChangeNeverTakesEffect() public {
        vm.startPrank(owner);
        judged.queueBrain(stranger);
        vm.expectEmit(address(judged));
        emit JudgedCapture.ChangeCancelled(JudgedCapture.Setting.Brain);
        judged.cancel(JudgedCapture.Setting.Brain);
        vm.expectRevert(JudgedCapture.NothingQueued.selector);
        judged.cancel(JudgedCapture.Setting.Brain);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(JudgedCapture.NothingQueued.selector);
        judged.execute(JudgedCapture.Setting.Brain);
        assertEq(judged.brain(), brain);
    }

    function test_requeueingRestartsTheDelay() public {
        vm.prank(owner);
        judged.queueBrain(stranger);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        judged.queueBrain(payee);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(JudgedCapture.TooEarly.selector);
        judged.execute(JudgedCapture.Setting.Brain);
        vm.warp(block.timestamp + 1 days);
        judged.execute(JudgedCapture.Setting.Brain);
        assertEq(judged.brain(), payee);
    }

    function test_revokingTheBrainStopsCaptureAndVoidAtOnce() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory accepted = _accept();
        JudgedCapture.Decision memory refused = _refuse();
        bytes memory acceptance = _sign(brainKey, accepted);
        bytes memory refusal = _sign(brainKey, refused);

        vm.expectEmit(address(judged));
        emit JudgedCapture.BrainSet(address(0));
        vm.prank(owner);
        judged.revokeBrain();
        assertEq(judged.brain(), address(0));
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, terms, accepted, acceptance);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, terms, refused, refusal);
    }

    // Cap

    function test_aNewCapTakesEffectAfterTheDelayForNewPaymentsOnly() public {
        _authorized();
        vm.prank(owner);
        judged.queueCap(5e6);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(judged));
        emit JudgedCapture.CapSet(5e6);
        judged.execute(JudgedCapture.Setting.Cap);
        assertEq(judged.cap(), 5e6);

        JudgedCapture.Terms memory next = _terms(OTHER_TASK);
        IAuthCaptureEscrow.PaymentInfo memory big = _payment(payer, AMOUNT, next);
        bytes memory sig = _authorization(payerKey, big);
        vm.expectRevert(JudgedCapture.OverCap.selector);
        judged.authorize(big, AMOUNT, ERC3009_COLLECTOR, sig);

        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, terms, d, _sign(brainKey, d));
        assertEq(_held(p), 0, "a payment held before the change still settles");
    }

    function test_theCapCannotRiseBeforeTheDelay() public {
        vm.prank(owner);
        judged.queueCap(1_000e6);
        vm.expectRevert(JudgedCapture.TooEarly.selector);
        judged.execute(JudgedCapture.Setting.Cap);
        assertEq(judged.cap(), CAP);
    }

    // Ownership

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(stranger);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.transferOwnership(stranger);
        vm.prank(owner);
        vm.expectRevert(JudgedCapture.ZeroAddress.selector);
        judged.transferOwnership(address(0));

        address next = makeAddr("next-safe");
        vm.prank(owner);
        judged.transferOwnership(next);
        assertEq(judged.pendingOwner(), next);
        vm.prank(stranger);
        vm.expectRevert(JudgedCapture.NotPendingOwner.selector);
        judged.acceptOwnership();

        vm.prank(next);
        judged.acceptOwnership();
        assertEq(judged.owner(), next);
        assertEq(judged.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.queueCap(1);
        vm.prank(next);
        judged.queueCap(1);
    }

    function test_theContractHoldsNothing() public {
        _authorized();
        assertEq(IERC20(token).balanceOf(address(judged)), 0);
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, terms, d, _sign(brainKey, d));
        assertEq(IERC20(token).balanceOf(address(judged)), 0);
    }
}
