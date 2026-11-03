// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {MockERC20} from "./MockERC20.sol";

contract FixedAttestation is IDcapAttestation {
    bytes public output;

    function set(bytes memory output_) external {
        output = output_;
    }

    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) {
        return (true, output);
    }

    function verifyAndAttestOnChain(bytes calldata, uint32) external payable returns (bool, bytes memory) {
        return (true, output);
    }
}

/// Properties set 3.4.0 holds that earlier sets did not.
contract Hardening340Test is Test {
    bytes32 internal constant YES = bytes32(uint256(1));
    uint128 internal constant BOUNTY = 5e6;

    address internal brain = makeAddr("brain");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal worker = makeAddr("worker");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal usdg;
    TestBRAIN internal brainToken;
    DecisionLog internal decisionLog;
    DecisionExecutor internal executor;
    ModelRegistry internal registry;
    WorkerStaking internal staking;
    TaskBoard internal board;
    ProposalBonds internal bonds;

    function setUp() public {
        usdg = new MockERC20();
        brainToken = new TestBRAIN(address(this), 1_000_000e18);
        decisionLog = new DecisionLog(address(this), brain);
        executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 hours, 5, 10e6, 20e6);
        registry = new ModelRegistry(address(this));
        staking = new WorkerStaking(IERC20(address(brainToken)), address(this), 500e18, 3 days, 2_000);
        board = new TaskBoard(
            IERC20(address(usdg)),
            decisionLog,
            registry,
            staking,
            address(this),
            guardian,
            TaskBoard.Config(7_000, 7_000, 7_000, 1 hours, 7 days, 6 hours, 1 hours, 6 hours, 1e6)
        );
        staking.setSlasher(address(board), true);
        bonds = new ProposalBonds(
            IERC20(address(brainToken)),
            decisionLog,
            IDecisionExecutor(address(executor)),
            address(this),
            100e18,
            7 days
        );
        usdg.mint(poster, 1_000e6);
        vm.prank(poster);
        usdg.approve(address(board), type(uint256).max);
    }

    function _decide(DecisionLog.Kind kind, bytes32 subject, bytes32 answer, uint16 confidence)
        internal
        returns (uint256)
    {
        vm.prank(brain);
        return decisionLog.record(kind, subject, 0, answer, confidence, 0, "");
    }

    function _propose(address who, bytes memory data) internal returns (uint256 id) {
        brainToken.transfer(who, 100e18);
        vm.startPrank(who);
        brainToken.approve(address(bonds), 100e18);
        id = bonds.propose(address(board), data, "ipfs://proposal");
        vm.stopPrank();
    }

    /// A call has one open proposal at a time, so one decision settles exactly
    /// the proposal that is open for it.
    function test_aCallHasOneOpenProposalAtATime() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        bytes32 subject = executor.changeSubject(address(board), data);
        uint256 p1 = _propose(alice, data);
        assertEq(bonds.openProposal(subject), p1);

        brainToken.transfer(bob, 100e18);
        vm.startPrank(bob);
        brainToken.approve(address(bonds), 100e18);
        vm.expectRevert(abi.encodeWithSelector(ProposalBonds.AlreadyProposed.selector, p1));
        bonds.propose(address(board), data, "");
        vm.stopPrank();

        uint256 d = _decide(DecisionLog.Kind.Change, subject, YES, 9_000);
        bonds.settle(p1, d);
        assertEq(bonds.openProposal(subject), 0);
        uint256 p2 = _propose(bob, data);
        assertEq(bonds.openProposal(subject), p2);
    }

    /// setBrain closes attestation until the owner reopens it, so an enclave
    /// still on the allowlists cannot name itself over the owner's choice.
    function test_setBrainHoldsUntilTheOwnerReopensAttestation() public {
        FixedAttestation verifier = new FixedAttestation();
        bytes memory mrtd = _fill(48, 0x11);
        bytes memory rtmrs = _fill(144, 0x22);
        bytes memory rtmr3 = _fill(48, 0x33);
        decisionLog.setAttestation(verifier);
        decisionLog.allowImage(keccak256(abi.encodePacked(mrtd, rtmrs)), true);
        decisionLog.allowApp(keccak256(rtmr3), true);
        address enclaveKey = makeAddr("enclave");
        address recoveryKey = makeAddr("recovery");

        // The owner moves the brain to a recovery key.
        decisionLog.setBrain(recoveryKey);
        assertEq(decisionLog.brain(), recoveryKey);
        assertEq(address(decisionLog.attestation()), address(0), "attestation closed");

        // The enclave still serves quotes for the current nonce; they name nothing now.
        bytes memory header = new bytes(11);
        header[1] = 0x04;
        header[3] = 0x02;
        verifier.set(
            abi.encodePacked(
                header,
                new bytes(136),
                mrtd,
                new bytes(144),
                rtmrs,
                rtmr3,
                decisionLog.attestationNonce(),
                bytes32(uint256(uint160(enclaveKey)))
            )
        );
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(DecisionLog.NoAttestation.selector);
        decisionLog.attestBrain("quote");
        assertEq(decisionLog.brain(), recoveryKey, "the recovery holds");

        // Once the owner reopens attestation, the enclave names itself again.
        decisionLog.setAttestation(verifier);
        decisionLog.attestBrain("quote");
        assertEq(decisionLog.brain(), enclaveKey);
    }

    /// Boards are added to the staking contract one by one, so a new board
    /// leaves the old board settling its own tasks.
    function test_addingABoardLeavesTheOldBoardSettling() public {
        brainToken.transfer(worker, 500e18);
        vm.startPrank(worker);
        brainToken.approve(address(staking), 500e18);
        staking.stake(500e18, 1e6);
        vm.stopPrank();
        board.setWorkerAllowed(worker, true);

        vm.prank(poster);
        uint256 id = board.post(BOUNTY, uint64(block.timestamp + 1 days), 0, "");
        uint256 d = _decide(DecisionLog.Kind.Hire, board.subjectOf(id), staking.idOf(worker), 9_000);
        vm.prank(brain);
        board.hire(id, d);

        // A new set binds the staking contract to its own board as well.
        staking.setSlasher(makeAddr("newBoard"), true);

        vm.warp(block.timestamp + 1 days + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6, "the poster was refunded");
        assertEq(staking.held(worker), 0);
    }

    function _fill(uint256 length, bytes1 value) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = value;
        }
    }
}
