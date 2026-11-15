// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IAuthCaptureEscrow, JudgedCapture} from "../src/escrow/JudgedCapture.sol";

/// @notice Deploys JudgedCapture on Base (chain 8453): the operator of the
/// commerce-payments escrow for USDC payments BrainChain judges, with a cap of
/// 25 USDC per payment, which the owner can later change through the delay.
///
/// A plain run only simulates the deployment and prints the address:
///
///   OWNER=<Base Safe> BRAIN=<brain key> forge script script/DeployJudgedCapture.s.sol --rpc-url https://mainnet.base.org
///
/// It refuses `--broadcast` unless DEPLOY_JUDGED_CAPTURE=true is set as well.
///
/// Env: OWNER (the owners' Safe on Base), BRAIN (the key that signs final decisions).
contract DeployJudgedCapture is Script {
    IAuthCaptureEscrow constant ESCROW = IAuthCaptureEscrow(0xf96815976523E00e65Be8f34cA5e64b4f41EB19c);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 constant CAP = 25e6;

    function run() external returns (JudgedCapture judged) {
        require(block.chainid == 8453, "not Base (8453): pass --rpc-url https://mainnet.base.org");
        require(
            vm.isContext(VmSafe.ForgeContext.ScriptDryRun) || vm.envOr("DEPLOY_JUDGED_CAPTURE", false),
            "a dry run only: set DEPLOY_JUDGED_CAPTURE=true to broadcast"
        );
        address owner = vm.envAddress("OWNER");
        address brain = vm.envAddress("BRAIN");

        vm.startBroadcast();
        judged = _deploy(owner, brain);
        vm.stopBroadcast();
        console2.log("JudgedCapture", address(judged));
    }

    function _deploy(address owner, address brain) internal returns (JudgedCapture judged) {
        require(owner.code.length > 0, "OWNER has no code: it should be the Base Safe");
        require(address(ESCROW).code.length > 0, "the escrow has no code");
        judged = new JudgedCapture(ESCROW, USDC, owner, brain, CAP);
        require(judged.owner() == owner && judged.brain() == brain, "JudgedCapture is not the owner's");
        require(judged.cap() == CAP && judged.token() == USDC, "JudgedCapture is mis-wired");
    }
}
