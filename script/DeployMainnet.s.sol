// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
/// A chain change needs Jev to adopt it with at least 60% confidence in its
/// answer. Measured that way, Jev's adopt decisions on well-supported changes
/// land at 59 to 69%, so a higher bar blocks every change.
///
/// Env: ADMIN_SAFE, BRAIN, USDG (bridged USDG on BrainChain), FEE_RECIPIENT,
/// WORKER_CLAUDE, WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK,
/// optional ADMIN_DELAY (seconds, default 48 hours), optional ADMIN_TIMELOCK
/// (reuse a timelock the Safe already proposes to, such as the one that holds
/// the chain-ownership powers, instead of deploying a new one).
contract DeployMainnet is Script {
    function run() external {
        require(
            block.chainid == 274663, "not BrainChain mainnet (274663): pass --rpc-url https://rpc.usebrainchain.com"
        );
        address safe = vm.envAddress("ADMIN_SAFE");
        address brainKey = vm.envAddress("BRAIN");
        IERC20 usdg = IERC20(vm.envAddress("USDG"));
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 adminDelay = vm.envOr("ADMIN_DELAY", uint256(48 hours));
        // Every amount below is in 6-decimal units.
        require(address(usdg).code.length > 0, "USDG has no code on this chain");
        require(IERC20Metadata(address(usdg)).decimals() == 6, "USDG is not a 6-decimal token");
        require(safe.code.length > 0, "ADMIN_SAFE has no code");
        require(feeRecipient != address(0), "FEE_RECIPIENT is unset");
        string[5] memory names = ["WORKER_CLAUDE", "WORKER_GPT", "WORKER_GEMINI", "WORKER_GROK", "WORKER_DEEPSEEK"];
        address[5] memory workers = [
            vm.envAddress("WORKER_CLAUDE"),
            vm.envAddress("WORKER_GPT"),
            vm.envAddress("WORKER_GEMINI"),
            vm.envAddress("WORKER_GROK"),
            vm.envAddress("WORKER_DEEPSEEK")
        ];
        for (uint256 i; i < 5; ++i) {
            require(workers[i] != address(0), string.concat(names[i], " is unset"));
            for (uint256 j = i + 1; j < 5; ++j) {
                require(workers[i] != workers[j], string.concat(names[i], " and ", names[j], " are the same account"));
            }
        }

        vm.startBroadcast();
        address deployer = msg.sender;
        require(brainKey != deployer, string.concat("BRAIN is the deploying key ", vm.toString(deployer)));
        require(brainKey != safe, "BRAIN is the admin Safe");

        TimelockController admin = _admin(safe, adminDelay);
        DecisionLog decisionLog = new DecisionLog(address(admin), brainKey);
        DecisionExecutor executor = new DecisionExecutor(decisionLog, usdg, deployer, 6_000, 48 hours, 5, 2e6, 10e6);
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
        registry.setModel(keccak256("claude"), workers[0], 0.4e6, true);
        registry.setModel(keccak256("gpt"), workers[1], 0.35e6, true);
        registry.setModel(keccak256("gemini"), workers[2], 0.25e6, true);
        registry.setModel(keccak256("grok"), workers[3], 0.3e6, true);
        registry.setModel(keccak256("deepseek"), workers[4], 0.1e6, true);
        registry.setOwner(address(executor));
        board.setOwner(address(executor));
        executor.bindBoard(board);
        vm.stopBroadcast();

        // The set is wired as intended, or the run fails before anyone points a service at it.
        require(decisionLog.owner() == address(admin) && decisionLog.brain() == brainKey, "DecisionLog is mis-wired");
        require(
            registry.owner() == address(executor) && board.owner() == address(executor),
            "the executor does not own the board and registry"
        );
        require(
            executor.board() == board && executor.models() == registry,
            "the executor is bound to another board or registry"
        );
        require(board.feeBps() == 300 && board.feeRouter() == feeRecipient, "the fee is mis-set");
        require(admin.hasRole(admin.EXECUTOR_ROLE(), safe), "the Safe cannot execute through the admin");
        require(
            !admin.hasRole(admin.PROPOSER_ROLE(), deployer) && !admin.hasRole(admin.EXECUTOR_ROLE(), deployer),
            "the deployer holds an admin role"
        );

        console2.log("AdminTimelock", address(admin));
        console2.log("DecisionLog", address(decisionLog));
        console2.log("ModelRegistry", address(registry));
        console2.log("DecisionExecutor", address(executor));
        console2.log("TaskBoard", address(board));
    }

    function _admin(address safe, uint256 delay) private returns (TimelockController admin) {
        address existing = vm.envOr("ADMIN_TIMELOCK", address(0));
        if (existing == address(0)) {
            require(delay >= 1 days, "ADMIN_DELAY must be at least a day");
            address[] memory safes = new address[](1);
            safes[0] = safe;
            return new TimelockController(delay, safes, safes, address(0));
        }
        require(existing.code.length > 0, "ADMIN_TIMELOCK has no code");
        admin = TimelockController(payable(existing));
        require(admin.hasRole(admin.PROPOSER_ROLE(), safe), "the Safe cannot propose to ADMIN_TIMELOCK");
        require(admin.getMinDelay() == delay, "ADMIN_TIMELOCK has a different delay");
    }
}
