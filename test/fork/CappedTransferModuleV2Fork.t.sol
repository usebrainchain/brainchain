// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CappedTransferModuleV2, ISafeModuleExec} from "../../src/safe/CappedTransferModuleV2.sol";

interface ISafe141 {
    function VERSION() external view returns (string memory);
    function enableModule(address module) external;
    function disableModule(address prevModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);
}

/// Runs the module against the real treasury Safe on Robinhood Chain: ETH to the gas keeper at the caps the autopilot
/// plan sets, and USDG to the desk. Skips unless the RPC is set:
///   ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path test/fork/CappedTransferModuleV2Fork.t.sol -vv
contract CappedTransferModuleV2ForkTest is Test {
    address constant SAFE = 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant OPERATOR = 0x70C665780E43BA1496a4E691e408F24844dB58eC;
    address constant GAS_KEEPER = 0x183db433a7526d3faaD8ba799C87Cf18d9D6896A;
    address constant DESK = 0x97D558417c3D61f1074422AD843e1Db1E565b952;
    address constant SAFE_OWNER = 0x8D4b5d7E287ddf83C440a19b2DD6037F58723660;

    function test_ethToTheGasKeeper() public {
        _run(address(0), GAS_KEEPER, 0.008 ether);
    }

    function test_usdgToTheDesk() public {
        _run(USDG, DESK, 3e6);
    }

    function _held(address token, address account) private view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    function _run(address token, address to, uint128 daily) private {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        ISafe141 safe = ISafe141(SAFE);
        assertEq(safe.VERSION(), "1.4.1");
        uint256 safeBefore = _held(token, SAFE);
        assertGe(safeBefore, 13 * uint256(daily), "the Safe holds a window and a day of the caps");
        uint256 toBefore = _held(token, to);

        CappedTransferModuleV2 module = new CappedTransferModuleV2(ISafeModuleExec(SAFE), token, OPERATOR);
        vm.startPrank(SAFE);
        module.setRecipient(to);
        module.setCaps(daily, 12 * daily);
        safe.enableModule(address(module));
        vm.stopPrank();
        assertTrue(safe.isModuleEnabled(address(module)));

        uint256 part = daily * 5 / 8;
        vm.prank(OPERATOR);
        module.send(part);
        assertEq(_held(token, to), toBefore + part);
        assertEq(_held(token, SAFE), safeBefore - part);

        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(CappedTransferModuleV2.OverDailyCap.selector, daily - part + 1, daily - part)
        );
        module.send(daily - part + 1);
        vm.prank(OPERATOR);
        module.send(daily - part);
        assertEq(module.left(), 0);

        _refusesEveryoneElse(module, safe, token, to);
        address next = _fillTheWindowAndRotate(module, daily);
        assertEq(_held(token, SAFE), safeBefore - 13 * uint256(daily));
        assertEq(_held(token, to), toBefore + 13 * uint256(daily));

        vm.prank(SAFE);
        safe.disableModule(address(1), address(module));
        vm.warp(block.timestamp + 1 days);
        vm.prank(next);
        vm.expectRevert("GS104");
        module.send(1);
    }

    function _refusesEveryoneElse(CappedTransferModuleV2 module, ISafe141 safe, address token, address to) private {
        // Another recipient: the module takes none, only the Safe may change it, and the Safe refuses the
        // operator as a module of its own.
        address other = makeAddr("other");
        vm.startPrank(OPERATOR);
        (bool ok,) = address(module).call(abi.encodeWithSignature("send(address,uint256)", other, 1));
        assertFalse(ok);
        vm.expectRevert(CappedTransferModuleV2.NotSafe.selector);
        module.setRecipient(other);
        vm.expectRevert(CappedTransferModuleV2.NotSafe.selector);
        module.setOperator(other);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(other, 1, "", 0);
        vm.stopPrank();
        assertEq(_held(token, other), 0);

        address[3] memory others = [makeAddr("stranger"), SAFE_OWNER, to];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(CappedTransferModuleV2.NotOperator.selector);
            module.send(1);
        }
    }

    /// Eleven more days at the daily cap fill the window, and the next day only the window refuses. Thirty days on,
    /// the first day has left it. The Safe then rotates the operator, and the old key is refused from then on.
    function _fillTheWindowAndRotate(CappedTransferModuleV2 module, uint128 daily) private returns (address next) {
        uint256 start = block.timestamp;
        for (uint256 day = 1; day < 12; day++) {
            vm.warp(start + day * 1 days);
            vm.prank(OPERATOR);
            module.send(daily);
        }
        assertEq(module.spentInWindow(), 12 * uint256(daily));
        vm.warp(start + 12 days);
        assertEq(module.leftToday(), daily);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModuleV2.OverWindowCap.selector, 1, 0));
        module.send(1);

        vm.warp(start + 30 days);
        assertEq(module.leftInWindow(), daily);
        next = makeAddr("next operator");
        vm.prank(SAFE);
        module.setOperator(next);
        vm.prank(OPERATOR);
        vm.expectRevert(CappedTransferModuleV2.NotOperator.selector);
        module.send(1);
        vm.prank(next);
        module.send(daily);
    }
}
