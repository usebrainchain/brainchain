// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IERC8183, IERC8183Hook} from "../interfaces/IERC8183.sol";

/// @notice An ERC-8183 hook that holds a job's settlement for an appeal window
/// after its evaluator's first decision, and takes one bonded appeal from the
/// side that decision went against. It serves one job contract and one
/// evaluator, an `Erc8183Evaluator`, which must be the job's evaluator.
///
/// A hook can refuse `complete` and `reject`, so the evaluator's settlement
/// waits for this hook's clock. It cannot hold `claimRefund`: the standard
/// keeps it unhookable, and once `expiredAt` plus the job contract's grace
/// period has passed anyone can expire a submitted job and refund its client.
/// A first decision is therefore taken only if the appeal window and the
/// ruling period both close by `expiredAt`.
///
/// A bond that an appeal ruling confirms goes to the side that won, so the
/// judge gains nothing by upholding its own decision. Every other bond goes
/// back to the appellant: when the ruling reverses the decision, when the
/// ruling is below the evaluator's confidence bar, and when no ruling comes in
/// time.
contract Erc8183AppealHook is IERC8183Hook {
    using SafeERC20 for IERC20;

    enum Stage {
        None,
        Funded,
        Submitted,
        Decided,
        Appealed,
        Settled
    }

    /// A job's appeal terms, fixed when it is funded, and its progress.
    struct Hold {
        Stage stage;
        /// What the first decision does: complete the job, or reject it.
        bool completes;
        uint32 window;
        uint32 rulingPeriod;
        address token;
        uint256 bond;
        bytes32 deliverable;
        uint64 decidedAt;
        uint64 appealedAt;
        address appellant;
    }

    error NotJobContract();
    error NotEvaluator();
    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error BadTerms();
    error WrongEvaluator();
    error TokenNotServed();
    error NoTimeToAppeal();
    error NotFunded();
    error NotSubmitted();
    error NotDecided();
    error NotAppealed();
    error AlreadyAppealed();
    error AppealClosed();
    error NotLosingSide();
    error WindowOpen();
    error RulingOpen();
    error RulingClosed();
    error WrongOutcome();
    error JobOpen();
    error TransferMismatch();

    event TermsFixed(uint256 indexed jobId, address indexed token, uint256 bond, uint32 window, uint32 rulingPeriod);
    event WindowOpened(uint256 indexed jobId, bool completes, uint256 closesAt);
    event Appealed(uint256 indexed jobId, address indexed appellant, uint256 bond);
    event BondSettled(uint256 indexed jobId, address indexed to, uint256 bond);
    event BondSet(address indexed token, uint256 bond);
    event TermsSet(uint32 window, uint32 rulingPeriod);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    uint32 public constant MAX_PERIOD = 30 days;

    IERC8183 public immutable jobContract;
    address public immutable evaluator;
    address public owner;
    address public pendingOwner;
    /// How long after the first decision the losing side may appeal.
    uint32 public window;
    /// How long after an appeal the evaluator has to apply a ruling on it.
    uint32 public rulingPeriod;
    /// The appeal bond for jobs paid in `token`. Zero: this hook does not serve the token.
    mapping(address token => uint256) public bondOf;
    mapping(uint256 jobId => Hold) private _holds;

    constructor(IERC8183 jobContract_, address evaluator_, address owner_, uint32 window_, uint32 rulingPeriod_) {
        if (address(jobContract_) == address(0) || evaluator_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        jobContract = jobContract_;
        evaluator = evaluator_;
        owner = owner_;
        emit OwnerSet(owner_);
        _setTerms(window_, rulingPeriod_);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC8183Hook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (msg.sender != address(jobContract)) revert NotJobContract();
        if (selector == IERC8183.fund.selector) {
            _fix(jobId);
        } else if (selector == IERC8183.submit.selector) {
            if (_holds[jobId].stage != Stage.Funded) revert NotFunded();
        } else if (selector == IERC8183.complete.selector || selector == IERC8183.reject.selector) {
            _gate(jobId, selector == IERC8183.complete.selector, data);
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external {
        if (msg.sender != address(jobContract)) revert NotJobContract();
        if (selector == IERC8183.submit.selector) {
            (, bytes32 deliverable,) = abi.decode(data, (address, bytes32, bytes));
            Hold storage h = _holds[jobId];
            h.deliverable = deliverable;
            h.stage = Stage.Submitted;
        } else if (selector == IERC8183.complete.selector || selector == IERC8183.reject.selector) {
            _release(jobId, data);
        }
    }

    /// @notice Starts the appeal window on the evaluator's first decision.
    function onDecision(uint256 jobId, bool completes) external {
        if (msg.sender != evaluator) revert NotEvaluator();
        Hold storage h = _holds[jobId];
        if (h.stage != Stage.Submitted) revert NotSubmitted();
        if (block.timestamp + h.window + h.rulingPeriod > jobContract.getJob(jobId).expiredAt) revert NoTimeToAppeal();

        h.stage = Stage.Decided;
        h.completes = completes;
        h.decidedAt = uint64(block.timestamp);
        emit WindowOpened(jobId, completes, block.timestamp + h.window);
    }

    /// @notice The side the first decision went against (the client when it
    /// completes the job, the provider when it rejects it) may appeal once,
    /// inside the window, by posting the bond in the job's token.
    function appeal(uint256 jobId) external {
        Hold storage h = _holds[jobId];
        if (h.stage == Stage.Appealed) revert AlreadyAppealed();
        if (h.stage != Stage.Decided) revert NotDecided();
        if (block.timestamp > uint256(h.decidedAt) + h.window) revert AppealClosed();
        IERC8183.Job memory job = jobContract.getJob(jobId);
        if (job.status != IERC8183.JobStatus.Submitted) revert NotSubmitted();
        if (msg.sender != (h.completes ? job.client : job.provider)) revert NotLosingSide();

        h.stage = Stage.Appealed;
        h.appellant = msg.sender;
        h.appealedAt = uint64(block.timestamp);

        IERC20 token = IERC20(h.token);
        uint256 bond = h.bond;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), bond);
        if (token.balanceOf(address(this)) - before != bond) revert TransferMismatch();
        emit Appealed(jobId, msg.sender, bond);
    }

    /// @notice Returns an appeal bond to its appellant when the job ended
    /// without passing through this hook: it expired through `claimRefund`, or
    /// the job contract's admin detached the hook.
    function releaseBond(uint256 jobId) external {
        Hold storage h = _holds[jobId];
        if (h.stage != Stage.Appealed) revert NotAppealed();
        if (jobContract.getJob(jobId).status == IERC8183.JobStatus.Submitted) revert JobOpen();
        h.stage = Stage.Settled;
        _payBond(jobId, h, h.appellant);
    }

    function holdOf(uint256 jobId) external view returns (Hold memory) {
        return _holds[jobId];
    }

    /// @notice The deliverable the job's provider submitted, as the job contract passed it to this hook.
    function deliverableOf(uint256 jobId) external view returns (bytes32) {
        return _holds[jobId].deliverable;
    }

    /// @notice Sets the bond for jobs funded from now on in `token`; zero stops serving it.
    function setBond(address token, uint256 bond) external {
        if (msg.sender != owner) revert NotOwner();
        if (token == address(0)) revert ZeroAddress();
        bondOf[token] = bond;
        emit BondSet(token, bond);
    }

    /// @notice Sets the window and ruling period for jobs funded from now on.
    function setTerms(uint32 window_, uint32 rulingPeriod_) external {
        if (msg.sender != owner) revert NotOwner();
        _setTerms(window_, rulingPeriod_);
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

    /// @dev Funding fixes the terms, and is refused for a job this hook cannot
    /// carry: another evaluator, a token without a bond, or an expiry too close
    /// for a window and a ruling.
    function _fix(uint256 jobId) private {
        IERC8183.Job memory job = jobContract.getJob(jobId);
        if (job.evaluator != evaluator) revert WrongEvaluator();
        uint256 bond = bondOf[job.paymentToken];
        if (bond == 0) revert TokenNotServed();
        (uint32 window_, uint32 rulingPeriod_) = (window, rulingPeriod);
        if (block.timestamp + window_ + rulingPeriod_ > job.expiredAt) revert NoTimeToAppeal();

        Hold storage h = _holds[jobId];
        h.stage = Stage.Funded;
        h.window = window_;
        h.rulingPeriod = rulingPeriod_;
        h.token = job.paymentToken;
        h.bond = bond;
        emit TermsFixed(jobId, job.paymentToken, bond, window_, rulingPeriod_);
    }

    /// @dev The evaluator passes `abi.encode(bool ruling, bool keepBond)`:
    /// whether it applies an appeal ruling, and whether that ruling confirmed
    /// the first decision. Anything else settles the first decision once its
    /// window, or its appeal's ruling period, has closed.
    function _gate(uint256 jobId, bool completes, bytes calldata data) private view {
        (address caller,, bytes memory params) = abi.decode(data, (address, bytes32, bytes));
        // Anyone but the evaluator here is a client or provider rejecting an unfunded job.
        if (caller != evaluator) return;
        (bool ruling, bool keepBond) = abi.decode(params, (bool, bool));
        Hold storage h = _holds[jobId];

        if (ruling) {
            if (h.stage != Stage.Appealed) revert NotAppealed();
            if (block.timestamp > uint256(h.appealedAt) + h.rulingPeriod) revert RulingClosed();
            if (keepBond && completes != h.completes) revert WrongOutcome();
            return;
        }
        if (completes != h.completes) revert WrongOutcome();
        if (h.stage == Stage.Decided) {
            if (block.timestamp <= uint256(h.decidedAt) + h.window) revert WindowOpen();
        } else if (h.stage == Stage.Appealed) {
            if (block.timestamp <= uint256(h.appealedAt) + h.rulingPeriod) revert RulingOpen();
        } else {
            revert NotDecided();
        }
    }

    function _release(uint256 jobId, bytes calldata data) private {
        (address caller,, bytes memory params) = abi.decode(data, (address, bytes32, bytes));
        if (caller != evaluator) return;
        Hold storage h = _holds[jobId];
        Stage stage = h.stage;
        h.stage = Stage.Settled;
        if (stage != Stage.Appealed) return;

        (, bool keepBond) = abi.decode(params, (bool, bool));
        address to = h.appellant;
        if (keepBond) {
            IERC8183.Job memory job = jobContract.getJob(jobId);
            to = to == job.client ? job.provider : job.client;
        }
        _payBond(jobId, h, to);
    }

    function _payBond(uint256 jobId, Hold storage h, address to) private {
        uint256 bond = h.bond;
        IERC20(h.token).safeTransfer(to, bond);
        emit BondSettled(jobId, to, bond);
    }

    function _setTerms(uint32 window_, uint32 rulingPeriod_) private {
        if (window_ == 0 || rulingPeriod_ == 0 || window_ > MAX_PERIOD || rulingPeriod_ > MAX_PERIOD) {
            revert BadTerms();
        }
        window = window_;
        rulingPeriod = rulingPeriod_;
        emit TermsSet(window_, rulingPeriod_);
    }
}
