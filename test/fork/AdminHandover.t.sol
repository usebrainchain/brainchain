// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {AdminHandover, IArbOwner, IUpgradeExecutor} from "../../script/AdminHandover.s.sol";

interface IRoles {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// Replays the UpgradeExecutor half of the handover on forks of BrainChain and
/// Robinhood Chain. ArbOwner is an Arbitrum precompile that forks cannot run,
/// so steps 1 and 3 are checked by their calldata. Each test skips unless its
/// RPC is set (BRAINCHAIN_RPC or ROBINHOOD_RPC).
contract AdminHandoverForkTest is Test {
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    address constant DEPLOYER = 0x8D4b5d7E287ddf83C440a19b2DD6037F58723660;
    address constant L3_EXECUTOR = 0xf5B096ddE063311CaEC2F9665ef3E94eAb1280bA;
    address constant ROLLUP_EXECUTOR = 0x12c59492BB508EFDb6c5D43F2aA907d8B55524D6;

    AdminHandover handover;
    address timelock = makeAddr("timelock");

    function _send(address from, address to, bytes memory data) private {
        vm.prank(from);
        (bool ok, bytes memory reason) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function test_l3ExecutorRolesMove() public {
        string memory rpc = vm.envOr("BRAINCHAIN_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        // Mainnet has already been handed over, and the RPC keeps no history to fork from before it.
        if (!IRoles(L3_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER)) vm.skip(true);
        handover = new AdminHandover();
        bytes[4] memory calls = handover.l3Calls(L3_EXECUTOR, timelock, DEPLOYER);
        assertEq(calls[0], abi.encodeCall(IArbOwner.addChainOwner, (L3_EXECUTOR)));
        assertEq(
            calls[2],
            abi.encodeCall(
                IUpgradeExecutor.executeCall, (address(0x70), abi.encodeCall(IArbOwner.removeChainOwner, (DEPLOYER)))
            )
        );
        assertTrue(IRoles(L3_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER));

        _send(DEPLOYER, L3_EXECUTOR, calls[1]);
        _send(DEPLOYER, L3_EXECUTOR, calls[3]);

        assertTrue(IRoles(L3_EXECUTOR).hasRole(EXECUTOR_ROLE, timelock));
        assertFalse(IRoles(L3_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER));
        vm.prank(DEPLOYER);
        vm.expectRevert();
        IUpgradeExecutor(L3_EXECUTOR).executeCall(L3_EXECUTOR, "");
    }

    function test_rollupExecutorRolesMove() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        if (!IRoles(ROLLUP_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER)) vm.skip(true);
        handover = new AdminHandover();
        bytes[2] memory calls = handover.rollupCalls(ROLLUP_EXECUTOR, timelock, DEPLOYER);
        assertTrue(IRoles(ROLLUP_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER));

        _send(DEPLOYER, ROLLUP_EXECUTOR, calls[0]);
        _send(DEPLOYER, ROLLUP_EXECUTOR, calls[1]);

        assertTrue(IRoles(ROLLUP_EXECUTOR).hasRole(EXECUTOR_ROLE, timelock));
        assertFalse(IRoles(ROLLUP_EXECUTOR).hasRole(EXECUTOR_ROLE, DEPLOYER));
    }
}
