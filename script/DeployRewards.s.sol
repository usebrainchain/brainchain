// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {FeeSplitter, IFeeEscrow} from "../src/rewards/FeeSplitter.sol";
import {RewardDistributor} from "../src/rewards/RewardDistributor.sol";

/// @notice Deploys the $BRAIN fee rewards on Robinhood Chain (chain 4663), and
/// the timelock that takes over the rollup's UpgradeExecutor (see
/// AdminHandover.s.sol).
///
/// The reward contracts are owned by the Safe directly, not through a
/// timelock: the owner must be able to revoke a bad round within its 24-hour
/// claim delay, and the FeeSplitter delays its own owner actions by three days.
/// The deployer binds the $BRAIN curve once it launches.
///
/// Env: OWNER_SAFE, PUBLISHER, TREASURY, PONS_ESCROW, optional ADMIN_DELAY
/// (seconds, default 48 hours).
contract DeployRewards is Script {
    function run() external {
        address safe = vm.envAddress("OWNER_SAFE");
        address publisher = vm.envAddress("PUBLISHER");
        address treasury = vm.envAddress("TREASURY");
        IFeeEscrow escrow = IFeeEscrow(vm.envAddress("PONS_ESCROW"));
        uint256 adminDelay = vm.envOr("ADMIN_DELAY", uint256(48 hours));
        require(block.chainid == 4663, "not Robinhood Chain");

        vm.startBroadcast();
        RewardDistributor distributor = new RewardDistributor(safe, publisher);
        FeeSplitter splitter = new FeeSplitter(escrow, address(distributor), treasury, safe);
        address[] memory safes = new address[](1);
        safes[0] = safe;
        TimelockController rollupAdmin = new TimelockController(adminDelay, safes, safes, address(0));
        vm.stopBroadcast();

        console2.log("RewardDistributor", address(distributor));
        console2.log("FeeSplitter", address(splitter));
        console2.log("RollupAdminTimelock", address(rollupAdmin));
    }
}
