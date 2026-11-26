// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISafeModuleExec} from "../../src/safe/CappedTransferModuleV2.sol";
import {FeeShareModule, IFeeLedger} from "../../src/safe/FeeShareModule.sol";
import {FeeShareTransferModule} from "../../src/safe/FeeShareTransferModule.sol";

interface ISafe141 {
    function VERSION() external view returns (string memory);
    function enableModule(address module) external;
    function disableModule(address prevModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

interface IHook is IFeeLedger {
    function owed(address token, address account) external view returns (uint256);
    function claimFor(address token, address account) external returns (uint256);
}

interface IIncome {
    function minRound() external view returns (uint256);
    function treasury() external view returns (address);
    function undistributed() external view returns (uint256);
    function distribute() external;
}

interface ILock {
    function MAIN_POOL() external view returns (bytes32);
    function POOL_MANAGER() external view returns (address);
    function POSITION_MANAGER() external view returns (address);
    function lockedKey() external view returns (PoolKey memory);
    function MAX_DRIFT() external view returns (int24);
    function referenceTick() external view returns (int24);
    function setReference(int24 tick) external;
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IPositionManager {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}

/// Buys the market's token with WETH through the pool manager, so the market's hook charges its fees as on any trade.
contract Buyer {
    uint160 constant MIN_PRICE_LIMIT = 4295128740;

    IPoolManager immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buy(PoolKey memory key, uint256 amountIn) external {
        manager.unlock(abi.encode(key, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        int256 delta = manager.swap(key, SwapParams(true, -int256(amountIn), MIN_PRICE_LIMIT), "");
        int128 paid = int128(delta >> 128);
        int128 got = int128(delta);
        manager.sync(key.currency0);
        IWETH(key.currency0).transfer(address(manager), uint256(uint128(-paid)));
        manager.settle();
        if (got > 0) manager.take(key.currency1, address(this), uint256(uint128(got)));
        return "";
    }
}

/// Runs the module against the real treasury Safe on Robinhood Chain, beside the live FeeShareModule, on the ledger,
/// fee token and income account that module reads. Fees come from a real trade on the $BRAIN market, which the hook
/// charges and pays out to the income account, which forwards them to the Safe. Skips unless its RPC is set:
///   ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path test/fork/FeeShareTransferModuleFork.t.sol -vv
contract FeeShareTransferModuleForkTest is Test {
    address constant SAFE = 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d;
    FeeShareModule constant LIVE = FeeShareModule(0xFD268Ae2c1Ec0Db03C3C6b17E1AEDE973729FE29);
    address constant SENTINEL = address(1);
    // Small enough that the market stays within the lock's gap to its own pool, as arbitrage keeps it.
    uint256 constant TRADE = 0.05 ether;

    ISafe141 safe = ISafe141(SAFE);
    address job = makeAddr("buyback job");

    function test_takesTheShareOfNewPayoutsBesideTheLiveModule() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        assertEq(safe.VERSION(), "1.4.1");
        assertEq(address(LIVE.SAFE()), SAFE);

        IHook hook = IHook(address(LIVE.LEDGER()));
        address weth = LIVE.FEE_TOKEN();
        address income = LIVE.INCOME();
        assertEq(IIncome(income).treasury(), SAFE, "the income account pays the Safe");

        // What the market owes now was earned before the module and is paid out first, as the hourly sweep does.
        if (hook.owed(weth, income) != 0) hook.claimFor(weth, income);
        uint256 baseline = hook.claimed(weth, income);

        FeeShareTransferModule module =
            new FeeShareTransferModule(ISafeModuleExec(SAFE), IFeeLedger(address(hook)), weth, income, job, job, 5, 12);
        assertEq(module.BASELINE(), baseline);
        assertEq(module.due(), 0, "nothing paid out before deployment counts");
        vm.prank(SAFE);
        safe.enableModule(address(module));
        assertTrue(safe.isModuleEnabled(address(module)));

        uint256 paidOut = _tradeAndPayOut(hook, weth, income);
        uint256 share = paidOut * 5 / 12;
        assertGt(share, 0);
        assertEq(module.earned(), share);
        assertEq(module.due(), share);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeShareTransferModule.NotOperator.selector);
        module.take(share);
        vm.prank(job);
        vm.expectRevert(abi.encodeWithSelector(FeeShareTransferModule.OverDue.selector, share + 1, share));
        module.take(share + 1);

        uint256 liveDue = LIVE.due();
        uint256 safeBefore = SAFE.balance;
        uint256 jobBefore = job.balance;
        vm.prank(job);
        module.take(share);
        assertEq(job.balance - jobBefore, share, "the recipient got exactly the share");
        assertEq(safeBefore - SAFE.balance, share, "and the Safe paid exactly that");
        assertEq(module.due(), 0);
        assertEq(LIVE.due(), liveDue, "the live module's due is untouched");

        _liveModuleStillPasses();
        _theSafeEndsItAndEnablesAnother(module, hook, weth, income);
    }

    /// A trade on the market charges the hook's fees, the hook pays them out to the income account, and the income
    /// account forwards them to the Safe in native token.
    function _tradeAndPayOut(IHook hook, address weth, address income) private returns (uint256 paidOut) {
        ILock lock = ILock(address(LIVE.LOCK()));
        PoolKey memory key = IPositionManager(lock.POSITION_MANAGER()).poolKeys(bytes25(lock.MAIN_POOL()));
        assertEq(key.currency0, weth);
        assertEq(key.hooks, address(hook));

        Buyer buyer = new Buyer(IPoolManager(lock.POOL_MANAGER()));
        vm.deal(address(this), TRADE);
        IWETH(weth).deposit{value: TRADE}();
        IWETH(weth).transfer(address(buyer), TRADE);
        uint256 claimedBefore = hook.claimed(weth, income);
        buyer.buy(key, TRADE);
        uint256 owed = hook.owed(weth, income);
        assertGt(owed, 0, "the trade was charged a fee for the income account");

        // The income account may still hold a payout under its smallest round, which it forwards with this one.
        uint256 waiting = IIncome(income).undistributed();
        hook.claimFor(weth, income);
        paidOut = hook.claimed(weth, income) - claimedBefore;
        assertEq(paidOut, owed);
        assertEq(IIncome(income).undistributed(), waiting + paidOut);
        uint256 safeBefore = SAFE.balance;
        if (waiting + paidOut >= IIncome(income).minRound()) {
            IIncome(income).distribute();
            assertEq(SAFE.balance - safeBefore, waiting + paidOut, "the Safe got it in native token, one for one");
        }
    }

    /// The lock checks the bounds against the market and against the pool it pairs in, so they span both.
    function _liveModuleStillPasses() private {
        uint256 due = LIVE.due();
        assertGt(due, 0);
        ILock lock = ILock(address(LIVE.LOCK()));
        (uint160 market, int24 tick) = _slot0(lock, lock.MAIN_POOL());
        (uint160 locked,) = _slot0(lock, keccak256(abi.encode(lock.lockedKey())));
        int256 drift = int256(tick) - int256(lock.referenceTick());
        if (drift > lock.MAX_DRIFT() || drift < -lock.MAX_DRIFT()) {
            vm.prank(SAFE);
            lock.setReference(tick);
        }
        uint160 low = market < locked ? market : locked;
        uint160 high = market < locked ? locked : market;

        uint256 safeBefore = SAFE.balance;
        vm.prank(LIVE.OPERATOR());
        (uint256 amount,) = LIVE.passAndPair(low - low / 200, high + high / 200);
        assertEq(amount, due);
        assertEq(safeBefore - SAFE.balance, due, "the live module still passes its own share");
        assertEq(LIVE.due(), 0);
    }

    /// A pool's sqrt price and tick, read from the pool manager's storage as v4's StateLibrary does.
    function _slot0(ILock lock, bytes32 pool) private view returns (uint160 price, int24 tick) {
        bytes32 data =
            IPoolManager(lock.POOL_MANAGER()).extsload(keccak256(abi.encodePacked(pool, bytes32(uint256(6)))));
        price = uint160(uint256(data));
        tick = int24(int256(uint256(data) >> 160));
    }

    /// Disabled by the Safe, the module moves nothing however much is due. A replacement with other numbers counts
    /// from its own deployment.
    function _theSafeEndsItAndEnablesAnother(FeeShareTransferModule module, IHook hook, address weth, address income)
        private
    {
        address prev = _previous(address(module));
        vm.prank(SAFE);
        safe.disableModule(prev, address(module));
        assertFalse(safe.isModuleEnabled(address(module)));
        assertTrue(safe.isModuleEnabled(address(LIVE)), "the live module stays enabled");

        _tradeAndPayOut(hook, weth, income);
        uint256 due = module.due();
        assertGt(due, 0);
        uint256 safeBefore = SAFE.balance;
        vm.prank(job);
        vm.expectRevert("GS104");
        module.take(due);
        assertEq(SAFE.balance, safeBefore, "nothing moved");
        assertEq(module.due(), due);

        address next = makeAddr("next buyback job");
        FeeShareTransferModule replacement = new FeeShareTransferModule(
            ISafeModuleExec(SAFE), IFeeLedger(address(hook)), weth, income, next, next, 1, 4
        );
        vm.prank(SAFE);
        safe.enableModule(address(replacement));
        assertEq(replacement.due(), 0, "the replacement counts only what is paid out after it");

        uint256 paidOut = _tradeAndPayOut(hook, weth, income);
        assertEq(replacement.due(), paidOut / 4);
        safeBefore = SAFE.balance;
        vm.prank(next);
        replacement.take(paidOut / 4);
        assertEq(next.balance, paidOut / 4);
        assertEq(safeBefore - SAFE.balance, paidOut / 4);
    }

    function _previous(address module) private view returns (address prev) {
        (address[] memory modules,) = safe.getModulesPaginated(SENTINEL, 50);
        prev = SENTINEL;
        for (uint256 i; i < modules.length; i++) {
            if (modules[i] == module) return prev;
            prev = modules[i];
        }
        revert("not enabled");
    }
}
