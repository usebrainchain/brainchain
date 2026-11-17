// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {DeployRewards} from "../script/DeployRewards.s.sol";

/// The script refuses a single-key treasury, the setup 3.1.0 replaced, before it deploys anything.
contract DeployRewardsTest is Test {
    function test_refusesInputsWithoutCode() public {
        vm.chainId(4663);
        address safe = makeAddr("safe");
        address escrow = makeAddr("escrow");
        vm.etch(safe, hex"00");
        // The script reads the process environment, which every test shares, so every case runs in this one test.
        vm.setEnv("OWNER_SAFE", vm.toString(safe));
        vm.setEnv("PUBLISHER", vm.toString(makeAddr("publisher")));
        vm.setEnv("PONS_ESCROW", vm.toString(escrow));
        vm.setEnv("TREASURY", vm.toString(makeAddr("treasury-key")));
        DeployRewards script = new DeployRewards();

        vm.expectRevert(bytes("TREASURY has no code: the treasury half goes to a Safe, not a single key"));
        script.run();
        vm.setEnv("TREASURY", vm.toString(safe));
        vm.expectRevert(bytes("PONS_ESCROW has no code"));
        script.run();
        vm.setEnv("OWNER_SAFE", vm.toString(makeAddr("owner-key")));
        vm.expectRevert(bytes("OWNER_SAFE has no code"));
        script.run();

        vm.chainId(274663);
        vm.expectRevert(bytes("not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"));
        script.run();
    }
}
