// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {ProofsIncome, IWETH, IProofs} from "../src/rewards/ProofsIncome.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/// @dev Pieces minted in sequence from 1, like the launch's Collection721.
contract MockProofs is ERC721 {
    uint256 public totalSupply;

    constructor() ERC721("BrainChain Proofs", "PROOF") {}

    function mint(address to) external returns (uint256 id) {
        id = ++totalSupply;
        _mint(to, id);
    }
}

contract Rejecting {
    receive() external payable {
        revert("no");
    }
}

contract ProofsIncomeTest is Test {
    MockWETH weth;
    MockProofs proofs;
    ProofsIncome income;

    address owner = makeAddr("owner");
    address splitter = makeAddr("splitter");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        weth = new MockWETH();
        proofs = new MockProofs();
        income = new ProofsIncome(IWETH(address(weth)), splitter, treasury, owner, 5000, 2500, 0);
        income.bindProofs(IProofs(address(proofs)));
    }

    function pay(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(income), amount);
    }

    function test_constructorChecks() public {
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        new ProofsIncome(IWETH(address(0)), splitter, treasury, owner, 5000, 2500, 0);
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        new ProofsIncome(IWETH(address(weth)), address(0), treasury, owner, 5000, 2500, 0);
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        new ProofsIncome(IWETH(address(weth)), splitter, address(0), owner, 5000, 2500, 0);
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        new ProofsIncome(IWETH(address(weth)), splitter, treasury, address(0), 5000, 2500, 0);
        vm.expectRevert(ProofsIncome.BadShares.selector);
        new ProofsIncome(IWETH(address(weth)), splitter, treasury, owner, 5001, 5000, 0);
        ProofsIncome fresh = new ProofsIncome(IWETH(address(weth)), splitter, treasury, owner, 5000, 2500, 1 ether);
        assertEq(fresh.deployer(), address(this));
        assertEq(fresh.minRound(), 1 ether);
        assertEq(address(fresh.proofs()), address(0));
    }

    function test_bindProofsOnceByDeployer() public {
        ProofsIncome fresh = new ProofsIncome(IWETH(address(weth)), splitter, treasury, owner, 5000, 2500, 0);
        vm.prank(alice);
        vm.expectRevert(ProofsIncome.NotDeployer.selector);
        fresh.bindProofs(IProofs(address(proofs)));
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        fresh.bindProofs(IProofs(address(0)));
        vm.expectRevert(ProofsIncome.BadProofs.selector);
        fresh.bindProofs(IProofs(alice));
        vm.expectRevert(ProofsIncome.BadProofs.selector);
        fresh.bindProofs(IProofs(address(weth)));
        fresh.bindProofs(IProofs(address(proofs)));
        assertEq(address(fresh.proofs()), address(proofs));
        vm.expectRevert(ProofsIncome.ProofsSet.selector);
        fresh.bindProofs(IProofs(address(proofs)));
    }

    function test_distributeNeedsProofsBound() public {
        ProofsIncome fresh = new ProofsIncome(IWETH(address(weth)), splitter, treasury, owner, 5000, 2500, 0);
        vm.deal(address(fresh), 1 ether);
        vm.expectRevert(ProofsIncome.NoProofs.selector);
        fresh.distribute();
    }

    function test_distributeSplitsAndReservesHoldersShare() public {
        for (uint256 i = 0; i < 4; i++) {
            proofs.mint(alice);
        }
        pay(1 ether);
        assertEq(income.undistributed(), 1 ether);

        vm.expectEmit();
        emit ProofsIncome.Distributed(1, 0.125 ether, 4, 0.25 ether, 0.25 ether);
        income.distribute();

        assertEq(weth.balanceOf(address(income)), 0);
        assertEq(address(income).balance, 0.5 ether);
        assertEq(income.reserved(), 0.5 ether);
        assertEq(income.undistributed(), 0);
        assertEq(splitter.balance, 0.25 ether);
        assertEq(treasury.balance, 0.25 ether);
        assertEq(income.rounds(), 1);
        for (uint256 id = 1; id <= 4; id++) {
            assertEq(income.due(id), 0.125 ether);
        }
        assertEq(income.due(5), 0);
    }

    function test_laterProofsJoinFromTheirFirstRound() public {
        proofs.mint(alice);
        proofs.mint(alice);
        pay(1 ether);
        income.distribute();
        proofs.mint(bob);
        pay(0.3 ether);
        income.distribute();

        assertEq(income.due(1), 0.25 ether + 0.05 ether);
        assertEq(income.due(2), 0.25 ether + 0.05 ether);
        assertEq(income.due(3), 0.05 ether);
        assertEq(income.due(4), 0);
        assertEq(income.reserved(), 0.5 ether + 0.15 ether);
    }

    function test_claimPaysTheCurrentHolderOnce() public {
        uint256 id = proofs.mint(alice);
        pay(1 ether);
        income.distribute();

        vm.expectEmit();
        emit ProofsIncome.Claimed(id, alice, 0.5 ether);
        vm.prank(bob);
        income.claim(id);
        assertEq(alice.balance, 0.5 ether);
        assertEq(income.reserved(), 0);
        assertEq(income.claimedThrough(id), 1);
        assertEq(income.due(id), 0);

        income.claim(id);
        assertEq(alice.balance, 0.5 ether);

        vm.prank(alice);
        proofs.transferFrom(alice, bob, id);
        pay(1 ether);
        income.distribute();
        income.claim(id);
        assertEq(bob.balance, 0.5 ether);
        assertEq(alice.balance, 0.5 ether);
    }

    function test_claimManyAndSkippedRounds() public {
        proofs.mint(alice);
        proofs.mint(bob);
        for (uint256 i = 0; i < 5; i++) {
            pay(1 ether);
            income.distribute();
        }
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        income.claimMany(ids);
        assertEq(alice.balance, 1.25 ether);
        assertEq(bob.balance, 1.25 ether);
        assertEq(income.reserved(), 0);
        assertEq(address(income).balance, 0);
    }

    function test_claimForAProofThatDoesNotExistReverts() public {
        pay(1 ether);
        proofs.mint(alice);
        income.distribute();
        vm.expectRevert();
        income.claim(2);
        vm.expectRevert();
        income.claim(0);
    }

    function test_noProofsSendsTheHoldersShareToTheTreasury() public {
        pay(1 ether);
        income.distribute();
        assertEq(income.rounds(), 0);
        assertEq(income.reserved(), 0);
        assertEq(splitter.balance, 0.25 ether);
        assertEq(treasury.balance, 0.75 ether);
    }

    function test_dustGoesToTheTreasury() public {
        for (uint256 i = 0; i < 3; i++) {
            proofs.mint(alice);
        }
        pay(1 ether);
        income.distribute();
        uint256 perProof = uint256(0.5 ether) / 3;
        assertEq(income.due(1), perProof);
        assertEq(income.reserved(), perProof * 3);
        assertEq(treasury.balance, 1 ether - perProof * 3 - 0.25 ether);
        assertEq(address(income).balance, perProof * 3);
    }

    function test_distributeRefusesNothingOrTooLittle() public {
        proofs.mint(alice);
        vm.expectRevert(ProofsIncome.TooLittle.selector);
        income.distribute();
        vm.prank(owner);
        income.setMinRound(0.01 ether);
        pay(0.009 ether);
        vm.expectRevert(ProofsIncome.TooLittle.selector);
        income.distribute();
        pay(0.001 ether);
        income.distribute();
        assertEq(income.rounds(), 1);
    }

    function test_plainEthIsIncomeToo() public {
        proofs.mint(alice);
        (bool ok,) = address(income).call{value: 1 ether}("");
        assertTrue(ok);
        pay(1 ether);
        assertEq(income.undistributed(), 2 ether);
        income.distribute();
        assertEq(income.due(1), 1 ether);
        assertEq(splitter.balance, 0.5 ether);
        assertEq(treasury.balance, 0.5 ether);
    }

    function test_reservedEthNeverRedistributed() public {
        proofs.mint(alice);
        pay(1 ether);
        income.distribute();
        vm.expectRevert(ProofsIncome.TooLittle.selector);
        income.distribute();
        assertEq(income.due(1), 0.5 ether);
    }

    function test_sharesAndTargets() public {
        vm.prank(alice);
        vm.expectRevert(ProofsIncome.NotOwner.selector);
        income.setShares(1000, 1000);
        vm.prank(owner);
        vm.expectRevert(ProofsIncome.BadShares.selector);
        income.setShares(6000, 4001);
        vm.prank(owner);
        income.setShares(0, 10_000);
        proofs.mint(alice);
        pay(1 ether);
        income.distribute();
        assertEq(splitter.balance, 1 ether);
        assertEq(income.rounds(), 0);

        address splitter2 = makeAddr("splitter2");
        address treasury2 = makeAddr("treasury2");
        vm.prank(alice);
        vm.expectRevert(ProofsIncome.NotOwner.selector);
        income.setTargets(splitter2, treasury2);
        vm.prank(owner);
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        income.setTargets(address(0), treasury2);
        vm.startPrank(owner);
        income.setTargets(splitter2, treasury2);
        income.setShares(5000, 0);
        vm.stopPrank();
        pay(1 ether);
        income.distribute();
        assertEq(treasury2.balance, 0.5 ether);
        assertEq(splitter2.balance, 0);
        assertEq(income.due(1), 0.5 ether);

        vm.prank(alice);
        vm.expectRevert(ProofsIncome.NotOwner.selector);
        income.setMinRound(1);
    }

    function test_sweepTokenSparesTheIncome() public {
        MockERC20 stray = new MockERC20();
        stray.mint(address(income), 7e6);
        income.sweepToken(stray);
        assertEq(stray.balanceOf(treasury), 7e6);
        income.sweepToken(stray);
        pay(1 ether);
        vm.expectRevert(ProofsIncome.NotSweepable.selector);
        income.sweepToken(weth);
        assertEq(weth.balanceOf(address(income)), 1 ether);
    }

    function test_holderThatRejectsEthBlocksOnlyItsOwnClaim() public {
        Rejecting rejecting = new Rejecting();
        proofs.mint(address(rejecting));
        proofs.mint(alice);
        pay(1 ether);
        income.distribute();
        vm.expectRevert(ProofsIncome.TransferFailed.selector);
        income.claim(1);
        income.claim(2);
        assertEq(alice.balance, 0.25 ether);
        assertEq(income.reserved(), 0.25 ether);
    }

    function test_targetThatRejectsEthBlocksDistribution() public {
        Rejecting rejecting = new Rejecting();
        vm.prank(owner);
        income.setTargets(address(rejecting), treasury);
        pay(1 ether);
        vm.expectRevert(ProofsIncome.TransferFailed.selector);
        income.distribute();
    }

    function test_ownershipInTwoSteps() public {
        vm.prank(alice);
        vm.expectRevert(ProofsIncome.NotOwner.selector);
        income.transferOwnership(alice);
        vm.prank(owner);
        vm.expectRevert(ProofsIncome.ZeroAddress.selector);
        income.transferOwnership(address(0));
        vm.prank(owner);
        income.transferOwnership(alice);
        assertEq(income.owner(), owner);
        vm.prank(bob);
        vm.expectRevert(ProofsIncome.NotPendingOwner.selector);
        income.acceptOwnership();
        vm.prank(alice);
        income.acceptOwnership();
        assertEq(income.owner(), alice);
        assertEq(income.pendingOwner(), address(0));
    }

    /// @dev Every wei distributed ends up with a holder, the splitter or the
    /// treasury, whatever the order of mints, payments and claims.
    function testFuzz_conservation(uint8[8] calldata mints, uint64[8] calldata payments, uint8 claimMask) public {
        uint256 paid;
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 m = 0; m < mints[i] % 4; m++) {
                proofs.mint(m % 2 == 0 ? alice : bob);
            }
            uint256 amount = uint256(payments[i]) + 1;
            pay(amount);
            paid += amount;
            income.distribute();
            if (claimMask & (1 << i) != 0 && proofs.totalSupply() > 0) {
                income.claim(1 + (i % proofs.totalSupply()));
            }
        }
        uint256 supply = proofs.totalSupply();
        uint256 dues;
        for (uint256 id = 1; id <= supply; id++) {
            dues += income.due(id);
        }
        assertEq(dues, income.reserved());
        assertEq(address(income).balance, income.reserved());
        assertEq(alice.balance + bob.balance + splitter.balance + treasury.balance + income.reserved(), paid);
        for (uint256 id = 1; id <= supply; id++) {
            income.claim(id);
        }
        assertEq(income.reserved(), 0);
        assertEq(address(income).balance, 0);
    }
}
