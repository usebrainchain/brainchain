// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ProofIndex} from "../src/ProofIndex.sol";

/// @dev The `isMet` of Shipped's StaticCallCheck
/// (0x2e7C4F0F2e6079C3B5F7Cd2440308234CBDc537D on Robinhood Chain), copied so
/// the test reads the index exactly as a delivery bond does.
contract ShippedCheck {
    enum Op {
        Gte,
        Gt,
        Lte,
        Lt,
        Eq,
        Neq,
        CodeExists
    }

    uint256 public constant CALL_GAS = 500_000;

    function isMet(uint256, bytes calldata data) external view returns (bool) {
        (address target, bytes memory callData, Op op, uint256 threshold) =
            abi.decode(data, (address, bytes, Op, uint256));
        if (op == Op.CodeExists) return target.code.length > 0;
        if (target.code.length == 0) return false;
        (bool ok, bytes memory ret) = target.staticcall{gas: CALL_GAS}(callData);
        if (!ok || ret.length < 32) return false;
        uint256 value = abi.decode(ret, (uint256));
        if (op == Op.Gte) return value >= threshold;
        if (op == Op.Gt) return value > threshold;
        if (op == Op.Lte) return value <= threshold;
        if (op == Op.Lt) return value < threshold;
        if (op == Op.Eq) return value == threshold;
        return value != threshold;
    }
}

contract ProofIndexTest is Test {
    event ProofSet(uint256 indexed taskId, uint256 indexed tokenId);
    event OperatorSet(address indexed operator);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    address constant PROOFS = 0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169;
    uint256 constant BOARD_CHAIN_ID = 274663;

    ProofIndex index;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");

    function setUp() public {
        index = new ProofIndex(owner, operator, PROOFS, BOARD_CHAIN_ID);
    }

    function test_constructorChecks() public {
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        new ProofIndex(address(0), operator, PROOFS, BOARD_CHAIN_ID);
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        new ProofIndex(owner, address(0), PROOFS, BOARD_CHAIN_ID);
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        new ProofIndex(owner, operator, address(0), BOARD_CHAIN_ID);

        vm.expectEmit(true, true, true, true);
        emit OwnerSet(owner);
        vm.expectEmit(true, true, true, true);
        emit OperatorSet(operator);
        ProofIndex fresh = new ProofIndex(owner, operator, PROOFS, BOARD_CHAIN_ID);
        assertEq(fresh.owner(), owner);
        assertEq(fresh.operator(), operator);
        assertEq(fresh.pendingOwner(), address(0));
        assertEq(fresh.COLLECTION(), PROOFS);
        assertEq(fresh.BOARD_CHAIN_ID(), BOARD_CHAIN_ID);
    }

    function test_setProofRecordsTheToken() public {
        assertEq(index.proofOf(7), 0);
        vm.prank(operator);
        vm.expectEmit(true, true, true, true, address(index));
        emit ProofSet(7, 3);
        index.setProof(7, 3);
        assertEq(index.proofOf(7), 3);
        assertEq(index.proofOf(8), 0);
    }

    function test_setProofIsWrittenOnce() public {
        vm.startPrank(operator);
        index.setProof(7, 3);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(7, 4);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(7, 3);
        vm.stopPrank();
        assertEq(index.proofOf(7), 3);
    }

    function test_setProofRefusesTokenZero() public {
        vm.prank(operator);
        vm.expectRevert(ProofIndex.ZeroToken.selector);
        index.setProof(7, 0);
        assertEq(index.proofOf(7), 0);
    }

    function test_onlyTheOperatorWrites() public {
        vm.prank(owner);
        vm.expectRevert(ProofIndex.NotOperator.selector);
        index.setProof(7, 3);
        vm.prank(stranger);
        vm.expectRevert(ProofIndex.NotOperator.selector);
        index.setProof(7, 3);
        assertEq(index.proofOf(7), 0);
    }

    function test_ownerRotatesTheOperator() public {
        address next = makeAddr("next operator");

        vm.prank(operator);
        vm.expectRevert(ProofIndex.NotOwner.selector);
        index.setOperator(next);
        vm.prank(owner);
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        index.setOperator(address(0));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(index));
        emit OperatorSet(next);
        index.setOperator(next);
        assertEq(index.operator(), next);

        vm.prank(operator);
        vm.expectRevert(ProofIndex.NotOperator.selector);
        index.setProof(7, 3);
        vm.prank(next);
        index.setProof(7, 3);
        assertEq(index.proofOf(7), 3);
    }

    function test_ownershipMovesInTwoSteps() public {
        address next = makeAddr("next owner");

        vm.prank(stranger);
        vm.expectRevert(ProofIndex.NotOwner.selector);
        index.transferOwnership(next);
        vm.prank(owner);
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        index.transferOwnership(address(0));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(index));
        emit OwnershipTransferStarted(owner, next);
        index.transferOwnership(next);
        assertEq(index.owner(), owner);
        assertEq(index.pendingOwner(), next);

        vm.prank(stranger);
        vm.expectRevert(ProofIndex.NotPendingOwner.selector);
        index.acceptOwnership();

        vm.prank(next);
        vm.expectEmit(true, true, true, true, address(index));
        emit OwnerSet(next);
        index.acceptOwnership();
        assertEq(index.owner(), next);
        assertEq(index.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(ProofIndex.NotOwner.selector);
        index.setOperator(stranger);
        vm.prank(next);
        index.setOperator(stranger);
        assertEq(index.operator(), stranger);
    }

    function testFuzz_setProof(uint256 taskId, uint256 tokenId, uint256 other) public {
        vm.assume(tokenId != 0 && other != 0);
        vm.startPrank(operator);
        index.setProof(taskId, tokenId);
        assertEq(index.proofOf(taskId), tokenId);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(taskId, other);
        vm.stopPrank();
        assertEq(index.proofOf(taskId), tokenId);
    }

    /// @dev A delivery bond on task 42 with the check data a worker's bond
    /// carries: `proofOf(42) >= 1` on the index. The check is not met until the
    /// Proof is recorded and stays met afterwards.
    function test_shippedCheckReadsTheIndex() public {
        ShippedCheck check = new ShippedCheck();
        uint256 taskId = 42;
        bytes memory data =
            abi.encode(address(index), abi.encodeWithSignature("proofOf(uint256)", taskId), ShippedCheck.Op.Gte, 1);

        assertFalse(check.isMet(0, data));

        vm.prank(operator);
        index.setProof(taskId, 118);
        assertTrue(check.isMet(0, data));

        bytes memory otherTask =
            abi.encode(address(index), abi.encodeWithSignature("proofOf(uint256)", taskId + 1), ShippedCheck.Op.Gte, 1);
        assertFalse(check.isMet(0, otherTask));

        bytes memory noIndex =
            abi.encode(stranger, abi.encodeWithSignature("proofOf(uint256)", taskId), ShippedCheck.Op.Gte, 1);
        assertFalse(check.isMet(0, noIndex));

        bytes memory badCall = abi.encode(address(index), abi.encodeWithSignature("nothing()"), ShippedCheck.Op.Gte, 1);
        assertFalse(check.isMet(0, badCall));
    }
}
