// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeskMandate, IAggregatorV3} from "../src/desks/DeskMandate.sol";
import {DeskMandateV2, ISettlerRegistry} from "../src/desks/DeskMandateV2.sol";

/// @notice Deploys DeskMandateV2 on Robinhood Chain (chain 4663) with the five models and the seven stock
/// tokens of the first mandate, each on the Chainlink feed the first mandate prices it by, and starts the
/// handover to the treasury Safe, which accepts with `acceptOwnership`.
///
/// A plain run only simulates the deployment and prints the address:
///
///   SAFE=<treasury Safe> OPERATOR=<desk key> forge script script/DeployDeskMandateV2.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sender <deployer>
///
/// It refuses `--broadcast` unless DEPLOY_DESK_MANDATE_V2=true is set as well. A fresh key's first transaction
/// lands at an address known in advance, so the brain release can name it before the deploy; with EXPECT set
/// to that address, the script refuses to deploy anywhere else.
///
/// After the Safe accepts, and before anything is funded, `check` reads back everything the deployer could
/// have changed while it was the owner and compares it with what this script set:
///
///   SAFE=<treasury Safe> OPERATOR=<desk key> forge script script/DeployDeskMandateV2.s.sol --sig "check(address)" <mandate> --rpc-url https://rpc.mainnet.chain.robinhood.com
///
/// Env: SAFE (the treasury Safe), OPERATOR (the brain's desk key), EXPECT (optional, the planned address).
contract DeployDeskMandateV2 is Script {
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;
    ISettlerRegistry constant SETTLERS = ISettlerRegistry(0x00000000000004533Fe15556B1E086BB1A72cEae);
    DeskMandate constant FIRST = DeskMandate(0xA76916D1b75a82776779fb9d7EB156A4E4a55099);
    uint8 constant DESKS = 5;
    uint256 constant STOCK_TOKENS = 7;

    // One order an hour, a 1% premium, half the desk's USDG per buy, and 1% of the desk a day in shortfall.
    // The stock feeds report at least once every 24 hours on weekdays and not from Friday night to Sunday
    // night: 25 hours keeps every weekday order priced and stops orders on Friday's prices by Saturday night.
    uint64 constant INTERVAL = 1 hours;
    uint16 constant PREMIUM_BPS = 100;
    uint16 constant MAX_BUY_BPS = 5_000;
    uint64 constant MAX_FEED_AGE = 25 hours;
    uint16 constant BUDGET_BPS = 100;

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
        require(safe.code.length > 0, "SAFE has no code: pass the treasury Safe");
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

    /// @notice Reverts unless `mandate` is owned by SAFE, run by OPERATOR, and still exactly as deployed.
    function check(DeskMandateV2 mandate) external view {
        require(
            mandate.owner() == vm.envAddress("SAFE") && mandate.pendingOwner() == address(0),
            "the Safe is not the owner"
        );
        _check(mandate, vm.envAddress("OPERATOR"));
        console2.log("DeskMandateV2 is as deployed", address(mandate));
    }

    function _deploy(address deployer, address safe, address operator) internal returns (DeskMandateV2 mandate) {
        bytes32[DESKS] memory models;
        for (uint8 i = 0; i < DESKS; i++) {
            (models[i],,,) = FIRST.desks(i);
        }
        mandate = new DeskMandateV2(USDG, ALLOWANCE_HOLDER, SETTLERS, deployer, operator, models);
        for (uint256 i = 0; i < FIRST.tokenCount(); i++) {
            address token = FIRST.tokens(i);
            (, IAggregatorV3 feed, bool live) = FIRST.venues(token);
            if (!live) continue;
            mandate.setVenue(token, feed, true, true);
            require(mandate.price(token) == FIRST.price(token), "a token prices differently from the first mandate");
        }
        // After listing, which prices each token: on a weekend the feeds are older than MAX_FEED_AGE.
        mandate.setBounds(INTERVAL, PREMIUM_BPS, MAX_BUY_BPS, MAX_FEED_AGE, BUDGET_BPS);
        mandate.transferOwnership(safe);
        require(mandate.pendingOwner() == safe, "the handover to the Safe did not start");
        _check(mandate, operator);
    }

    function _check(DeskMandateV2 mandate, address operator) internal view {
        require(
            mandate.USDG() == USDG && mandate.ALLOWANCE_HOLDER() == ALLOWANCE_HOLDER && mandate.SETTLERS() == SETTLERS,
            "USDG or 0x is not the deploy's"
        );
        require(mandate.operator() == operator, "the operator is not OPERATOR");
        require(!mandate.paused(), "the mandate is paused");
        require(
            mandate.interval() == INTERVAL && mandate.premiumBps() == PREMIUM_BPS && mandate.maxBuyBps() == MAX_BUY_BPS
                && mandate.maxFeedAge() == MAX_FEED_AGE && mandate.budgetBps() == BUDGET_BPS,
            "the bounds are not the deploy's"
        );
        uint256 listed;
        for (uint256 i = 0; i < FIRST.tokenCount(); i++) {
            address token = FIRST.tokens(i);
            (, IAggregatorV3 firstFeed, bool firstLive) = FIRST.venues(token);
            if (!firstLive) continue;
            (IAggregatorV3 feed, bool scaled, bool live) = mandate.venues(token);
            require(
                mandate.tokens(listed) == token && feed == firstFeed && scaled && live,
                "a venue is not the first mandate's"
            );
            require(mandate.booked(token) == 0, "a desk already holds a token");
            listed++;
        }
        require(
            listed == STOCK_TOKENS && mandate.tokenCount() == listed, "the listed tokens are not the seven stock tokens"
        );
        require(mandate.booked(address(USDG)) == 0, "a desk already holds USDG");
        for (uint8 i = 0; i < DESKS; i++) {
            (bytes32 model,,,) = FIRST.desks(i);
            (bytes32 copied,,, uint32 orders,,,) = mandate.desks(i);
            require(copied == model && orders == 0, "a desk is not the first mandate's or has traded");
        }
    }
}
