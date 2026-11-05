// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ProofIndex} from "../../src/ProofIndex.sol";

// ProofIndex read by the StaticCallCheck Shipped has deployed on Robinhood
// Chain (chain 4663). Skipped without a fork:
//   forge test --match-path test/fork/ProofIndexFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv

interface IMilestoneCheck {
    function isMet(uint256 bondId, bytes calldata data) external view returns (bool);
}

contract ProofIndexForkTest is Test {
    IMilestoneCheck constant CHECK = IMilestoneCheck(0x2e7C4F0F2e6079C3B5F7Cd2440308234CBDc537D);
    address constant PROOFS = 0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169;

    function test_shippedCheckSettlesFromTheIndex() public {
        vm.skip(block.chainid != 4663);
        address operator = makeAddr("operator");
        ProofIndex index = new ProofIndex(makeAddr("owner"), operator, PROOFS, 274663);
        uint256 taskId = 42;
        bytes memory data = abi.encode(address(index), abi.encodeWithSignature("proofOf(uint256)", taskId), 0, 1);

        assertFalse(CHECK.isMet(1, data));
        vm.prank(operator);
        index.setProof(taskId, 118);
        assertTrue(CHECK.isMet(1, data));
    }
}
