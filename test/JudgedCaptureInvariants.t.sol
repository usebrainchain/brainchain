// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAuthCaptureEscrow, JudgedCapture} from "../src/escrow/JudgedCapture.sol";
import {JudgedCaptureBase, JudgedCaptureSetup} from "./JudgedCapture.t.sol";
import {MockERC3009} from "./MockERC3009.sol";

contract JudgedCaptureHandler is JudgedCaptureBase {
    struct Held {
        IAuthCaptureEscrow.PaymentInfo info;
        JudgedCapture.Terms terms;
        uint256 capAtAuthorization;
    }

    MockERC3009 internal immutable usdc;
    uint256[3] internal payerKeys;
    address[2] internal payees;
    uint256 internal currentBrainKey;
    uint256[] internal formerBrainKeys;

    Held[] internal payments;
    mapping(address => uint256) public expected;
    uint256 public heldSum;

    uint256 public capturedWithoutClearing;
    uint256 public capturedBeforeWindows;
    uint256 public voidedOnClearing;
    uint256 public movedWithoutTheBrain;
    uint256 public movedAcrossPayments;
    uint256 public authorizedOverCap;

    constructor(JudgedCapture judged_, MockERC3009 usdc_, address owner_, uint256 brainKey_) {
        judged = judged_;
        usdc = usdc_;
        token = address(usdc_);
        owner = owner_;
        currentBrainKey = brainKey_;
        payerKeys = [uint256(keccak256("payer 0")), uint256(keccak256("payer 1")), uint256(keccak256("payer 2"))];
        payees = [makeAddr("payee 0"), makeAddr("payee 1")];
    }

    function authorize(
        uint256 payerSeed,
        uint256 payeeSeed,
        uint8 taskSeed,
        uint256 amount,
        uint16 bar,
        uint32 windows,
        uint32 margin,
        uint16 feeBps
    ) external {
        uint256 key = payerKeys[payerSeed % 3];
        address from = vm.addr(key);
        // A fifth of the range is above the starting cap.
        amount = bound(amount, 1, CAP + CAP / 4);
        JudgedCapture.Terms memory terms = JudgedCapture.Terms({
            task: keccak256(abi.encode("task", taskSeed % 4)),
            barBps: uint16(bound(bar, 0, 10_000)),
            windowsClose: uint48(block.timestamp + bound(windows, 0, 3 days))
        });
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(from, uint120(amount), terms);
        p.receiver = payees[payeeSeed % 2];
        p.authorizationExpiry = terms.windowsClose + uint48(bound(margin, 1 hours, 3 days));
        p.refundExpiry = p.authorizationExpiry;
        p.minFeeBps = uint16(bound(feeBps, 0, 1_000));
        p.maxFeeBps = p.minFeeBps;
        if (p.minFeeBps == 0 && feeBps % 2 == 0) p.feeReceiver = address(0);

        usdc.mint(from, amount);
        expected[from] += amount;
        bytes memory sig = _authorization(key, p);
        uint256 capNow = judged.cap();
        vm.prank(stranger);
        try judged.authorize(p, amount, ERC3009_COLLECTOR, sig) {
            if (amount > capNow) authorizedOverCap++;
            expected[from] -= amount;
            heldSum += amount;
            payments.push(Held(p, terms, capNow));
        } catch {}
    }

    function decide(uint256 index, bool accepted, uint16 confidence, bool capture, bool waitForWindows) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        if (waitForWindows && block.timestamp < h.terms.windowsClose) vm.warp(h.terms.windowsClose);
        _apply(
            h,
            h.terms,
            _decision(h.info, h.terms.task, accepted, uint16(bound(confidence, 0, 10_000))),
            currentBrainKey,
            capture
        );
    }

    /// A brain-signed decision about one payment, tried on another.
    function decideAcross(uint256 from, uint256 to, bool useTheirTerms, bool capture) external {
        if (payments.length == 0) return;
        Held memory a = payments[from % payments.length];
        Held memory b = payments[to % payments.length];
        JudgedCapture.Decision memory d = _decision(a.info, a.terms.task, true, 10_000);
        _apply(b, useTheirTerms ? a.terms : b.terms, d, currentBrainKey, capture);
    }

    /// A brain that pairs one payment's task with another payment.
    function decideMismatched(uint256 from, uint256 to, bool capture) external {
        if (payments.length == 0) return;
        Held memory a = payments[from % payments.length];
        Held memory b = payments[to % payments.length];
        _apply(b, b.terms, _decision(b.info, a.terms.task, true, 10_000), currentBrainKey, capture);
    }

    function decideWithLooserTerms(uint256 index, uint16 bar, uint48 windowsClose) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        JudgedCapture.Terms memory looser = JudgedCapture.Terms({
            task: h.terms.task, barBps: uint16(bound(bar, 0, 10_000)), windowsClose: windowsClose
        });
        _apply(h, looser, _decision(h.info, h.terms.task, true, looser.barBps), currentBrainKey, true);
    }

    function decideWithAnotherKey(uint256 index, uint256 keySeed, bool capture) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        uint256 key = formerBrainKeys.length > 0 && keySeed % 2 == 0
            ? formerBrainKeys[keySeed % formerBrainKeys.length]
            : payerKeys[keySeed % 3];
        _apply(h, h.terms, _decision(h.info, h.terms.task, capture, 10_000), key, capture);
    }

    function reclaim(uint256 index) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        uint256 held = _held(h.info);
        vm.prank(h.info.payer);
        try ESCROW.reclaim(h.info) {
            expected[h.info.payer] += held;
            heldSum -= held;
        } catch {}
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 1 days));
    }

    /// The owner names a new brain key or a new cap, and the delay runs out.
    function changeSetting(bool brainKey_, uint256 seed) external {
        vm.startPrank(owner);
        if (brainKey_) {
            uint256 next = uint256(keccak256(abi.encode("brain", seed))) % type(uint128).max + 1;
            judged.queueBrain(vm.addr(next));
            formerBrainKeys.push(currentBrainKey);
            currentBrainKey = next;
        } else {
            judged.queueCap(bound(seed, 0, 2 * CAP));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + judged.DELAY());
        judged.execute(brainKey_ ? JudgedCapture.Setting.Brain : JudgedCapture.Setting.Cap);
    }

    function paymentCount() external view returns (uint256) {
        return payments.length;
    }

    function payment(uint256 i) external view returns (IAuthCaptureEscrow.PaymentInfo memory, uint256) {
        return (payments[i].info, payments[i].capAtAuthorization);
    }

    function actors() external view returns (address[] memory list) {
        list = new address[](7);
        for (uint256 i; i < 3; ++i) {
            list[i] = vm.addr(payerKeys[i]);
        }
        list[3] = payees[0];
        list[4] = payees[1];
        list[5] = feeRecipient;
        list[6] = stranger;
    }

    function _apply(
        Held memory target,
        JudgedCapture.Terms memory termsUsed,
        JudgedCapture.Decision memory d,
        uint256 key,
        bool capture
    ) internal {
        IAuthCaptureEscrow.PaymentInfo memory p = target.info;
        bytes memory sig = _sign(key, d);
        uint256 held = _held(p);
        bool clears = d.accepted && d.confidenceBps >= target.terms.barBps;
        bool sameTarget = d.task == target.terms.task && d.paymentInfoHash == ESCROW.getHash(p);
        bool byBrain = vm.addr(key) == judged.brain();

        vm.prank(stranger);
        if (capture) {
            try judged.capture(p, termsUsed, d, sig) {
                if (!clears) capturedWithoutClearing++;
                if (block.timestamp < target.terms.windowsClose) capturedBeforeWindows++;
                if (!sameTarget) movedAcrossPayments++;
                if (!byBrain) movedWithoutTheBrain++;
                uint256 fee = held * p.minFeeBps / 10_000;
                expected[p.receiver] += held - fee;
                expected[p.feeReceiver] += fee;
                heldSum -= held;
            } catch {}
        } else {
            try judged.void(p, termsUsed, d, sig) {
                if (clears) voidedOnClearing++;
                if (!sameTarget) movedAcrossPayments++;
                if (!byBrain) movedWithoutTheBrain++;
                expected[p.payer] += held;
                heldSum -= held;
            } catch {}
        }
    }
}

contract JudgedCaptureInvariants is JudgedCaptureSetup {
    JudgedCaptureHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new JudgedCaptureHandler(judged, usdc, owner, brainKey);
        targetContract(address(handler));
    }

    /// Funds leave the escrow only to the payee on an acceptance at or above the bar, or back to the payer.
    function invariant_fundsMoveOnlyByTheRules() public view {
        assertEq(handler.capturedWithoutClearing(), 0, "captured without an acceptance at the bar");
        assertEq(handler.capturedBeforeWindows(), 0, "captured inside the windows");
        assertEq(handler.voidedOnClearing(), 0, "voided an acceptance at the bar");
        assertEq(handler.movedWithoutTheBrain(), 0, "moved on a signature that is not the brain's");

        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; ++i) {
            assertEq(usdc.balanceOf(actors[i]), handler.expected(actors[i]), "an actor's balance moved off the rules");
        }
        assertEq(usdc.balanceOf(ESCROW.getTokenStore(address(judged))), handler.heldSum(), "store holds what is held");
        assertEq(usdc.balanceOf(address(judged)), 0);
        assertEq(usdc.balanceOf(ERC3009_COLLECTOR), 0);
    }

    function invariant_aDecisionNeverMovesAnotherPayment() public view {
        assertEq(handler.movedAcrossPayments(), 0);
    }

    function invariant_theCapHolds() public view {
        assertEq(handler.authorizedOverCap(), 0);
        uint256 capturable;
        for (uint256 i; i < handler.paymentCount(); ++i) {
            (IAuthCaptureEscrow.PaymentInfo memory p, uint256 capAtAuthorization) = handler.payment(i);
            assertLe(p.maxAmount, capAtAuthorization, "a payment above the cap in force");
            capturable += _held(p);
        }
        assertEq(capturable, handler.heldSum(), "the escrow's own balances agree");
    }
}
