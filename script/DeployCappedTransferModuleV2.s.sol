// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {CappedTransferModuleV2, ISafeModuleExec} from "../src/safe/CappedTransferModuleV2.sol";

interface ISafeInfo {
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
}

/// @notice Deploys a CappedTransferModuleV2 for one Safe on Robinhood Chain (chain 4663) or BrainChain (chain 274663).
/// Fixed at deployment: the Safe, the asset and the first operator. The deployer pays the gas and gets no power over
/// the module. The module can do nothing until the Safe sets its recipient and caps and enables it, which takes the
/// Safe's owners: `setRecipient`, `setCaps` and the Safe's own `enableModule`, in one batch.
///
/// Env: SAFE (a Safe 1.4.1 whose threshold is two or more), TOKEN (the ERC-20 to send, or
/// 0x0000000000000000000000000000000000000000 for native ETH; there is no default), OPERATOR (the key that sends).
/// Without --broadcast it simulates the deployment and prints the address:
///   SAFE=<safe> TOKEN=<token or zero> OPERATOR=<operator> forge script \
///     script/DeployCappedTransferModuleV2.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
/// Add --keystore <deployer keystore> --password-file <its password> --sender <deployer> --broadcast to deploy.
contract DeployCappedTransferModuleV2 is Script {
    function run() external {
        require(
            block.chainid == 4663 || block.chainid == 274663,
            "not Robinhood Chain (4663) or BrainChain (274663): pass --rpc-url"
        );
        address safe = vm.envAddress("SAFE");
        address token = vm.envAddress("TOKEN");
        address operator = vm.envAddress("OPERATOR");
        require(safe.code.length > 0, "SAFE has no code");
        require(keccak256(bytes(ISafeInfo(safe).VERSION())) == keccak256("1.4.1"), "SAFE is not a Safe 1.4.1");
        require(ISafeInfo(safe).getThreshold() >= 2, "SAFE must need two or more signatures");
        require(token == address(0) || token.code.length > 0, "TOKEN has no code");
        require(operator != address(0) && operator != safe, "OPERATOR is zero or the Safe");

        vm.startBroadcast();
        CappedTransferModuleV2 module = new CappedTransferModuleV2(ISafeModuleExec(safe), token, operator);
        vm.stopBroadcast();

        require(address(module.SAFE()) == safe && module.TOKEN() == token, "the module names another Safe or asset");
        require(module.operator() == operator, "the module names another operator");
        require(
            module.recipient() == address(0) && module.dailyCap() == 0 && module.windowCap() == 0,
            "the module starts with settings"
        );
        console2.log("CappedTransferModuleV2", address(module));
        console2.log(token == address(0) ? "asset: native ETH" : "asset: ERC-20", token);
    }
}
