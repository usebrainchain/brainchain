// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @notice The calls JudgedCapture makes on the commerce-payments AuthCaptureEscrow (v1.1).
interface IAuthCaptureEscrow {
    struct PaymentInfo {
        address operator;
        address payer;
        address receiver;
        address token;
        uint120 maxAmount;
        uint48 preApprovalExpiry;
        uint48 authorizationExpiry;
        uint48 refundExpiry;
        uint16 minFeeBps;
        uint16 maxFeeBps;
        address feeReceiver;
        uint256 salt;
    }

    function authorize(
        PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external;

    function capture(PaymentInfo calldata paymentInfo, uint256 amount, uint256 feeAmount, address feeReceiver) external;

    function void(PaymentInfo calldata paymentInfo) external;

    function getHash(PaymentInfo calldata paymentInfo) external view returns (bytes32);

    function paymentState(bytes32 paymentInfoHash)
        external
        view
        returns (bool hasCollectedPayment, uint120 capturableAmount, uint120 refundableAmount);
}

/// @notice The x402 auth-capture operator (`operatorType: "custom"`) for work
/// BrainChain judges. A payment held in the escrow leaves it one of three ways:
/// to the payee, on the final decision about it, signed by the brain key, that
/// accepts the work at or above the payer's bar, once the dispute and appeal
/// windows have closed; back to the payer, on a final decision that does not,
/// at once; or back to the payer through the escrow's `reclaim` after the
/// capture deadline, which this contract cannot block.
///
/// The payer's terms are the payment's salt, so its own signature fixes them:
/// `saltOf(terms)` packs the task, the acceptance bar and the time the windows
/// close, and `authorize` refuses terms under which the payment could never
/// be captured. A decision names the task and the exact payment.
///
/// Each payment is decided by the brain key in force when it was authorized.
/// The owner (a Safe) names the key for later payments with `DELAY` of notice,
/// and can revoke any key at once, which stops the payments bound to it until
/// their payers reclaim.
contract JudgedCapture is EIP712 {
    /// @notice What the payer signs, packed into `PaymentInfo.salt`.
    struct Terms {
        /// The task the payment is for, as the seller named it.
        bytes24 task;
        /// The lowest confidence, in basis points, at which an acceptance captures.
        uint16 barBps;
        /// When the dispute and appeal windows close; nothing captures before.
        uint48 windowsClose;
    }

    /// @notice What the brain key signs about one payment.
    struct Decision {
        bytes24 task;
        /// `escrow.getHash(paymentInfo)`.
        bytes32 paymentInfoHash;
        bool accepted;
        /// Signed once per payment, after the last appeal window on BrainChain
        /// has closed. Nothing else can capture or void.
        bool isFinal;
        uint16 confidenceBps;
        /// The decision's id in the BrainChain DecisionLog at `decisionLog`.
        uint256 decisionId;
        address decisionLog;
    }

    enum Setting {
        Brain,
        Cap
    }

    struct Change {
        uint256 value;
        uint64 readyAt;
    }

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error WrongOperator();
    error WrongToken();
    error PartialHold();
    error OverCap();
    error NoFeeReceiver();
    error NoBrain();
    error NoTask();
    error BadBar();
    error DeadlineTooSoon();
    error NoCharge();
    error NotFinal();
    error BadConfidence();
    error WrongTask();
    error WrongPayment();
    error NotBrain();
    error NotAccepted();
    error Accepted();
    error WindowsOpen();
    error NothingQueued();
    error TooEarly();

    event Captured(
        bytes32 indexed paymentInfoHash,
        bytes24 indexed task,
        uint256 indexed decisionId,
        address decisionLog,
        uint256 amount,
        uint256 fee
    );
    event Voided(
        bytes32 indexed paymentInfoHash, bytes24 indexed task, uint256 indexed decisionId, address decisionLog
    );
    event ChangeQueued(Setting indexed setting, uint256 value, uint64 readyAt);
    event ChangeCancelled(Setting indexed setting);
    event BrainSet(address indexed brain);
    event BrainRevoked(address indexed brain);
    event CapSet(uint256 cap);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    bytes32 public constant DECISION_TYPEHASH = keccak256(
        "Decision(bytes24 task,bytes32 paymentInfoHash,bool accepted,bool isFinal,uint16 confidenceBps,uint256 decisionId,address decisionLog)"
    );
    /// @notice Notice the owner gives before a new brain key or cap takes effect.
    uint256 public constant DELAY = 2 days;
    /// @notice The least time a payment leaves between `windowsClose` and its
    /// capture deadline: room for the brain to sign the final decision and land
    /// the capture through a restart or a congested block, so accepted work
    /// does not lapse to a reclaim. A day covers that and adds at most a day to
    /// a payer's wait for a reclaim.
    uint256 public constant CAPTURE_MARGIN = 1 days;

    IAuthCaptureEscrow public immutable escrow;
    /// @notice The only token accepted; `cap` is in its units.
    address public immutable token;

    address public owner;
    address public pendingOwner;
    /// @notice The key that decides payments authorized from now on. Zero after it is revoked.
    address public brain;
    /// @notice The largest payment `authorize` accepts.
    uint256 public cap;
    mapping(Setting => Change) public pending;
    /// @notice The key that decides each payment, fixed when it was authorized.
    mapping(bytes32 paymentInfoHash => address) public brainOf;
    mapping(address => bool) public revoked;

    constructor(IAuthCaptureEscrow escrow_, address token_, address owner_, address brain_, uint256 cap_)
        EIP712("JudgedCapture", "1")
    {
        if (address(escrow_) == address(0) || token_ == address(0) || owner_ == address(0) || brain_ == address(0)) {
            revert ZeroAddress();
        }
        escrow = escrow_;
        token = token_;
        owner = owner_;
        cap = cap_;
        emit OwnerSet(owner_);
        emit CapSet(cap_);
        _nameBrain(brain_);
    }

    /// @notice Collects the payer's signed authorization into the escrow, in
    /// full, and binds the payment to the current brain key. Anyone may submit
    /// it. This is the collect call an x402 facilitator relays.
    function authorize(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external {
        check(paymentInfo, amount);
        brainOf[escrow.getHash(paymentInfo)] = brain;
        escrow.authorize(paymentInfo, amount, tokenCollector, collectorData);
    }

    /// @notice A judged payment is held until it is decided, so there is no
    /// charge. The scheme has `custom` operators expose the selector; this one
    /// refuses it.
    function charge(IAuthCaptureEscrow.PaymentInfo calldata, uint256, address, bytes calldata, uint256, address)
        external
        pure
    {
        revert NoCharge();
    }

    /// @notice Pays the held amount to the payee, less the fee at the payer's
    /// floor (`minFeeBps`) to the payer's `feeReceiver`. Needs a final
    /// acceptance at or above the bar, after the windows close and before the
    /// capture deadline. Anyone may submit it.
    function capture(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Decision calldata decision,
        bytes calldata signature
    ) external {
        (bytes32 hash, Terms memory terms) = _check(paymentInfo, decision, signature);
        if (!_clears(terms, decision)) revert NotAccepted();
        if (block.timestamp < terms.windowsClose) revert WindowsOpen();

        (, uint120 held,) = escrow.paymentState(hash);
        uint256 fee = uint256(held) * paymentInfo.minFeeBps / 10_000;
        escrow.capture(paymentInfo, held, fee, paymentInfo.feeReceiver);
        emit Captured(hash, terms.task, decision.decisionId, decision.decisionLog, held, fee);
    }

    /// @notice Returns the whole held amount to the payer on a final decision
    /// that does not clear the bar: a refusal, or an acceptance below it. No
    /// wait. Anyone may submit it.
    function void(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Decision calldata decision,
        bytes calldata signature
    ) external {
        (bytes32 hash, Terms memory terms) = _check(paymentInfo, decision, signature);
        if (_clears(terms, decision)) revert Accepted();

        escrow.void(paymentInfo);
        emit Voided(hash, terms.task, decision.decisionId, decision.decisionLog);
    }

    /// @notice Reverts unless `authorize` would accept this payment: the rules
    /// here, before the escrow's own. A seller calls it before settling, with
    /// the payment the payer signed and the amount it will submit.
    function check(IAuthCaptureEscrow.PaymentInfo calldata paymentInfo, uint256 amount)
        public
        view
        returns (Terms memory terms)
    {
        if (paymentInfo.operator != address(this)) revert WrongOperator();
        if (paymentInfo.token != token) revert WrongToken();
        // A smaller hold would spend the payer's single-use authorization on less than it signed for.
        if (amount != paymentInfo.maxAmount) revert PartialHold();
        if (amount > cap) revert OverCap();
        // Capture always takes the payer's fee floor, which needs somewhere to go.
        if (paymentInfo.minFeeBps != 0 && paymentInfo.feeReceiver == address(0)) revert NoFeeReceiver();
        if (brain == address(0) || revoked[brain]) revert NoBrain();

        terms = termsOf(paymentInfo.salt);
        if (terms.task == 0) revert NoTask();
        if (terms.barBps > 10_000) revert BadBar();
        if (uint256(terms.windowsClose) + CAPTURE_MARGIN > paymentInfo.authorizationExpiry) revert DeadlineTooSoon();
    }

    /// @notice The salt a payer signs: the task in the high 24 bytes, then the
    /// bar, then the windows' close in the low 6 bytes.
    function saltOf(Terms memory terms) public pure returns (uint256) {
        return uint256(bytes32(terms.task)) | (uint256(terms.barBps) << 48) | terms.windowsClose;
    }

    function termsOf(uint256 salt) public pure returns (Terms memory) {
        return Terms(bytes24(bytes32(salt)), uint16(salt >> 48), uint48(salt));
    }

    /// @notice The EIP-712 digest the brain key signs for `decision`.
    function digestOf(Decision calldata decision) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(DECISION_TYPEHASH, decision)));
    }

    function queueBrain(address next) external {
        if (next == address(0)) revert ZeroAddress();
        _queue(Setting.Brain, uint160(next));
    }

    function queueCap(uint256 next) external {
        _queue(Setting.Cap, next);
    }

    function cancel(Setting setting) external {
        if (msg.sender != owner) revert NotOwner();
        if (pending[setting].readyAt == 0) revert NothingQueued();
        delete pending[setting];
        emit ChangeCancelled(setting);
    }

    /// @notice Applies a queued change once its notice has run. Anyone may call
    /// it. A new key decides only payments authorized after it.
    function execute(Setting setting) external {
        Change memory change = pending[setting];
        if (change.readyAt == 0) revert NothingQueued();
        if (block.timestamp < change.readyAt) revert TooEarly();
        delete pending[setting];
        if (setting == Setting.Brain) {
            _nameBrain(address(uint160(change.value)));
        } else {
            cap = change.value;
            emit CapSet(change.value);
        }
    }

    /// @notice Stops a key at once, for good: the payments bound to it can no
    /// longer be captured or voided, and their payers reclaim at the deadline.
    /// Revoking the current key also stops new payments until a key is named.
    function revokeBrain(address key) external {
        if (msg.sender != owner) revert NotOwner();
        revoked[key] = true;
        emit BrainRevoked(key);
        if (key == brain) {
            brain = address(0);
            emit BrainSet(address(0));
        }
    }

    function transferOwnership(address pendingOwner_) external {
        if (msg.sender != owner) revert NotOwner();
        if (pendingOwner_ == address(0)) revert ZeroAddress();
        pendingOwner = pendingOwner_;
        emit OwnershipTransferStarted(owner, pendingOwner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @dev Ties a final decision to this payment's terms and to the key bound to it.
    function _check(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Decision calldata decision,
        bytes calldata signature
    ) private view returns (bytes32 hash, Terms memory terms) {
        if (!decision.isFinal) revert NotFinal();
        if (decision.confidenceBps > 10_000) revert BadConfidence();
        terms = termsOf(paymentInfo.salt);
        if (decision.task != terms.task) revert WrongTask();
        hash = escrow.getHash(paymentInfo);
        if (decision.paymentInfoHash != hash) revert WrongPayment();
        address signer = ECDSA.recover(digestOf(decision), signature);
        if (signer != brainOf[hash] || revoked[signer]) revert NotBrain();
    }

    function _clears(Terms memory terms, Decision calldata decision) private pure returns (bool) {
        return decision.accepted && decision.confidenceBps >= terms.barBps;
    }

    function _queue(Setting setting, uint256 value) private {
        if (msg.sender != owner) revert NotOwner();
        uint64 readyAt = uint64(block.timestamp + DELAY);
        pending[setting] = Change(value, readyAt);
        emit ChangeQueued(setting, value, readyAt);
    }

    /// @dev The one place a brain key is named. An Automata DCAP verifier is
    /// deployed on Base, so a later version can add the path DecisionLog has:
    /// verify an enclave's TDX quote against allowed measurements and call this
    /// with the key in its report data, in place of a queued change.
    function _nameBrain(address brain_) private {
        brain = brain_;
        emit BrainSet(brain_);
    }
}
