// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";

/// @notice Deploys the BrainChain v3 core on mainnet (chain 274663), with open
/// workers: any agent can stake $BRAIN in WorkerStaking and be hired on the
/// board once governance allow-lists it, and anyone can bond $BRAIN in
/// ProposalBonds to propose a chain change.
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
/// As on testnet, the DecisionExecutor owns WorkerStaking and ProposalBonds.
/// Changes can only call the executor, the board and the registry, so the
/// stake, cooldown, slash, bond and decision window set here hold for the life
/// of this set, and the board is the only slasher it will have.
///
/// The board fee goes to FEE_RECIPIENT. There is no FeeRouter on mainnet: the
/// router buys $BRAIN through a swap venue, and BrainChain has none.
///
/// Env: ADMIN_SAFE, BRAIN, USDG (bridged USDG on BrainChain), BRAIN_TOKEN
/// (bridged $BRAIN on BrainChain, 18 decimals), FEE_RECIPIENT, WORKER_CLAUDE,
/// WORKER_GPT, WORKER_GEMINI, WORKER_GROK, WORKER_DEEPSEEK, optional
/// ADMIN_DELAY (seconds, default 48 hours), optional ADMIN_TIMELOCK (reuse a
/// timelock the Safe already proposes to, such as the one that holds the
/// chain-ownership powers, instead of deploying a new one), optional STAKE_MIN
/// (whole $BRAIN a worker stakes to be hireable, default 1000000), optional
/// STAKE_COOLDOWN (seconds before unstaked $BRAIN can be withdrawn, default
/// 3 days), optional SLASH_BPS (share of stake burned when a worker loses a
/// dispute, default 2000), optional BOND (whole $BRAIN bonded per proposal,
/// default 250000), optional BOND_DECIDE_WITHIN (seconds Jev has to decide a
/// proposal before its bond is returned, default 7 days).
contract DeployMainnet is Script {
    struct Config {
        address safe;
        address brain;
        IERC20 usdg;
        IERC20 brainToken;
        address feeRecipient;
        address[5] workers;
        uint256 adminDelay;
        uint128 stakeMin;
        uint64 stakeCooldown;
        uint16 slashBps;
        uint128 bond;
        uint64 decideWithin;
    }

    struct Deployment {
        TimelockController admin;
        DecisionLog decisionLog;
        DecisionExecutor executor;
        ModelRegistry registry;
        WorkerStaking staking;
        TaskBoard board;
        ProposalBonds bonds;
    }

    function run() external returns (Deployment memory d) {
        require(
            block.chainid == 274663, "not BrainChain mainnet (274663): pass --rpc-url https://rpc.usebrainchain.com"
        );
        Config memory c = _config();

        vm.startBroadcast();
        address deployer = msg.sender;
        require(c.brain != deployer, string.concat("BRAIN is the deploying key ", vm.toString(deployer)));
        require(c.brain != c.safe, "BRAIN is the admin Safe");
        d = _deploy(c, deployer);
        vm.stopBroadcast();

        _check(c, d, deployer);

        console2.log("AdminTimelock", address(d.admin));
        console2.log("DecisionLog", address(d.decisionLog));
        console2.log("ModelRegistry", address(d.registry));
        console2.log("DecisionExecutor", address(d.executor));
        console2.log("TaskBoard", address(d.board));
        console2.log("WorkerStaking", address(d.staking));
        console2.log("ProposalBonds", address(d.bonds));
    }

    function _config() internal view returns (Config memory c) {
        c.safe = vm.envAddress("ADMIN_SAFE");
        c.brain = vm.envAddress("BRAIN");
        c.usdg = IERC20(vm.envAddress("USDG"));
        c.brainToken = IERC20(vm.envAddress("BRAIN_TOKEN"));
        c.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        c.adminDelay = vm.envOr("ADMIN_DELAY", uint256(48 hours));
        c.stakeMin = SafeCast.toUint128(vm.envOr("STAKE_MIN", uint256(1_000_000)) * 1e18);
        c.stakeCooldown = SafeCast.toUint64(vm.envOr("STAKE_COOLDOWN", uint256(3 days)));
        c.slashBps = SafeCast.toUint16(vm.envOr("SLASH_BPS", uint256(2_000)));
        c.bond = SafeCast.toUint128(vm.envOr("BOND", uint256(250_000)) * 1e18);
        c.decideWithin = SafeCast.toUint64(vm.envOr("BOND_DECIDE_WITHIN", uint256(7 days)));
        // Every USDG amount below is in 6-decimal units, every $BRAIN amount in 18.
        require(address(c.usdg).code.length > 0, "USDG has no code on this chain");
        require(IERC20Metadata(address(c.usdg)).decimals() == 6, "USDG is not a 6-decimal token");
        require(address(c.brainToken).code.length > 0, "BRAIN_TOKEN has no code on this chain");
        require(IERC20Metadata(address(c.brainToken)).decimals() == 18, "BRAIN_TOKEN is not an 18-decimal token");
        require(c.safe.code.length > 0, "ADMIN_SAFE has no code");
        require(c.feeRecipient != address(0), "FEE_RECIPIENT is unset");
        string[5] memory names = ["WORKER_CLAUDE", "WORKER_GPT", "WORKER_GEMINI", "WORKER_GROK", "WORKER_DEEPSEEK"];
        for (uint256 i; i < 5; ++i) {
            c.workers[i] = vm.envAddress(names[i]);
            require(c.workers[i] != address(0), string.concat(names[i], " is unset"));
            for (uint256 j; j < i; ++j) {
                require(
                    c.workers[i] != c.workers[j], string.concat(names[j], " and ", names[i], " are the same account")
                );
            }
        }
    }

    function _deploy(Config memory c, address deployer) internal returns (Deployment memory d) {
        d.admin = _admin(c.safe, c.adminDelay);
        d.decisionLog = new DecisionLog(address(d.admin), c.brain);
        d.executor = new DecisionExecutor(d.decisionLog, c.usdg, deployer, 6_000, 48 hours, 5, 2e6, 10e6);
        d.registry = new ModelRegistry(deployer);
        d.staking = new WorkerStaking(c.brainToken, deployer, c.stakeMin, c.stakeCooldown, c.slashBps);
        d.board = new TaskBoard(
            c.usdg,
            d.decisionLog,
            d.registry,
            d.staking,
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
        d.bonds = new ProposalBonds(
            c.brainToken,
            d.decisionLog,
            IDecisionExecutor(address(d.executor)),
            address(d.executor),
            c.bond,
            c.decideWithin
        );

        d.staking.setSlasher(address(d.board));
        d.board.setFee(300, c.feeRecipient);
        d.registry.setModel(keccak256("claude"), c.workers[0], 0.4e6, true);
        d.registry.setModel(keccak256("gpt"), c.workers[1], 0.35e6, true);
        d.registry.setModel(keccak256("gemini"), c.workers[2], 0.25e6, true);
        d.registry.setModel(keccak256("grok"), c.workers[3], 0.3e6, true);
        d.registry.setModel(keccak256("deepseek"), c.workers[4], 0.1e6, true);
        d.registry.setOwner(address(d.executor));
        d.board.setOwner(address(d.executor));
        d.staking.setOwner(address(d.executor));
        d.executor.bindBoard(d.board);
    }

    /// @dev The set is wired as intended, or the run fails before anyone points a service at it.
    function _check(Config memory c, Deployment memory d, address deployer) internal view {
        TimelockController admin = d.admin;
        require(d.decisionLog.owner() == address(admin) && d.decisionLog.brain() == c.brain, "DecisionLog is mis-wired");
        require(
            d.registry.owner() == address(d.executor) && d.board.owner() == address(d.executor),
            "the executor does not own the board and registry"
        );
        require(d.staking.owner() == address(d.executor), "the executor does not own WorkerStaking");
        require(
            d.executor.board() == d.board && d.executor.models() == d.registry,
            "the executor is bound to another board or registry"
        );
        require(d.board.feeBps() == 300 && d.board.feeRouter() == c.feeRecipient, "the fee is mis-set");
        require(d.board.staking() == d.staking, "the board hires from another staking contract");
        require(d.staking.slasher() == address(d.board), "the board cannot slash or hold stakes");
        require(
            d.staking.token() == c.brainToken && d.bonds.token() == c.brainToken, "staking or bonds take another token"
        );
        require(d.bonds.bond() == c.bond, "the proposal bond is mis-set");
        require(admin.hasRole(admin.EXECUTOR_ROLE(), c.safe), "the Safe cannot execute through the admin");
        require(
            !admin.hasRole(admin.PROPOSER_ROLE(), deployer) && !admin.hasRole(admin.EXECUTOR_ROLE(), deployer),
            "the deployer holds an admin role"
        );
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
