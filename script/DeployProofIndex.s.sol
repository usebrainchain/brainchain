// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {ProofIndex} from "../src/ProofIndex.sol";

/// @notice Deploys the ProofIndex on Robinhood Chain (chain 4663), next to the
/// BrainChain Proofs collection: the record Shipped's StaticCallCheck reads to
/// settle a delivery bond on a BrainChain task. The operator is the brain
/// service's key, which writes a task's Proof token id when it reveals the
/// Proof; the owner rotates that key. Record the deployed address under
/// `robinhoodChain.ProofIndex` in `deployments/mainnet.json` and inscribe the
/// deployment.
///
/// Env: OWNER (the owners' Safe), OPERATOR (the brain service's key).
contract DeployProofIndex is Script {
    address constant PROOFS = 0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169;
    uint256 constant BOARD_CHAIN_ID = 274663;

    function run() external {
        require(
            block.chainid == 4663, "not Robinhood Chain (4663): pass --rpc-url https://rpc.mainnet.chain.robinhood.com"
        );
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");
        require(owner != address(0), "OWNER is zero");
        require(operator != address(0), "OPERATOR is zero");
        require(PROOFS.code.length > 0, "the Proofs collection has no code");
        require(ERC165Checker.supportsInterface(PROOFS, 0x80ac58cd), "the Proofs collection is not an ERC-721");

        vm.startBroadcast();
        ProofIndex index = new ProofIndex(owner, operator, PROOFS, BOARD_CHAIN_ID);
        vm.stopBroadcast();

        require(index.owner() == owner && index.operator() == operator, "the index is not the owner's");
        require(index.COLLECTION() == PROOFS && index.BOARD_CHAIN_ID() == BOARD_CHAIN_ID, "the index is mis-wired");
        console2.log("ProofIndex", address(index));
    }
}
