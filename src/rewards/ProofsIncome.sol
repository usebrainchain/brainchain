// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

interface IWETH is IERC20 {
    function withdraw(uint256 amount) external;
}

interface IProofs {
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The payee of the $BRAIN launch on ripples.run. The launch treasury
/// pays its creator income here in WETH; anyone may then distribute it:
/// unwrapped and split between the holders of BrainChain Proofs, the fee
/// splitter and the treasury. The holders' share is cut into equal parts, one
/// per Proof minted by then, and each part waits here until that Proof's holder
/// claims it. Proofs are minted in sequence and never burned, so a Proof takes
/// part in every distribution from the first one that counted it, and a claim
/// is one binary search however many distributions have passed. The owner can
/// change the split and the two targets; what holders were allotted can never
/// be taken back. The Proofs collection is created by the launch, after this
/// contract, so the deployer binds it once.
contract ProofsIncome {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error TransferFailed();
    error NotOwner();
    error NotPendingOwner();
    error NotDeployer();
    error ProofsSet();
    error NoProofs();
    error BadProofs();
    error BadShares();
    error TooLittle();
    error NotSweepable();

    event ProofsBound(address indexed proofs);
    event Distributed(uint256 indexed rounds, uint256 perProof, uint256 proofs, uint256 toSplitter, uint256 toTreasury);
    event Claimed(uint256 indexed tokenId, address indexed to, uint256 amount);
    event SharesSet(uint16 holdersBps, uint16 splitterBps);
    event TargetsSet(address indexed splitter, address indexed treasury);
    event MinRoundSet(uint256 minRound);
    event TokenSwept(address indexed token, uint256 amount);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    /// @dev One distribution. `cumulative` is the sum of every round's per-Proof
    /// amount through this one, so a claim is a difference of two entries.
    struct Round {
        uint128 cumulative;
        uint128 proofs;
    }

    uint16 public constant BPS = 10_000;

    IWETH public immutable weth;
    address public immutable deployer;

    IProofs public proofs;
    address public owner;
    address public pendingOwner;
    address public splitter;
    address public treasury;
    uint16 public holdersBps;
    uint16 public splitterBps;
    /// @notice The least amount a distribution splits, so rounds stay worth their gas.
    uint256 public minRound;
    /// @notice ETH allotted to Proof holders and not yet claimed.
    uint256 public reserved;
    /// @notice Rounds a Proof has been paid through.
    mapping(uint256 => uint256) public claimedThrough;

    Round[] private _rounds;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IWETH weth_,
        address splitter_,
        address treasury_,
        address owner_,
        uint16 holdersBps_,
        uint16 splitterBps_,
        uint256 minRound_
    ) {
        if (address(weth_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        weth = weth_;
        deployer = msg.sender;
        owner = owner_;
        _setTargets(splitter_, treasury_);
        _setShares(holdersBps_, splitterBps_);
        minRound = minRound_;
        emit OwnerSet(owner_);
        emit MinRoundSet(minRound_);
    }

    receive() external payable {}

    /// @notice Binds the Proofs collection, once. It must be an ERC-721 that counts its pieces.
    function bindProofs(IProofs proofs_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(proofs) != address(0)) revert ProofsSet();
        if (address(proofs_) == address(0)) revert ZeroAddress();
        if (!ERC165Checker.supportsInterface(address(proofs_), 0x80ac58cd)) revert BadProofs();
        proofs_.totalSupply();
        proofs = proofs_;
        emit ProofsBound(address(proofs_));
    }

    function rounds() external view returns (uint256) {
        return _rounds.length;
    }

    function round(uint256 index) external view returns (Round memory) {
        return _rounds[index];
    }

    /// @notice What the next distribution splits: everything held, in WETH or
    /// ETH, that is not allotted to holders.
    function undistributed() public view returns (uint256) {
        return weth.balanceOf(address(this)) + address(this).balance - reserved;
    }

    /// @notice Anyone may call this. Unwraps the WETH held, cuts the holders'
    /// share into one part per Proof and sends the rest to the splitter and the
    /// treasury. Rounding dust, and the holders' share while no Proof exists,
    /// goes to the treasury.
    function distribute() external {
        if (address(proofs) == address(0)) revert NoProofs();
        uint256 held = weth.balanceOf(address(this));
        if (held > 0) weth.withdraw(held);
        uint256 amount = address(this).balance - reserved;
        if (amount == 0 || amount < minRound) revert TooLittle();

        uint256 count = proofs.totalSupply();
        uint256 toSplitter = amount * splitterBps / BPS;
        uint256 perProof = count == 0 ? 0 : amount * holdersBps / BPS / count;
        uint256 kept = perProof * count;
        uint256 toTreasury = amount - kept - toSplitter;

        if (kept > 0) {
            uint256 n = _rounds.length;
            uint128 last = n == 0 ? 0 : _rounds[n - 1].cumulative;
            _rounds.push(Round(last + uint128(perProof), uint128(count)));
            reserved += kept;
        }
        if (toSplitter > 0) _send(splitter, toSplitter);
        if (toTreasury > 0) _send(treasury, toTreasury);
        emit Distributed(_rounds.length, perProof, count, toSplitter, toTreasury);
    }

    /// @notice What a Proof's holder can claim.
    function due(uint256 tokenId) public view returns (uint256) {
        uint256 n = _rounds.length;
        uint256 start = _firstRound(tokenId);
        if (claimedThrough[tokenId] > start) start = claimedThrough[tokenId];
        if (start >= n) return 0;
        return _rounds[n - 1].cumulative - (start == 0 ? 0 : _rounds[start - 1].cumulative);
    }

    /// @notice Pays a Proof's due to whoever holds it now. Anyone may call this.
    function claim(uint256 tokenId) external {
        _claim(tokenId);
    }

    function claimMany(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _claim(tokenIds[i]);
        }
    }

    function setShares(uint16 holdersBps_, uint16 splitterBps_) external onlyOwner {
        _setShares(holdersBps_, splitterBps_);
    }

    function setTargets(address splitter_, address treasury_) external onlyOwner {
        _setTargets(splitter_, treasury_);
    }

    function setMinRound(uint256 minRound_) external onlyOwner {
        minRound = minRound_;
        emit MinRoundSet(minRound_);
    }

    /// @notice Sends this contract's whole balance of a stray token to the
    /// treasury. Anyone may call this. The WETH is income and is distributed.
    function sweepToken(IERC20 token) external {
        if (address(token) == address(weth)) revert NotSweepable();
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) return;
        token.safeTransfer(treasury, amount);
        emit TokenSwept(address(token), amount);
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

    function _claim(uint256 tokenId) private {
        address to = proofs.ownerOf(tokenId);
        uint256 amount = due(tokenId);
        claimedThrough[tokenId] = _rounds.length;
        if (amount == 0) return;
        reserved -= amount;
        _send(to, amount);
        emit Claimed(tokenId, to, amount);
    }

    /// @dev The first round that counted this Proof. Counts never fall, so the
    /// rounds that include a Proof are a suffix and a binary search finds it.
    function _firstRound(uint256 tokenId) private view returns (uint256) {
        uint256 lo = 0;
        uint256 hi = _rounds.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_rounds[mid].proofs >= tokenId) hi = mid;
            else lo = mid + 1;
        }
        return lo;
    }

    function _setShares(uint16 holdersBps_, uint16 splitterBps_) private {
        if (uint256(holdersBps_) + splitterBps_ > BPS) revert BadShares();
        holdersBps = holdersBps_;
        splitterBps = splitterBps_;
        emit SharesSet(holdersBps_, splitterBps_);
    }

    function _setTargets(address splitter_, address treasury_) private {
        if (splitter_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        splitter = splitter_;
        treasury = treasury_;
        emit TargetsSet(splitter_, treasury_);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
