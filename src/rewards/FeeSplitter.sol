// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFeeEscrow {
    function claim() external returns (uint256);
    function claimToken(address token) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

interface IPonsCurve {
    function sweepFees(uint256 minBuybackTokensOut) external;
    function graduated() external view returns (bool);
    function deployer() external view returns (address);
    function feeEscrow() external view returns (address);
    function token() external view returns (address);
    function factory() external view returns (address);
}

interface IPonsFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function setBuybackEnabled(address token, bool enabled) external;
}

/// @notice Creator fee recipient for $BRAIN on Pons. Claims the accrued ETH
/// from the Pons fee escrow and splits it in half: one half to the reward
/// distributor, the other to the treasury. The split and both recipients are
/// fixed at deployment. Any ERC-20 that reaches this contract or its escrow
/// balance (an ERC-20 pair, buyback releases, rescued pool fees) goes to the
/// treasury. Pons only lets the fee recipient sweep a curve's fees into the
/// escrow, so this contract does that too, for the one curve the deployer
/// binds after launch. The owner can hand the fee stream to a new recipient,
/// or change the launch's buyback setting, three days after announcing it.
contract FeeSplitter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error TransferFailed();
    error NotDeployer();
    error NotOwner();
    error NotPendingOwner();
    error CurveSet();
    error NoCurve();
    error BadCurve();
    error NothingPending();
    error NotReady();

    event Split(uint256 toRewards, uint256 toTreasury);
    event CurveBound(address indexed curve, address indexed token, address indexed factory);
    event SweepFailed(bytes reason);
    event TokenSwept(address indexed token, uint256 amount);
    event RecipientChangeProposed(address indexed newRecipient, uint64 eta);
    event RecipientChanged(address indexed newRecipient);
    event BuybackChangeProposed(bool enabled, uint64 eta);
    event BuybackChanged(bool enabled);
    event PendingCancelled();
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    uint64 public constant DELAY = 3 days;

    IFeeEscrow public immutable escrow;
    address public immutable rewards;
    address public immutable treasury;
    address public immutable deployer;

    address public owner;
    address public pendingOwner;
    IPonsCurve public curve;
    address public launchToken;
    IPonsFactory public factory;

    address public pendingRecipient;
    uint64 public recipientEta;
    bool public pendingBuyback;
    uint64 public buybackEta;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IFeeEscrow escrow_, address rewards_, address treasury_, address owner_) {
        if (address(escrow_) == address(0) || rewards_ == address(0) || treasury_ == address(0) || owner_ == address(0))
        {
            revert ZeroAddress();
        }
        escrow = escrow_;
        rewards = rewards_;
        treasury = treasury_;
        owner = owner_;
        deployer = msg.sender;
        emit OwnerSet(owner_);
    }

    receive() external payable {}

    /// @notice Binds the $BRAIN bonding curve, once. The curve is created by the
    /// launch, after this contract exists, and must name this contract as its
    /// fee recipient and credit the same escrow.
    function bindCurve(IPonsCurve curve_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(curve) != address(0)) revert CurveSet();
        if (address(curve_) == address(0)) revert ZeroAddress();
        if (curve_.deployer() != address(this) || curve_.feeEscrow() != address(escrow)) revert BadCurve();
        address token_ = curve_.token();
        address factory_ = curve_.factory();
        if (token_ == address(0) || factory_ == address(0)) revert BadCurve();
        curve = curve_;
        launchToken = token_;
        factory = IPonsFactory(factory_);
        emit CurveBound(address(curve_), token_, factory_);
    }

    /// @notice Anyone may call this. Sweeps the curve's fees into the escrow
    /// while the curve trades, claims what the escrow holds for this contract,
    /// and splits it. A failed sweep is reported, not hidden; a failed claim
    /// reverts so a keeper with too little gas cannot skip it silently.
    function claimAndSplit() external {
        if (address(curve) != address(0) && !curve.graduated()) {
            try curve.sweepFees(0) {}
            catch (bytes memory reason) {
                emit SweepFailed(reason);
            }
        }
        if (escrow.balanceOf(address(this)) > 0) escrow.claim();
        split();
    }

    /// @notice Splits ETH already held, for example when the escrow was claimed directly.
    function split() public {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        uint256 toRewards = balance / 2;
        uint256 toTreasury = balance - toRewards;
        _send(rewards, toRewards);
        _send(treasury, toTreasury);
        emit Split(toRewards, toTreasury);
    }

    /// @notice Claims this contract's escrow balance of `token` and sends it,
    /// with anything already held, to the treasury. Anyone may call this.
    function claimToken(address token) external {
        if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
        sweepToken(IERC20(token));
    }

    /// @notice Sends this contract's whole balance of `token` to the treasury. Anyone may call this.
    function sweepToken(IERC20 token) public {
        uint256 amount = token.balanceOf(address(this));
        if (amount == 0) return;
        token.safeTransfer(treasury, amount);
        emit TokenSwept(address(token), amount);
    }

    function proposeRecipient(address newRecipient) external onlyOwner {
        if (address(curve) == address(0)) revert NoCurve();
        if (newRecipient == address(0)) revert ZeroAddress();
        pendingRecipient = newRecipient;
        recipientEta = uint64(block.timestamp) + DELAY;
        emit RecipientChangeProposed(newRecipient, recipientEta);
    }

    /// @notice Hands future creator fees to the announced recipient. Fees
    /// already in the escrow for this contract can still be claimed here.
    function executeRecipient() external onlyOwner {
        address newRecipient = pendingRecipient;
        if (newRecipient == address(0)) revert NothingPending();
        if (block.timestamp < recipientEta) revert NotReady();
        pendingRecipient = address(0);
        recipientEta = 0;
        factory.transferCreatorFeeRecipient(launchToken, newRecipient);
        emit RecipientChanged(newRecipient);
    }

    function proposeBuyback(bool enabled) external onlyOwner {
        if (address(curve) == address(0)) revert NoCurve();
        pendingBuyback = enabled;
        buybackEta = uint64(block.timestamp) + DELAY;
        emit BuybackChangeProposed(enabled, buybackEta);
    }

    function executeBuyback() external onlyOwner {
        if (buybackEta == 0) revert NothingPending();
        if (block.timestamp < buybackEta) revert NotReady();
        bool enabled = pendingBuyback;
        buybackEta = 0;
        pendingBuyback = false;
        factory.setBuybackEnabled(launchToken, enabled);
        emit BuybackChanged(enabled);
    }

    function cancelPending() external onlyOwner {
        pendingRecipient = address(0);
        recipientEta = 0;
        pendingBuyback = false;
        buybackEta = 0;
        emit PendingCancelled();
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

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
