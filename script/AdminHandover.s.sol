// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IArbOwner {
    function addChainOwner(address owner) external;
    function removeChainOwner(address owner) external;
}

interface IUpgradeExecutor {
    function executeCall(address target, bytes calldata data) external payable;
}

interface IAccessControl {
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
}

/// @notice Prints, and never sends, the transactions that move BrainChain's
/// chain-level powers from the deployer key to the admin timelocks. Review the
/// output, then send each transaction from the deployer in the order printed.
///
/// Today the deployer is BrainChain's only chain owner and holds EXECUTOR_ROLE
/// on both UpgradeExecutors: BrainChain's (which owns the bridged-token beacon
/// and proxy admin) and the rollup's on Robinhood Chain (which owns the rollup
/// contracts). After the handover only the timelocks, proposed to by the Safe,
/// can use those powers, each 48 hours after announcing it.
///
/// Env: L3_ADMIN (the AdminTimelock from DeployMainnet), ROLLUP_ADMIN (the
/// RollupAdminTimelock from DeployRewards), optional DEPLOYER, L3_UPGRADE_EXECUTOR,
/// ROLLUP_UPGRADE_EXECUTOR.
contract AdminHandover is Script {
    address constant ARB_OWNER = 0x0000000000000000000000000000000000000070;
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    function run() external view {
        address l3Admin = vm.envAddress("L3_ADMIN");
        address rollupAdmin = vm.envAddress("ROLLUP_ADMIN");
        address deployer = vm.envOr("DEPLOYER", address(0x8D4b5d7E287ddf83C440a19b2DD6037F58723660));
        address l3Executor = vm.envOr("L3_UPGRADE_EXECUTOR", address(0xf5B096ddE063311CaEC2F9665ef3E94eAb1280bA));
        address rollupExecutor =
            vm.envOr("ROLLUP_UPGRADE_EXECUTOR", address(0x12c59492BB508EFDb6c5D43F2aA907d8B55524D6));

        console2.log("On BrainChain (274663), from", deployer);
        _print("1. make the UpgradeExecutor a chain owner", ARB_OWNER, l3Calls(l3Executor, l3Admin, deployer)[0]);
        _print("2. give the admin timelock EXECUTOR_ROLE", l3Executor, l3Calls(l3Executor, l3Admin, deployer)[1]);
        _print("3. remove the deployer as chain owner", l3Executor, l3Calls(l3Executor, l3Admin, deployer)[2]);
        _print("4. revoke the deployer's EXECUTOR_ROLE", l3Executor, l3Calls(l3Executor, l3Admin, deployer)[3]);

        console2.log("On Robinhood Chain (4663), from", deployer);
        _print(
            "5. give the rollup timelock EXECUTOR_ROLE",
            rollupExecutor,
            rollupCalls(rollupExecutor, rollupAdmin, deployer)[0]
        );
        _print(
            "6. revoke the deployer's EXECUTOR_ROLE",
            rollupExecutor,
            rollupCalls(rollupExecutor, rollupAdmin, deployer)[1]
        );
    }

    function l3Calls(address l3Executor, address l3Admin, address deployer)
        public
        pure
        returns (bytes[4] memory calls)
    {
        calls[0] = abi.encodeCall(IArbOwner.addChainOwner, (l3Executor));
        calls[1] = _selfCall(l3Executor, abi.encodeCall(IAccessControl.grantRole, (EXECUTOR_ROLE, l3Admin)));
        calls[2] = abi.encodeCall(
            IUpgradeExecutor.executeCall, (ARB_OWNER, abi.encodeCall(IArbOwner.removeChainOwner, (deployer)))
        );
        calls[3] = _selfCall(l3Executor, abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR_ROLE, deployer)));
    }

    function rollupCalls(address rollupExecutor, address rollupAdmin, address deployer)
        public
        pure
        returns (bytes[2] memory calls)
    {
        calls[0] = _selfCall(rollupExecutor, abi.encodeCall(IAccessControl.grantRole, (EXECUTOR_ROLE, rollupAdmin)));
        calls[1] = _selfCall(rollupExecutor, abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR_ROLE, deployer)));
    }

    /// @dev Role changes go through the executor itself, which holds ADMIN_ROLE over its own roles.
    function _selfCall(address executor, bytes memory data) private pure returns (bytes memory) {
        return abi.encodeCall(IUpgradeExecutor.executeCall, (executor, data));
    }

    function _print(string memory step, address target, bytes memory data) private pure {
        console2.log(step);
        console2.log("  to  ", target);
        console2.logBytes(data);
    }
}
