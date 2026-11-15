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
        uint256 brainKey;
    }

    MockERC3009 internal immutable usdc;
    uint256[3] internal payerKeys;
    address[2] internal payees;
    uint256 internal currentBrainKey;
    uint256[] internal formerBrainKeys;
    mapping(address => bool) internal revokedKey;

    Held[] internal payments;
    mapping(address => uint256) public expected;
    uint256 public heldSum;

    uint256 public capturedWithoutClearing;
    uint256 public capturedBeforeWindows;
    uint256 public voidedOnClearing;
    uint256 public movedOnAnUnfitDecision;
    uint256 public movedWithoutTheBoundKey;
    uint256 public movedAcrossPayments;
    uint256 public authorizedOverCap;
    uint256 public heldUndecidable;

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
        uint16 feeBps,
        uint256 unfitSeed
    ) external {
        uint256 key = payerKeys[payerSeed % 3];
        // A fifth of the range is above the starting cap.
        amount = bound(amount, 1, CAP + CAP / 4);
        (JudgedCapture.Terms memory terms, uint48 deadline) = _draft(taskSeed, bar, windows, margin, unfitSeed);
        IAuthCaptureEscrow.PaymentInfo memory p = _payment(vm.addr(key), uint120(amount), terms);
        p.receiver = payees[payeeSeed % 2];
        p.authorizationExpiry = deadline;
        p.refundExpiry = deadline;
        p.minFeeBps = uint16(bound(feeBps, 0, 1_000));
        p.maxFeeBps = p.minFeeBps;
        if (p.minFeeBps == 0 && feeBps % 2 == 0) p.feeReceiver = address(0);

        usdc.mint(p.payer, amount);
        expected[p.payer] += amount;
        bytes memory sig = _authorization(key, p);
        uint256 capNow = judged.cap();
        vm.prank(stranger);
        try judged.authorize(p, amount, ERC3009_COLLECTOR, sig) {
            if (amount > capNow) authorizedOverCap++;
            if (
                terms.task == 0 || terms.barBps > 10_000 || terms.windowsClose + judged.CAPTURE_MARGIN() > deadline
                    || revokedKey[vm.addr(currentBrainKey)]
            ) heldUndecidable++;
            expected[p.payer] -= amount;
            heldSum += amount;
            payments.push(Held(p, terms, capNow, currentBrainKey));
        } catch {}
    }

    function decide(
        uint256 index,
        bool accepted,
        uint16 confidence,
        bool capture,
        bool waitForWindows,
        bool preliminary
    ) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        if (waitForWindows && block.timestamp < h.terms.windowsClose) vm.warp(h.terms.windowsClose);
        JudgedCapture.Decision memory d =
            _decision(h.info, h.terms.task, accepted, uint16(bound(confidence, 0, 10_500)));
        d.isFinal = !preliminary;
        _apply(h, d, h.brainKey, capture);
    }

    /// A decision about one payment, signed by the key bound to another, tried on that other.
    function decideAcross(uint256 from, uint256 to, bool capture) external {
        if (payments.length == 0) return;
        Held memory a = payments[from % payments.length];
        Held memory b = payments[to % payments.length];
        _apply(b, _decision(a.info, a.terms.task, capture, 10_000), b.brainKey, capture);
    }

    /// A brain that pairs one payment's task with another payment.
    function decideMismatched(uint256 from, uint256 to, bool capture) external {
        if (payments.length == 0) return;
        Held memory a = payments[from % payments.length];
        Held memory b = payments[to % payments.length];
        _apply(b, _decision(b.info, a.terms.task, capture, 10_000), b.brainKey, capture);
    }

    /// The owner's current key, a former key or a payer's key, on a payment bound to another key.
    function decideWithAnotherKey(uint256 index, uint256 keySeed, bool capture) external {
        if (payments.length == 0) return;
        Held memory h = payments[index % payments.length];
        uint256 key = keySeed % 3 == 0
            ? currentBrainKey
            : formerBrainKeys.length > 0 && keySeed % 3 == 1
                ? formerBrainKeys[keySeed % formerBrainKeys.length]
                : payerKeys[keySeed % 3];
        _apply(h, _decision(h.info, h.terms.task, capture, 10_000), key, capture);
    }

    /// Rare, so most of a run has a live key: one call in sixteen revokes, half of those the current key.
    function revoke(uint256 index, uint256 seed) external {
        // Hashed, since the fuzzer favours zero and would revoke on most calls.
        uint256 roll = uint256(keccak256(abi.encode(seed)));
        if (roll % 16 != 0) return;
        bool current = roll % 32 == 0;
        if (payments.length == 0 && !current) return;
        uint256 key = current ? currentBrainKey : payments[index % payments.length].brainKey;
        vm.prank(owner);
        judged.revokeBrain(vm.addr(key));
        revokedKey[vm.addr(key)] = true;
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

    function payment(uint256 i) external view returns (IAuthCaptureEscrow.PaymentInfo memory, uint256, address) {
        return (payments[i].info, payments[i].capAtAuthorization, vm.addr(payments[i].brainKey));
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

    /// Terms and a capture deadline. One draft in eight breaks a term so that nothing
    /// could ever capture the payment: a zero task, a bar above 10,000 or too little margin.
    function _draft(uint8 taskSeed, uint16 bar, uint32 windows, uint32 margin, uint256 unfitSeed)
        internal
        view
        returns (JudgedCapture.Terms memory terms, uint48 deadline)
    {
        terms = JudgedCapture.Terms({
            task: bytes24(keccak256(abi.encode("task", taskSeed % 4))),
            barBps: uint16(bound(bar, 0, 10_000)),
            windowsClose: uint48(block.timestamp + bound(windows, 0, 3 days))
        });
        uint256 afterWindows = bound(margin, 1 days, 4 days);
        uint256 unfit = uint256(keccak256(abi.encode(unfitSeed)));
        if (unfit % 8 == 0) {
            if (unfit % 3 == 0) terms.task = 0;
            else if (unfit % 3 == 1) terms.barBps = uint16(bound(bar, 10_001, type(uint16).max));
            else afterWindows = bound(margin, 1 hours, 1 days - 1);
        }
        deadline = terms.windowsClose + uint48(afterWindows);
    }

    function _apply(Held memory target, JudgedCapture.Decision memory d, uint256 key, bool capture) internal {
        IAuthCaptureEscrow.PaymentInfo memory p = target.info;
        bytes memory sig = _sign(key, d);
        uint256 held = _held(p);
        bool clears = d.accepted && d.confidenceBps >= target.terms.barBps;
        bool fit = d.isFinal && d.confidenceBps <= 10_000;
        bool sameTarget = d.task == target.terms.task && d.paymentInfoHash == ESCROW.getHash(p);
        bool boundKey = key == target.brainKey && !revokedKey[vm.addr(key)];

        vm.prank(stranger);
        if (capture) {
            try judged.capture(p, d, sig) {
                if (!clears) capturedWithoutClearing++;
                if (block.timestamp < target.terms.windowsClose) capturedBeforeWindows++;
                if (!fit) movedOnAnUnfitDecision++;
                if (!sameTarget) movedAcrossPayments++;
                if (!boundKey) movedWithoutTheBoundKey++;
                uint256 fee = held * p.minFeeBps / 10_000;
                expected[p.receiver] += held - fee;
                expected[p.feeReceiver] += fee;
                heldSum -= held;
            } catch {}
        } else {
            try judged.void(p, d, sig) {
                if (clears) voidedOnClearing++;
                if (!fit) movedOnAnUnfitDecision++;
                if (!sameTarget) movedAcrossPayments++;
                if (!boundKey) movedWithoutTheBoundKey++;
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

    /// Funds leave the escrow only to the payee on a final acceptance at or above the bar, or back to the payer.
    function invariant_fundsMoveOnlyByTheRules() public view {
        assertEq(handler.capturedWithoutClearing(), 0, "captured without an acceptance at the bar");
        assertEq(handler.capturedBeforeWindows(), 0, "captured inside the windows");
        assertEq(handler.voidedOnClearing(), 0, "voided an acceptance at the bar");
        assertEq(handler.movedOnAnUnfitDecision(), 0, "moved on a preliminary or out-of-range decision");
        assertEq(handler.movedWithoutTheBoundKey(), 0, "moved without the key bound at authorization");

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
            (IAuthCaptureEscrow.PaymentInfo memory p, uint256 capAtAuthorization,) = handler.payment(i);
            assertLe(p.maxAmount, capAtAuthorization, "a payment above the cap in force");
            capturable += _held(p);
        }
        assertEq(capturable, handler.heldSum(), "the escrow's own balances agree");
    }

    /// Every held payment has terms it can be captured under and a live key bound to it when it was taken.
    function invariant_everyPaymentCanBeDecided() public view {
        assertEq(handler.heldUndecidable(), 0);
        for (uint256 i; i < handler.paymentCount(); ++i) {
            (IAuthCaptureEscrow.PaymentInfo memory p,, address key) = handler.payment(i);
            assertEq(judged.brainOf(ESCROW.getHash(p)), key, "bound to the key in force at authorization");
        }
    }
}
