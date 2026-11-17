// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployJudgedCapture} from "../script/DeployJudgedCapture.s.sol";
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

    function _terms(bytes24 task) internal view returns (JudgedCapture.Terms memory) {
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

    /// A final decision; tests that need a preliminary one clear `isFinal`.
    function _decision(IAuthCaptureEscrow.PaymentInfo memory p, bytes24 task, bool accepted, uint16 confidenceBps)
        internal
        view
        returns (JudgedCapture.Decision memory)
    {
        return JudgedCapture.Decision({
            task: task,
            paymentInfoHash: ESCROW.getHash(p),
            accepted: accepted,
            isFinal: true,
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
    bytes24 internal constant TASK = bytes24(keccak256("order 1"));
    bytes24 internal constant OTHER_TASK = bytes24(keccak256("order 2"));
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

    function _rejects(bytes4 error_) internal {
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(error_);
        judged.check(p, p.maxAmount);
        vm.expectRevert(error_);
        judged.authorize(p, p.maxAmount, ERC3009_COLLECTOR, sig);
    }

    function _nameBrain(uint256 key) internal {
        vm.prank(owner);
        judged.queueBrain(vm.addr(key));
        vm.warp(block.timestamp + 2 days);
        judged.execute(JudgedCapture.Setting.Brain);
    }

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
        assertEq(judged.CAPTURE_MARGIN(), 1 days);
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            judged.eip712Domain();
        assertEq(name, "JudgedCapture");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(judged));
    }

    function testFuzz_theSaltIsTheTermsAndBack(bytes24 task, uint16 bar, uint48 windowsClose) public view {
        JudgedCapture.Terms memory t = JudgedCapture.Terms(task, bar, windowsClose);
        uint256 salt = judged.saltOf(t);
        assertEq(salt, uint256(bytes32(task)) | (uint256(bar) << 48) | windowsClose);
        JudgedCapture.Terms memory back = judged.termsOf(salt);
        assertEq(back.task, task);
        assertEq(back.barBps, bar);
        assertEq(back.windowsClose, windowsClose);
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
                    "Decision(bytes24 task,bytes32 paymentInfoHash,bool accepted,bool isFinal,uint16 confidenceBps,uint256 decisionId,address decisionLog)"
                ),
                d.task,
                d.paymentInfoHash,
                d.accepted,
                d.isFinal,
                d.confidenceBps,
                d.decisionId,
                d.decisionLog
            )
        );
        assertEq(judged.digestOf(d), keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
    }

    function test_anyoneSubmitsTheAuthorizationAndTheFullAmountIsHeld() public {
        _authorized();
        assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        assertEq(usdc.balanceOf(ESCROW.getTokenStore(address(judged))), AMOUNT);
        assertEq(_held(p), AMOUNT);
        assertEq(judged.brainOf(ESCROW.getHash(p)), brain, "bound to the key in force");
    }

    function test_checkReturnsTheTermsAuthorizeWouldHold() public view {
        JudgedCapture.Terms memory t = judged.check(p, AMOUNT);
        assertEq(t.task, TASK);
        assertEq(t.barBps, BAR);
        assertEq(t.windowsClose, terms.windowsClose);
    }

    function test_authorizeRejectsAnotherOperator() public {
        p.operator = stranger;
        _rejects(JudgedCapture.WrongOperator.selector);
    }

    function test_authorizeRejectsAnotherToken() public {
        p.token = address(new MockERC3009());
        vm.expectRevert(JudgedCapture.WrongToken.selector);
        judged.check(p, AMOUNT);
        vm.expectRevert(JudgedCapture.WrongToken.selector);
        judged.authorize(p, AMOUNT, ERC3009_COLLECTOR, "");
    }

    function test_authorizeRejectsAPartialHold() public {
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.PartialHold.selector);
        judged.check(p, AMOUNT - 1);
        vm.expectRevert(JudgedCapture.PartialHold.selector);
        judged.authorize(p, AMOUNT - 1, ERC3009_COLLECTOR, sig);
    }

    function test_authorizeHoldsUpToTheCapAndNoMore() public {
        p = _payment(payer, uint120(CAP), terms);
        _authorize(payerKey, p);
        assertEq(_held(p), CAP);

        p = _payment(payer, uint120(CAP + 1), _terms(OTHER_TASK));
        _rejects(JudgedCapture.OverCap.selector);
    }

    function test_authorizeRejectsAFeeFloorWithNowhereToGo() public {
        p.feeReceiver = address(0);
        _rejects(JudgedCapture.NoFeeReceiver.selector);
    }

    function test_authorizeRejectsAZeroTask() public {
        terms.task = 0;
        p.salt = judged.saltOf(terms);
        _rejects(JudgedCapture.NoTask.selector);
    }

    function test_authorizeRejectsABarAboveCertainty() public {
        terms.barBps = 10_001;
        p.salt = judged.saltOf(terms);
        _rejects(JudgedCapture.BadBar.selector);
        terms.barBps = 10_000;
        p.salt = judged.saltOf(terms);
        judged.check(p, AMOUNT);
    }

    function test_authorizeLeavesTheMarginBeforeTheDeadline() public {
        p.authorizationExpiry = terms.windowsClose + CAPTURE_MARGIN - 1;
        p.refundExpiry = p.authorizationExpiry;
        _rejects(JudgedCapture.DeadlineTooSoon.selector);
        p.authorizationExpiry = terms.windowsClose + CAPTURE_MARGIN;
        p.refundExpiry = p.authorizationExpiry;
        _authorize(payerKey, p);
    }

    function test_authorizeRejectsARandomSalt() public {
        // An x402 client's usual random salt, unpacked, sets a bar above 10,000 bps.
        p.salt = uint256(keccak256("x402 client random bytes"));
        assertGt(judged.termsOf(p.salt).barBps, 10_000);
        _rejects(JudgedCapture.BadBar.selector);
        // With a plausible bar, its windows close far past any deadline.
        p.salt = (p.salt & ~(uint256(type(uint16).max) << 48)) | (uint256(BAR) << 48);
        _rejects(JudgedCapture.DeadlineTooSoon.selector);
    }

    function test_authorizeNeedsALiveBrainKey() public {
        vm.prank(owner);
        judged.revokeBrain(brain);
        _rejects(JudgedCapture.NoBrain.selector);
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

    function test_chargeIsExposedAndRefused() public {
        bytes memory sig = _authorization(payerKey, p);
        vm.expectRevert(JudgedCapture.NoCharge.selector);
        judged.charge(p, AMOUNT, ERC3009_COLLECTOR, sig, 0, feeRecipient);
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    function test_captureAfterTheWindowsPaysThePayeeLessTheFee() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;

        vm.expectEmit(address(judged));
        emit JudgedCapture.Captured(ESCROW.getHash(p), TASK, DECISION_ID, decisionLog, AMOUNT, fee);
        vm.prank(stranger);
        judged.capture(p, d, _sign(brainKey, d));

        assertEq(usdc.balanceOf(payee), AMOUNT - fee);
        assertEq(usdc.balanceOf(feeRecipient), fee);
        assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        assertEq(_held(p), 0);
    }

    function test_captureAtTheBarExactly() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR);
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(_held(p), 0);
    }

    function test_captureRefusesAnAcceptanceBelowTheBar() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.NotAccepted.selector);
        judged.capture(p, d, sig);
    }

    function test_captureRefusesARefusal() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _refuse();
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.NotAccepted.selector);
        judged.capture(p, d, sig);
    }

    function test_captureWaitsForTheWindows() public {
        _authorized();
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.warp(terms.windowsClose - 1);
        vm.expectRevert(JudgedCapture.WindowsOpen.selector);
        judged.capture(p, d, sig);
        vm.warp(terms.windowsClose);
        judged.capture(p, d, sig);
    }

    function test_captureEndsAtTheCaptureDeadline() public {
        _authorized();
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        vm.warp(p.authorizationExpiry);
        vm.expectPartialRevert(bytes4(keccak256("AfterAuthorizationExpiry(uint48,uint48)")));
        judged.capture(p, d, sig);
    }

    function test_aConfidenceAboveCertaintyIsRefused() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, 10_001);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.BadConfidence.selector);
        judged.capture(p, d, sig);
        d.accepted = false;
        sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.BadConfidence.selector);
        judged.void(p, d, sig);
    }

    function test_aDecisionForAnotherTaskDoesNotCapture() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, OTHER_TASK, true, 9_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.capture(p, d, sig);
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
        judged.capture(p, d, sig);
        judged.capture(second, d, sig);
        assertEq(_held(p), AMOUNT, "the first payment is untouched");
    }

    function test_aDecisionForAnotherTasksPaymentDoesNotCapture() public {
        _authorized();
        IAuthCaptureEscrow.PaymentInfo memory other = _payment(payer, 5e6, _terms(OTHER_TASK));
        _authorize(payerKey, other);
        vm.warp(terms.windowsClose);

        // Even a brain that pairs this task with the other task's payment cannot move it.
        JudgedCapture.Decision memory d = _decision(other, TASK, true, 9_000);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.capture(other, d, sig);
        assertEq(_held(other), 5e6);
    }

    function test_captureNeedsTheBrainKey() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(payerKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, d, sig);
    }

    function test_aSignatureForAnotherDeploymentDoesNotCapture() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        JudgedCapture twin = new JudgedCapture(ESCROW, token, owner, brain, CAP);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(brainKey, twin.digestOf(d));
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, d, abi.encodePacked(r, s, v));
    }

    function test_aChangedDecisionDoesNotVerify() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        bytes memory sig = _sign(brainKey, d);
        d.confidenceBps = 9_000;
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, d, sig);
    }

    function test_aPaymentCapturesOnce() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(brainKey, d);
        judged.capture(p, d, sig);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        judged.capture(p, d, sig);
    }

    function test_captureWithNoFeePaysThePayeeInFull() public {
        p.minFeeBps = 0;
        p.maxFeeBps = 0;
        p.feeReceiver = address(0);
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_captureTakesTheFeeFloorOfARange() public {
        p.minFeeBps = 100;
        p.maxFeeBps = 1_000;
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(feeRecipient), uint256(AMOUNT) / 100);
        assertEq(usdc.balanceOf(payee), AMOUNT - uint256(AMOUNT) / 100);
    }

    function test_aPreliminaryAcceptanceCannotCaptureAfterTheWindows() public {
        _authorized();
        JudgedCapture.Decision memory early = _accept();
        early.isFinal = false;
        bytes memory earlySig = _sign(brainKey, early);
        JudgedCapture.Decision memory ruling = _refuse();
        ruling.decisionId = DECISION_ID + 1;
        bytes memory rulingSig = _sign(brainKey, ruling);

        vm.warp(terms.windowsClose);
        vm.expectRevert(JudgedCapture.NotFinal.selector);
        judged.capture(p, early, earlySig);
        judged.void(p, ruling, rulingSig);
        assertEq(usdc.balanceOf(payer), 1_000e6);
        assertEq(usdc.balanceOf(payee), 0);
    }

    function test_aPreliminaryRefusalCannotVoid() public {
        _authorized();
        JudgedCapture.Decision memory grade = _refuse();
        grade.isFinal = false;
        bytes memory sig = _sign(brainKey, grade);
        vm.expectRevert(JudgedCapture.NotFinal.selector);
        judged.void(p, grade, sig);
        assertEq(_held(p), AMOUNT, "the payee can still dispute and appeal");
    }

    function test_onlyOneFinalDecisionActs() public {
        _authorized();
        JudgedCapture.Decision memory refused = _refuse();
        judged.void(p, refused, _sign(brainKey, refused));
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory accepted = _accept();
        bytes memory sig = _sign(brainKey, accepted);
        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        judged.capture(p, accepted, sig);
    }

    function test_aFinalRefusalReturnsTheFullAmountAtOnce() public {
        _authorized();
        JudgedCapture.Decision memory d = _refuse();
        vm.expectEmit(address(judged));
        emit JudgedCapture.Voided(ESCROW.getHash(p), TASK, DECISION_ID, decisionLog);
        vm.prank(stranger);
        judged.void(p, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
        assertEq(usdc.balanceOf(payee), 0);
        assertEq(usdc.balanceOf(feeRecipient), 0);
        assertEq(_held(p), 0);
    }

    function test_anAcceptanceBelowTheBarVoids() public {
        _authorized();
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR - 1);
        judged.void(p, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    function test_anAcceptanceAtTheBarDoesNotVoid() public {
        _authorized();
        JudgedCapture.Decision memory d = _decision(p, TASK, true, BAR);
        bytes memory sig = _sign(brainKey, d);
        vm.expectRevert(JudgedCapture.Accepted.selector);
        judged.void(p, d, sig);
    }

    function test_voidAfterCaptureFindsNothingHeld() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory accepted = _accept();
        judged.capture(p, accepted, _sign(brainKey, accepted));
        JudgedCapture.Decision memory refused = _refuse();
        bytes memory sig = _sign(brainKey, refused);
        vm.expectPartialRevert(bytes4(keccak256("ZeroAuthorization(bytes32)")));
        judged.void(p, refused, sig);
    }

    function test_voidStillWorksAfterTheDeadline() public {
        _authorized();
        vm.warp(p.authorizationExpiry + 1 days);
        JudgedCapture.Decision memory d = _refuse();
        judged.void(p, d, _sign(brainKey, d));
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

    function test_voidChecksTheTaskPaymentAndKey() public {
        _authorized();
        JudgedCapture.Decision memory d = _refuse();

        JudgedCapture.Decision memory otherTask = _decision(p, OTHER_TASK, false, 9_000);
        bytes memory sig = _sign(brainKey, otherTask);
        vm.expectRevert(JudgedCapture.WrongTask.selector);
        judged.void(p, otherTask, sig);

        JudgedCapture.Decision memory otherPayment = _refuse();
        otherPayment.paymentInfoHash = keccak256("another payment");
        sig = _sign(brainKey, otherPayment);
        vm.expectRevert(JudgedCapture.WrongPayment.selector);
        judged.void(p, otherPayment, sig);

        sig = _sign(payerKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, d, sig);
    }

    function testFuzz_aFinalDecisionCapturesOrVoidsByTheBar(bool accepted, uint16 confidence, uint16 bar) public {
        confidence = uint16(bound(confidence, 0, 10_000));
        terms.barBps = uint16(bound(bar, 0, 10_000));
        p = _payment(payer, AMOUNT, terms);
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _decision(p, TASK, accepted, confidence);
        bytes memory sig = _sign(brainKey, d);

        if (accepted && confidence >= terms.barBps) {
            vm.expectRevert(JudgedCapture.Accepted.selector);
            judged.void(p, d, sig);
            judged.capture(p, d, sig);
            assertEq(usdc.balanceOf(payer), 1_000e6 - AMOUNT);
        } else {
            vm.expectRevert(JudgedCapture.NotAccepted.selector);
            judged.capture(p, d, sig);
            judged.void(p, d, sig);
            assertEq(usdc.balanceOf(payer), 1_000e6);
        }
        assertEq(_held(p), 0);
    }

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
        judged.capture(p, d, sig);
    }

    function test_theOwnerCannotStopAReclaim() public {
        _authorized();
        vm.prank(owner);
        judged.revokeBrain(brain);
        vm.warp(p.authorizationExpiry);
        vm.prank(payer);
        ESCROW.reclaim(p);
        assertEq(usdc.balanceOf(payer), 1_000e6);
    }

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
        judged.void(p, d, old);
        judged.void(p, d, _sign(nextKey, d));
    }

    function test_aNewKeyCannotDecidePaymentsHeldBeforeIt() public {
        _authorized();
        uint256 colluderKey = uint256(keccak256("owner's colluding key"));
        _nameBrain(colluderKey);
        vm.warp(terms.windowsClose);

        JudgedCapture.Decision memory d = _accept();
        bytes memory sig = _sign(colluderKey, d);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, d, sig);
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(_held(p), 0, "the key bound at authorization still decides");
    }

    function test_onlyTheOwnerQueuesCancelsAndRevokes() public {
        vm.startPrank(stranger);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.queueBrain(stranger);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.queueCap(1);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.cancel(JudgedCapture.Setting.Brain);
        vm.expectRevert(JudgedCapture.NotOwner.selector);
        judged.revokeBrain(brain);
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

    function test_revokingTheCurrentKeyStopsItsPaymentsAndNewOnes() public {
        _authorized();
        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory accepted = _accept();
        JudgedCapture.Decision memory refused = _refuse();
        bytes memory acceptance = _sign(brainKey, accepted);
        bytes memory refusal = _sign(brainKey, refused);

        vm.expectEmit(address(judged));
        emit JudgedCapture.BrainRevoked(brain);
        vm.expectEmit(address(judged));
        emit JudgedCapture.BrainSet(address(0));
        vm.prank(owner);
        judged.revokeBrain(brain);
        assertEq(judged.brain(), address(0));
        assertTrue(judged.revoked(brain));
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.capture(p, accepted, acceptance);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, refused, refusal);

        uint256 nextKey = uint256(keccak256("next brain key"));
        _nameBrain(nextKey);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, refused, refusal);
        bytes memory byNextKey = _sign(nextKey, refused);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, refused, byNextKey);
    }

    function test_revokingAFormerKeyLeavesTheCurrentOne() public {
        _authorized();
        uint256 nextKey = uint256(keccak256("next brain key"));
        _nameBrain(nextKey);
        vm.prank(owner);
        judged.revokeBrain(brain);
        assertEq(judged.brain(), vm.addr(nextKey));

        JudgedCapture.Decision memory refused = _refuse();
        bytes memory refusal = _sign(brainKey, refused);
        vm.expectRevert(JudgedCapture.NotBrain.selector);
        judged.void(p, refused, refusal);

        JudgedCapture.Terms memory fresh = _terms(OTHER_TASK);
        IAuthCaptureEscrow.PaymentInfo memory later = _payment(payer, AMOUNT, fresh);
        _authorize(payerKey, later);
        JudgedCapture.Decision memory d = _decision(later, OTHER_TASK, false, 9_000);
        judged.void(later, d, _sign(nextKey, d));
    }

    function test_aNewCapTakesEffectAfterTheDelayForNewPaymentsOnly() public {
        _authorized();
        vm.prank(owner);
        judged.queueCap(5e6);
        vm.warp(block.timestamp + 2 days);
        vm.expectEmit(address(judged));
        emit JudgedCapture.CapSet(5e6);
        judged.execute(JudgedCapture.Setting.Cap);
        assertEq(judged.cap(), 5e6);

        IAuthCaptureEscrow.PaymentInfo memory big = _payment(payer, AMOUNT, _terms(OTHER_TASK));
        bytes memory sig = _authorization(payerKey, big);
        vm.expectRevert(JudgedCapture.OverCap.selector);
        judged.authorize(big, AMOUNT, ERC3009_COLLECTOR, sig);

        vm.warp(terms.windowsClose);
        JudgedCapture.Decision memory d = _accept();
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(_held(p), 0, "a payment held before the change still settles");
    }

    function test_theCapCannotRiseBeforeTheDelay() public {
        vm.prank(owner);
        judged.queueCap(1_000e6);
        vm.expectRevert(JudgedCapture.TooEarly.selector);
        judged.execute(JudgedCapture.Setting.Cap);
        assertEq(judged.cap(), CAP);
    }

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
        judged.capture(p, d, _sign(brainKey, d));
        assertEq(IERC20(token).balanceOf(address(judged)), 0);
    }
}

/// Runs the script's deployment without a broadcast, against the escrow code from Base.
contract DeployJudgedCaptureHarness is DeployJudgedCapture {
    function deploy(address owner, address brain) external returns (JudgedCapture) {
        return _deploy(owner, brain);
    }
}

contract DeployJudgedCaptureTest is JudgedCaptureSetup {
    function test_theScriptDeploysWithTheCapOfTwentyFiveUsdc() public {
        DeployJudgedCaptureHarness script = new DeployJudgedCaptureHarness();
        vm.expectRevert(bytes("OWNER has no code: it should be the Base Safe"));
        script.deploy(owner, brain);

        vm.etch(owner, hex"00");
        JudgedCapture deployed = script.deploy(owner, brain);
        assertEq(deployed.cap(), 25e6);
        assertEq(deployed.token(), 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(address(deployed.escrow()), address(ESCROW));
        assertEq(deployed.owner(), owner);
        assertEq(deployed.brain(), brain);
    }
}
