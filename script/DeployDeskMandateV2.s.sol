// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeskMandate, IAggregatorV3} from "../src/desks/DeskMandate.sol";
import {DeskMandateV2, IPriceFeed, ISettlerRegistry} from "../src/desks/DeskMandateV2.sol";

/// @notice Deploys DeskMandateV2 on Robinhood Chain (chain 4663) with the five models and the seven stock
/// tokens of the first mandate, each on the Chainlink feed the first mandate prices it by, and starts the
/// handover to the treasury Safe, which accepts with `acceptOwnership`.
///
/// A plain run only simulates the deployment and prints the address:
///
///   SAFE=<treasury Safe> OPERATOR=<desk key> forge script script/DeployDeskMandateV2.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com
///
/// It refuses `--broadcast` unless DEPLOY_DESK_MANDATE_V2=true is set as well. With EXPECT set, it refuses
/// unless the contract lands there: deployed by a fresh key as its first transaction, the address is
/// known before the brain release that names it is built.
///
/// Env: SAFE (the treasury Safe), OPERATOR (the brain's desk key), EXPECT (optional, the planned address).
contract DeployDeskMandateV2 is Script {
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    ISettlerRegistry constant SETTLERS = ISettlerRegistry(0x00000000000004533Fe15556B1E086BB1A72cEae);
    DeskMandate constant FIRST = DeskMandate(0xA76916D1b75a82776779fb9d7EB156A4E4a55099);

    function run() external returns (DeskMandateV2 mandate) {
        require(
            block.chainid == 4663, "not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"
        );
        require(
            vm.isContext(VmSafe.ForgeContext.ScriptDryRun) || vm.envOr("DEPLOY_DESK_MANDATE_V2", false),
            "a dry run only: set DEPLOY_DESK_MANDATE_V2=true to broadcast"
        );
        address safe = vm.envAddress("SAFE");
        address operator = vm.envAddress("OPERATOR");
        require(safe.code.length > 0, "SAFE has no code: it should be the treasury Safe");
        require(ALLOWANCE_HOLDER.code.length > 0 && address(SETTLERS).code.length > 0, "0x is not deployed here");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address expected = vm.envOr("EXPECT", address(0));
        if (expected != address(0)) {
            require(
                vm.computeCreateAddress(deployer, vm.getNonce(deployer)) == expected,
                "the deployer would not land at EXPECT: use a fresh key and make this its first transaction"
            );
        }
        mandate = _deploy(deployer, safe, operator);
        vm.stopBroadcast();
        console2.log("DeskMandateV2", address(mandate));
    }

    function _deploy(address deployer, address safe, address operator) internal returns (DeskMandateV2 mandate) {
        bytes32[5] memory models;
        for (uint8 i = 0; i < 5; i++) {
            (models[i],,,) = FIRST.desks(i);
        }
        mandate = new DeskMandateV2(USDG, ALLOWANCE_HOLDER, SETTLERS, deployer, operator, models);
        uint256 listed;
        for (uint256 i = 0; i < FIRST.tokenCount(); i++) {
            address token = FIRST.tokens(i);
            (, IAggregatorV3 feed, bool live) = FIRST.venues(token);
            if (!live) continue;
            mandate.setVenue(token, IPriceFeed(address(feed)), true, true);
            require(mandate.price(token) == FIRST.price(token), "a token prices differently from the first mandate");
            listed++;
        }
        mandate.transferOwnership(safe);
        require(mandate.pendingOwner() == safe && mandate.operator() == operator, "DeskMandateV2 is mis-wired");
        require(listed == 7 && mandate.tokenCount() == listed, "the seven stock tokens are not all listed");
    }
}
