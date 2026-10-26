// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {RewardDistributor} from "../src/rewards/RewardDistributor.sol";

/// Random publishes (including roots whose leaves claim more than the round's
/// total), claims, revocations, expiries and deposits.
contract RewardHandler is Test {
    RewardDistributor public distributor;
    address public owner;
    address public publisher;
    address[2] public accounts;

    struct Tree {
        uint256 a;
        uint256 b;
    }

    mapping(uint256 => Tree) public trees;
    uint256[] public rounds;

    constructor(RewardDistributor distributor_, address owner_, address publisher_) {
        distributor = distributor_;
        owner = owner_;
        publisher = publisher_;
        accounts = [makeAddr("alice"), makeAddr("bob")];
    }

    function _leaf(address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
    }

    function _root(bytes32 x, bytes32 y) private pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    function deposit(uint96 amount) external {
        vm.deal(address(this), amount);
        (bool ok,) = address(distributor).call{value: amount}("");
        require(ok);
    }

    function publish(uint96 a, uint96 b, uint96 declared) external {
        uint256 available = distributor.available();
        if (available == 0) return;
        uint256 total = bound(declared, 1, available);
        // Leaves may promise more than the declared total; claims must not exceed it.
        uint256 amountA = bound(a, 0, total * 2);
        uint256 amountB = bound(b, 0, total * 2);
        vm.prank(publisher);
        uint256 round = distributor.publish(_root(_leaf(accounts[0], amountA), _leaf(accounts[1], amountB)), total, "");
        trees[round] = Tree(amountA, amountB);
        rounds.push(round);
    }

    function claim(uint256 seed, bool first) external {
        if (rounds.length == 0) return;
        uint256 round = rounds[seed % rounds.length];
        Tree memory t = trees[round];
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = first ? _leaf(accounts[1], t.b) : _leaf(accounts[0], t.a);
        try distributor.claim(round, first ? accounts[0] : accounts[1], first ? t.a : t.b, proof) {} catch {}
    }

    function revoke(uint256 seed) external {
        if (rounds.length == 0) return;
        vm.prank(owner);
        try distributor.revoke(rounds[seed % rounds.length]) {} catch {}
    }

    function expire(uint256 seed) external {
        if (rounds.length == 0) return;
        try distributor.expire(rounds[seed % rounds.length]) {} catch {}
    }

    function warp(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 weeks));
    }

    function roundCount() external view returns (uint256) {
        return rounds.length;
    }

    function roundAt(uint256 i) external view returns (uint256) {
        return rounds[i];
    }
}

contract RewardInvariants is StdInvariant, Test {
    RewardDistributor internal distributor;
    RewardHandler internal h;

    function setUp() public {
        address owner = makeAddr("owner");
        address publisher = makeAddr("publisher");
        distributor = new RewardDistributor(owner, publisher);
        h = new RewardHandler(distributor, owner, publisher);
        targetContract(address(h));
    }

    function invariant_roundsNeverPayMoreThanTheirTotal() public view {
        for (uint256 i; i < h.roundCount(); i++) {
            RewardDistributor.Round memory r = distributor.getRound(h.roundAt(i));
            assertLe(r.claimed, r.total);
        }
    }

    function invariant_outstandingIsWhatOpenRoundsStillOwe() public view {
        uint256 owed;
        for (uint256 i; i < h.roundCount(); i++) {
            RewardDistributor.Round memory r = distributor.getRound(h.roundAt(i));
            if (!r.expired && !r.revoked) owed += r.total - r.claimed;
        }
        assertEq(distributor.outstanding(), owed);
    }

    function invariant_balanceCoversWhatIsOwed() public view {
        assertGe(address(distributor).balance, distributor.outstanding());
    }
}
