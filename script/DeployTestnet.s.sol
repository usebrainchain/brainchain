// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {TestUSDG} from "../src/testnet/TestUSDG.sol";

/// @notice Deploys BrainChain testnet. The deployer acts as guardian on testnet.
/// Env: BRAIN, WORKER_CLAUDE, WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK.
contract DeployTestnet is Script {
    function run() external {
        address brain = vm.envAddress("BRAIN");
        vm.startBroadcast();
        address deployer = msg.sender;

        DecisionLog decisionLog = new DecisionLog(deployer, brain);
        ModelRegistry registry = new ModelRegistry(deployer);

        // The executor needs the token first; the token mints the house treasury to the executor,
        // so the executor's address is predicted from the deployer's next nonce.
        address predictedExecutor = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        TestUSDG usdg = new TestUSDG(predictedExecutor, 100e6);
        DecisionExecutor executor =
            new DecisionExecutor(decisionLog, IERC20(address(usdg)), deployer, 8_500, 2 hours, 20);
        require(address(executor) == predictedExecutor, "executor address mismatch");

        TaskBoard board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            address(executor),
            deployer,
            TaskBoard.Config({
                hireThresholdBps: 7_000,
                gradeThresholdBps: 7_000,
                ruleThresholdBps: 7_000,
                minDuration: 30 minutes,
                maxDuration: 3 days,
                gradeWindow: 6 hours,
                disputeWindow: 1 hours,
                ruleWindow: 6 hours,
                minBounty: 1e6
            })
        );
        executor.bindBoard(board);

        registry.setModel(keccak256("claude"), vm.envAddress("WORKER_CLAUDE"), 0.4e6, true);
        registry.setModel(keccak256("gpt"), vm.envAddress("WORKER_GPT"), 0.35e6, true);
        registry.setModel(keccak256("gemini"), vm.envAddress("WORKER_GEMINI"), 0.25e6, true);
        registry.setModel(keccak256("grok"), vm.envAddress("WORKER_GROK"), 0.3e6, true);
        registry.setModel(keccak256("deepseek"), vm.envAddress("WORKER_DEEPSEEK"), 0.1e6, true);

        registry.setOwner(address(executor));
        decisionLog.setOwner(address(executor));
        vm.stopBroadcast();

        console2.log("TestUSDG", address(usdg));
        console2.log("DecisionLog", address(decisionLog));
        console2.log("ModelRegistry", address(registry));
        console2.log("DecisionExecutor", address(executor));
        console2.log("TaskBoard", address(board));
    }
}
