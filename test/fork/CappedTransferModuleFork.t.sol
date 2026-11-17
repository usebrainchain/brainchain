// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CappedTransferModule, ISafeModuleCall} from "../../src/safe/CappedTransferModule.sol";

interface ISafe141 {
    function VERSION() external view returns (string memory);
    function enableModule(address module) external;
    function disableModule(address prevModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success);
}

/// Runs the module against the real treasury Safe on Robinhood Chain and the real admin Safe on BrainChain, each
/// with its own USDG. Each test skips unless its RPC is set:
///   ROBINHOOD_RPC=https://rpc.mainnet.chain.robinhood.com BRAINCHAIN_RPC=https://rpc.usebrainchain.com \
///     forge test --match-path test/fork/CappedTransferModuleFork.t.sol -vv
contract CappedTransferModuleForkTest is Test {
    address constant OPERATOR = 0x70C665780E43BA1496a4E691e408F24844dB58eC;
    address constant DESK = 0x97D558417c3D61f1074422AD843e1Db1E565b952;
    address constant SAFE_OWNER = 0x8D4b5d7E287ddf83C440a19b2DD6037F58723660;
    uint256 constant CAP = 10e6;

    function test_robinhoodTreasurySafe() public {
        _run("ROBINHOOD_RPC", 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    }

    function test_brainchainAdminSafe() public {
        _run("BRAINCHAIN_RPC", 0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c, 0x8eBFEce96c0AeF7Fd23425D846a302a552c8c451);
    }

    function _run(string memory rpcVar, address safeAddress, address token) private {
        string memory rpc = vm.envOr(rpcVar, string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        ISafe141 safe = ISafe141(safeAddress);
        IERC20 usdg = IERC20(token);
        assertEq(safe.VERSION(), "1.4.1");
        uint256 safeBefore = usdg.balanceOf(safeAddress);
        assertGe(safeBefore, 2 * CAP, "the Safe holds two days of the cap");
        uint256 deskBefore = usdg.balanceOf(DESK);

        CappedTransferModule module = new CappedTransferModule(ISafeModuleCall(safeAddress), usdg, OPERATOR);
        vm.startPrank(safeAddress);
        module.setRecipient(DESK);
        module.setCap(CAP);
        safe.enableModule(address(module));
        vm.stopPrank();
        assertTrue(safe.isModuleEnabled(address(module)));

        vm.prank(OPERATOR);
        module.send(6e6);
        assertEq(usdg.balanceOf(DESK), deskBefore + 6e6);
        assertEq(usdg.balanceOf(safeAddress), safeBefore - 6e6);

        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(CappedTransferModule.OverCap.selector, 5e6, 4e6));
        module.send(5e6);

        vm.prank(OPERATOR);
        module.send(4e6);
        assertEq(module.left(), 0);

        // Another recipient: the module takes none, only the Safe may change it, and the Safe refuses the
        // operator as a module of its own.
        address other = makeAddr("other");
        vm.prank(OPERATOR);
        (bool ok,) = address(module).call(abi.encodeWithSignature("send(address,uint256)", other, 1e6));
        assertFalse(ok);
        vm.prank(OPERATOR);
        vm.expectRevert(CappedTransferModule.NotSafe.selector);
        module.setRecipient(other);
        vm.prank(OPERATOR);
        vm.expectRevert("GS104");
        safe.execTransactionFromModule(address(usdg), 0, abi.encodeCall(IERC20.transfer, (other, 1e6)), 0);
        assertEq(usdg.balanceOf(other), 0);

        address[3] memory others = [makeAddr("stranger"), SAFE_OWNER, DESK];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(CappedTransferModule.NotOperator.selector);
            module.send(1e6);
        }

        vm.warp(block.timestamp + 1 days);
        vm.prank(OPERATOR);
        module.send(CAP);
        assertEq(usdg.balanceOf(safeAddress), safeBefore - 2 * CAP);
        assertEq(usdg.balanceOf(DESK), deskBefore + 2 * CAP);

        vm.prank(safeAddress);
        safe.disableModule(address(1), address(module));
        vm.warp(block.timestamp + 1 days);
        vm.prank(OPERATOR);
        vm.expectRevert("GS104");
        module.send(1e6);
    }
}
