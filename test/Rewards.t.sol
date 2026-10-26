// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeSplitter, IFeeEscrow, IPonsCurve, IPonsFactory} from "../src/rewards/FeeSplitter.sol";
import {RewardDistributor} from "../src/rewards/RewardDistributor.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockEscrow is IFeeEscrow {
    mapping(address => uint256) public credit;
    mapping(address => mapping(address => uint256)) public tokenCredit;
    bool public failClaims;

    function fund(address to) external payable {
        credit[to] += msg.value;
    }

    function fundToken(address to, MockERC20 token, uint256 amount) external {
        token.mint(address(this), amount);
        tokenCredit[to][address(token)] += amount;
    }

    function setFailClaims(bool fail) external {
        failClaims = fail;
    }

    function claim() external returns (uint256 amount) {
        require(!failClaims, "ClaimFailed");
        amount = credit[msg.sender];
        require(amount > 0, "NoBalance");
        credit[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }

    function claimToken(address token) external returns (uint256 amount) {
        amount = tokenCredit[msg.sender][token];
        require(amount > 0, "NoBalance");
        tokenCredit[msg.sender][token] = 0;
        IERC20(token).transfer(msg.sender, amount);
    }

    function balanceOf(address recipient) external view returns (uint256) {
        return credit[recipient];
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return tokenCredit[recipient][token];
    }
}

contract MockFactory is IPonsFactory {
    address public lastToken;
    address public recipient;
    bool public buyback;
    uint256 public buybackCalls;

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        lastToken = token;
        recipient = newRecipient;
    }

    function setBuybackEnabled(address token, bool enabled) external {
        lastToken = token;
        buyback = enabled;
        buybackCalls += 1;
    }
}

contract MockCurve is IPonsCurve {
    uint256 public sweeps;
    bool public graduated;
    bool public failSweeps;
    address public deployer;
    address public feeEscrow;
    address public token;
    address public factory;

    constructor(address deployer_, address feeEscrow_, address token_, address factory_) {
        deployer = deployer_;
        feeEscrow = feeEscrow_;
        token = token_;
        factory = factory_;
    }

    function setGraduated(bool g) external {
        graduated = g;
    }

    function setFailSweeps(bool f) external {
        failSweeps = f;
    }

    function sweepFees(uint256) external {
        require(!failSweeps, "InternalSwapRequiresOperator");
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
    MockFactory factory = new MockFactory();
    address rewards = makeAddr("rewards");
    address treasury = makeAddr("treasury");
    address owner = makeAddr("owner");
    address launchToken = makeAddr("brain-token");
    FeeSplitter splitter;

    function setUp() public {
        vm.warp(1_800_000_000);
        splitter = new FeeSplitter(escrow, rewards, treasury, owner);
    }

    function _curve() internal returns (MockCurve) {
        return new MockCurve(address(splitter), address(escrow), launchToken, address(factory));
    }

    function _bound() internal returns (MockCurve curve) {
        curve = _curve();
        splitter.bindCurve(curve);
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

    function test_bindCurveOnceByDeployerAndRecordsTheLaunch() public {
        MockCurve curve = _curve();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FeeSplitter.NotDeployer.selector);
        splitter.bindCurve(curve);

        splitter.bindCurve(curve);
        assertEq(address(splitter.curve()), address(curve));
        assertEq(splitter.launchToken(), launchToken);
        assertEq(address(splitter.factory()), address(factory));
        vm.expectRevert(FeeSplitter.CurveSet.selector);
        splitter.bindCurve(curve);

        splitter.claimAndSplit();
        assertEq(curve.sweeps(), 1);
    }

    /// v2 accepted any address, including the token pasted instead of the curve.
    function test_bindCurveRejectsAnotherLaunchOrEscrow() public {
        MockCurve otherRecipient = new MockCurve(makeAddr("someone"), address(escrow), launchToken, address(factory));
        vm.expectRevert(FeeSplitter.BadCurve.selector);
        splitter.bindCurve(otherRecipient);

        MockCurve otherEscrow = new MockCurve(address(splitter), makeAddr("escrow2"), launchToken, address(factory));
        vm.expectRevert(FeeSplitter.BadCurve.selector);
        splitter.bindCurve(otherEscrow);

        MockCurve noToken = new MockCurve(address(splitter), address(escrow), address(0), address(factory));
        vm.expectRevert(FeeSplitter.BadCurve.selector);
        splitter.bindCurve(noToken);

        vm.expectRevert();
        splitter.bindCurve(IPonsCurve(launchToken)); // not a contract

        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.bindCurve(IPonsCurve(address(0)));
    }

    function test_graduatedCurveIsNotSwept() public {
        MockCurve curve = _bound();
        curve.setGraduated(true);
        escrow.fund{value: 1 ether}(address(splitter));
        splitter.claimAndSplit();
        assertEq(curve.sweeps(), 0);
        assertEq(rewards.balance, 0.5 ether);
    }

    function test_failedSweepIsReportedAndTheClaimStillRuns() public {
        MockCurve curve = _bound();
        curve.setFailSweeps(true);
        escrow.fund{value: 1 ether}(address(splitter));
        vm.expectEmit(address(splitter));
        emit FeeSplitter.SweepFailed(abi.encodeWithSignature("Error(string)", "InternalSwapRequiresOperator"));
        splitter.claimAndSplit();
        assertEq(rewards.balance + treasury.balance, 1 ether);
    }

    /// v2 wrapped the claim in try/catch, so a keeper with too little gas skipped it silently.
    function test_failedClaimReverts() public {
        escrow.fund{value: 1 ether}(address(splitter));
        escrow.setFailClaims(true);
        vm.expectRevert(bytes("ClaimFailed"));
        splitter.claimAndSplit();
    }

    /// v2 had no token path: an ERC-20 pair or buyback release stranded every fee.
    function test_tokenFeesGoToTheTreasury() public {
        MockERC20 quote = new MockERC20();
        escrow.fundToken(address(splitter), quote, 27e6);
        quote.mint(address(splitter), 3e6); // e.g. pushed by a pool fee rescue
        vm.prank(makeAddr("anyone"));
        splitter.claimToken(address(quote));
        assertEq(quote.balanceOf(treasury), 30e6);
        assertEq(quote.balanceOf(address(splitter)), 0);
        assertEq(escrow.balanceOfToken(address(splitter), address(quote)), 0);

        splitter.claimToken(address(quote)); // nothing left: no-op
        splitter.sweepToken(IERC20(address(quote)));
        assertEq(quote.balanceOf(treasury), 30e6);
    }

    function test_recipientChangeWaitsThreeDaysAndIsOwnerOnly() public {
        address next = makeAddr("next-recipient");
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NoCurve.selector);
        splitter.proposeRecipient(next);

        _bound();
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.proposeRecipient(next);

        vm.prank(owner);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.proposeRecipient(address(0));

        vm.startPrank(owner);
        vm.expectRevert(FeeSplitter.NothingPending.selector);
        splitter.executeRecipient();
        splitter.proposeRecipient(next);
        vm.expectRevert(FeeSplitter.NotReady.selector);
        splitter.executeRecipient();
        vm.warp(block.timestamp + 3 days);
        splitter.executeRecipient();
        vm.stopPrank();

        assertEq(factory.recipient(), next);
        assertEq(factory.lastToken(), launchToken);
        assertEq(splitter.pendingRecipient(), address(0));
        assertEq(splitter.recipientEta(), 0);
    }

    function test_enablingBuybackWaitsThreeDays() public {
        _bound();
        vm.startPrank(owner);
        splitter.proposeBuyback(true);
        assertTrue(splitter.pendingBuyback());
        assertEq(splitter.buybackEta(), block.timestamp + 3 days);
        vm.warp(block.timestamp + 3 days - 1);
        vm.expectRevert(FeeSplitter.NotReady.selector);
        splitter.executeBuyback();
        vm.warp(block.timestamp + 1);
        splitter.executeBuyback();
        vm.stopPrank();
        assertTrue(factory.buyback());
        assertFalse(splitter.pendingBuyback());
        assertEq(splitter.buybackEta(), 0);
    }

    function test_cancelClearsEveryPendingChange() public {
        _bound();
        vm.startPrank(owner);
        splitter.proposeRecipient(makeAddr("next"));
        splitter.proposeBuyback(true);
        splitter.cancelPending();
        vm.stopPrank();
        assertEq(splitter.pendingRecipient(), address(0));
        assertEq(splitter.recipientEta(), 0);
        assertFalse(splitter.pendingBuyback());
        assertEq(splitter.buybackEta(), 0);
    }

    function test_recipientChangeIsReadyExactlyThreeDaysLater() public {
        _bound();
        vm.prank(owner);
        splitter.proposeRecipient(makeAddr("next"));
        assertEq(splitter.recipientEta(), block.timestamp + 3 days);
    }

    function test_buybackChangeWaitsThreeDaysAndCanBeCancelled() public {
        _bound();
        vm.startPrank(owner);
        vm.expectRevert(FeeSplitter.NothingPending.selector);
        splitter.executeBuyback();

        splitter.proposeBuyback(true);
        splitter.cancelPending();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(FeeSplitter.NothingPending.selector);
        splitter.executeBuyback();

        splitter.proposeBuyback(false);
        vm.expectRevert(FeeSplitter.NotReady.selector);
        splitter.executeBuyback();
        vm.warp(block.timestamp + 3 days);
        splitter.executeBuyback();
        vm.stopPrank();
        assertEq(factory.buybackCalls(), 1);
        assertFalse(factory.buyback());

        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NothingPending.selector);
        splitter.executeBuyback();
    }

    function test_buybackProposalNeedsACurveAndTheOwner() public {
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.NoCurve.selector);
        splitter.proposeBuyback(true);
        _bound();
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.proposeBuyback(true);
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.cancelPending();
    }

    function test_ownershipIsTwoStep() public {
        address next = makeAddr("next-owner");
        vm.expectRevert(FeeSplitter.NotOwner.selector);
        splitter.transferOwnership(next);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        splitter.transferOwnership(address(0));
        vm.prank(owner);
        splitter.transferOwnership(next);
        assertEq(splitter.owner(), owner);
        vm.expectRevert(FeeSplitter.NotPendingOwner.selector);
        splitter.acceptOwnership();
        vm.prank(next);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), next);
        assertEq(splitter.pendingOwner(), address(0));
    }

    function test_revertsOnZeroAddress() public {
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(escrow, address(0), treasury, owner);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(escrow, rewards, address(0), owner);
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(escrow, rewards, treasury, address(0));
        vm.expectRevert(FeeSplitter.ZeroAddress.selector);
        new FeeSplitter(IFeeEscrow(address(0)), rewards, treasury, owner);
    }

    function test_failedTransferReverts() public {
        FeeSplitter bad = new FeeSplitter(escrow, address(new Rejecter()), treasury, owner);
        (bool ok,) = address(bad).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(FeeSplitter.TransferFailed.selector);
        bad.split();
    }

    function testFuzz_splitConservesEveryWei(uint96 amount) public {
        escrow.fund{value: amount}(address(splitter));
        splitter.claimAndSplit();
        assertEq(rewards.balance + treasury.balance, amount);
        assertLe(treasury.balance - rewards.balance, 1);
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

    function _root(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// Two-leaf tree: each leaf's proof is the other leaf.
    function _publish(uint256 a, uint256 b) private returns (uint256 round, bytes32 leafA, bytes32 leafB) {
        leafA = _leaf(alice, a);
        leafB = _leaf(bob, b);
        vm.prank(publisher);
        round = distributor.publish(_root(leafA, leafB), a + b, "ipfs://round");
    }

    function _proof(bytes32 sibling) private pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = sibling;
    }

    function _open() private {
        vm.warp(block.timestamp + distributor.CLAIM_DELAY());
    }

    function test_claimPaysAccountOnceAfterTheDelay() public {
        (uint256 round, bytes32 leafA, bytes32 leafB) = _publish(1 ether, 2 ether);
        assertEq(distributor.available(), 7 ether);

        vm.expectRevert(RewardDistributor.TooEarly.selector);
        distributor.claim(round, alice, 1 ether, _proof(leafB));

        _open();
        vm.prank(bob);
        distributor.claim(round, alice, 1 ether, _proof(leafB));
        assertEq(alice.balance, 1 ether);

        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        distributor.claim(round, alice, 1 ether, _proof(leafB));

        distributor.claim(round, bob, 2 ether, _proof(leafA));
        assertEq(bob.balance, 2 ether);
        assertEq(distributor.outstanding(), 0);
    }

    /// v2 let a round declared at 1 ETH pay 4 ETH out of other rounds' allocations.
    function test_roundCannotPayMoreThanItsTotal() public {
        bytes32 leafA = _leaf(alice, 4 ether);
        bytes32 leafB = _leaf(bob, 0);
        vm.prank(publisher);
        uint256 round = distributor.publish(_root(leafA, leafB), 1 ether, "");
        (uint256 honest, bytes32 hA, bytes32 hB) = _publish(1 ether, 2 ether);
        _open();
        vm.expectRevert(RewardDistributor.OverClaimed.selector);
        distributor.claim(round, alice, 4 ether, _proof(leafB));
        distributor.claim(honest, alice, 1 ether, _proof(hB));
        distributor.claim(honest, bob, 2 ether, _proof(hA));
        assertEq(distributor.outstanding(), 1 ether);
    }

    function test_rejectsEmptyRounds() public {
        vm.startPrank(publisher);
        vm.expectRevert(RewardDistributor.EmptyRound.selector);
        distributor.publish(bytes32(0), 1 ether, "");
        vm.expectRevert(RewardDistributor.EmptyRound.selector);
        distributor.publish(bytes32(uint256(1)), 0, "");
        vm.stopPrank();
    }

    function test_ownerRevokesDuringTheDelay() public {
        (uint256 round,, bytes32 leafB) = _publish(1 ether, 2 ether);
        vm.expectRevert(RewardDistributor.NotOwner.selector);
        distributor.revoke(round);
        vm.prank(owner);
        distributor.revoke(round);
        assertEq(distributor.outstanding(), 0);
        assertEq(distributor.available(), 10 ether);
        _open();
        vm.expectRevert(RewardDistributor.RoundClosed.selector);
        distributor.claim(round, alice, 1 ether, _proof(leafB));
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.RoundClosed.selector);
        distributor.revoke(round);
        vm.warp(block.timestamp + distributor.CLAIM_WINDOW());
        vm.expectRevert(RewardDistributor.RoundClosed.selector);
        distributor.expire(round);
    }

    function test_revokeClosesWhenClaimsOpen() public {
        (uint256 round,,) = _publish(1 ether, 2 ether);
        _open();
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.TooLate.selector);
        distributor.revoke(round);
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.UnknownRound.selector);
        distributor.revoke(99);
    }

    function test_rejectsWrongAmount() public {
        (uint256 round,, bytes32 leafB) = _publish(1 ether, 2 ether);
        _open();
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

    function test_claimsCloseAtTheWindowAndExpiryReturnsTheRemainder() public {
        (uint256 round,, bytes32 leafB) = _publish(1 ether, 2 ether);
        _open();
        distributor.claim(round, alice, 1 ether, _proof(leafB));

        vm.expectRevert(RewardDistributor.TooEarly.selector);
        distributor.expire(round);

        vm.warp(block.timestamp + distributor.CLAIM_WINDOW());
        vm.expectRevert(RewardDistributor.TooLate.selector);
        distributor.claim(round, bob, 2 ether, _proof(bytes32(0)));

        distributor.expire(round);
        assertEq(distributor.outstanding(), 0);
        assertEq(distributor.available(), 9 ether);

        vm.expectRevert(RewardDistributor.RoundClosed.selector);
        distributor.claim(round, bob, 2 ether, _proof(bytes32(0)));
        vm.expectRevert(RewardDistributor.RoundClosed.selector);
        distributor.expire(round);
        vm.expectRevert(RewardDistributor.UnknownRound.selector);
        distributor.expire(99);
    }

    function test_ownerRotatesPublisher() public {
        vm.expectRevert(RewardDistributor.NotOwner.selector);
        distributor.setPublisher(alice);
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.setPublisher(address(0));
        vm.prank(owner);
        distributor.setPublisher(alice);
        assertEq(distributor.publisher(), alice);
    }

    function test_ownershipIsTwoStep() public {
        vm.expectRevert(RewardDistributor.NotOwner.selector);
        distributor.transferOwnership(alice);
        vm.prank(owner);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        distributor.transferOwnership(address(0));
        vm.prank(owner);
        distributor.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(RewardDistributor.NotPendingOwner.selector);
        distributor.acceptOwnership();
        vm.prank(alice);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), alice);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(address(0), publisher);
        vm.expectRevert(RewardDistributor.ZeroAddress.selector);
        new RewardDistributor(owner, address(0));
    }

    function test_unknownRound() public {
        vm.expectRevert(RewardDistributor.UnknownRound.selector);
        distributor.claim(1, alice, 1, new bytes32[](0));
    }

    function test_failedPayoutReverts() public {
        address rejecter = address(new Rejecter());
        bytes32 leafA = _leaf(rejecter, 1 ether);
        bytes32 leafB = _leaf(bob, 1 ether);
        vm.prank(publisher);
        uint256 round = distributor.publish(_root(leafA, leafB), 2 ether, "");
        _open();
        vm.expectRevert(RewardDistributor.TransferFailed.selector);
        distributor.claim(round, rejecter, 1 ether, _proof(leafB));
    }
}
