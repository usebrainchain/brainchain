// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployMainnet} from "../script/DeployMainnet.s.sol";
import {PayoutPreferences} from "../src/PayoutPreferences.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {MockERC20} from "./MockERC20.sol";

/// Runs the script's steps without a broadcast (forge refuses one under a prank), as the deployer.
contract DeployMainnetHarness is DeployMainnet {
    function deploy() external returns (Deployment memory d) {
        Config memory c = _config();
        d = _deploy(c, address(this));
        _check(c, d, address(this));
    }
}

/// Deploys the mainnet set on a local chain with a 6-decimal USDG and an
/// 18-decimal $BRAIN, and checks the open-worker wiring.
contract DeployMainnetTest is Test {
    function test_deploysAndWiresOpenWorkers() public {
        MockERC20 usdg = new MockERC20();
        TestBRAIN brainToken = new TestBRAIN(address(this), 1_000_000e18);
        address safe = makeAddr("safe");
        vm.etch(safe, hex"00");
        address feeRecipient = makeAddr("feeRecipient");

        // The script reads the process environment, which every test shares, so every case runs in this one test.
        vm.setEnv("ADMIN_SAFE", vm.toString(safe));
        vm.setEnv("BRAIN", vm.toString(makeAddr("brain")));
        vm.setEnv("USDG", vm.toString(address(usdg)));
        vm.setEnv("FEE_RECIPIENT", vm.toString(feeRecipient));
        vm.setEnv("WORKER_CLAUDE", vm.toString(makeAddr("claude")));
        vm.setEnv("WORKER_GPT", vm.toString(makeAddr("gpt")));
        vm.setEnv("WORKER_GEMINI", vm.toString(makeAddr("gemini")));
        vm.setEnv("WORKER_GROK", vm.toString(makeAddr("grok")));
        vm.setEnv("WORKER_DEEPSEEK", vm.toString(makeAddr("deepseek")));
        vm.setEnv("WATCHER", vm.toString(makeAddr("watcher")));

        DeployMainnetHarness script = new DeployMainnetHarness();
        vm.setEnv("BRAIN_TOKEN", vm.toString(address(usdg)));
        vm.expectRevert(bytes("BRAIN_TOKEN is not an 18-decimal token"));
        script.deploy();

        vm.setEnv("BRAIN_TOKEN", vm.toString(address(brainToken)));
        vm.setEnv("WATCHER", vm.toString(address(0)));
        vm.expectRevert(bytes("WATCHER is unset"));
        script.deploy();
        vm.setEnv("WATCHER", vm.toString(address(script)));
        vm.expectRevert(bytes("WATCHER is the deploying key"));
        script.deploy();
        vm.setEnv("WATCHER", vm.toString(makeAddr("brain")));
        vm.expectRevert(bytes("WATCHER is the brain"));
        script.deploy();

        vm.setEnv("WATCHER", vm.toString(makeAddr("watcher")));
        DeployMainnet.Deployment memory off = script.deploy();
        assertEq(address(off.board.payouts()), address(0));
        assertEq(off.board.payoutHouse(), address(0));

        vm.setEnv("PAYOUT_PREFERENCES", vm.toString(makeAddr("no code")));
        vm.expectRevert(bytes("PAYOUT_PREFERENCES has no code on this chain"));
        script.deploy();

        PayoutPreferences preferences = new PayoutPreferences();
        vm.setEnv("PAYOUT_PREFERENCES", vm.toString(address(preferences)));
        DeployMainnet.Deployment memory d = script.deploy();

        assertEq(address(d.board.payouts()), address(preferences));
        assertEq(d.board.payoutHouse(), address(d.executor));
        assertEq(d.board.owner(), address(d.executor));

        assertEq(address(d.board.staking()), address(d.staking));
        assertTrue(d.staking.slashers(address(d.board)));
        assertEq(d.staking.owner(), address(d.admin));
        assertEq(address(d.staking.token()), address(brainToken));
        assertEq(d.staking.minStake(), 1_000_000e18);
        assertEq(d.staking.cooldown(), 3 days);
        assertEq(d.staking.slashBps(), 2_000);
        assertEq(address(d.bonds.token()), address(brainToken));
        assertEq(address(d.bonds.decisions()), address(d.decisionLog));
        assertEq(address(d.bonds.executor()), address(d.executor));
        assertEq(d.bonds.owner(), address(d.admin));
        assertEq(d.bonds.bond(), 250_000e18);
        assertEq(d.bonds.decideWithin(), 7 days);
        assertEq(d.board.feeRouter(), feeRecipient);
        (uint64 appealWindow, uint16 appealBondBps) = d.board.appealConfig();
        assertEq(appealWindow, 24 hours);
        assertEq(appealBondBps, 2_500);
        assertEq(d.executor.changeThresholdBps(), 6_000);
        assertEq(d.executor.timelock(), 48 hours);
        (uint16 hireBps, uint16 gradeBps, uint16 ruleBps,,,,,,) = d.board.config();
        assertEq(hireBps, 1_500);
        assertEq(gradeBps, 8_000);
        assertEq(ruleBps, 8_000);

        address worker = makeAddr("worker");
        brainToken.transfer(worker, 1_000_000e18);
        vm.startPrank(worker);
        brainToken.approve(address(d.staking), 1_000_000e18);
        d.staking.stake(1_000_000e18, 0.5e6);
        vm.stopPrank();
        (address account, bool active,) = d.staking.worker(d.staking.idOf(worker));
        assertEq(account, worker);
        assertTrue(active);
    }
}
