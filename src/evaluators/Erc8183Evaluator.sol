// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IERC8183} from "../interfaces/IERC8183.sol";
import {Erc8183AppealHook} from "./Erc8183AppealHook.sol";

/// @notice An on-chain check a proposed brain key must pass before it takes
/// effect, such as a TDX quote verified on this chain. Unset until one exists.
interface IBrainKeyCheck {
    function isAttested(address key) external view returns (bool);
}

/// @notice The evaluator for ERC-8183 jobs judged by BrainChain. A job names
/// this contract as its evaluator and, as its hook, an `Erc8183AppealHook`
/// that this contract's owner has allowed. The evaluator completes or rejects a job only on a decision
/// signed by the brain key about that job and the deliverable its provider
/// submitted. Anyone may submit a signed decision.
///
/// The first decision does not settle the job. The hook holds it for an appeal
/// window, and the side it went against may appeal once with a bond. A ruling
/// on the appeal, signed the same way, settles the job; with no appeal, anyone
/// calls `finalize` once the window closes and the first decision settles it.
///
/// A decision below `minConfidenceBps` takes the safe default: a first
/// decision rejects the job, refunding the client, and an appeal ruling leaves
/// the first decision standing.
contract Erc8183Evaluator is EIP712 {
    using SafeERC20 for IERC20;

    /// @dev `logChainId`, `decisionLog` and `decisionId` name the BrainChain
    /// record behind the decision. `appeal` marks a ruling on an appeal.
    struct Decision {
        address jobContract;
        uint256 jobId;
        bytes32 deliverable;
        bool appeal;
        bool accept;
        uint16 confidenceBps;
        uint256 logChainId;
        address decisionLog;
        uint256 decisionId;
    }

    /// The first decision on a job, and the key that signed it.
    struct Judgment {
        bool decided;
        bool completes;
        address signer;
        uint256 decisionId;
        bytes32 digest;
    }

    error NotOwner();
    error NotPendingOwner();
    error NotBrain();
    error NoBrain();
    error SignerNotBrain();
    error ZeroAddress();
    error BadConfidence();
    error BadDelay();
    error DecisionUsed();
    error NotEvaluator();
    error NotSubmitted();
    error WrongHook();
    error WrongDeliverable();
    error AlreadyDecided();
    error NotDecided();
    error NoPendingBrain();
    error NoPendingHook();
    error TooEarly();
    error KeyNotAttested();

    event Decided(
        address indexed jobContract,
        uint256 indexed jobId,
        uint256 indexed decisionId,
        bool appeal,
        bool completes,
        uint16 confidenceBps
    );
    event Settled(address indexed jobContract, uint256 indexed jobId, uint256 indexed decisionId, bool completed);
    event BrainProposed(address indexed brain, uint256 readyAt);
    event BrainProposalCancelled(address indexed brain);
    event BrainSet(address indexed brain);
    event BrainRevoked(address indexed brain);
    event HookProposed(address indexed hook, uint256 readyAt);
    event HookAllowed(address indexed hook, bool allowed);
    event KeyCheckSet(address indexed keyCheck);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    bytes32 public constant DECISION_TYPEHASH = keccak256(
        "Decision(address jobContract,uint256 jobId,bytes32 deliverable,bool appeal,bool accept,uint16 confidenceBps,uint256 logChainId,address decisionLog,uint256 decisionId)"
    );
    uint256 public constant MIN_DELAY = 1 days;

    /// How long a new brain key or a new hook waits before it can take effect.
    uint256 public immutable delay;
    uint16 public immutable minConfidenceBps;

    address public owner;
    address public pendingOwner;
    address public brain;
    address public pendingBrain;
    uint256 public brainReadyAt;
    IBrainKeyCheck public keyCheck;
    /// Hooks whose deliverable record and appeal clock this evaluator trusts.
    mapping(address hook => bool) public hookAllowed;
    mapping(address hook => uint256) public hookReadyAt;

    /// keccak256(logChainId, decisionLog, decisionId) => applied. A BrainChain decision applies once.
    mapping(bytes32 => bool) public decisionUsed;
    mapping(address jobContract => mapping(uint256 jobId => Judgment)) private _judgments;

    constructor(address owner_, address brain_, uint256 delay_, uint16 minConfidenceBps_)
        EIP712("BrainChain ERC-8183 Evaluator", "1")
    {
        if (owner_ == address(0) || brain_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY) revert BadDelay();
        if (minConfidenceBps_ > 10_000) revert BadConfidence();
        owner = owner_;
        brain = brain_;
        delay = delay_;
        minConfidenceBps = minConfidenceBps_;
        emit OwnerSet(owner_);
        emit BrainSet(brain_);
    }

    /// @notice Applies a decision signed by the brain key. A first decision
    /// opens the hook's appeal window; a ruling on an appeal settles the job.
    function decide(Decision calldata d, bytes calldata signature) external {
        if (d.confidenceBps > 10_000) revert BadConfidence();
        if (brain == address(0)) revert NoBrain();
        bytes32 digest = hashDecision(d);
        if (ECDSA.recover(digest, signature) != brain) revert NotBrain();
        bytes32 ref = keccak256(abi.encode(d.logChainId, d.decisionLog, d.decisionId));
        if (decisionUsed[ref]) revert DecisionUsed();
        Erc8183AppealHook hook = _hookOf(d.jobContract, d.jobId);
        if (hook.deliverableOf(d.jobId) != d.deliverable) revert WrongDeliverable();

        decisionUsed[ref] = true;
        Judgment storage j = _judgments[d.jobContract][d.jobId];
        bool confident = d.confidenceBps >= minConfidenceBps;

        if (!d.appeal) {
            if (j.decided) revert AlreadyDecided();
            bool completes = d.accept && confident;
            (j.decided, j.completes, j.decisionId, j.digest) = (true, completes, d.decisionId, digest);
            j.signer = brain;
            emit Decided(d.jobContract, d.jobId, d.decisionId, false, completes, d.confidenceBps);
            hook.onDecision(d.jobId, completes);
            return;
        }

        if (!j.decided) revert NotDecided();
        bool completesOnAppeal = confident ? d.accept : j.completes;
        bool keepBond = confident && d.accept == j.completes;
        emit Decided(d.jobContract, d.jobId, d.decisionId, true, completesOnAppeal, d.confidenceBps);
        _settle(d.jobContract, d.jobId, completesOnAppeal, d.decisionId, digest, abi.encode(true, keepBond));
    }

    /// @notice Settles a job on its first decision. The hook lets this through
    /// once the appeal window closes unappealed, or once an appeal's ruling
    /// period closes without a ruling. A decision whose key has since been
    /// revoked or replaced never settles this way: the job then needs a ruling
    /// by the current key, or it expires and refunds its client.
    function finalize(address jobContract, uint256 jobId) external {
        Judgment storage j = _judgments[jobContract][jobId];
        if (!j.decided) revert NotDecided();
        if (j.signer != brain) revert SignerNotBrain();
        _settle(jobContract, jobId, j.completes, j.decisionId, j.digest, abi.encode(false, false));
    }

    /// @notice The EIP-712 digest the brain signs for `d`.
    function hashDecision(Decision calldata d) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DECISION_TYPEHASH,
                    d.jobContract,
                    d.jobId,
                    d.deliverable,
                    d.appeal,
                    d.accept,
                    d.confidenceBps,
                    d.logChainId,
                    d.decisionLog,
                    d.decisionId
                )
            )
        );
    }

    function judgmentOf(address jobContract, uint256 jobId) external view returns (Judgment memory) {
        return _judgments[jobContract][jobId];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Starts a change of brain key; it can take effect after `delay`.
    function proposeBrain(address next) external {
        if (msg.sender != owner) revert NotOwner();
        if (next == address(0)) revert ZeroAddress();
        pendingBrain = next;
        brainReadyAt = block.timestamp + delay;
        emit BrainProposed(next, brainReadyAt);
    }

    function cancelBrain() external {
        if (msg.sender != owner) revert NotOwner();
        address next = pendingBrain;
        if (next == address(0)) revert NoPendingBrain();
        delete pendingBrain;
        delete brainReadyAt;
        emit BrainProposalCancelled(next);
    }

    /// @notice Completes a proposed change once its delay has passed. Anyone
    /// may call it; with a key check set, the new key must also pass it.
    function acceptBrain() external {
        address next = pendingBrain;
        if (next == address(0)) revert NoPendingBrain();
        if (block.timestamp < brainReadyAt) revert TooEarly();
        if (address(keyCheck) != address(0) && !keyCheck.isAttested(next)) revert KeyNotAttested();
        brain = next;
        delete pendingBrain;
        delete brainReadyAt;
        emit BrainSet(next);
    }

    /// @notice Stops the current brain key at once, for a key that may have
    /// leaked. Until a proposed key takes effect, every decision is refused,
    /// rulings included, and no first decision the key applied can settle
    /// through `finalize`.
    function revokeBrain() external {
        if (msg.sender != owner) revert NotOwner();
        emit BrainRevoked(brain);
        brain = address(0);
    }

    /// @notice Starts allowing `hook`; it can be allowed after `delay`. A hook
    /// takes effect only after the delay because the evaluator relies on its
    /// record of the deliverable and on its appeal clock.
    function proposeHook(address hook) external {
        if (msg.sender != owner) revert NotOwner();
        if (hook == address(0)) revert ZeroAddress();
        hookReadyAt[hook] = block.timestamp + delay;
        emit HookProposed(hook, hookReadyAt[hook]);
    }

    function acceptHook(address hook) external {
        uint256 readyAt = hookReadyAt[hook];
        if (readyAt == 0) revert NoPendingHook();
        if (block.timestamp < readyAt) revert TooEarly();
        hookAllowed[hook] = true;
        delete hookReadyAt[hook];
        emit HookAllowed(hook, true);
    }

    /// @notice Stops trusting `hook` at once and drops any proposal for it.
    /// Its jobs take no further decisions; a job already decided by the
    /// current key still settles through `finalize`.
    function removeHook(address hook) external {
        if (msg.sender != owner) revert NotOwner();
        delete hookAllowed[hook];
        delete hookReadyAt[hook];
        emit HookAllowed(hook, false);
    }

    /// @notice Sets the check a proposed key must pass, or zero for none. It
    /// adds a condition to `acceptBrain` and never shortens the delay.
    function setKeyCheck(IBrainKeyCheck keyCheck_) external {
        if (msg.sender != owner) revert NotOwner();
        keyCheck = keyCheck_;
        emit KeyCheckSet(address(keyCheck_));
    }

    /// @notice Sends this contract's balance of `token` to `to`. It holds no
    /// job escrow; what builds up here is the evaluator fee a job contract
    /// pays its evaluator on completion.
    function sweep(IERC20 token, address to) external {
        if (msg.sender != owner) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        emit Swept(address(token), to, amount);
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

    /// @dev The job must name this evaluator, be submitted, and carry an
    /// allowed hook bound to this evaluator and job contract: the reference
    /// job contract does not store deliverables, so the hook's record is the
    /// one checked.
    function _hookOf(address jobContract, uint256 jobId) private view returns (Erc8183AppealHook hook) {
        IERC8183.Job memory job = IERC8183(jobContract).getJob(jobId);
        if (job.evaluator != address(this)) revert NotEvaluator();
        if (job.status != IERC8183.JobStatus.Submitted) revert NotSubmitted();
        if (!hookAllowed[job.hook]) revert WrongHook();
        hook = Erc8183AppealHook(job.hook);
        if (hook.evaluator() != address(this) || address(hook.jobContract()) != jobContract) revert WrongHook();
    }

    function _settle(
        address jobContract,
        uint256 jobId,
        bool completes,
        uint256 decisionId,
        bytes32 reason,
        bytes memory hookParams
    ) private {
        emit Settled(jobContract, jobId, decisionId, completes);
        if (completes) IERC8183(jobContract).complete(jobId, reason, hookParams);
        else IERC8183(jobContract).reject(jobId, reason, hookParams);
    }
}
