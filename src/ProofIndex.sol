// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ProofIndex
/// @notice Which BrainChain Proof stands for which task, kept on Robinhood
/// Chain next to the Proofs collection. Tasks live on the BrainChain task
/// board (chain `BOARD_CHAIN_ID`); a paid task's Proof is minted in
/// `COLLECTION` and the operator, the same key that records every decision,
/// writes its token id here when the Proof is revealed. An entry is written
/// once and can never be changed or removed.
///
/// Shipped settles delivery bonds on BrainChain tasks from this index. Its
/// `StaticCallCheck` (`0x2e7C4F0F2e6079C3B5F7Cd2440308234CBDc537D` on chain
/// 4663) calls `proofOf(taskId)` and treats a value of 1 or more as delivered.
/// Shipped accepts only check state that cannot be created and undone within
/// one transaction; an entry here cannot be undone at all.
contract ProofIndex {
    error ZeroAddress();
    error ZeroToken();
    error AlreadySet();
    error NotOwner();
    error NotOperator();
    error NotPendingOwner();

    event ProofSet(uint256 indexed taskId, uint256 indexed tokenId);
    event OperatorSet(address indexed operator);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    /// @notice The Proofs collection the token ids belong to.
    address public immutable COLLECTION;
    /// @notice The chain whose task board the task ids belong to.
    uint256 public immutable BOARD_CHAIN_ID;

    address public owner;
    address public pendingOwner;
    address public operator;
    /// @notice The Proof token id of a task, zero until its Proof is revealed.
    mapping(uint256 taskId => uint256 tokenId) public proofOf;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(address owner_, address operator_, address collection_, uint256 boardChainId_) {
        if (owner_ == address(0) || operator_ == address(0) || collection_ == address(0)) revert ZeroAddress();
        COLLECTION = collection_;
        BOARD_CHAIN_ID = boardChainId_;
        owner = owner_;
        operator = operator_;
        emit OwnerSet(owner_);
        emit OperatorSet(operator_);
    }

    /// @notice Records the Proof of a task, once.
    function setProof(uint256 taskId, uint256 tokenId) external onlyOperator {
        if (tokenId == 0) revert ZeroToken();
        if (proofOf[taskId] != 0) revert AlreadySet();
        proofOf[taskId] = tokenId;
        emit ProofSet(taskId, tokenId);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function transferOwnership(address pendingOwner_) external onlyOwner {
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
