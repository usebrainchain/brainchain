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
import {GuardianGate, IGuardedBoard, IGuardedExecutor} from "../src/GuardianGate.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {TestSwap} from "../src/testnet/TestSwap.sol";
import {TestUSDG} from "../src/testnet/TestUSDG.sol";

/// @notice Deploys BrainChain testnet with the $BRAIN flywheel, using test
/// tokens. The deployer is the guardian on testnet and configures every
/// contract before handing ownership to the DecisionExecutor. The DecisionLog
/// is owned by an admin timelock (2 hours on testnet) that the deployer
/// proposes to, so the brain can never replace itself.
/// Env: BRAIN, WORKER_CLAUDE, WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK, WATCHER.
/// A later set reuses the first one's tokens, swap and admin timelock when
/// TEST_USDG, TEST_BRAIN, TEST_SWAP and ADMIN_TIMELOCK are set, so faucets,
/// balances and the worker CLI's token addresses stay put; its house treasury
/// is then a day's faucet claim. The guardian seat goes to a GuardianGate whose
/// Safe is the deployer and whose watcher is WATCHER; the admin hands it over.
contract DeployTestnet is Script {
    struct Deployed {
        TimelockController admin;
        TestUSDG usdg;
        TestBRAIN brainToken;
        TestSwap swap;
        DecisionLog decisionLog;
        ModelRegistry registry;
        DecisionExecutor executor;
        WorkerStaking staking;
        TaskBoard board;
        FeeRouter router;
        ProposalBonds bonds;
        GuardianGate gate;
    }

    function run() external {
        address brainKey = vm.envAddress("BRAIN");
        vm.startBroadcast();
        address deployer = msg.sender;
        Deployed memory d;
        d.admin = _admin(deployer);
        d.decisionLog = new DecisionLog(address(d.admin), brainKey);
        d.registry = new ModelRegistry(deployer);
        address existingBrain = vm.envOr("TEST_BRAIN", address(0));
        d.brainToken = existingBrain == address(0) ? new TestBRAIN(deployer, 10_000_000e18) : TestBRAIN(existingBrain);
        (d.usdg, d.executor) = _usdgAndExecutor(deployer, d.decisionLog);
        d.staking = new WorkerStaking(IERC20(address(d.brainToken)), deployer, 500e18, 3 days, 2_000);
        d.board = new TaskBoard(
            IERC20(address(d.usdg)),
            d.decisionLog,
            d.registry,
            d.staking,
            deployer,
            deployer,
            TaskBoard.Config({
                hireThresholdBps: 1_500,
                gradeThresholdBps: 8_000,
                ruleThresholdBps: 8_000,
                minDuration: 30 minutes,
                maxDuration: 3 days,
                gradeWindow: 6 hours,
                disputeWindow: 1 hours,
                ruleWindow: 6 hours,
                minBounty: 1e6
            })
        );
        d.router = new FeeRouter(IERC20(address(d.usdg)), address(d.executor), deployer, brainKey, 5_000);
        d.swap = _swap(d.usdg, d.brainToken);
        d.bonds = new ProposalBonds(
            IERC20(address(d.brainToken)),
            d.decisionLog,
            IDecisionExecutor(address(d.executor)),
            address(d.executor),
            100e18,
            7 days
        );
        _wire(d, deployer);
        d.gate = new GuardianGate(
            deployer, IGuardedExecutor(address(d.executor)), IGuardedBoard(address(d.board)), vm.envAddress("WATCHER")
        );
        vm.stopBroadcast();
        _print(d);
    }

    function _admin(address deployer) private returns (TimelockController admin) {
        address existing = vm.envOr("ADMIN_TIMELOCK", address(0));
        if (existing != address(0)) return TimelockController(payable(existing));
        address[] memory admins = new address[](1);
        admins[0] = deployer;
        admin = new TimelockController(2 hours, admins, admins, address(0));
    }

    /// The first set mints the executor's house treasury in the token's constructor, which needs the
    /// executor's address predicted. A later set reuses the token and funds the treasury from the faucet.
    function _usdgAndExecutor(address deployer, DecisionLog decisionLog)
        private
        returns (TestUSDG usdg, DecisionExecutor executor)
    {
        address existing = vm.envOr("TEST_USDG", address(0));
        if (existing == address(0)) {
            address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
            usdg = new TestUSDG(predicted, 100e6);
            executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), deployer, 6_000, 2 hours, 20, 5e6, 40e6);
            require(address(executor) == predicted, "executor address mismatch");
        } else {
            usdg = TestUSDG(existing);
            executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), deployer, 6_000, 2 hours, 20, 5e6, 40e6);
            // The deployer's daily claim may already be spent; the treasury is then funded after the deploy.
            if (block.timestamp >= usdg.lastClaim(deployer) + usdg.FAUCET_INTERVAL()) usdg.faucet();
            usdg.transfer(address(executor), usdg.balanceOf(deployer));
        }
    }

    function _swap(TestUSDG usdg, TestBRAIN brainToken) private returns (TestSwap swap) {
        address existing = vm.envOr("TEST_SWAP", address(0));
        if (existing != address(0)) return TestSwap(existing);
        swap = new TestSwap(IERC20(address(usdg)), IERC20(address(brainToken)), 1e14);
        brainToken.transfer(address(swap), 5_000_000e18);
    }

    function _wire(Deployed memory d, address deployer) private {
        d.staking.setSlasher(address(d.board), true);
        d.board.setFee(300, address(d.router));
        d.router.setBrain(IERC20(address(d.brainToken)));
        d.router.setAdapter(d.swap);
        // 5% under the swap's fixed rate, scaled by 1e18.
        d.router.setFloorRate((1e14 * 1e18 * 95) / 100);

        d.registry.setModel(keccak256("claude"), vm.envAddress("WORKER_CLAUDE"), 0.4e6, true);
        d.registry.setModel(keccak256("gpt"), vm.envAddress("WORKER_GPT"), 0.35e6, true);
        d.registry.setModel(keccak256("gemini"), vm.envAddress("WORKER_GEMINI"), 0.25e6, true);
        d.registry.setModel(keccak256("grok"), vm.envAddress("WORKER_GROK"), 0.3e6, true);
        d.registry.setModel(keccak256("deepseek"), vm.envAddress("WORKER_DEEPSEEK"), 0.1e6, true);

        d.registry.setOwner(address(d.executor));
        d.board.setOwner(address(d.executor));
        d.executor.bindBoard(d.board);
        d.staking.setOwner(address(d.executor));
        d.router.setOwner(address(d.executor));
        require(d.executor.guardian() == deployer, "the deployer is not the guardian");
    }

    function _print(Deployed memory d) private pure {
        console2.log("AdminTimelock", address(d.admin));
        console2.log("TestUSDG", address(d.usdg));
        console2.log("TestBRAIN", address(d.brainToken));
        console2.log("DecisionLog", address(d.decisionLog));
        console2.log("ModelRegistry", address(d.registry));
        console2.log("DecisionExecutor", address(d.executor));
        console2.log("TaskBoard", address(d.board));
        console2.log("WorkerStaking", address(d.staking));
        console2.log("FeeRouter", address(d.router));
        console2.log("TestSwap", address(d.swap));
        console2.log("ProposalBonds", address(d.bonds));
        console2.log("GuardianGate", address(d.gate));
    }
}
