// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DecisionLog} from "./DecisionLog.sol";
import {ModelRegistry} from "./ModelRegistry.sol";
import {WorkerStaking} from "./flywheel/WorkerStaking.sol";
import {PayoutPreferences} from "./PayoutPreferences.sol";

/// @notice Tasks with a bounty in escrow, settled only by Jev's recorded
/// decisions. The board applies its own confidence thresholds: a decision below
/// threshold never moves funds toward a model, and every path that stalls (no
/// hire, no delivery, no grade) ends in a refund to the poster. A task settles
/// under the terms in force when it was posted, and pays the account that
/// submitted the work. The side a ruling goes against may appeal it once, with
/// a bond, for a second ruling by Jev on the full record.
contract TaskBoard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None,
        Open,
        Hired,
        Submitted,
        Graded,
        Disputed,
        Paid,
        Refunded,
        /// A ruling stands and settles once its appeal window closes unappealed.
        Ruled,
        /// The side the ruling went against appealed; Jev rules again.
        Appealed
    }

    enum RefundReason {
        NotHired,
        NotDelivered,
        NotGraded,
        Rejected,
        RuledForPoster
    }

    /// @dev The first thirteen fields keep their v2 order so older readers
    /// still decode them; the rest are the task's fixed terms.
    struct Task {
        address poster;
        uint128 bounty;
        uint64 deadline;
        Status status;
        bool accepted;
        bool disputed;
        bool disputedByModel;
        bytes32 model;
        bytes32 briefHash;
        bytes32 resultHash;
        uint64 submittedAt;
        uint64 gradedAt;
        uint64 disputedAt;
        uint64 postedAt;
        address payee;
        address feeRecipient;
        uint16 feeBps;
        uint16 hireThresholdBps;
        uint16 gradeThresholdBps;
        uint16 ruleThresholdBps;
        uint64 gradeWindow;
        uint64 disputeWindow;
        uint64 ruleWindow;
    }

    /// @notice A task's appeal terms, fixed when it was posted, and its ruling
    /// once there is one.
    struct Appeal {
        /// How long after a ruling the losing side may appeal; zero settles at the ruling.
        uint64 window;
        /// The bond, as a share of the bounty.
        uint16 bondBps;
        uint64 ruledAt;
        /// What the standing ruling decides, and whether it was at or above the ruling threshold.
        bool pays;
        bool confident;
        address appellant;
        uint128 bond;
        uint64 appealedAt;
    }

    struct AppealConfig {
        uint64 window;
        uint16 bondBps;
    }

    struct Config {
        uint16 hireThresholdBps;
        uint16 gradeThresholdBps;
        uint16 ruleThresholdBps;
        uint64 minDuration;
        uint64 maxDuration;
        uint64 gradeWindow;
        uint64 disputeWindow;
        uint64 ruleWindow;
        uint128 minBounty;
    }

    error NotOwner();
    error BadPayouts();
    error NotGuardian();
    error NotBrain();
    error NotWorker();
    error NotDisputant();
    error ZeroAddress();
    error IsPaused();
    error BadConfig();
    error BadBounty();
    error BadDeadline();
    error BadStatus();
    error BadDecision();
    error StaleDecision();
    error DecisionUsed();
    error ModelInactive();
    error TooLate();
    error TooEarly();
    error TransferMismatch();
    error BadFee();
    error NotPoster();
    error BadThreshold();
    error NotAppellant();

    event Posted(
        uint256 indexed id, address indexed poster, uint128 bounty, uint64 deadline, bytes32 briefHash, string briefURI
    );
    event GradeBarRaised(uint256 indexed id, uint16 gradeThresholdBps, uint16 ruleThresholdBps);
    event WorkerHired(uint256 indexed id, bytes32 indexed model, uint256 indexed decisionId);
    event HireHeld(uint256 indexed id, uint256 indexed decisionId);
    event WorkSubmitted(uint256 indexed id, bytes32 indexed model, bytes32 resultHash, string resultURI);
    event WorkGraded(uint256 indexed id, uint256 indexed decisionId, bool accepted);
    event GradeDisputed(uint256 indexed id, address indexed opener);
    /// @param confident False when the ruling was below threshold and the grade stood.
    event Ruled(uint256 indexed id, uint256 indexed decisionId, bool paid, bool confident);
    event BountyPaid(uint256 indexed id, bytes32 indexed model, address indexed account, uint128 bounty, uint128 fee);
    event BountyRefunded(uint256 indexed id, address indexed poster, uint128 amount, RefundReason reason);
    event FeeTaken(uint256 indexed id, address indexed recipient, uint128 fee);
    event Appealed(uint256 indexed id, address indexed appellant, uint128 bond);
    /// @param paid What settles the task. @param overturned True when Jev confidently decided against the standing ruling.
    event AppealRuled(uint256 indexed id, uint256 indexed decisionId, bool paid, bool confident, bool overturned);
    event AppealBondSettled(uint256 indexed id, address indexed to, uint128 bond);
    event AppealConfigSet(AppealConfig config);
    event ConfigSet(Config config);
    event FeeSet(uint16 feeBps, address feeRouter);
    event PayoutsSet(address indexed payouts, address indexed house);
    event PausedSet(bool paused);
    event OwnerSet(address indexed owner);
    event GuardianSet(address indexed guardian);
    event WorkerAllowedSet(address indexed account, bool allowed);

    bytes32 private constant YES = bytes32(uint256(1));

    uint16 public constant MAX_FEE_BPS = 1_000;
    uint64 public constant MAX_WINDOW = 7 days;
    uint64 public constant MAX_DURATION = 30 days;

    IERC20 public immutable token;
    DecisionLog public immutable decisions;
    ModelRegistry public immutable models;
    /// @notice Open worker staking; zero when only house models can be hired.
    WorkerStaking public immutable staking;

    /// @notice Share of each paid bounty sent to the fee router, in basis points.
    uint16 public feeBps;
    address public feeRouter;
    /// @notice Workers that take their pay in stock are paid through the house, which pays the stock on the parent chain.
    PayoutPreferences public payouts;
    address public payoutHouse;

    address public owner;
    address public guardian;
    bool public paused;
    Config public config;
    /// @notice Appeal terms for tasks posted from now on. Zero window: rulings settle at once.
    AppealConfig public appealConfig;

    uint256 public count;
    mapping(uint256 => Task) private _tasks;
    mapping(uint256 => Appeal) private _appeals;
    mapping(uint256 => bool) public decisionUsed;
    /// @notice Staked workers governance has approved for hire. Staking alone
    /// is not enough: anyone can stake, and without it a compromised brain key
    /// could hire an address it staked itself and take a bounty.
    mapping(address => bool) public workerAllowed;

    constructor(
        IERC20 token_,
        DecisionLog decisions_,
        ModelRegistry models_,
        WorkerStaking staking_,
        address owner_,
        address guardian_,
        Config memory config_
    ) {
        if (
            address(token_) == address(0) || address(decisions_) == address(0) || address(models_) == address(0)
                || owner_ == address(0) || guardian_ == address(0)
        ) revert ZeroAddress();
        token = token_;
        decisions = decisions_;
        models = models_;
        staking = staking_;
        owner = owner_;
        guardian = guardian_;
        _setConfig(config_);
        emit OwnerSet(owner_);
        emit GuardianSet(guardian_);
    }

    /// @notice What a decision about task `id` must name as its subject: the
    /// task on this board on this chain, so a decision can never be applied to
    /// another task, board or chain.
    function subjectOf(uint256 id) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), id));
    }

    function post(uint128 bounty, uint64 deadline, bytes32 briefHash, string calldata briefURI)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (paused) revert IsPaused();
        Config memory c = config;
        if (bounty < c.minBounty) revert BadBounty();
        if (deadline < block.timestamp + c.minDuration || deadline > block.timestamp + c.maxDuration) {
            revert BadDeadline();
        }

        id = ++count;
        Task storage task = _tasks[id];
        task.poster = msg.sender;
        task.bounty = bounty;
        task.deadline = deadline;
        task.briefHash = briefHash;
        task.status = Status.Open;
        task.postedAt = uint64(block.timestamp);
        task.feeRecipient = feeRouter;
        task.feeBps = feeRouter == address(0) ? 0 : feeBps;
        task.hireThresholdBps = c.hireThresholdBps;
        task.gradeThresholdBps = c.gradeThresholdBps;
        task.ruleThresholdBps = c.ruleThresholdBps;
        task.gradeWindow = c.gradeWindow;
        task.disputeWindow = c.disputeWindow;
        task.ruleWindow = c.ruleWindow;
        AppealConfig memory a = appealConfig;
        if (a.window != 0) {
            _appeals[id].window = a.window;
            _appeals[id].bondBps = a.bondBps;
        }

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), bounty);
        if (token.balanceOf(address(this)) - before != bounty) revert TransferMismatch();

        emit Posted(id, msg.sender, bounty, deadline, briefHash, briefURI);
    }

    /// @notice The poster raises its own task's grade bar while the task is
    /// still open: work is then paid only when the grade reaches the new bar,
    /// and a ruling needs at least as much to overturn a grade. The bars fixed
    /// when the task was posted are the floor; nothing lowers them.
    function raiseGradeBar(uint256 id, uint16 bps) external {
        Task storage task = _tasks[id];
        if (msg.sender != task.poster) revert NotPoster();
        if (task.status != Status.Open) revert BadStatus();
        if (bps <= task.gradeThresholdBps || bps > 10_000) revert BadThreshold();
        task.gradeThresholdBps = bps;
        if (bps > task.ruleThresholdBps) task.ruleThresholdBps = bps;
        emit GradeBarRaised(id, bps, task.ruleThresholdBps);
    }

    /// @notice Applies a Hire decision. Below threshold, or with no model chosen,
    /// the task stays open for a later round and refunds at its deadline.
    function hire(uint256 id, uint256 decisionId) external nonReentrant {
        if (paused) revert IsPaused();
        Task storage task = _tasks[id];
        if (task.status != Status.Open) revert BadStatus();
        if (block.timestamp >= task.deadline) revert TooLate();
        DecisionLog.Decision memory d = _consume(decisionId, DecisionLog.Kind.Hire, id, task.postedAt);

        if (d.confidenceBps < task.hireThresholdBps || d.answer == bytes32(0)) {
            emit HireHeld(id, decisionId);
            return;
        }
        (address account, bool active) = _worker(d.answer);
        if (!active) revert ModelInactive();

        task.model = d.answer;
        task.status = Status.Hired;
        if (_isStaked(d.answer)) staking.hold(account);
        emit WorkerHired(id, d.answer, decisionId);
    }

    /// @notice The hired model's account delivers. That account is the one paid,
    /// whatever the registry says later.
    function submit(uint256 id, bytes32 resultHash, string calldata resultURI) external {
        Task storage task = _tasks[id];
        if (task.status != Status.Hired) revert BadStatus();
        (address account,) = _worker(task.model);
        if (msg.sender != account) revert NotWorker();
        if (block.timestamp > task.deadline) revert TooLate();

        task.payee = _payeeOf(account);
        task.resultHash = resultHash;
        task.submittedAt = uint64(block.timestamp);
        task.status = Status.Submitted;
        emit WorkSubmitted(id, task.model, resultHash, resultURI);
    }

    /// @notice Applies a Grade decision recorded after the work was submitted.
    /// Work counts as accepted only with a yes at or above the grade threshold.
    /// Settlement waits for the dispute window.
    function grade(uint256 id, uint256 decisionId) external nonReentrant {
        if (paused) revert IsPaused();
        Task storage task = _tasks[id];
        if (task.status != Status.Submitted) revert BadStatus();
        if (block.timestamp > uint256(task.submittedAt) + task.gradeWindow) revert TooLate();
        DecisionLog.Decision memory d = _consume(decisionId, DecisionLog.Kind.Grade, id, task.submittedAt);

        task.accepted = d.answer == YES && d.confidenceBps >= task.gradeThresholdBps;
        task.gradedAt = uint64(block.timestamp);
        task.status = Status.Graded;
        emit WorkGraded(id, decisionId, task.accepted);
    }

    /// @notice The poster or the account that delivered can dispute a grade
    /// once, inside the dispute window.
    function dispute(uint256 id) external {
        Task storage task = _tasks[id];
        if (task.status != Status.Graded || task.disputed) revert BadStatus();
        (address account,) = _worker(task.model);
        if (msg.sender != task.poster && msg.sender != task.payee && msg.sender != account) revert NotDisputant();
        if (block.timestamp > uint256(task.gradedAt) + task.disputeWindow) revert TooLate();

        task.disputed = true;
        task.disputedByModel = msg.sender != task.poster;
        task.disputedAt = uint64(block.timestamp);
        task.status = Status.Disputed;
        emit GradeDisputed(id, msg.sender);
    }

    /// @notice Applies a Ruling decision recorded after the dispute. A confident
    /// ruling decides; below threshold the grade stands, so a dispute alone can
    /// never overturn a grade. Under appeal terms the ruling settles when its
    /// appeal window closes, unless the side it went against appeals.
    function rule(uint256 id, uint256 decisionId) external nonReentrant {
        if (paused) revert IsPaused();
        Task storage task = _tasks[id];
        if (task.status != Status.Disputed) revert BadStatus();
        if (block.timestamp > uint256(task.disputedAt) + task.ruleWindow) revert TooLate();
        DecisionLog.Decision memory d = _consume(decisionId, DecisionLog.Kind.Ruling, id, task.disputedAt);

        bool confident = d.confidenceBps >= task.ruleThresholdBps;
        bool pay = confident ? d.answer == YES : task.accepted;
        emit Ruled(id, decisionId, pay, confident);
        Appeal storage a = _appeals[id];
        // A bond that rounds to nothing would make appeals free, so such a task settles now.
        if (a.window == 0 || _bond(task, a) == 0) {
            _settleRuling(id, task, pay, confident);
            return;
        }
        a.ruledAt = uint64(block.timestamp);
        a.pays = pay;
        a.confident = confident;
        task.status = Status.Ruled;
    }

    /// @notice The side the ruling went against (the poster when it pays, the
    /// account that delivered when it refunds) may appeal once, inside the
    /// appeal window, by posting the bond.
    function appeal(uint256 id) external nonReentrant {
        Task storage task = _tasks[id];
        Appeal storage a = _appeals[id];
        if (task.status != Status.Ruled) revert BadStatus();
        (address account,) = _worker(task.model);
        if (a.pays ? msg.sender != task.poster : (msg.sender != task.payee && msg.sender != account)) {
            revert NotAppellant();
        }
        if (block.timestamp > uint256(a.ruledAt) + a.window) revert TooLate();

        uint128 bond = _bond(task, a);
        a.appellant = msg.sender;
        a.bond = bond;
        a.appealedAt = uint64(block.timestamp);
        task.status = Status.Appealed;

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), bond);
        if (token.balanceOf(address(this)) - before != bond) revert TransferMismatch();
        emit Appealed(id, msg.sender, bond);
    }

    /// @notice Applies the second Ruling, recorded after the appeal, and settles
    /// the task. A confident ruling that differs from the standing one decides
    /// and returns the bond; a confident one that agrees keeps the bond, which
    /// paid for the second look; below threshold the standing ruling settles and
    /// the bond returns.
    function ruleAppeal(uint256 id, uint256 decisionId) external nonReentrant {
        if (paused) revert IsPaused();
        Task storage task = _tasks[id];
        Appeal storage a = _appeals[id];
        if (task.status != Status.Appealed) revert BadStatus();
        if (block.timestamp > uint256(a.appealedAt) + task.ruleWindow) revert TooLate();
        DecisionLog.Decision memory d = _consume(decisionId, DecisionLog.Kind.Ruling, id, a.appealedAt);

        bool confident = d.confidenceBps >= task.ruleThresholdBps;
        bool overturned = confident && (d.answer == YES) != a.pays;
        bool pay = overturned ? !a.pays : a.pays;
        emit AppealRuled(id, decisionId, pay, confident, overturned);
        _settleBond(id, task, a, confident && !overturned);
        _settleRuling(id, task, pay, confident || a.confident);
    }

    /// @notice Settles a task whose next step has run out of time. Anyone can
    /// call it. A grade stands once its dispute window closes, or once a
    /// dispute's ruling window closes without a ruling; every other stalled
    /// state refunds the poster.
    function finalize(uint256 id) external nonReentrant {
        Task storage task = _tasks[id];
        Status status = task.status;

        if (status == Status.Graded) {
            if (block.timestamp <= uint256(task.gradedAt) + task.disputeWindow) revert TooEarly();
            _settle(id, task, task.accepted, RefundReason.Rejected);
        } else if (status == Status.Open || status == Status.Hired) {
            if (block.timestamp <= task.deadline) revert TooEarly();
            _settle(id, task, false, status == Status.Open ? RefundReason.NotHired : RefundReason.NotDelivered);
        } else if (status == Status.Submitted) {
            if (block.timestamp <= uint256(task.submittedAt) + task.gradeWindow) revert TooEarly();
            _settle(id, task, false, RefundReason.NotGraded);
        } else if (status == Status.Disputed) {
            if (block.timestamp <= uint256(task.disputedAt) + task.ruleWindow) revert TooEarly();
            _settle(id, task, task.accepted, RefundReason.Rejected);
        } else if (status == Status.Ruled) {
            Appeal storage a = _appeals[id];
            if (block.timestamp <= uint256(a.ruledAt) + a.window) revert TooEarly();
            _settleRuling(id, task, a.pays, a.confident);
        } else if (status == Status.Appealed) {
            // No second ruling in time: the standing ruling settles and the appellant gets its bond back.
            Appeal storage a = _appeals[id];
            if (block.timestamp <= uint256(a.appealedAt) + task.ruleWindow) revert TooEarly();
            _settleBond(id, task, a, false);
            _settleRuling(id, task, a.pays, a.confident);
        } else {
            revert BadStatus();
        }
    }

    /// @dev A staked worker that disputes and loses the final ruling forfeits part of its stake.
    function _settleRuling(uint256 id, Task storage task, bool pay, bool confident) private {
        _settle(id, task, pay, confident ? RefundReason.RuledForPoster : RefundReason.Rejected);
        if (!pay && task.disputedByModel && _isStaked(task.model)) {
            staking.slash(address(uint160(uint256(task.model))));
        }
    }

    /// @dev A kept bond goes to the task's fee recipient, or to the other side when the task has none.
    function _settleBond(uint256 id, Task storage task, Appeal storage a, bool keep) private {
        address to = a.appellant;
        if (keep) {
            to = task.feeRecipient != address(0) ? task.feeRecipient : (to == task.poster ? task.payee : task.poster);
        }
        uint128 bond = a.bond;
        token.safeTransfer(to, bond);
        emit AppealBondSettled(id, to, bond);
    }

    function _bond(Task storage task, Appeal storage a) private view returns (uint128) {
        return uint128((uint256(task.bounty) * a.bondBps) / 10_000);
    }

    function _settle(uint256 id, Task storage task, bool pay, RefundReason reason) private {
        uint128 bounty = task.bounty;
        task.status = pay ? Status.Paid : Status.Refunded;
        if (_isStaked(task.model)) staking.release(address(uint160(uint256(task.model))));
        if (pay) {
            uint128 fee = uint128((uint256(bounty) * task.feeBps) / 10_000);
            if (fee > 0) {
                token.safeTransfer(task.feeRecipient, fee);
                emit FeeTaken(id, task.feeRecipient, fee);
            }
            token.safeTransfer(task.payee, bounty - fee);
            emit BountyPaid(id, task.model, task.payee, bounty, fee);
        } else {
            token.safeTransfer(task.poster, bounty);
            emit BountyRefunded(id, task.poster, bounty, reason);
        }
    }

    function _isStaked(bytes32 id) private view returns (bool) {
        return address(staking) != address(0) && staking.isWorkerId(id);
    }

    /// @dev House models live in the registry; staked workers are found by
    /// their account-shaped id and must also be allow-listed. A model that is
    /// no longer active can still deliver work it was already hired for.
    /// @dev A worker that takes its pay in stock is paid through the house.
    function _payeeOf(address account) private view returns (address) {
        if (address(payouts) != address(0) && payouts.inStock(account)) return payoutHouse;
        return account;
    }

    function _worker(bytes32 id) private view returns (address account, bool active) {
        if (_isStaked(id)) {
            (account, active,) = staking.worker(id);
            return (account, active && workerAllowed[account]);
        }
        ModelRegistry.Model memory model = models.get(id);
        return (model.account, model.active);
    }

    /// @dev A decision applies only to the task its subject names, only if it
    /// is the latest of its kind for that task, and only if it was recorded
    /// after the event it judges (`notBefore`).
    function _consume(uint256 decisionId, DecisionLog.Kind kind, uint256 id, uint64 notBefore)
        private
        returns (DecisionLog.Decision memory d)
    {
        if (msg.sender != decisions.brain()) revert NotBrain();
        if (decisionUsed[decisionId]) revert DecisionUsed();
        d = decisions.get(decisionId);
        bytes32 subject = subjectOf(id);
        if (d.kind != kind || d.subject != subject || d.recordedAt < notBefore) revert BadDecision();
        if (decisions.latestOf(subject, kind) != decisionId) revert StaleDecision();
        decisionUsed[decisionId] = true;
    }

    function get(uint256 id) external view returns (Task memory) {
        return _tasks[id];
    }

    function appealOf(uint256 id) external view returns (Appeal memory) {
        return _appeals[id];
    }

    /// @notice The bond an appeal of task `id` takes, under the terms it was posted with.
    function appealBond(uint256 id) external view returns (uint128) {
        return _bond(_tasks[id], _appeals[id]);
    }

    function setConfig(Config calldata config_) external {
        if (msg.sender != owner) revert NotOwner();
        _setConfig(config_);
    }

    /// @notice Sets the appeal window and bond for tasks posted from now on. A
    /// zero window turns appeals off; otherwise the bond is between 1 bp and the bounty.
    function setAppealConfig(AppealConfig calldata config_) external {
        if (msg.sender != owner) revert NotOwner();
        if (config_.window > MAX_WINDOW || config_.bondBps > 10_000 || (config_.window != 0 && config_.bondBps == 0)) {
            revert BadConfig();
        }
        appealConfig = config_;
        emit AppealConfigSet(config_);
    }

    /// @notice The guardian can stop new posts and every decision the brain
    /// would apply. Delivery, disputes and settlement keep working, so work in
    /// flight settles by its windows and no bounty is stuck.
    function setPaused(bool paused_) external {
        if (msg.sender != guardian && msg.sender != owner) revert NotGuardian();
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setOwner(address owner_) external {
        if (msg.sender != owner) revert NotOwner();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    /// @notice Sets the protocol fee on bounties posted from now on, capped at 10%.
    /// @notice The payout preferences the board reads at delivery, and the house paid in a worker's place.
    function setPayouts(PayoutPreferences payouts_, address house_) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(payouts_) != address(0) && house_ == address(0)) revert BadPayouts();
        payouts = payouts_;
        payoutHouse = house_;
        emit PayoutsSet(address(payouts_), house_);
    }

    function setFee(uint16 feeBps_, address feeRouter_) external {
        if (msg.sender != owner) revert NotOwner();
        if (feeBps_ > MAX_FEE_BPS || (feeBps_ > 0 && feeRouter_ == address(0))) revert BadFee();
        feeBps = feeBps_;
        feeRouter = feeRouter_;
        emit FeeSet(feeBps_, feeRouter_);
    }

    function setGuardian(address guardian_) external {
        if (msg.sender != owner) revert NotOwner();
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setWorkerAllowed(address account, bool allowed) external {
        if (msg.sender != owner) revert NotOwner();
        if (account == address(0)) revert ZeroAddress();
        workerAllowed[account] = allowed;
        emit WorkerAllowedSet(account, allowed);
    }

    function _setConfig(Config memory c) private {
        if (
            c.hireThresholdBps > 10_000 || c.gradeThresholdBps > 10_000 || c.ruleThresholdBps > 10_000
                || c.minDuration == 0 || c.minDuration >= c.maxDuration || c.maxDuration > MAX_DURATION
                || c.gradeWindow == 0 || c.gradeWindow > MAX_WINDOW || c.disputeWindow == 0
                || c.disputeWindow > MAX_WINDOW || c.ruleWindow == 0 || c.ruleWindow > MAX_WINDOW || c.minBounty == 0
        ) revert BadConfig();
        config = c;
        emit ConfigSet(c);
    }
}
