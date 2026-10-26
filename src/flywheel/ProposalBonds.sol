// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DecisionLog} from "../DecisionLog.sol";

interface IChangeThreshold {
    function changeThresholdBps() external view returns (uint16);
    function changeSubject(address target, bytes calldata data) external view returns (bytes32);
}

/// @notice Anyone can propose a chain change by bonding $BRAIN. When Jev
/// decides, the bond is returned if the change was adopted above the change
/// threshold and burned otherwise. Only Jev's latest decision on the call
/// settles a proposal, and each decision settles one proposal. A proposal Jev
/// never decides on is returned after the decision window.
contract ProposalBonds is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum State {
        None,
        Open,
        Returned,
        Burned
    }

    struct Proposal {
        address proposer;
        uint128 bond;
        uint64 createdAt;
        State state;
        bytes32 subject;
    }

    error NotOwner();
    error ZeroAddress();
    error BadState();
    error BadDecision();
    error StaleDecision();
    error DecisionUsed();
    error TooEarly();
    error BadConfig();

    event Proposed(
        uint256 indexed id, address indexed proposer, address indexed target, bytes data, uint128 bond, string uri
    );
    event Settled(uint256 indexed id, uint256 indexed decisionId, bool adopted);
    event Expired(uint256 indexed id);
    event ConfigSet(uint128 bond, uint64 decideWithin);

    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    bytes32 private constant YES = bytes32(uint256(1));

    IERC20 public immutable token;
    DecisionLog public immutable decisions;
    IChangeThreshold public immutable executor;
    address public owner;
    uint128 public bond;
    uint64 public decideWithin;

    uint256 public count;
    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => bool) public decisionUsed;

    constructor(
        IERC20 token_,
        DecisionLog decisions_,
        IChangeThreshold executor_,
        address owner_,
        uint128 bond_,
        uint64 decideWithin_
    ) {
        if (
            address(token_) == address(0) || address(decisions_) == address(0) || address(executor_) == address(0)
                || owner_ == address(0)
        ) {
            revert ZeroAddress();
        }
        token = token_;
        decisions = decisions_;
        executor = executor_;
        owner = owner_;
        _setConfig(bond_, decideWithin_);
    }

    /// @notice Proposes the exact call `target.data` and bonds the current bond.
    function propose(address target, bytes calldata data, string calldata uri)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (target == address(0)) revert ZeroAddress();
        id = ++count;
        uint128 amount = bond;
        _proposals[id] =
            Proposal(msg.sender, amount, uint64(block.timestamp), State.Open, executor.changeSubject(target, data));
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Proposed(id, msg.sender, target, data, amount, uri);
    }

    /// @notice Settles a proposal on Jev's recorded change decision. Anyone can call it.
    function settle(uint256 id, uint256 decisionId) external nonReentrant {
        Proposal storage p = _proposals[id];
        if (p.state != State.Open) revert BadState();
        if (decisionUsed[decisionId]) revert DecisionUsed();
        DecisionLog.Decision memory d = decisions.get(decisionId);
        if (d.kind != DecisionLog.Kind.Change || d.subject != p.subject || d.recordedAt < p.createdAt) {
            revert BadDecision();
        }
        if (decisions.latestOf(p.subject, DecisionLog.Kind.Change) != decisionId) revert StaleDecision();
        decisionUsed[decisionId] = true;

        bool adopted = d.answer == YES && d.confidenceBps >= executor.changeThresholdBps();
        p.state = adopted ? State.Returned : State.Burned;
        token.safeTransfer(adopted ? p.proposer : BURN, p.bond);
        emit Settled(id, decisionId, adopted);
    }

    /// @notice Returns the bond of a proposal Jev did not decide on in time.
    function expire(uint256 id) external nonReentrant {
        Proposal storage p = _proposals[id];
        if (p.state != State.Open) revert BadState();
        if (block.timestamp <= uint256(p.createdAt) + decideWithin) revert TooEarly();
        p.state = State.Returned;
        token.safeTransfer(p.proposer, p.bond);
        emit Expired(id);
    }

    function get(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function setConfig(uint128 bond_, uint64 decideWithin_) external {
        if (msg.sender != owner) revert NotOwner();
        _setConfig(bond_, decideWithin_);
    }

    function _setConfig(uint128 bond_, uint64 decideWithin_) private {
        if (bond_ == 0 || decideWithin_ == 0) revert BadConfig();
        bond = bond_;
        decideWithin = decideWithin_;
        emit ConfigSet(bond_, decideWithin_);
    }
}
