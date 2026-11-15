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
/// to the payee, on a decision signed by the brain key that accepts the work at
/// or above the payer's bar, once the dispute and appeal windows have closed;
/// back to the payer, on any other decision, at once; or back to the payer
/// through the escrow's `reclaim` after the capture deadline, which this
/// contract cannot block.
///
/// The payer fixes its terms by signing `PaymentInfo.salt`, which must equal
/// `saltOf(terms)`: the task, the acceptance bar and the time the windows close.
/// Nobody can change them afterwards. A decision names the task and the exact
/// payment, so it applies to that payment alone.
///
/// The owner (a Safe) names the brain key with `DELAY` of notice and can revoke
/// it at once. Decisions are checked against the key in place when they are
/// applied, so a replaced key's signatures stop working.
contract JudgedCapture is EIP712 {
    /// @notice What the payer signs, through `PaymentInfo.salt`.
    struct Terms {
        /// The task the payment is for, as the seller named it in its payment requirements.
        bytes32 task;
        /// The lowest confidence, in basis points, at which an acceptance captures.
        uint16 barBps;
        /// When the dispute and appeal windows close; nothing captures before.
        uint48 windowsClose;
    }

    /// @notice What the brain key signs about one payment.
    struct Decision {
        bytes32 task;
        /// `escrow.getHash(paymentInfo)`.
        bytes32 paymentInfoHash;
        bool accepted;
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
    error WrongToken();
    error PartialHold();
    error OverCap();
    error NoFeeReceiver();
    error WrongTerms();
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
        bytes32 indexed task,
        uint256 indexed decisionId,
        address decisionLog,
        uint256 amount,
        uint256 fee
    );
    event Voided(
        bytes32 indexed paymentInfoHash, bytes32 indexed task, uint256 indexed decisionId, address decisionLog
    );
    event ChangeQueued(Setting indexed setting, uint256 value, uint64 readyAt);
    event ChangeCancelled(Setting indexed setting);
    event BrainSet(address indexed brain);
    event CapSet(uint256 cap);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    bytes32 public constant TERMS_TYPEHASH =
        keccak256("JudgedCaptureTerms(bytes32 task,uint16 barBps,uint48 windowsClose)");
    bytes32 public constant DECISION_TYPEHASH = keccak256(
        "Decision(bytes32 task,bytes32 paymentInfoHash,bool accepted,uint16 confidenceBps,uint256 decisionId,address decisionLog)"
    );
    /// @notice Notice the owner gives before a new brain key or cap takes effect.
    uint256 public constant DELAY = 2 days;

    IAuthCaptureEscrow public immutable escrow;
    /// @notice The only token accepted; `cap` is in its units.
    address public immutable token;

    address public owner;
    address public pendingOwner;
    /// @notice The key whose signature a decision needs. Zero while revoked.
    address public brain;
    /// @notice The largest payment `authorize` accepts.
    uint256 public cap;
    mapping(Setting => Change) public pending;

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
    /// full. Anyone may submit it. This is the collect call an x402 facilitator relays.
    function authorize(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        uint256 amount,
        address tokenCollector,
        bytes calldata collectorData
    ) external {
        if (paymentInfo.token != token) revert WrongToken();
        // A smaller hold would spend the payer's single-use authorization on less than it signed for.
        if (amount != paymentInfo.maxAmount) revert PartialHold();
        if (amount > cap) revert OverCap();
        // Capture always takes the payer's fee floor, which needs somewhere to go.
        if (paymentInfo.minFeeBps != 0 && paymentInfo.feeReceiver == address(0)) revert NoFeeReceiver();
        escrow.authorize(paymentInfo, amount, tokenCollector, collectorData);
    }

    /// @notice Pays the held amount to the payee, less the fee at the payer's
    /// floor (`minFeeBps`) to the payer's `feeReceiver`. Needs an acceptance at
    /// or above the bar, after the windows close and before the capture deadline.
    /// Anyone may submit it.
    function capture(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Terms calldata terms,
        Decision calldata decision,
        bytes calldata signature
    ) external {
        bytes32 hash = _check(paymentInfo, terms, decision, signature);
        if (!_clears(terms, decision)) revert NotAccepted();
        if (block.timestamp < terms.windowsClose) revert WindowsOpen();

        (, uint120 held,) = escrow.paymentState(hash);
        uint256 fee = uint256(held) * paymentInfo.minFeeBps / 10_000;
        escrow.capture(paymentInfo, held, fee, paymentInfo.feeReceiver);
        emit Captured(hash, terms.task, decision.decisionId, decision.decisionLog, held, fee);
    }

    /// @notice Returns the whole held amount to the payer on a decision that
    /// does not clear the bar: a refusal, or an acceptance below it. No wait.
    /// Anyone may submit it.
    function void(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Terms calldata terms,
        Decision calldata decision,
        bytes calldata signature
    ) external {
        bytes32 hash = _check(paymentInfo, terms, decision, signature);
        if (_clears(terms, decision)) revert Accepted();

        escrow.void(paymentInfo);
        emit Voided(hash, terms.task, decision.decisionId, decision.decisionLog);
    }

    function saltOf(Terms calldata terms) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(TERMS_TYPEHASH, terms)));
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

    /// @notice Applies a queued change once its notice has run. Anyone may call it.
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

    /// @notice Stops every capture and void until a new key is named through
    /// the delay. Held payments stay reclaimable by their payers.
    function revokeBrain() external {
        if (msg.sender != owner) revert NotOwner();
        brain = address(0);
        emit BrainSet(address(0));
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

    /// @dev Ties the decision to these terms and this payment, and to the brain key.
    function _check(
        IAuthCaptureEscrow.PaymentInfo calldata paymentInfo,
        Terms calldata terms,
        Decision calldata decision,
        bytes calldata signature
    ) private view returns (bytes32 hash) {
        if (paymentInfo.salt != saltOf(terms)) revert WrongTerms();
        if (decision.task != terms.task) revert WrongTask();
        hash = escrow.getHash(paymentInfo);
        if (decision.paymentInfoHash != hash) revert WrongPayment();
        if (ECDSA.recover(digestOf(decision), signature) != brain) revert NotBrain();
    }

    function _clears(Terms calldata terms, Decision calldata decision) private pure returns (bool) {
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
