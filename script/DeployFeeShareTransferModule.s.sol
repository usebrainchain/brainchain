// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ISafeModuleExec} from "../src/safe/CappedTransferModuleV2.sol";
import {IFeeLedger} from "../src/safe/FeeShareModule.sol";
import {FeeShareTransferModule} from "../src/safe/FeeShareTransferModule.sol";

interface ISafeInfo {
    function VERSION() external view returns (string memory);
    function getThreshold() external view returns (uint256);
}

/// @notice Deploys a FeeShareTransferModule on Robinhood Chain (chain 4663): the operator has the treasury Safe pay
/// the buyback wallet a share of the $BRAIN market's fee payouts from deployment on, in native ETH. Every number is
/// fixed at deployment; the deployer pays the gas and gets no power over the module. It does nothing until the Safe's
/// owners enable it, and the Safe ends it by disabling it.
///
/// Env: SAFE (a Safe 1.4.1 whose threshold is two or more), LEDGER (the market's fee hook), FEE_TOKEN (the WETH it
/// pays out in), INCOME (the account it pays out to), RECIPIENT (the buyback wallet), OPERATOR (the key that takes;
/// may be the recipient), SHARE_NUMERATOR and SHARE_DENOMINATOR (5 and 12 when unset).
/// Without --broadcast it simulates the deployment and prints the address:
///   SAFE=<safe> LEDGER=<hook> FEE_TOKEN=<weth> INCOME=<income> RECIPIENT=<wallet> OPERATOR=<key> forge script \
///     script/DeployFeeShareTransferModule.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
/// Add --keystore <deployer keystore> --password-file <its password> --sender <deployer> --broadcast to deploy.
contract DeployFeeShareTransferModule is Script {
    function run() external returns (FeeShareTransferModule module) {
        require(
            block.chainid == 4663, "not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"
        );
        address safe = _address("SAFE");
        address ledger = _address("LEDGER");
        address feeToken = _address("FEE_TOKEN");
        address income = _address("INCOME");
        address recipient = _address("RECIPIENT");
        address operator = _address("OPERATOR");
        uint256 numerator = vm.envOr("SHARE_NUMERATOR", uint256(5));
        uint256 denominator = vm.envOr("SHARE_DENOMINATOR", uint256(12));

        require(safe.code.length > 0, "SAFE has no code");
        require(keccak256(bytes(ISafeInfo(safe).VERSION())) == keccak256("1.4.1"), "SAFE is not a Safe 1.4.1");
        require(ISafeInfo(safe).getThreshold() >= 2, "SAFE must need two or more signatures");
        require(ledger.code.length > 0, "LEDGER has no code");
        require(feeToken.code.length > 0, "FEE_TOKEN has no code");
        require(recipient != safe && operator != safe, "RECIPIENT or OPERATOR is the Safe");
        require(numerator > 0 && numerator <= denominator, "the share must be above zero and at most one");

        console2.log("SAFE", safe);
        console2.log("LEDGER", ledger);
        console2.log("FEE_TOKEN", feeToken);
        console2.log("INCOME", income);
        console2.log("RECIPIENT", recipient);
        console2.log("OPERATOR", operator);
        console2.log("SHARE_NUMERATOR", numerator);
        console2.log("SHARE_DENOMINATOR", denominator);

        vm.startBroadcast();
        module = new FeeShareTransferModule(
            ISafeModuleExec(safe), IFeeLedger(ledger), feeToken, income, recipient, operator, numerator, denominator
        );
        vm.stopBroadcast();

        require(address(module.SAFE()) == safe && address(module.LEDGER()) == ledger, "the module names another Safe");
        require(module.FEE_TOKEN() == feeToken && module.INCOME() == income, "the module reads another payout");
        require(module.RECIPIENT() == recipient && module.OPERATOR() == operator, "the module names other keys");
        require(module.SHARE_NUMERATOR() == numerator && module.SHARE_DENOMINATOR() == denominator, "another share");
        require(module.taken() == 0 && module.due() == 0, "the module starts with something due");
        console2.log("FeeShareTransferModule", address(module));
        console2.log("BASELINE (paid out before deployment, not counted)", module.BASELINE());
    }

    function _address(string memory name) private view returns (address value) {
        value = vm.envAddress(name);
        require(value != address(0), string.concat(name, " is the zero address"));
    }
}
