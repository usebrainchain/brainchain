// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FeeSplitter, IFeeEscrow, IPonsCurve} from "../src/rewards/FeeSplitter.sol";
import {RewardDistributor} from "../src/rewards/RewardDistributor.sol";

contract MockEscrow is IFeeEscrow {
    mapping(address => uint256) public credit;

    function fund(address to) external payable {
        credit[to] += msg.value;
    }

    function claim() external {
        uint256 amount = credit[msg.sender];
        require(amount > 0, "NoBalance");
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

contract MockCurve is IPonsCurve {
    uint256 public sweeps;

    function sweepFees(uint256) external {
        sweeps += 1;
    }
}

contract Rejecter {
    receive() external payable {
        revert();
    }
}

contract FeeSplitterTest is Test {
    MockEscrow escrow = new MockEscrow();
    address rewards = makeAddr("rewards");
    address treasury = makeAddr("treasury");
    FeeSplitter splitter;

    function setUp() public {
        splitter = new FeeSplitter(escrow, rewards, treasury);
    }

    function test_splitsClaimInHalf() public {
        escrow.fund{value: 1 ether + 1}(address(splitter));
        vm.prank(makeAddr("anyone"));
        splitter.claimAndSplit();
        assertEq(rewards.balance, 0.5 ether);
        assertEq(treasury.balance, 0.5 ether + 1);
        assertEq(address(splitter).balance, 0);
    }

    function test_emptyEscrowIsNotAnError() public {
        splitter.claimAndSplit();
        assertEq(rewards.balance, 0);
    }

    function test_splitsEthSentDirectly() public {
        (bool ok,) = address(splitter).call{value: 2 ether}("");
        assertTrue(ok);
        splitter.split();
        assertEq(rewards.balance, 1 ether);
        assertEq(treasury.balance, 1 ether);
    }

    function test_bindCurveOnceByDeployer() public {
        MockCurve curve = new MockCurve();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeSplitter.NotDeployer.selector);
        splitter.bindCurve(curve);

        splitter.bindCurve(curve);
        vm.expectRevert(FeeSplitter.CurveSet.selector);
        splitter.bindCurve(curve);

        splitter.claimAndSplit();
        assertEq(curve.sweeps(), 1);
    }

    function test_revertsOnZeroAddress() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(escrow, address(0), treasury);
    }

    function test_failedTransferReverts() public {
        FeeSplitter bad = new FeeSplitter(escrow, address(new Rejecter()), treasury);
        (bool ok,) = address(bad).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(FeeSplitter.TransferFailed.selector);
        bad.split();
    }
}

contract RewardDistributorTest is Test {
    address owner = makeAddr("owner");
    address publisher = makeAddr("publisher");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    RewardDistributor distributor;

    function setUp() public {
        distributor = new RewardDistributor(owner, publisher);
        vm.deal(address(distributor), 10 ether);
    }

    function _leaf(address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    /// Two-leaf tree: each leaf's proof is the other leaf.
    function _publish(uint256 a, uint256 b) private returns (uint256 round, bytes32 leafA, bytes32 leafB) {
        leafA = _leaf(alice, a);
        leafB = _leaf(bob, b);
        bytes32 root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));
        vm.prank(publisher);
        round = distributor.publish(root, a + b, "ipfs://round");
    }

    function _proof(bytes32 sibling) private pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function test_claimPaysAccountOnce() public {
        (uint256 round, bytes32 leafA, bytes32 leafB) = _publish(1 ether, 2 ether);
        assertEq(distributor.available(), 7 ether);

        vm.prank(bob);
        distributor.claim(round, alice, 1 ether, _proof(leafB));
        assertEq(alice.balance, 1 ether);

        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        distributor.claim(round, alice, 1 ether, _proof(leafB));

        distributor.claim(round, bob, 2 ether, _proof(leafA));
        assertEq(bob.balance, 2 ether);
        assertEq(distributor.outstanding(), 0);
    }

    function test_rejectsWrongAmount() public {
        (uint256 round,, bytes32 leafB) = _publish(1 ether, 2 ether);
        vm.expectRevert(RewardDistributor.BadProof.selector);
        distributor.claim(round, alice, 2 ether, _proof(leafB));
    }

    function test_cannotOverAllocate() public {
        vm.prank(publisher);
        vm.expectRevert(RewardDistributor.OverAllocated.selector);
        distributor.publish(bytes32(uint256(1)), 11 ether, "");
    }

    function test_onlyPublisherPublishes() public {
        vm.expectRevert(RewardDistributor.NotPublisher.selector);
        distributor.publish(bytes32(uint256(1)), 1 ether, "");
    }

    function test_expiryReturnsRemainder() public {
        (uint256 round,, bytes32 leafB) = _publish(1 ether, 2 ether);
        distributor.claim(round, alice, 1 ether, _proof(leafB));

        vm.expectRevert(RewardDistributor.TooEarly.selector);
        distributor.expire(round);

        vm.warp(block.timestamp + distributor.CLAIM_WINDOW());
        distributor.expire(round);
        assertEq(distributor.outstanding(), 0);
        assertEq(distributor.available(), 9 ether);

        vm.expectRevert(RewardDistributor.RoundExpired.selector);
        distributor.claim(round, bob, 2 ether, _proof(bytes32(0)));
    }

    function test_ownerRotatesPublisher() public {
        vm.expectRevert(RewardDistributor.NotOwner.selector);
        distributor.setPublisher(alice);
        vm.prank(owner);
        distributor.setPublisher(alice);
        assertEq(distributor.publisher(), alice);
    }

    function test_unknownRound() public {
        vm.expectRevert(RewardDistributor.UnknownRound.selector);
        distributor.claim(1, alice, 1, new bytes32[](0));
    }
}
