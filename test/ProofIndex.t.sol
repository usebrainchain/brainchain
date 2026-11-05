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
    event ProofSet(address indexed board, uint256 indexed taskId, uint256 indexed tokenId);
    event OperatorSet(address indexed operator);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnerSet(address indexed owner);

    address constant PROOFS = 0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169;
    address constant BOARD = 0x8385bb4b8990411CcdD8e851B2676da1A4C1f3C4;
    uint256 constant BOARD_CHAIN_ID = 274663;

    ProofIndex index;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address stranger = makeAddr("stranger");
    address nextBoard = makeAddr("next board");

    function setUp() public {
        index = new ProofIndex(owner, operator, PROOFS, BOARD_CHAIN_ID);
    }

    function checkData(address board, uint256 taskId) internal view returns (bytes memory) {
        return abi.encode(
            address(index), abi.encodeWithSignature("proofOf(address,uint256)", board, taskId), ShippedCheck.Op.Gte, 1
        );
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
        assertEq(index.proofOf(BOARD, 7), 0);
        vm.prank(operator);
        vm.expectEmit(true, true, true, true, address(index));
        emit ProofSet(BOARD, 7, 3);
        index.setProof(BOARD, 7, 3);
        assertEq(index.proofOf(BOARD, 7), 3);
        assertEq(index.proofOf(BOARD, 8), 0);
        assertEq(index.proofOf(nextBoard, 7), 0);
    }

    function test_setProofIsWrittenOnce() public {
        vm.startPrank(operator);
        index.setProof(BOARD, 7, 3);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(BOARD, 7, 4);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(BOARD, 7, 3);
        vm.stopPrank();
        assertEq(index.proofOf(BOARD, 7), 3);
    }

    /// @dev Task ids start over with each contract set, so the same id on the
    /// next board is a different task.
    function test_boardsKeepTheirOwnTasks() public {
        vm.startPrank(operator);
        index.setProof(BOARD, 7, 3);
        index.setProof(nextBoard, 7, 9);
        vm.stopPrank();
        assertEq(index.proofOf(BOARD, 7), 3);
        assertEq(index.proofOf(nextBoard, 7), 9);
    }

    function test_setProofRefusesTokenZeroAndBoardZero() public {
        vm.prank(operator);
        vm.expectRevert(ProofIndex.ZeroToken.selector);
        index.setProof(BOARD, 7, 0);
        vm.prank(operator);
        vm.expectRevert(ProofIndex.ZeroAddress.selector);
        index.setProof(address(0), 7, 3);
        assertEq(index.proofOf(BOARD, 7), 0);
        assertEq(index.proofOf(address(0), 7), 0);
    }

    function test_onlyTheOperatorWrites() public {
        vm.prank(owner);
        vm.expectRevert(ProofIndex.NotOperator.selector);
        index.setProof(BOARD, 7, 3);
        vm.prank(stranger);
        vm.expectRevert(ProofIndex.NotOperator.selector);
        index.setProof(BOARD, 7, 3);
        assertEq(index.proofOf(BOARD, 7), 0);
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
        index.setProof(BOARD, 7, 3);
        vm.prank(next);
        index.setProof(BOARD, 7, 3);
        assertEq(index.proofOf(BOARD, 7), 3);
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

    function testFuzz_setProof(address board, uint256 taskId, uint256 tokenId, uint256 other) public {
        vm.assume(board != address(0) && tokenId != 0 && other != 0);
        vm.startPrank(operator);
        index.setProof(board, taskId, tokenId);
        assertEq(index.proofOf(board, taskId), tokenId);
        vm.expectRevert(ProofIndex.AlreadySet.selector);
        index.setProof(board, taskId, other);
        vm.stopPrank();
        assertEq(index.proofOf(board, taskId), tokenId);
    }

    /// @dev A delivery bond on task 42 with the check data a worker's bond
    /// carries: `proofOf(board, 42) >= 1` on the index. The check is not met
    /// until the Proof is recorded and stays met afterwards.
    function test_shippedCheckReadsTheIndex() public {
        ShippedCheck check = new ShippedCheck();
        uint256 taskId = 42;
        bytes memory data = checkData(BOARD, taskId);

        assertFalse(check.isMet(0, data));

        vm.prank(operator);
        index.setProof(BOARD, taskId, 118);
        assertTrue(check.isMet(0, data));

        assertFalse(check.isMet(0, checkData(BOARD, taskId + 1)));
        assertFalse(check.isMet(0, checkData(nextBoard, taskId)));

        bytes memory noIndex = abi.encode(
            stranger, abi.encodeWithSignature("proofOf(address,uint256)", BOARD, taskId), ShippedCheck.Op.Gte, 1
        );
        assertFalse(check.isMet(0, noIndex));

        bytes memory oldShape =
            abi.encode(address(index), abi.encodeWithSignature("proofOf(uint256)", taskId), ShippedCheck.Op.Gte, 1);
        assertFalse(check.isMet(0, oldShape));
    }
}
