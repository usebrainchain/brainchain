// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ProofsIncome, IWETH} from "../src/rewards/ProofsIncome.sol";
import {FeeSplitter} from "../src/rewards/FeeSplitter.sol";

/// @notice Deploys the ProofsIncome router on Robinhood Chain (chain 4663): the
/// payee of the $BRAIN launch on ripples.run. Half of the income goes to the
/// holders of BrainChain Proofs, a quarter to the FeeSplitter and a quarter to
/// the owners' Safe, which also owns the router. Run it before the launch: the
/// launch names the router as its payee, and the deployer binds the Proofs
/// collection the launch creates with `bindProofs`.
///
/// Env: OWNER_SAFE (owner and treasury), FEE_SPLITTER.
contract DeployProofsIncome is Script {
    IWETH constant WETH = IWETH(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);

    function run() external {
        require(
            block.chainid == 4663, "not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"
        );
        address safe = vm.envAddress("OWNER_SAFE");
        address splitter = vm.envAddress("FEE_SPLITTER");
        require(safe.code.length > 0, "OWNER_SAFE has no code");
        require(splitter.code.length > 0, "FEE_SPLITTER has no code");
        require(FeeSplitter(payable(splitter)).treasury() == safe, "FEE_SPLITTER does not pay the Safe");
        require(address(WETH).code.length > 0, "WETH has no code");

        vm.startBroadcast();
        ProofsIncome income = new ProofsIncome(WETH, splitter, safe, safe, 5000, 2500, 0.001 ether);
        vm.stopBroadcast();

        require(income.treasury() == safe && income.owner() == safe, "the router is not the Safe's");
        require(income.splitter() == splitter && address(income.weth()) == address(WETH), "the router is mis-wired");
        require(income.holdersBps() == 5000 && income.splitterBps() == 2500, "the split is off");
        require(income.minRound() == 0.001 ether, "the round minimum is off");
        console2.log("ProofsIncome", address(income));
    }
}
