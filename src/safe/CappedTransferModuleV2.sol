// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISafeModuleCall} from "./CappedTransferModule.sol";

interface ISafeModuleExec is ISafeModuleCall {
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);
}

/// @notice A Safe module with one power: the operator sends one asset from the Safe to the recipient, up to a cap per
/// UTC day and a cap over the last 30 UTC days. The asset is an ERC-20, or native ETH when the token is the zero
/// address. The Safe and the asset are fixed at deployment. Only the Safe sets the recipient and the caps, and only the
/// Safe replaces the operator, so a leaked operator key is rotated without a new module. Days are calendar days: across
/// midnight the operator can send up to twice the daily cap within seconds, and any 30 days of real time see at most
/// the 30-day cap plus one daily cap. A lower cap applies at once, to what is left of the day and of the window.
contract CappedTransferModuleV2 {
    // The 30-day window is a ring of one bucket per UTC day, slot `day % 30`, beside a running total of the window.
    // Each bucket carries its day, so a slot last written 30 or more days ago reads as empty and is never cleared. The
    // total is exact as of the day of the last send; bringing it to a later day subtracts the buckets that left the
    // window in between, at most 29 reads, and none at all after a gap of 30 days or more. With sends every day the one
    // bucket that leaves is the one being overwritten, so a send writes two slots to keep both caps. The window is
    // exact to the UTC day, like the daily cap, and storage stays at 31 slots. A log of every send would be exact to
    // the second but grow without bound; a decaying total is cheap but not exact.
    struct Bucket {
        uint32 day;
        uint224 spent;
    }

    uint8 private constant CALL = 0;
    uint256 public constant WINDOW_DAYS = 30;

    ISafeModuleExec public immutable SAFE;
    /// @notice The asset sent: an ERC-20, or native ETH when this is the zero address.
    address public immutable TOKEN;

    address public operator;
    bool private _sending;
    address public recipient;
    // Caps fit 128 bits, so a day's or a window's total always fits its 224-bit field.
    uint128 public dailyCap;
    uint128 public windowCap;

    Bucket[WINDOW_DAYS] private _buckets;
    uint32 private _totalDay;
    uint224 private _total;

    event Sent(address indexed recipient, uint256 amount, uint256 spentToday, uint256 spentInWindow);
    event RecipientSet(address indexed recipient);
    event CapsSet(uint256 dailyCap, uint256 windowCap);
    event OperatorSet(address indexed operator);

    error ZeroAddress();
    error NotASafe(address safe);
    error NotAToken(address token);
    error SafeIsToken();
    error SafeIsOperator();
    error NotSafe();
    error NotOperator();
    error Reentered();
    error NoRecipient();
    error ZeroAmount();
    error OverDailyCap(uint256 amount, uint256 left);
    error OverWindowCap(uint256 amount, uint256 left);
    error TransferFailed();

    modifier onlySafe() {
        if (msg.sender != address(SAFE)) revert NotSafe();
        _;
    }

    /// @param token The ERC-20 to send, or the zero address for native ETH.
    constructor(ISafeModuleExec safe, address token, address operator_) {
        if (address(safe) == address(0) || operator_ == address(0)) revert ZeroAddress();
        if (address(safe).code.length == 0) revert NotASafe(address(safe));
        // A token without code would make every transfer look successful.
        if (token != address(0) && token.code.length == 0) revert NotAToken(token);
        if (token == address(safe)) revert SafeIsToken();
        if (operator_ == address(safe)) revert SafeIsOperator();
        SAFE = safe;
        TOKEN = token;
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setRecipient(address recipient_) external onlySafe {
        if (recipient_ == address(0)) revert ZeroAddress();
        recipient = recipient_;
        emit RecipientSet(recipient_);
    }

    function setCaps(uint128 dailyCap_, uint128 windowCap_) external onlySafe {
        dailyCap = dailyCap_;
        windowCap = windowCap_;
        emit CapsSet(dailyCap_, windowCap_);
    }

    /// @notice Replaces the operator. What the old one sent still counts against both caps.
    function setOperator(address operator_) external onlySafe {
        if (operator_ == address(0)) revert ZeroAddress();
        if (operator_ == address(SAFE)) revert SafeIsOperator();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function spentToday() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        Bucket memory bucket = _buckets[today % WINDOW_DAYS];
        return bucket.day == today ? bucket.spent : 0;
    }

    /// @notice What was sent on the current UTC day and the 29 before it.
    function spentInWindow() public view returns (uint256) {
        return _totalOn(block.timestamp / 1 days);
    }

    function leftToday() public view returns (uint256) {
        return _room(dailyCap, spentToday());
    }

    function leftInWindow() public view returns (uint256) {
        return _room(windowCap, spentInWindow());
    }

    /// @notice The most the operator can send now: the lesser of what is left today and in the window.
    function left() external view returns (uint256) {
        uint256 day = leftToday();
        uint256 window = leftInWindow();
        return day < window ? day : window;
    }

    function send(uint256 amount) external {
        if (msg.sender != operator) revert NotOperator();
        if (_sending) revert Reentered();
        if (amount == 0) revert ZeroAmount();
        address to = recipient;
        if (to == address(0)) revert NoRecipient();

        uint256 today = block.timestamp / 1 days;
        Bucket memory bucket = _buckets[today % WINDOW_DAYS];
        uint256 day = bucket.day == today ? bucket.spent : 0;
        uint256 window = _totalOn(today);
        uint256 room = _room(dailyCap, day);
        if (amount > room) revert OverDailyCap(amount, room);
        room = _room(windowCap, window);
        if (amount > room) revert OverWindowCap(amount, room);

        day += amount;
        window += amount;
        _buckets[today % WINDOW_DAYS] = Bucket(uint32(today), uint224(day));
        (_totalDay, _total) = (uint32(today), uint224(window));
        _sending = true;
        emit Sent(to, amount, day, window);

        bool ok;
        if (TOKEN == address(0)) {
            ok = SAFE.execTransactionFromModule(to, amount, "", CALL);
        } else {
            bytes memory returned;
            (ok, returned) =
                SAFE.execTransactionFromModuleReturnData(TOKEN, 0, abi.encodeCall(IERC20.transfer, (to, amount)), CALL);
            ok = ok && (returned.length == 0 || abi.decode(returned, (bool)));
        }
        if (!ok) revert TransferFailed();
        _sending = false;
    }

    function _totalOn(uint256 today) private view returns (uint256 total) {
        uint256 last = _totalDay;
        if (today >= last + WINDOW_DAYS) return 0;
        total = _total;
        for (uint256 d = last + 1; d <= today; ++d) {
            Bucket memory bucket = _buckets[d % WINDOW_DAYS];
            if (bucket.day + WINDOW_DAYS == d) total -= bucket.spent;
        }
    }

    function _room(uint256 cap, uint256 used) private pure returns (uint256) {
        return cap > used ? cap - used : 0;
    }
}
