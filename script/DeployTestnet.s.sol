// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {FeeRouter} from "../src/flywheel/FeeRouter.sol";
import {IChangeThreshold, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {TestSwap} from "../src/testnet/TestSwap.sol";
import {TestUSDG} from "../src/testnet/TestUSDG.sol";

/// @notice Deploys BrainChain testnet with the $BRAIN flywheel, using test
/// tokens. The deployer is the guardian on testnet and configures every
/// contract before handing ownership to the DecisionExecutor. The DecisionLog
/// is owned by an admin timelock (2 hours on testnet) that the deployer
/// proposes to, so the brain can never replace itself.
/// Env: BRAIN, WORKER_CLAUDE, WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK.
contract DeployTestnet is Script {
    function run() external {
        address brainKey = vm.envAddress("BRAIN");
        vm.startBroadcast();
        address deployer = msg.sender;

        address[] memory admins = new address[](1);
        admins[0] = deployer;
        TimelockController admin = new TimelockController(2 hours, admins, admins, address(0));
        DecisionLog decisionLog = new DecisionLog(address(admin), brainKey);
        ModelRegistry registry = new ModelRegistry(deployer);
        TestBRAIN brainToken = new TestBRAIN(deployer, 10_000_000e18);

        // The executor's address is needed by the USDG treasury mint, so it is predicted.
        address predictedExecutor = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        TestUSDG usdg = new TestUSDG(predictedExecutor, 100e6);
        DecisionExecutor executor =
            new DecisionExecutor(decisionLog, IERC20(address(usdg)), deployer, 8_500, 2 hours, 20, 5e6, 40e6);
        require(address(executor) == predictedExecutor, "executor address mismatch");

        WorkerStaking staking = new WorkerStaking(IERC20(address(brainToken)), deployer, 500e18, 3 days, 2_000);
        TaskBoard board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            staking,
            deployer,
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
        FeeRouter router = new FeeRouter(IERC20(address(usdg)), address(executor), deployer, brainKey, 5_000);
        TestSwap swap = new TestSwap(IERC20(address(usdg)), IERC20(address(brainToken)), 1e14);
        brainToken.transfer(address(swap), 5_000_000e18);
        ProposalBonds bonds = new ProposalBonds(
            IERC20(address(brainToken)),
            decisionLog,
            IChangeThreshold(address(executor)),
            address(executor),
            100e18,
            7 days
        );

        staking.setSlasher(address(board));
        board.setFee(300, address(router));
        router.setBrain(IERC20(address(brainToken)));
        router.setAdapter(swap);
        // 5% under the swap's fixed rate, scaled by 1e18.
        router.setFloorRate((1e14 * 1e18 * 95) / 100);

        registry.setModel(keccak256("claude"), vm.envAddress("WORKER_CLAUDE"), 0.4e6, true);
        registry.setModel(keccak256("gpt"), vm.envAddress("WORKER_GPT"), 0.35e6, true);
        registry.setModel(keccak256("gemini"), vm.envAddress("WORKER_GEMINI"), 0.25e6, true);
        registry.setModel(keccak256("grok"), vm.envAddress("WORKER_GROK"), 0.3e6, true);
        registry.setModel(keccak256("deepseek"), vm.envAddress("WORKER_DEEPSEEK"), 0.1e6, true);

        registry.setOwner(address(executor));
        board.setOwner(address(executor));
        executor.bindBoard(board);
        staking.setOwner(address(executor));
        router.setOwner(address(executor));
        vm.stopBroadcast();

        console2.log("AdminTimelock", address(admin));
        console2.log("TestUSDG", address(usdg));
        console2.log("TestBRAIN", address(brainToken));
        console2.log("DecisionLog", address(decisionLog));
        console2.log("ModelRegistry", address(registry));
        console2.log("DecisionExecutor", address(executor));
        console2.log("TaskBoard", address(board));
        console2.log("WorkerStaking", address(staking));
        console2.log("FeeRouter", address(router));
        console2.log("TestSwap", address(swap));
        console2.log("ProposalBonds", address(bonds));
    }
}
