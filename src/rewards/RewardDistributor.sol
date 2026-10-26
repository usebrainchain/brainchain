// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Weekly ETH rewards for accepted work on BrainChain mainnet. The
/// publisher posts one Merkle root per round, allocating ETH the contract
/// already holds; each address claims its own share. Claims open
/// `CLAIM_DELAY` after publishing, which gives the owner time to revoke a bad
/// round, and close `CLAIM_WINDOW` after publishing. A round can never pay out
/// more than its total, so a wrong or stolen root cannot reach other rounds.
contract RewardDistributor {
    error NotOwner();
    error NotPendingOwner();
    error NotPublisher();
    error ZeroAddress();
    error EmptyRound();
    error OverAllocated();
    error OverClaimed();
    error UnknownRound();
    error AlreadyClaimed();
    error BadProof();
    error RoundClosed();
    error TooEarly();
    error TooLate();
    error TransferFailed();

    event Published(uint256 indexed round, bytes32 root, uint256 total, string uri);
    event Claimed(uint256 indexed round, address indexed account, uint256 amount);
    event Revoked(uint256 indexed round, uint256 returned);
    event Expired(uint256 indexed round, uint256 returned);
    event PublisherSet(address indexed publisher);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    struct Round {
        bytes32 root;
        uint128 total;
        uint128 claimed;
        uint64 publishedAt;
        bool expired;
        bool revoked;
    }

    uint256 public constant CLAIM_DELAY = 24 hours;
    uint256 public constant CLAIM_WINDOW = 12 weeks;

    address public owner;
    address public pendingOwner;
    address public publisher;
    uint256 public rounds;
    /// @notice ETH allocated to open rounds and not yet claimed.
    uint256 public outstanding;

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => bool)) public claimed;

    constructor(address owner_, address publisher_) {
        if (owner_ == address(0) || publisher_ == address(0)) revert ZeroAddress();
        owner = owner_;
        publisher = publisher_;
        emit OwnerSet(owner_);
        emit PublisherSet(publisher_);
    }

    receive() external payable {}

    /// @notice ETH that the next round can allocate.
    function available() public view returns (uint256) {
        return address(this).balance - outstanding;
    }

    function getRound(uint256 round) external view returns (Round memory) {
        return _rounds[round];
    }

    /// @notice Publishes a round. Leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))`,
    /// and `uri` points to the full list so anyone can rebuild the root.
    function publish(bytes32 root, uint256 total, string calldata uri) external returns (uint256 round) {
        if (msg.sender != publisher) revert NotPublisher();
        if (root == bytes32(0) || total == 0) revert EmptyRound();
        if (total > available()) revert OverAllocated();
        round = ++rounds;
        _rounds[round] = Round({
            root: root,
            total: uint128(total),
            claimed: 0,
            publishedAt: uint64(block.timestamp),
            expired: false,
            revoked: false
        });
        outstanding += total;
        emit Published(round, root, total, uri);
    }

    /// @notice Pays `account` its share of `round`. Anyone may submit the claim; the ETH always goes to `account`.
    function claim(uint256 round, address account, uint256 amount, bytes32[] calldata proof) external {
        Round storage r = _rounds[round];
        if (r.root == bytes32(0)) revert UnknownRound();
        if (r.expired || r.revoked) revert RoundClosed();
        if (block.timestamp < uint256(r.publishedAt) + CLAIM_DELAY) revert TooEarly();
        if (block.timestamp >= uint256(r.publishedAt) + CLAIM_WINDOW) revert TooLate();
        if (claimed[round][account]) revert AlreadyClaimed();
        if (uint256(r.claimed) + amount > r.total) revert OverClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, r.root, leaf)) revert BadProof();

        claimed[round][account] = true;
        r.claimed += uint128(amount);
        outstanding -= amount;
        (bool ok,) = account.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(round, account, amount);
    }

    /// @notice Cancels a round before its claims open and returns its total to the pool.
    function revoke(uint256 round) external {
        if (msg.sender != owner) revert NotOwner();
        Round storage r = _rounds[round];
        if (r.root == bytes32(0)) revert UnknownRound();
        if (r.expired || r.revoked) revert RoundClosed();
        if (block.timestamp >= uint256(r.publishedAt) + CLAIM_DELAY) revert TooLate();
        r.revoked = true;
        outstanding -= r.total;
        emit Revoked(round, r.total);
    }

    /// @notice Returns a round's unclaimed remainder to the pool once its claim window has passed. Anyone may call.
    function expire(uint256 round) external {
        Round storage r = _rounds[round];
        if (r.root == bytes32(0)) revert UnknownRound();
        if (r.expired || r.revoked) revert RoundClosed();
        if (block.timestamp < uint256(r.publishedAt) + CLAIM_WINDOW) revert TooEarly();
        r.expired = true;
        uint256 remainder = r.total - r.claimed;
        outstanding -= remainder;
        emit Expired(round, remainder);
    }

    function setPublisher(address publisher_) external {
        if (msg.sender != owner) revert NotOwner();
        if (publisher_ == address(0)) revert ZeroAddress();
        publisher = publisher_;
        emit PublisherSet(publisher_);
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
