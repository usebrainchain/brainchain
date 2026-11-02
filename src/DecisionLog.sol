// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Automata's DCAP attestation entrypoint: verifies an Intel TDX quote
/// against the collateral held on chain and returns the decoded report.
interface IDcapAttestation {
    function verifyAndAttestOnChain(bytes calldata rawQuote)
        external
        payable
        returns (bool success, bytes memory output);

    function verifyAndAttestOnChain(bytes calldata rawQuote, uint32 tcbEvaluationDataNumber)
        external
        payable
        returns (bool success, bytes memory output);
}

/// @notice Append-only record of every Jev decision the chain acts on. Only the
/// brain (the harness that calls Jev) can record. The chain does not verify
/// that a recorded answer came from Jev: the brain key is trusted to record
/// Jev's answers faithfully, and contracts that act on a decision apply their
/// own confidence thresholds to what was recorded.
///
/// The brain key is named in one of two ways. The owner, an admin timelock, can
/// set it. Or an enclave proves it holds it: `attestBrain` verifies a TDX quote
/// on chain, requires the enclave's measurements to be on the owner's
/// allowlists, and names the address the enclave wrote into the quote's report
/// data next to the log's current attestation nonce. The brain cannot replace
/// itself otherwise.
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
    error NoAttestation();
    error QuoteRejected();
    error TcbNotAccepted(uint8 status);
    error ImageNotAllowed(bytes32 image);
    error AppNotAllowed(bytes32 app);
    error StaleQuote();
    error NotATdQuote();

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
    event BrainAttested(address indexed brain, bytes32 indexed image, bytes32 indexed app);
    event AttestationSet(address indexed attestation);
    event ImageAllowed(bytes32 indexed image, bool allowed);
    event AppAllowed(bytes32 indexed app, bool allowed);
    event TcbEvaluationSet(uint32 number);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    address public owner;
    address public pendingOwner;
    address public brain;
    uint256 public count;
    mapping(uint256 => Decision) private _decisions;
    mapping(bytes32 => mapping(Kind => uint256)) private _latest;

    /// Where quotes are verified; zero until the owner sets it, which leaves
    /// `setBrain` as the only path. `setBrain` clears it, so a recovery holds
    /// until the owner reopens attestation.
    IDcapAttestation public attestation;
    /// keccak256(MRTD, RTMR0, RTMR1, RTMR2): the virtual hardware, firmware and OS image.
    mapping(bytes32 => bool) public allowedImage;
    /// keccak256(RTMR3): the app, its compose and the instance that runs it.
    mapping(bytes32 => bool) public allowedApp;
    /// Successful attestations so far; the nonce a quote must carry moves with it.
    uint256 public attestations;
    /// Intel's TCB evaluation number to verify against, or zero for the verifier's default. Pinning keeps
    /// quotes verifying when Intel moves to a number the on-chain collateral does not cover yet.
    uint32 public tcbEvaluationNumber;

    // Offsets in the verifier's output: an 11-byte header (version, TEE type,
    // TCB status at byte 4, FMSPC), then the TD report body.
    uint256 private constant TCB_STATUS = 4;
    uint256 private constant MRTD = 147;
    uint256 private constant RTMR0 = 339;
    uint256 private constant RTMR3 = 483;
    uint256 private constant REPORT_DATA = 531;
    uint256 private constant OUTPUT_MIN = 595;
    /// Quote versions and body types the verifier reports for a TDX quote: v4 or v5 with a TD 1.0 or TD 1.5 body.
    uint8 private constant QUOTE_V4 = 4;
    uint8 private constant QUOTE_V5 = 5;
    uint8 private constant BODY_TD10 = 2;
    uint8 private constant BODY_TD15 = 3;
    /// TCB statuses accepted: up to date, or software hardening needed.
    uint8 private constant TCB_OK = 0;
    uint8 private constant TCB_SW_HARDENING_NEEDED = 1;

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

    /// @notice Names the brain directly and closes attestation, so an enclave
    /// still on the allowlists cannot name itself again until the owner calls
    /// `setAttestation`. A recovery therefore holds for as long as the owner wants.
    function setBrain(address brain_) external {
        if (msg.sender != owner) revert NotOwner();
        if (brain_ == address(0)) revert ZeroAddress();
        brain = brain_;
        emit BrainSet(brain_);
        if (address(attestation) != address(0)) {
            attestation = IDcapAttestation(address(0));
            emit AttestationSet(address(0));
        }
    }

    /// @notice What an enclave writes into the first 32 bytes of its quote's
    /// report data to name a key now. It changes with every attestation, so an
    /// older quote can never be replayed to name an earlier key.
    function attestationNonce() public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), attestations));
    }

    /// @notice Names the brain from an enclave's TDX quote: the report data is
    /// `attestationNonce()` followed by the brain address left-padded to 32 bytes.
    function attestBrain(bytes calldata quote) external returns (address brain_) {
        if (address(attestation) == address(0)) revert NoAttestation();
        bool ok;
        bytes memory out;
        if (tcbEvaluationNumber == 0) (ok, out) = attestation.verifyAndAttestOnChain(quote);
        else (ok, out) = attestation.verifyAndAttestOnChain(quote, tcbEvaluationNumber);
        if (!ok || out.length < OUTPUT_MIN) revert QuoteRejected();
        // Big-endian uint16 version and body type; an SGX report would be read at the wrong offsets.
        if (out[0] != 0 || (uint8(out[1]) != QUOTE_V4 && uint8(out[1]) != QUOTE_V5)) revert NotATdQuote();
        if (out[2] != 0 || (uint8(out[3]) != BODY_TD10 && uint8(out[3]) != BODY_TD15)) revert NotATdQuote();

        uint8 tcb = uint8(out[TCB_STATUS]);
        if (tcb != TCB_OK && tcb != TCB_SW_HARDENING_NEEDED) revert TcbNotAccepted(tcb);
        bytes32 image = keccak256(abi.encodePacked(_slice(out, MRTD, 48), _slice(out, RTMR0, 144)));
        if (!allowedImage[image]) revert ImageNotAllowed(image);
        bytes32 app = keccak256(_slice(out, RTMR3, 48));
        if (!allowedApp[app]) revert AppNotAllowed(app);

        if (bytes32(_slice(out, REPORT_DATA, 32)) != attestationNonce()) revert StaleQuote();
        uint256 padded = uint256(bytes32(_slice(out, REPORT_DATA + 32, 32)));
        if (padded >> 160 != 0) revert QuoteRejected();
        brain_ = address(uint160(padded));
        if (brain_ == address(0)) revert ZeroAddress();
        attestations++;
        brain = brain_;
        emit BrainSet(brain_);
        emit BrainAttested(brain_, image, app);
    }

    function setAttestation(IDcapAttestation attestation_) external {
        if (msg.sender != owner) revert NotOwner();
        attestation = attestation_;
        emit AttestationSet(address(attestation_));
    }

    function setTcbEvaluationNumber(uint32 number) external {
        if (msg.sender != owner) revert NotOwner();
        tcbEvaluationNumber = number;
        emit TcbEvaluationSet(number);
    }

    function allowImage(bytes32 image, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        allowedImage[image] = allowed;
        emit ImageAllowed(image, allowed);
    }

    function allowApp(bytes32 app, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        allowedApp[app] = allowed;
        emit AppAllowed(app, allowed);
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

    function _slice(bytes memory data, uint256 start, uint256 length) private pure returns (bytes memory part) {
        part = new bytes(length);
        for (uint256 i; i < length; ++i) {
            part[i] = data[start + i];
        }
    }
}
