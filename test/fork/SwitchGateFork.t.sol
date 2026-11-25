// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DecisionLog} from "../../src/DecisionLog.sol";
import {SwitchGate, ISwitchTimelock} from "../../src/SwitchGate.sol";

/// Runs release 13 (enclave v17), which the Safe scheduled on the real AdminTimelock, through a SwitchGate given the
/// executor role, once the Safe has armed it there. The fork is pinned to a block after releases 11 and 12 ran and
/// before release 13 is ready, so it keeps working once release 13 has run on BrainChain. Skips unless BRAINCHAIN_RPC
/// is set:
///   BRAINCHAIN_RPC=https://rpc.usebrainchain.com forge test --match-path test/fork/SwitchGateFork.t.sol -vv
contract SwitchGateForkTest is Test {
    TimelockController constant TIMELOCK = TimelockController(payable(0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e));
    address constant SAFE = 0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c;
    DecisionLog constant LOG_350 = DecisionLog(0x2EF509bd9cA1e7C5FBe2C2FD7Ff25cE9F6f9cB68);
    DecisionLog constant LOG_360 = DecisionLog(0x53e0137e45C8bAc1018802aD36060cDda3B159F0);
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 constant FORK_BLOCK = 5323;

    bytes32 constant OP = 0x531a3e08bc92c6111ef1cf8500c834834bdec7fd12c29b2b306af2299761dbb6;
    uint256 constant READY = 1795639560;
    bytes32 constant SALT = keccak256("brainchain mainnet enclave v17, image 116, release 13");
    bytes32 constant V17_APP = 0x3251e1baee0b9d2e076f1633f0079de324336853ad1e1a5a8f58ac15a537b4b6;
    bytes32 constant V16_APP = 0xdb8bc23d372d0364b56a671f1357bbb6efb1750bc6de84cc066cb41ea360da18;
    bytes constant ALLOW_V17 =
        hex"8bdea9553251e1baee0b9d2e076f1633f0079de324336853ad1e1a5a8f58ac15a537b4b60000000000000000000000000000000000000000000000000000000000000001";
    bytes constant DROP_V16 =
        hex"8bdea955db8bc23d372d0364b56a671f1357bbb6efb1750bc6de84cc066cb41ea360da180000000000000000000000000000000000000000000000000000000000000000";

    // Release 12, already run on BrainChain at block 5320.
    bytes32 constant V16_OP = 0xaa57c9c5d89084a26c0e8ce7706921a17212f57f0d12b099add730d588603703;
    bytes32 constant V16_SALT = 0xdcacefa4d7ba4410991d72031d64d80d845a2c600d70acaae1cbd4fabe44f6da;
    bytes constant ALLOW_V16 =
        hex"8bdea955db8bc23d372d0364b56a671f1357bbb6efb1750bc6de84cc066cb41ea360da180000000000000000000000000000000000000000000000000000000000000001";
    bytes constant DROP_V15 =
        hex"8bdea9557492b558beae61273f795c861b1d3fb028a7ff769dc14ac7c1d24d85dfded4910000000000000000000000000000000000000000000000000000000000000000";

    // A ready operation the Safe scheduled with `schedule`: the UpgradeExecutor calls ArbOwner.setNetworkFeeAccount.
    bytes32 constant FEE_OP = 0xb3493ae1cd51de830de1b10a486c0b76b494f560d28ef738d96465b256e55830;
    address constant UPGRADE_EXECUTOR = 0xf5B096ddE063311CaEC2F9665ef3E94eAb1280bA;
    bytes32 constant FEE_SALT = 0x740fd53dbc1bd2c8553c71cb66f1e38ab699a24fc41bc2084d0ab7c61c80ee39;
    bytes constant FEE_CALL =
        hex"bca8c7b5000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000024fcdde2b4000000000000000000000000183db433a7526d3faad8ba799c87cf18d9d6896a00000000000000000000000000000000000000000000000000000000";

    address operator = makeAddr("operator");
    SwitchGate gate;

    function setUp() public {
        string memory rpc = vm.envOr("BRAINCHAIN_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 274663);
        address[] memory logs = new address[](2);
        logs[0] = address(LOG_350);
        logs[1] = address(LOG_360);
        gate = new SwitchGate(SAFE, ISwitchTimelock(address(TIMELOCK)), operator, makeAddr("guardian"), logs);
    }

    function _release() internal pure returns (address[] memory t, bytes[] memory p) {
        t = new address[](4);
        p = new bytes[](4);
        (t[0], t[1], t[2], t[3]) = (address(LOG_350), address(LOG_350), address(LOG_360), address(LOG_360));
        (p[0], p[1], p[2], p[3]) = (ALLOW_V17, DROP_V16, ALLOW_V17, DROP_V16);
    }

    function _grant() internal {
        vm.prank(address(TIMELOCK));
        TIMELOCK.grantRole(EXECUTOR_ROLE, address(gate));
    }

    function _arm(bytes32 id) internal {
        vm.prank(SAFE);
        gate.arm(id);
    }

    function _notReady(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            id,
            bytes32(1 << uint8(TimelockController.OperationState.Ready))
        );
    }

    function test_theOperatorRunsReleaseThirteenThroughTheGate() public {
        assertTrue(TIMELOCK.hasRole(TIMELOCK.DEFAULT_ADMIN_ROLE(), address(TIMELOCK)), "the timelock is its own admin");
        assertFalse(TIMELOCK.hasRole(TIMELOCK.DEFAULT_ADMIN_ROLE(), SAFE));
        assertFalse(TIMELOCK.hasRole(EXECUTOR_ROLE, address(0)), "the executor role is not open");
        assertTrue(TIMELOCK.isOperationPending(OP));
        assertEq(TIMELOCK.getTimestamp(OP), READY);
        assertEq(ALLOW_V17, abi.encodeCall(DecisionLog.allowApp, (V17_APP, true)));
        assertEq(DROP_V16, abi.encodeCall(DecisionLog.allowApp, (V16_APP, false)));
        for (uint256 i; i < 2; i++) {
            DecisionLog log = i == 0 ? LOG_350 : LOG_360;
            assertEq(log.owner(), address(TIMELOCK));
            assertFalse(log.allowedApp(V17_APP));
            assertTrue(log.allowedApp(V16_APP));
        }

        (address[] memory t, bytes[] memory p) = _release();
        assertEq(TIMELOCK.hashOperationBatch(t, new uint256[](4), p, 0, SALT), OP);

        vm.warp(READY);
        _arm(OP);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(gate), EXECUTOR_ROLE
            )
        );
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), OP);

        _grant();
        _arm(bytes32(0));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, OP));
        gate.execute(t, p, 0, SALT);

        _arm(OP);
        vm.warp(READY - 1);
        vm.prank(operator);
        vm.expectRevert(_notReady(OP));
        gate.execute(t, p, 0, SALT);

        vm.warp(READY);
        vm.expectEmit(true, true, false, true, address(gate));
        emit SwitchGate.Executed(OP, operator);
        vm.prank(operator);
        gate.execute(t, p, 0, SALT);

        assertTrue(TIMELOCK.isOperationDone(OP));
        assertEq(gate.armed(), bytes32(0));
        for (uint256 i; i < 2; i++) {
            DecisionLog log = i == 0 ? LOG_350 : LOG_360;
            assertTrue(log.allowedApp(V17_APP));
            assertFalse(log.allowedApp(V16_APP));
        }
    }

    function test_theOperatorCannotRunAnyOtherBatch() public {
        _grant();
        vm.warp(READY);
        (address[] memory t, bytes[] memory p) = _release();
        uint256[] memory v = new uint256[](4);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, OP));
        gate.execute(t, p, 0, SALT);

        p[0] = abi.encodeCall(DecisionLog.allowApp, (keccak256("an enclave nobody approved"), true));
        p[2] = p[0];
        bytes32 madeUp = TIMELOCK.hashOperationBatch(t, v, p, 0, SALT);
        _arm(madeUp);
        vm.prank(operator);
        vm.expectRevert(_notReady(madeUp));
        gate.execute(t, p, 0, SALT);

        (t, p) = _release();
        bytes32 resalted = TIMELOCK.hashOperationBatch(t, v, p, 0, keccak256("release 13"));
        _arm(resalted);
        vm.prank(operator);
        vm.expectRevert(_notReady(resalted));
        gate.execute(t, p, 0, keccak256("release 13"));

        (p[0], p[1], p[2], p[3]) = (ALLOW_V16, DROP_V15, ALLOW_V16, DROP_V15);
        assertEq(TIMELOCK.hashOperationBatch(t, v, p, 0, V16_SALT), V16_OP);
        assertTrue(TIMELOCK.isOperationDone(V16_OP));
        _arm(V16_OP);
        vm.prank(operator);
        vm.expectRevert(_notReady(V16_OP));
        gate.execute(t, p, 0, V16_SALT);

        assertTrue(TIMELOCK.isOperationReady(FEE_OP));
        assertEq(TIMELOCK.hashOperation(UPGRADE_EXECUTOR, 0, FEE_CALL, 0, FEE_SALT), FEE_OP);
        address[] memory feeTargets = new address[](1);
        bytes[] memory feeCalls = new bytes[](1);
        feeTargets[0] = UPGRADE_EXECUTOR;
        feeCalls[0] = FEE_CALL;
        _arm(TIMELOCK.hashOperationBatch(feeTargets, new uint256[](1), feeCalls, 0, FEE_SALT));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 0));
        gate.execute(feeTargets, feeCalls, 0, FEE_SALT);

        feeTargets[0] = address(TIMELOCK);
        feeCalls[0] = abi.encodeCall(IAccessControl.grantRole, (TIMELOCK.PROPOSER_ROLE(), operator));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 0));
        gate.execute(feeTargets, feeCalls, 0, SALT);

        assertTrue(TIMELOCK.isOperationReady(OP));
        assertTrue(TIMELOCK.isOperationReady(FEE_OP));
        assertFalse(LOG_350.allowedApp(V17_APP));
        assertTrue(LOG_350.allowedApp(V16_APP));
    }
}
