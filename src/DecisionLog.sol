// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Append-only record of every Jev decision the chain acts on. Only the
/// brain (the harness that calls Jev) can record; contracts that act on a
/// decision read it from here and apply their own confidence thresholds.
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
        /// What the decision is about: a task id for Hire, Grade and Ruling, the
        /// hash of the proposed call for Change.
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
    event OwnerSet(address indexed owner);

    address public owner;
    address public brain;
    uint256 public count;
    mapping(uint256 => Decision) private _decisions;

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
        emit Recorded(id, kind, subject, inputHash, answer, confidenceBps, payloadHash, payloadURI);
    }

    function get(uint256 id) external view returns (Decision memory decision) {
        decision = _decisions[id];
        if (decision.kind == Kind.None) revert UnknownDecision();
    }

    function setBrain(address brain_) external {
        if (msg.sender != owner) revert NotOwner();
        if (brain_ == address(0)) revert ZeroAddress();
        brain = brain_;
        emit BrainSet(brain_);
    }

    function setOwner(address owner_) external {
        if (msg.sender != owner) revert NotOwner();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }
}
