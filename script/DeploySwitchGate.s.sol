// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {SwitchGate, ISwitchTimelock} from "../src/SwitchGate.sol";

interface ISwitchTimelockRoles {
    function PROPOSER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Deploys a SwitchGate on BrainChain (chain 274663): the executor seat on the admin timelock through which the
/// guard runs the one release the owners' Safe armed. The deployer pays the gas and gets no power over the gate. The
/// gate can do nothing until the timelock grants it EXECUTOR_ROLE, which takes an operation the Safe schedules and,
/// 48 hours later, executes (docs/switch-gate.md).
///
/// Env: SAFE (the owners' Safe, the timelock's proposer), TIMELOCK (the admin timelock), OPERATOR (the guard's key),
/// GUARDIAN (the key that may pause), LOGS (the DecisionLogs, comma-separated, each owned by the timelock).
/// Without --broadcast it simulates the deployment and prints the address:
///   SAFE=<safe> TIMELOCK=<timelock> OPERATOR=<operator> GUARDIAN=<guardian> LOGS=<log>,<log> forge script \
///     script/DeploySwitchGate.s.sol --rpc-url https://rpc.usebrainchain.com
/// Add --keystore <deployer keystore> --password-file <its password> --sender <deployer> --broadcast to deploy.
contract DeploySwitchGate is Script {
    function run() external {
        require(block.chainid == 274663, "not BrainChain (274663): pass --rpc-url https://rpc.usebrainchain.com");
        address safe = vm.envAddress("SAFE");
        address timelock = vm.envAddress("TIMELOCK");
        address operator = vm.envAddress("OPERATOR");
        address guardian = vm.envAddress("GUARDIAN");
        address[] memory logs = vm.envAddress("LOGS", ",");
        require(safe.code.length > 0, "SAFE has no code");
        require(timelock.code.length > 0, "TIMELOCK has no code");
        ISwitchTimelockRoles roles = ISwitchTimelockRoles(timelock);
        require(roles.hasRole(roles.PROPOSER_ROLE(), safe), "SAFE is not the timelock's proposer");
        require(operator != address(0) && operator != safe, "OPERATOR is zero or the Safe");
        require(guardian != address(0) && guardian != safe, "GUARDIAN is zero or the Safe");
        require(operator != guardian, "OPERATOR and GUARDIAN are the same key");
        require(logs.length > 0, "LOGS is empty");

        vm.startBroadcast();
        SwitchGate gate = new SwitchGate(safe, ISwitchTimelock(timelock), operator, guardian, logs);
        vm.stopBroadcast();

        require(gate.safe() == safe && address(gate.timelock()) == timelock, "the gate names another Safe or timelock");
        require(gate.operator() == operator && gate.guardian() == guardian, "the gate names other keys");
        require(gate.armed() == bytes32(0) && !gate.paused(), "the gate starts armed or paused");
        console2.log("SwitchGate", address(gate));
        console2.log("safe", safe);
        console2.log("timelock", timelock);
        console2.log("operator", operator);
        console2.log("guardian", guardian);
        for (uint256 i; i < logs.length; i++) {
            require(gate.isLog(logs[i]), "a log is not listed");
            console2.log("log", logs[i]);
        }
    }
}
