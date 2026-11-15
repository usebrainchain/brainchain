// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// Grants the operator key the executor role on the real AdminTimelock through the admin Safe, then checks what the
/// role allows: executing an operation the Safe scheduled once it is ready, and nothing else. Skips unless
/// BRAINCHAIN_RPC is set:
///   BRAINCHAIN_RPC=https://rpc.usebrainchain.com forge test --match-path test/fork/OperatorExecutorFork.t.sol -vv
contract OperatorExecutorForkTest is Test {
    TimelockController constant TIMELOCK = TimelockController(payable(0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e));
    address constant SAFE = 0xdFeFbdBF680568e8DC44abbbd657c0701964cC8c;
    address constant OPERATOR = 0x70C665780E43BA1496a4E691e408F24844dB58eC;
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    uint256 delay;

    function setUp() public {
        string memory rpc = vm.envOr("BRAINCHAIN_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        delay = TIMELOCK.getMinDelay();
        assertFalse(TIMELOCK.hasRole(EXECUTOR_ROLE, address(0)), "the executor role is not open to everyone");
        if (TIMELOCK.hasRole(EXECUTOR_ROLE, OPERATOR)) return;

        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            _one(address(TIMELOCK), abi.encodeCall(IAccessControl.grantRole, (EXECUTOR_ROLE, OPERATOR)));
        bytes32 salt = keccak256("op-2a: operator executes ready operations");
        vm.prank(SAFE);
        TIMELOCK.scheduleBatch(t, v, p, 0, salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(SAFE);
        TIMELOCK.executeBatch(t, v, p, 0, salt);
        assertTrue(TIMELOCK.hasRole(EXECUTOR_ROLE, OPERATOR));
    }

    function _one(address target, bytes memory data)
        private
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory p)
    {
        t = new address[](1);
        v = new uint256[](1);
        p = new bytes[](1);
        t[0] = target;
        p[0] = data;
    }

    function test_executesWhatTheSafeScheduledOnceReady() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            _one(address(TIMELOCK), abi.encodeCall(TimelockController.updateDelay, (delay)));
        bytes32 salt = keccak256("a routine operation");
        bytes32 id = TIMELOCK.hashOperationBatch(t, v, p, 0, salt);

        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(4))
            )
        );
        TIMELOCK.executeBatch(t, v, p, 0, salt);

        vm.prank(SAFE);
        TIMELOCK.scheduleBatch(t, v, p, 0, salt, delay);
        vm.warp(block.timestamp + delay - 1);
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(4))
            )
        );
        TIMELOCK.executeBatch(t, v, p, 0, salt);

        vm.warp(block.timestamp + 1);
        vm.prank(OPERATOR);
        TIMELOCK.executeBatch(t, v, p, 0, salt);
        assertTrue(TIMELOCK.isOperationDone(id));

        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(4))
            )
        );
        TIMELOCK.executeBatch(t, v, p, 0, salt);
    }

    function test_cannotScheduleCancelOrChangeRoles() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            _one(address(TIMELOCK), abi.encodeCall(TimelockController.updateDelay, (0)));
        bytes32 salt = keccak256("the operator's own operation");

        vm.startPrank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, PROPOSER_ROLE)
        );
        TIMELOCK.scheduleBatch(t, v, p, 0, salt, delay);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, PROPOSER_ROLE)
        );
        TIMELOCK.schedule(t[0], 0, p[0], 0, salt, delay);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, bytes32(0))
        );
        TIMELOCK.grantRole(PROPOSER_ROLE, OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, bytes32(0))
        );
        TIMELOCK.revokeRole(EXECUTOR_ROLE, SAFE);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, OPERATOR));
        TIMELOCK.updateDelay(0);
        vm.stopPrank();

        vm.prank(SAFE);
        TIMELOCK.scheduleBatch(t, v, p, 0, salt, delay);
        bytes32 id = TIMELOCK.hashOperationBatch(t, v, p, 0, salt);
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, CANCELLER_ROLE)
        );
        TIMELOCK.cancel(id);
    }

    function test_theSafeRevokesTheRole() public {
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            _one(address(TIMELOCK), abi.encodeCall(IAccessControl.revokeRole, (EXECUTOR_ROLE, OPERATOR)));
        bytes32 salt = keccak256("op-2a: revoke");
        vm.prank(SAFE);
        TIMELOCK.scheduleBatch(t, v, p, 0, salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(SAFE);
        TIMELOCK.executeBatch(t, v, p, 0, salt);
        assertFalse(TIMELOCK.hasRole(EXECUTOR_ROLE, OPERATOR));
        assertTrue(TIMELOCK.hasRole(EXECUTOR_ROLE, SAFE));
    }
}
