// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {FeeSplitter, IFeeEscrow} from "../src/rewards/FeeSplitter.sol";

/// @notice Deploys a FeeSplitter on Robinhood Chain (chain 4663) that pays the
/// treasury half of the $BRAIN creator fees to the owners' Safe instead of a
/// single key, next to an existing RewardDistributor. Run it before a curve is
/// bound: the $BRAIN launch names the deployed splitter as its fee recipient.
///
/// Env: OWNER_SAFE (owner and treasury), REWARD_DISTRIBUTOR, PONS_ESCROW.
contract DeployFeeSplitter is Script {
    function run() external {
        require(
            block.chainid == 4663, "not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"
        );
        address safe = vm.envAddress("OWNER_SAFE");
        address distributor = vm.envAddress("REWARD_DISTRIBUTOR");
        IFeeEscrow escrow = IFeeEscrow(vm.envAddress("PONS_ESCROW"));
        require(safe.code.length > 0, "OWNER_SAFE has no code");
        require(distributor.code.length > 0, "REWARD_DISTRIBUTOR has no code");
        require(address(escrow).code.length > 0, "PONS_ESCROW has no code");

        vm.startBroadcast();
        FeeSplitter splitter = new FeeSplitter(escrow, distributor, safe, safe);
        vm.stopBroadcast();

        require(splitter.treasury() == safe && splitter.owner() == safe, "the splitter is not the Safe's");
        require(
            splitter.rewards() == distributor && address(splitter.escrow()) == address(escrow),
            "the splitter is mis-wired"
        );
        console2.log("FeeSplitter", address(splitter));
    }
}
