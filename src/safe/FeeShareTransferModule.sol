// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISafeModuleExec} from "./CappedTransferModuleV2.sol";
import {IFeeLedger} from "./FeeShareModule.sol";

/// @notice A Safe module with one power: the operator has the Safe send native token to a fixed recipient, up to a
/// fixed fraction of what a market's fee ledger has paid out to the income account since the module was deployed,
/// less what the recipient has taken before. The recipient is the buyback wallet, which buys the token on its market
/// and locks it. The Safe, the ledger, the recipient, the fraction and the operator are fixed at deployment. The Safe
/// ends it at any time by disabling the module.
///
/// The module holds no funds and has no owner, setter, upgrade path or self-destruct, so nothing in it can keep the
/// Safe from disabling it. Other numbers take a new module, which the Safe enables in place of this one.
///
/// The share is counted on the ledger's payouts, in the fee token, and paid from the Safe in native token, one for
/// one: the fee token is the wrapped native token. It is due once the ledger has paid out, whether or not the income
/// account has forwarded its part to the Safe yet. The operator and the recipient may be one key: the operator can
/// only ever pay the recipient, so a key holding both can do nothing the operator alone could not.
contract FeeShareTransferModule {
    uint8 private constant CALL = 0;

    ISafeModuleExec public immutable SAFE;
    IFeeLedger public immutable LEDGER;
    address public immutable FEE_TOKEN;
    address public immutable INCOME;
    address public immutable RECIPIENT;
    address public immutable OPERATOR;
    uint256 public immutable SHARE_NUMERATOR;
    uint256 public immutable SHARE_DENOMINATOR;
    /// @notice What the ledger had paid out to the income account at deployment, which earns this module nothing.
    uint256 public immutable BASELINE;

    /// Native token sent to the recipient so far.
    uint256 public taken;

    event Taken(uint256 amount, uint256 takenTotal);

    error ZeroAddress();
    error NotAContract(address account);
    error BadShare();
    error SafeIsOperator();
    error SafeIsRecipient();
    error NotOperator();
    error ZeroAmount();
    error OverDue(uint256 amount, uint256 due);
    error TransferFailed();

    constructor(
        ISafeModuleExec safe,
        IFeeLedger ledger,
        address feeToken,
        address income,
        address recipient,
        address operator,
        uint256 shareNumerator,
        uint256 shareDenominator
    ) {
        if (feeToken == address(0) || income == address(0) || recipient == address(0) || operator == address(0)) {
            revert ZeroAddress();
        }
        if (address(safe).code.length == 0) revert NotAContract(address(safe));
        if (address(ledger).code.length == 0) revert NotAContract(address(ledger));
        if (shareNumerator == 0 || shareNumerator > shareDenominator) revert BadShare();
        if (operator == address(safe)) revert SafeIsOperator();
        // A send to itself would count as taken while nothing left the Safe.
        if (recipient == address(safe)) revert SafeIsRecipient();
        SAFE = safe;
        LEDGER = ledger;
        FEE_TOKEN = feeToken;
        INCOME = income;
        RECIPIENT = recipient;
        OPERATOR = operator;
        SHARE_NUMERATOR = shareNumerator;
        SHARE_DENOMINATOR = shareDenominator;
        BASELINE = ledger.claimed(feeToken, income);
    }

    /// @notice The share of everything the ledger has paid out since deployment.
    function earned() public view returns (uint256) {
        uint256 claimed = LEDGER.claimed(FEE_TOKEN, INCOME);
        if (claimed <= BASELINE) return 0;
        return (claimed - BASELINE) * SHARE_NUMERATOR / SHARE_DENOMINATOR;
    }

    /// @notice The share the recipient has not taken yet.
    function due() public view returns (uint256) {
        uint256 total = earned();
        return total > taken ? total - taken : 0;
    }

    /// @notice Has the Safe send `amount` of native token to the recipient, up to what is due.
    function take(uint256 amount) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        if (amount == 0) revert ZeroAmount();
        uint256 left = due();
        if (amount > left) revert OverDue(amount, left);
        uint256 total = taken + amount;
        taken = total;

        if (!SAFE.execTransactionFromModule(RECIPIENT, amount, "", CALL)) revert TransferFailed();
        emit Taken(amount, total);
    }
}
