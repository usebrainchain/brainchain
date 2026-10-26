// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";

/// @notice Deploys the BrainChain v3 core on mainnet (chain 274663).
///
/// The admin is a TimelockController (48 hours by default) whose only proposer
/// and executor is a Safe. It owns the DecisionLog, so it alone replaces the
/// brain or the guardian; it is also the target of the chain-ownership
/// handover (see AdminHandover.s.sol). The deployer is the guardian at first
/// and binds the board; the admin moves the guardian to the Safe afterwards.
///
/// Env: ADMIN_SAFE, BRAIN, USDG (bridged USDG on BrainChain), FEE_RECIPIENT,
/// WORKER_CLAUDE, WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK,
/// optional ADMIN_DELAY (seconds, default 48 hours).
contract DeployMainnet is Script {
    function run() external {
        address safe = vm.envAddress("ADMIN_SAFE");
        address brainKey = vm.envAddress("BRAIN");
        IERC20 usdg = IERC20(vm.envAddress("USDG"));
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 adminDelay = vm.envOr("ADMIN_DELAY", uint256(48 hours));
        require(block.chainid == 274663, "not BrainChain mainnet");

        vm.startBroadcast();
        address deployer = msg.sender;

        address[] memory safes = new address[](1);
        safes[0] = safe;
        TimelockController admin = new TimelockController(adminDelay, safes, safes, address(0));
        DecisionLog decisionLog = new DecisionLog(address(admin), brainKey);
        DecisionExecutor executor = new DecisionExecutor(decisionLog, usdg, deployer, 8_500, 48 hours, 5, 2e6, 10e6);
        ModelRegistry registry = new ModelRegistry(deployer);
        TaskBoard board = new TaskBoard(
            usdg,
            decisionLog,
            registry,
            WorkerStaking(address(0)),
            deployer,
            deployer,
            TaskBoard.Config({
                hireThresholdBps: 1_500,
                gradeThresholdBps: 7_000,
                ruleThresholdBps: 7_000,
                minDuration: 30 minutes,
                maxDuration: 3 days,
                gradeWindow: 6 hours,
                disputeWindow: 6 hours,
                ruleWindow: 6 hours,
                minBounty: 1e6
            })
        );

        board.setFee(300, feeRecipient);
        registry.setModel(keccak256("claude"), vm.envAddress("WORKER_CLAUDE"), 0.4e6, true);
        registry.setModel(keccak256("gpt"), vm.envAddress("WORKER_GPT"), 0.35e6, true);
        registry.setModel(keccak256("gemini"), vm.envAddress("WORKER_GEMINI"), 0.25e6, true);
        registry.setModel(keccak256("grok"), vm.envAddress("WORKER_GROK"), 0.3e6, true);
        registry.setModel(keccak256("deepseek"), vm.envAddress("WORKER_DEEPSEEK"), 0.1e6, true);
        registry.setOwner(address(executor));
        board.setOwner(address(executor));
        executor.bindBoard(board);
        vm.stopBroadcast();

        console2.log("AdminTimelock", address(admin));
        console2.log("DecisionLog", address(decisionLog));
        console2.log("ModelRegistry", address(registry));
        console2.log("DecisionExecutor", address(executor));
        console2.log("TaskBoard", address(board));
    }
}
