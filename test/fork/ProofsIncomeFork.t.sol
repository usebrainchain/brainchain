// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {ProofsIncome, IWETH, IProofs} from "../../src/rewards/ProofsIncome.sol";

// ProofsIncome against the real WETH and the deployed FeeSplitter on a fork of
// Robinhood Chain (chain 4663). Skipped without a fork:
//   forge test --match-path test/fork/ProofsIncomeFork.t.sol --fork-url https://rpc.mainnet.chain.robinhood.com -vv

contract MockProofs is ERC721 {
    uint256 public totalSupply;

    constructor() ERC721("BrainChain Proofs", "PROOF") {}

    function mint(address to) external returns (uint256 id) {
        id = ++totalSupply;
        _mint(to, id);
    }
}

contract ProofsIncomeForkTest is Test {
    IWETH constant WETH = IWETH(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address constant FEE_SPLITTER = 0x15Cf18dBA874EA0c77ED8Cecf38aDa64697102fb;
    address constant SAFE = 0x9a4B2A33644D3a65059cAA8E0A46b988bcC1D52d;

    function test_incomeFlowsThroughRealWethAndSplitter() public {
        vm.skip(block.chainid != 4663);
        MockProofs proofs = new MockProofs();
        ProofsIncome income = new ProofsIncome(WETH, FEE_SPLITTER, SAFE, SAFE, 5000, 2500, 0.001 ether);
        income.bindProofs(IProofs(address(proofs)));

        address holder = makeAddr("holder");
        proofs.mint(holder);
        proofs.mint(holder);

        address launchTreasury = makeAddr("launch treasury");
        vm.deal(launchTreasury, 1 ether);
        vm.startPrank(launchTreasury);
        (bool ok,) = address(WETH).call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        WETH.transfer(address(income), 1 ether);
        vm.stopPrank();

        uint256 splitterBefore = FEE_SPLITTER.balance;
        uint256 safeBefore = SAFE.balance;
        income.distribute();
        assertEq(FEE_SPLITTER.balance - splitterBefore, 0.25 ether);
        assertEq(SAFE.balance - safeBefore, 0.25 ether);
        assertEq(income.reserved(), 0.5 ether);
        assertEq(WETH.balanceOf(address(income)), 0);

        income.claim(1);
        assertEq(holder.balance, 0.25 ether);
        assertEq(income.due(2), 0.25 ether);
    }
}
