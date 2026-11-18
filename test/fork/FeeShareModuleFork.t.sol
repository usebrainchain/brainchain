// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISafeModuleCall} from "../../src/safe/CappedTransferModule.sol";
import {FeeShareModule, IFeeLedger, IPairLock} from "../../src/safe/FeeShareModule.sol";

interface ISafeModules {
    function VERSION() external view returns (string memory);
    function enableModule(address module) external;
    function disableModule(address prevModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
}

interface IHook is IFeeLedger {
    function owed(address token, address account) external view returns (uint256);
    function claimFor(address token, address account) external returns (uint256);
}

interface IIncome {
    function distribute() external;
}

interface ILock is IPairLock {
    function MAIN_POOL() external view returns (bytes32);
    function POOL_MANAGER() external view returns (address);
    function POSITION_MANAGER() external view returns (address);
    function totalEthPaired() external view returns (uint256);
    function referenceTick() external view returns (int24);
    function setReference(int24 tick) external;
}

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IOwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// Runs the module against the real owners' Safe, fee hook, income contract and pair-and-lock contract of $BRAIN on
/// Robinhood Chain. Skips unless its RPC is set:
///   ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path test/fork/FeeShareModuleFork.t.sol -vv
contract FeeShareModuleForkTest is Test {
    address constant SAFE = 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d;
    address constant HOOK = 0xBA7401628167fbcd8f9db9F6ad2dDA72aB41EAcc;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant INCOME = 0xeb1b4168D4b87D3d9F0D64E13B7071251BBB63b7;
    address constant LOCK = 0x870B0BFB24aF2C06180FbEe266117305e0B0E00F;
    address constant OPERATOR = 0x70C665780E43BA1496a4E691e408F24844dB58eC;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant SENTINEL = address(1);
    uint256 constant DUE = 0.02 ether;
    int24 constant MAX_DRIFT = 6_932;

    function test_passesTheShareAndLocksIt() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(ISafeModules(SAFE).VERSION(), "1.4.1");

        // What the market owes is claimed and forwarded first, as the hourly sweep does.
        if (IHook(HOOK).owed(WETH, INCOME) != 0) {
            IHook(HOOK).claimFor(WETH, INCOME);
            IIncome(INCOME).distribute();
        }
        uint256 share = IHook(HOOK).claimed(WETH, INCOME) / 6;
        assertGt(share, DUE, "the market has paid out more than the test passes");

        // As if all of the share but DUE had been passed by hand.
        FeeShareModule module = new FeeShareModule(
            ISafeModuleCall(SAFE), IFeeLedger(HOOK), WETH, INCOME, IPairLock(LOCK), OPERATOR, 1, 6, share - DUE
        );
        assertEq(module.due(), DUE);

        (uint160 price, int24 tick) = _market();
        vm.startPrank(SAFE);
        int256 drift = int256(tick) - int256(ILock(LOCK).referenceTick());
        if (drift > MAX_DRIFT || drift < -MAX_DRIFT) ILock(LOCK).setReference(tick);
        ISafeModules(SAFE).enableModule(address(module));
        vm.stopPrank();
        uint160 low = price - price / 200;
        uint160 high = price + price / 200;

        vm.expectRevert(FeeShareModule.NotOperator.selector);
        module.passAndPair(low, high);

        uint256 safeBefore = SAFE.balance;
        uint256 pairedBefore = ILock(LOCK).totalEthPaired();

        // Bounds the market is outside of: the lock refuses, and the share stays in the Safe.
        vm.prank(OPERATOR);
        vm.expectPartialRevert(FeeShareModule.PairFailed.selector);
        module.passAndPair(high, high + 1);
        assertEq(SAFE.balance, safeBefore);
        assertEq(module.due(), DUE);

        vm.prank(OPERATOR);
        (uint256 amount, uint256 tokenId) = module.passAndPair(low, high);

        assertEq(amount, DUE);
        assertEq(SAFE.balance, safeBefore - DUE, "the Safe paid exactly the share");
        assertApproxEqAbs(ILock(LOCK).totalEthPaired() - pairedBefore, DUE, 1e12, "and the lock paired it");
        assertEq(IOwnerOf(ILock(LOCK).POSITION_MANAGER()).ownerOf(tokenId), DEAD, "in a position nobody owns");
        assertEq(LOCK.balance, 0);
        assertEq(module.due(), 0);

        vm.prank(OPERATOR);
        vm.expectRevert(FeeShareModule.NothingDue.selector);
        module.passAndPair(low, high);

        vm.prank(SAFE);
        ISafeModules(SAFE).disableModule(SENTINEL, address(module));
        assertFalse(ISafeModules(SAFE).isModuleEnabled(address(module)));
    }

    /// The market's sqrt price and tick, read from the pool manager's storage as v4's StateLibrary does.
    function _market() private view returns (uint160 price, int24 tick) {
        bytes32 slot = keccak256(abi.encodePacked(ILock(LOCK).MAIN_POOL(), bytes32(uint256(6))));
        bytes32 data = IExtsload(ILock(LOCK).POOL_MANAGER()).extsload(slot);
        price = uint160(uint256(data));
        tick = int24(int256(uint256(data) >> 160));
    }
}
