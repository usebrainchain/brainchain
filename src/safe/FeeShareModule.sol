// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISafeModuleCall} from "./CappedTransferModule.sol";

interface IFeeLedger {
    /// What the ledger has paid out to `account` in `token`, in total.
    function claimed(address token, address account) external view returns (uint256);
}

interface IPairLock {
    function owner() external view returns (address);
    function pair(uint160 minPrice, uint160 maxPrice) external returns (uint256 tokenId);
}

/// @notice A Safe module with one power: the operator has the Safe pass on its share of a market's fee income to a
/// lock contract, which pairs it there and then. The share is a fixed fraction of what the market's fee ledger has
/// paid out to the income account, less what was passed on before, so the module can never move more than that and
/// never to anywhere else. The Safe, the ledger, the lock, the fraction and the operator are fixed at deployment.
/// The Safe ends it by disabling the module.
contract FeeShareModule {
    uint8 private constant CALL = 0;

    ISafeModuleCall public immutable SAFE;
    IFeeLedger public immutable LEDGER;
    address public immutable FEE_TOKEN;
    address public immutable INCOME;
    IPairLock public immutable LOCK;
    address public immutable OPERATOR;
    uint256 public immutable SHARE_NUMERATOR;
    uint256 public immutable SHARE_DENOMINATOR;

    /// Native token passed to the lock so far, counting what the Safe sent by hand before this module.
    uint256 public passed;

    event Passed(uint256 amount, uint256 passedTotal, uint256 tokenId);

    error ZeroAddress();
    error NotAContract(address account);
    error BadShare();
    error NotLockOwner(address owner);
    error SafeIsOperator();
    error NotOperator();
    error NothingDue();
    error TransferFailed();
    error PairFailed(bytes reason);

    /// @param passedBefore What the Safe passed to the lock by hand before this module, so it is not passed twice.
    constructor(
        ISafeModuleCall safe,
        IFeeLedger ledger,
        address feeToken,
        address income,
        IPairLock lock,
        address operator,
        uint256 shareNumerator,
        uint256 shareDenominator,
        uint256 passedBefore
    ) {
        if (feeToken == address(0) || income == address(0) || operator == address(0)) {
            revert ZeroAddress();
        }
        if (address(safe).code.length == 0) revert NotAContract(address(safe));
        if (address(ledger).code.length == 0) revert NotAContract(address(ledger));
        if (address(lock).code.length == 0) revert NotAContract(address(lock));
        if (shareNumerator == 0 || shareNumerator > shareDenominator) revert BadShare();
        if (operator == address(safe)) revert SafeIsOperator();
        // The Safe calls `pair` as the lock's owner. A lock it does not own would take the share and pair nothing.
        if (lock.owner() != address(safe)) revert NotLockOwner(lock.owner());
        SAFE = safe;
        LEDGER = ledger;
        FEE_TOKEN = feeToken;
        INCOME = income;
        LOCK = lock;
        OPERATOR = operator;
        SHARE_NUMERATOR = shareNumerator;
        SHARE_DENOMINATOR = shareDenominator;
        passed = passedBefore;
    }

    /// @notice The share of everything the ledger has paid out so far.
    function earned() public view returns (uint256) {
        return LEDGER.claimed(FEE_TOKEN, INCOME) * SHARE_NUMERATOR / SHARE_DENOMINATOR;
    }

    /// @notice The share not yet passed to the lock.
    function due() public view returns (uint256) {
        uint256 total = earned();
        return total > passed ? total - passed : 0;
    }

    /// @notice Sends what is due from the Safe to the lock and pairs it at once. If the lock refuses to pair, for a
    /// price outside the bounds or a market that has drifted, nothing moves.
    /// @param minPrice The lowest sqrtPriceX96 the operator accepts, passed to the lock with `maxPrice`.
    function passAndPair(uint160 minPrice, uint160 maxPrice) external returns (uint256 amount, uint256 tokenId) {
        if (msg.sender != OPERATOR) revert NotOperator();
        amount = due();
        if (amount == 0) revert NothingDue();
        uint256 total = passed + amount;
        passed = total;

        (bool ok,) = SAFE.execTransactionFromModuleReturnData(address(LOCK), amount, "", CALL);
        if (!ok) revert TransferFailed();
        bytes memory returned;
        (ok, returned) = SAFE.execTransactionFromModuleReturnData(
            address(LOCK), 0, abi.encodeCall(IPairLock.pair, (minPrice, maxPrice)), CALL
        );
        if (!ok) revert PairFailed(returned);
        tokenId = abi.decode(returned, (uint256));
        emit Passed(amount, total, tokenId);
    }
}
