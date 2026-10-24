// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeEscrow {
    function claim() external;
}

interface IPonsCurve {
    function sweepFees(uint256 minAmount) external;
}

/// @notice Creator fee recipient for $BRAIN on Pons. Claims the accrued ETH
/// from the Pons fee escrow and splits it in half: one half to the reward
/// distributor, the other to the treasury. The split and both recipients are
/// fixed at deployment; nobody can change them. Pons only lets the fee
/// recipient sweep a curve's fees into the escrow, so this contract does that
/// too, for the one curve the deployer binds after launch.
contract FeeSplitter {
    error ZeroAddress();
    error TransferFailed();
    error NotDeployer();
    error CurveSet();

    event Split(uint256 toRewards, uint256 toTreasury);
    event CurveBound(address curve);

    IFeeEscrow public immutable escrow;
    address public immutable rewards;
    address public immutable treasury;
    address public immutable deployer;
    IPonsCurve public curve;

    constructor(IFeeEscrow escrow_, address rewards_, address treasury_) {
        if (address(escrow_) == address(0) || rewards_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        rewards = rewards_;
        treasury = treasury_;
        deployer = msg.sender;
    }

    receive() external payable {}

    /// @notice Binds the $BRAIN bonding curve, once. The curve is created by the
    /// launch, after this contract exists.
    function bindCurve(IPonsCurve curve_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(curve) != address(0)) revert CurveSet();
        if (address(curve_) == address(0)) revert ZeroAddress();
        curve = curve_;
        emit CurveBound(address(curve_));
    }

    /// @notice Anyone may call this. Sweeps the curve's fees into the escrow,
    /// claims what the escrow holds for this contract, and splits it. Either
    /// step finding nothing is not an error.
    function claimAndSplit() external {
        if (address(curve) != address(0)) {
            try curve.sweepFees(0) {} catch {}
        }
        try escrow.claim() {} catch {}
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

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
