// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployMainnet} from "../script/DeployMainnet.s.sol";
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

        DeployMainnetHarness script = new DeployMainnetHarness();
        vm.setEnv("BRAIN_TOKEN", vm.toString(address(usdg)));
        vm.expectRevert(bytes("BRAIN_TOKEN is not an 18-decimal token"));
        script.deploy();

        vm.setEnv("BRAIN_TOKEN", vm.toString(address(brainToken)));
        DeployMainnet.Deployment memory d = script.deploy();

        assertEq(address(d.board.staking()), address(d.staking));
        assertEq(d.staking.slasher(), address(d.board));
        assertEq(d.staking.owner(), address(d.executor));
        assertEq(address(d.staking.token()), address(brainToken));
        assertEq(d.staking.minStake(), 1_000_000e18);
        assertEq(d.staking.cooldown(), 3 days);
        assertEq(d.staking.slashBps(), 2_000);
        assertEq(address(d.bonds.token()), address(brainToken));
        assertEq(address(d.bonds.decisions()), address(d.decisionLog));
        assertEq(address(d.bonds.executor()), address(d.executor));
        assertEq(d.bonds.owner(), address(d.executor));
        assertEq(d.bonds.bond(), 250_000e18);
        assertEq(d.bonds.decideWithin(), 7 days);
        assertEq(d.board.feeRouter(), feeRecipient);

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
