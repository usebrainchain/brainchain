// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IERC8183, IERC8183Hook} from "../../src/interfaces/IERC8183.sol";

/// @notice The reference payout receiver callback (contracts/IDisburser.sol at the same commit).
interface IDisburser is IERC165 {
    function onDisbursement(uint256 jobId, bytes4 selector, address token, uint256 amount, bytes calldata data) external;
}

/// @notice The ERC-8183 reference job contract (github.com/erc-8183/base-contracts
/// at 142e669, contracts/ERC8183.sol) reduced to its job lifecycle for tests:
/// the same checks, state changes, fees, hook calls and hook data, payout
/// receivers and their callback in the same order, pausing, hook detaching and
/// the one-hour evaluation grace period. Left out: milestone claims, the
/// admin's emergency withdrawal while paused, upgrades and signed
/// authorizations. Admin roles are a single admin address.
contract ERC8183 is IERC8183, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant EVALUATION_GRACE_PERIOD = 1 hours;

    address public admin;
    bool public paused;
    uint256 public platformFeeBP;
    address public platformTreasury;
    uint256 public evaluatorFeeBP;
    uint256 public jobCounter;
    mapping(uint256 => Job) public jobs;
    mapping(address => bool) public whitelistedHooks;
    mapping(address => bool) public allowedPaymentTokens;

    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        uint48 expiredAt,
        address hook
    );
    event BudgetSet(uint256 indexed jobId, address indexed token, uint256 amount);
    event PayoutReceiverSet(uint256 indexed jobId, address indexed payoutReceiver);
    event Disbursed(uint256 indexed jobId, address indexed receiver, bytes4 selector, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address indexed provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed recipient, uint256 amount);
    event PlatformFeePaid(uint256 indexed jobId, address indexed platformTreasury, uint256 amount);
    event EvaluatorFeePaid(uint256 indexed jobId, address indexed evaluator, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event HookDetached(uint256 indexed jobId, address indexed hook);

    error InvalidJob();
    error InvalidHook();
    error InvalidReceiver();
    error EnforcedPause();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ProviderNotSet();
    error FeesTooHigh();
    error HookNotWhitelisted();
    error BudgetMismatch();
    error PaymentTokenMismatch();
    error ProviderCannotBeEvaluator();
    error ClientCannotBeProvider();
    error GracePeriodActive();
    error PaymentTokenNotAllowed();
    error UnexpectedFundedAmount();

    constructor(address treasury_, address admin_) {
        if (treasury_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        platformTreasury = treasury_;
        admin = admin_;
        whitelistedHooks[address(0)] = true;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert EnforcedPause();
        _;
    }

    function pause() external onlyAdmin {
        paused = true;
    }

    function unpause() external onlyAdmin {
        paused = false;
    }

    function setPlatformFee(uint256 feeBP_, address treasury_) external onlyAdmin {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ + evaluatorFeeBP > 10000) revert FeesTooHigh();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
    }

    function setEvaluatorFee(uint256 feeBP_) external onlyAdmin {
        if (feeBP_ + platformFeeBP > 10000) revert FeesTooHigh();
        evaluatorFeeBP = feeBP_;
    }

    function setHookWhitelist(address hook, bool status) external onlyAdmin {
        if (hook == address(0)) revert ZeroAddress();
        whitelistedHooks[hook] = status;
    }

    function setPaymentTokenAllowed(address token, bool status) external onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        allowedPaymentTokens[token] = status;
    }

    function batchDetachHook(uint256[] calldata jobIds) external onlyAdmin {
        for (uint256 i = 0; i < jobIds.length; i++) {
            uint256 jobId = jobIds[i];
            if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
            Job storage job = jobs[jobId];
            address oldHook = job.hook;
            if (oldHook == address(0)) continue;
            job.hook = address(0);
            emit HookDetached(jobId, oldHook);
        }
    }

    function createJob(
        address provider,
        address evaluator,
        uint48 expiredAt,
        string calldata description,
        address hook,
        uint256 providerAgentId
    ) external whenNotPaused nonReentrant returns (uint256) {
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        if (msg.sender == provider) revert ClientCannotBeProvider();
        if (evaluator == address(0)) revert ZeroAddress();
        if (evaluator == provider) revert ProviderCannotBeEvaluator();
        if (!whitelistedHooks[hook]) revert HookNotWhitelisted();
        if (hook != address(0) && !ERC165Checker.supportsInterface(hook, type(IERC8183Hook).interfaceId)) {
            revert InvalidHook();
        }

        uint256 jobId = ++jobCounter;
        Job storage job = jobs[jobId];
        job.client = msg.sender;
        job.provider = provider;
        job.expiredAt = expiredAt;
        job.evaluator = evaluator;
        job.hook = hook;
        job.providerAgentId = provider != address(0) ? providerAgentId : 0;
        job.description = description;
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt, hook);
        return jobId;
    }

    function setPayoutReceiver(uint256 jobId, address payoutReceiver) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        _validatePayoutReceiver(payoutReceiver, job.paymentToken);
        job.payoutReceiver = payoutReceiver;
        emit PayoutReceiverSet(jobId, payoutReceiver);
    }

    function setBudget(uint256 jobId, address token, uint256 amount, bytes calldata optParams)
        external
        whenNotPaused
        nonReentrant
    {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        if (token == address(0)) revert ZeroAddress();
        if (!allowedPaymentTokens[token]) revert PaymentTokenNotAllowed();
        _validatePayoutReceiver(job.payoutReceiver, token);

        bytes memory data = abi.encode(msg.sender, token, amount, optParams);
        _beforeHook(job.hook, jobId, this.setBudget.selector, data);
        job.paymentToken = token;
        job.budget = amount;
        emit BudgetSet(jobId, token, amount);
        _afterHook(job.hook, jobId, this.setBudget.selector, data);
    }

    function fund(uint256 jobId, address expectedToken, uint256 expectedBudget, bytes calldata optParams)
        external
        whenNotPaused
        nonReentrant
    {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (block.timestamp >= job.expiredAt) revert WrongStatus();
        if (job.paymentToken != expectedToken) revert PaymentTokenMismatch();
        if (job.budget != expectedBudget) revert BudgetMismatch();

        bytes memory data = abi.encode(msg.sender, optParams);
        _beforeHook(job.hook, jobId, this.fund.selector, data);
        job.status = JobStatus.Funded;
        if (job.budget > 0) {
            IERC20 token = IERC20(job.paymentToken);
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), job.budget);
            if (token.balanceOf(address(this)) - balanceBefore != job.budget) revert UnexpectedFundedAmount();
        }
        emit JobFunded(jobId, msg.sender, job.budget);
        _afterHook(job.hook, jobId, this.fund.selector, data);
    }

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Funded && (job.status != JobStatus.Open || job.budget > 0)) revert WrongStatus();
        if (job.expiredAt != 0 && block.timestamp >= job.expiredAt) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, deliverable, optParams);
        _beforeHook(job.hook, jobId, this.submit.selector, data);
        job.status = JobStatus.Submitted;
        job.submittedAt = uint48(block.timestamp);
        emit JobSubmitted(jobId, msg.sender, deliverable);
        _afterHook(job.hook, jobId, this.submit.selector, data);
    }

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, this.complete.selector, data);
        job.status = JobStatus.Completed;

        uint256 amount = job.budget - job.settledAmount;
        uint256 platformFee = (amount * platformFeeBP) / 10000;
        uint256 evalFee = (amount * evaluatorFeeBP) / 10000;
        uint256 net = amount - platformFee - evalFee;
        IERC20 token = IERC20(job.paymentToken);
        if (platformFee > 0) {
            token.safeTransfer(platformTreasury, platformFee);
            emit PlatformFeePaid(jobId, platformTreasury, platformFee);
        }
        if (evalFee > 0) {
            token.safeTransfer(job.evaluator, evalFee);
            emit EvaluatorFeePaid(jobId, job.evaluator, evalFee);
        }
        _payout(jobId, job, net, this.complete.selector, optParams);
        emit JobCompleted(jobId, msg.sender, reason);
        _afterHook(job.hook, jobId, this.complete.selector, data);
    }

    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client && msg.sender != job.provider) revert Unauthorized();
        } else if (job.status == JobStatus.Funded || job.status == JobStatus.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }

        bytes memory data = abi.encode(msg.sender, reason, optParams);
        _beforeHook(job.hook, jobId, this.reject.selector, data);
        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;
        uint256 refundAmount = job.budget - job.settledAmount;
        if ((prev == JobStatus.Funded || prev == JobStatus.Submitted) && refundAmount > 0) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }
        emit JobRejected(jobId, msg.sender, reason);
        _afterHook(job.hook, jobId, this.reject.selector, data);
    }

    function claimRefund(uint256 jobId) external whenNotPaused nonReentrant {
        Job storage job = jobs[jobId];
        if (jobId == 0 || jobId > jobCounter) revert InvalidJob();
        if (job.status != JobStatus.Open && job.status != JobStatus.Funded && job.status != JobStatus.Submitted) {
            revert WrongStatus();
        }
        if (job.status == JobStatus.Submitted) {
            if (block.timestamp < job.expiredAt + EVALUATION_GRACE_PERIOD) revert GracePeriodActive();
        } else if (block.timestamp < job.expiredAt) {
            revert WrongStatus();
        }

        JobStatus prev = job.status;
        job.status = JobStatus.Expired;
        uint256 refundAmount = job.budget - job.settledAmount;
        if (refundAmount > 0 && (prev == JobStatus.Funded || prev == JobStatus.Submitted)) {
            IERC20(job.paymentToken).safeTransfer(job.client, refundAmount);
            emit Refunded(jobId, job.client, refundAmount);
        }
        emit JobExpired(jobId);
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }

    /// @dev As in the reference: the receiver's callback runs after the job is
    /// Completed and before the hook's `afterAction`.
    function _payout(uint256 jobId, Job storage job, uint256 net, bytes4 selector, bytes calldata optParams) internal {
        address recipient = job.payoutReceiver == address(0) ? job.provider : job.payoutReceiver;
        if (net == 0) return;
        IERC20(job.paymentToken).safeTransfer(recipient, net);
        emit PaymentReleased(jobId, recipient, net);
        if (recipient.code.length > 0 && ERC165Checker.supportsInterface(recipient, type(IDisburser).interfaceId)) {
            IDisburser(recipient).onDisbursement(jobId, selector, job.paymentToken, net, optParams);
            emit Disbursed(jobId, recipient, selector, net);
        }
    }

    function _validatePayoutReceiver(address payoutReceiver, address paymentToken) internal view {
        if (payoutReceiver == address(this)) revert InvalidReceiver();
        if (payoutReceiver != address(0) && payoutReceiver == paymentToken) revert InvalidReceiver();
    }

    function _beforeHook(address hook, uint256 jobId, bytes4 selector, bytes memory data) internal {
        if (hook != address(0)) IERC8183Hook(hook).beforeAction(jobId, selector, data);
    }

    function _afterHook(address hook, uint256 jobId, bytes4 selector, bytes memory data) internal {
        if (hook != address(0)) IERC8183Hook(hook).afterAction(jobId, selector, data);
    }
}
