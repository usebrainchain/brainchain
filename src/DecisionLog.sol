// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Append-only record of every Jev decision the chain acts on. Only the
/// brain (the harness that calls Jev) can record. The chain does not verify
/// that a recorded answer came from Jev: the brain key is trusted to record
/// Jev's answers faithfully, and contracts that act on a decision apply their
/// own confidence thresholds to what was recorded. The owner, an admin
/// timelock, replaces the brain; the brain cannot replace itself.
contract DecisionLog {
    enum Kind {
        None,
        Hire,
        Grade,
        Ruling,
        Change
    }

    struct Decision {
        Kind kind;
        /// What the decision is about. Task decisions name the board's
        /// `subjectOf(taskId)`; a Change names the hash of the proposed call.
        bytes32 subject;
        /// Hash of the full question and inputs sent to Jev.
        bytes32 inputHash;
        /// Hire: the model id, or zero for no hire. Grade: 1 accept, 0 reject.
        /// Ruling: 1 pay the model, 0 refund the poster. Change: 1 adopt, 0 keep.
        bytes32 answer;
        /// Jev's confidence in basis points (0 to 10,000).
        uint16 confidenceBps;
        uint64 recordedAt;
    }

    error NotOwner();
    error NotPendingOwner();
    error NotBrain();
    error ZeroAddress();
    error BadKind();
    error BadConfidence();
    error UnknownDecision();

    event Recorded(
        uint256 indexed id,
        Kind indexed kind,
        bytes32 indexed subject,
        bytes32 inputHash,
        bytes32 answer,
        uint16 confidenceBps,
        bytes32 payloadHash,
        string payloadURI
    );
    event BrainSet(address indexed brain);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    address public owner;
    address public pendingOwner;
    address public brain;
    uint256 public count;
    mapping(uint256 => Decision) private _decisions;
    mapping(bytes32 => mapping(Kind => uint256)) private _latest;

    constructor(address owner_, address brain_) {
        if (owner_ == address(0) || brain_ == address(0)) revert ZeroAddress();
        owner = owner_;
        brain = brain_;
        emit OwnerSet(owner_);
        emit BrainSet(brain_);
    }

    /// @param payloadHash Hash of the published decision record (question,
    /// probabilities, model version), so the off-chain copy can be checked.
    function record(
        Kind kind,
        bytes32 subject,
        bytes32 inputHash,
        bytes32 answer,
        uint16 confidenceBps,
        bytes32 payloadHash,
        string calldata payloadURI
    ) external returns (uint256 id) {
        if (msg.sender != brain) revert NotBrain();
        if (kind == Kind.None) revert BadKind();
        if (confidenceBps > 10_000) revert BadConfidence();

        id = ++count;
        _decisions[id] = Decision(kind, subject, inputHash, answer, confidenceBps, uint64(block.timestamp));
        _latest[subject][kind] = id;
        emit Recorded(id, kind, subject, inputHash, answer, confidenceBps, payloadHash, payloadURI);
    }

    function get(uint256 id) external view returns (Decision memory decision) {
        decision = _decisions[id];
        if (decision.kind == Kind.None) revert UnknownDecision();
    }

    /// @notice The most recent decision of `kind` about `subject`, or zero.
    /// Contracts act only on the latest, so an older answer cannot be applied
    /// once a newer one exists.
    function latestOf(bytes32 subject, Kind kind) external view returns (uint256) {
        return _latest[subject][kind];
    }

    function setBrain(address brain_) external {
        if (msg.sender != owner) revert NotOwner();
        if (brain_ == address(0)) revert ZeroAddress();
        brain = brain_;
        emit BrainSet(brain_);
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
}
