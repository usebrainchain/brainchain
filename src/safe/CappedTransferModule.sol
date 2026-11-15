// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISafeModuleCall {
    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData);
}

/// @notice A Safe module with one power: the operator sends the token from the Safe to the recipient, up to a daily
/// cap. The Safe, the token and the operator are fixed at deployment. Only the Safe sets the recipient and the cap.
/// A day is a UTC day. A lower cap applies at once, to what is left of the current day as well.
contract CappedTransferModule {
    uint8 private constant CALL = 0;

    ISafeModuleCall public immutable SAFE;
    IERC20 public immutable TOKEN;
    address public immutable OPERATOR;

    address public recipient;
    uint256 public cap;
    uint256 public day;
    uint256 public spent;

    event Sent(address indexed recipient, uint256 amount, uint256 spentToday, uint256 cap);
    event RecipientSet(address indexed recipient);
    event CapSet(uint256 cap);

    error ZeroAddress();
    error NotAToken(address token);
    error NotSafe();
    error NotOperator();
    error NoRecipient();
    error ZeroAmount();
    error OverCap(uint256 amount, uint256 left);
    error TransferFailed();

    modifier onlySafe() {
        if (msg.sender != address(SAFE)) revert NotSafe();
        _;
    }

    constructor(ISafeModuleCall safe, IERC20 token, address operator) {
        if (address(safe) == address(0) || operator == address(0)) revert ZeroAddress();
        // A token without code would make every transfer look successful.
        if (address(token).code.length == 0) revert NotAToken(address(token));
        SAFE = safe;
        TOKEN = token;
        OPERATOR = operator;
    }

    function setRecipient(address recipient_) external onlySafe {
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    function setCap(uint256 cap_) external onlySafe {
        cap = cap_;
        emit CapSet(cap_);
    }

    function spentToday() public view returns (uint256) {
        return day == block.timestamp / 1 days ? spent : 0;
    }

    function left() public view returns (uint256) {
        uint256 used = spentToday();
        return cap > used ? cap - used : 0;
    }

    function send(uint256 amount) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        if (amount == 0) revert ZeroAmount();
        address to = recipient;
        if (to == address(0)) revert NoRecipient();
        uint256 available = left();
        if (amount > available) revert OverCap(amount, available);

        uint256 total = spentToday() + amount;
        day = block.timestamp / 1 days;
        spent = total;
        emit Sent(to, amount, total, cap);

        (bool ok, bytes memory returned) = SAFE.execTransactionFromModuleReturnData(
            address(TOKEN), 0, abi.encodeCall(IERC20.transfer, (to, amount)), CALL
        );
        if (!ok || (returned.length != 0 && !abi.decode(returned, (bool)))) revert TransferFailed();
    }
}
