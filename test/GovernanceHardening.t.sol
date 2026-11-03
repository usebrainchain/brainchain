// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {MockERC20} from "./MockERC20.sol";

/// Adversarial checks on the governance contracts: veto scope, decision
/// binding, bond settlement, and the executor's limits on itself.
contract GovernanceHardeningTest is Test {
    bytes32 internal constant CLAUDE = keccak256("claude");
    bytes32 internal constant YES = bytes32(uint256(1));
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    address internal brain = makeAddr("brain");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal claude = makeAddr("claude");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    MockERC20 internal usdg;
    TestBRAIN internal brainToken;
    DecisionLog internal decisionLog;
    ModelRegistry internal registry;
    DecisionExecutor internal executor;
    WorkerStaking internal staking;
    TaskBoard internal board;
    ProposalBonds internal bonds;

    function setUp() public {
        usdg = new MockERC20();
        brainToken = new TestBRAIN(address(this), 1_000_000e18);
        decisionLog = new DecisionLog(address(this), brain);
        executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 hours, 5, 10e6, 20e6);
        registry = new ModelRegistry(address(this));
        registry.setModel(CLAUDE, claude, 0.4e6, true);
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
        registry.setOwner(address(executor));
        board.setOwner(address(executor));
        vm.prank(guardian);
        executor.bindBoard(board);
        bonds = new ProposalBonds(
            IERC20(address(brainToken)),
            decisionLog,
            IDecisionExecutor(address(executor)),
            address(this),
            100e18,
            7 days
        );
        usdg.mint(address(executor), 1_000e6);
        usdg.mint(poster, 1_000e6);
        vm.prank(poster);
        usdg.approve(address(board), type(uint256).max);
    }

    function _decide(bytes32 subject, bytes32 answer, uint16 confidence) internal returns (uint256) {
        vm.prank(brain);
        return decisionLog.record(DecisionLog.Kind.Change, subject, 0, answer, confidence, 0, "");
    }

    function _queue(address target, bytes memory data) internal returns (uint256 changeId) {
        uint256 d = _decide(executor.changeSubject(target, data), YES, 9_000);
        vm.prank(brain);
        changeId = executor.queue(d, target, data);
    }

    function _propose(address who, bytes memory data) internal returns (uint256 id) {
        brainToken.transfer(who, 100e18);
        vm.startPrank(who);
        brainToken.approve(address(bonds), 100e18);
        id = bonds.propose(address(board), data, "ipfs://proposal");
        vm.stopPrank();
    }

    // ---- A. a veto does not block the same call with non-canonical calldata

    /// The veto keys on exact calldata. Solidity's dispatcher ignores trailing
    /// bytes, so the brain re-queues the vetoed call with 32 junk bytes appended:
    /// new subject, new veto key, identical effect.
    /// A veto is keyed on the function, not the exact bytes: the dispatcher
    /// ignores trailing calldata, so the exact bytes alone would not shut it.
    function test_A_aVetoShutsTheFunctionWhateverTheCalldataUntilTheAdminClearsIt() public {
        bytes memory data = abi.encodeCall(DecisionExecutor.setParameters, (5_000, 1 hours, 5, 10e6, 20e6));
        uint256 changeA = _queue(address(executor), data);
        vm.prank(guardian);
        executor.veto(changeA);
        assertTrue(executor.vetoed(address(executor), DecisionExecutor.setParameters.selector));

        uint256 again = _decide(executor.changeSubject(address(executor), data), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.VetoedCall.selector);
        executor.queue(again, address(executor), data);

        bytes memory padded = bytes.concat(data, bytes32(uint256(0xdead)));
        uint256 padAgain = _decide(executor.changeSubject(address(executor), padded), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.VetoedCall.selector);
        executor.queue(padAgain, address(executor), padded);

        // Only the admin reopens it.
        vm.prank(guardian);
        vm.expectRevert(DecisionExecutor.NotAdmin.selector);
        executor.clearVeto(address(executor), DecisionExecutor.setParameters.selector);
        vm.prank(decisionLog.owner());
        executor.clearVeto(address(executor), DecisionExecutor.setParameters.selector);
        vm.prank(brain);
        uint256 changeB = executor.queue(again, address(executor), data);
        vm.warp(block.timestamp + 2 hours + 1);
        executor.execute(changeB);
        assertEq(executor.changeThresholdBps(), 5_000);
    }

    /// Same bypass against the treasury: a vetoed transfer runs when re-encoded.
    function test_A_aVetoedTreasuryTransferCannotBeReEncoded() public {
        bytes memory data = abi.encodeCall(DecisionExecutor.transfer, (attacker, 1_000e6));
        uint256 changeA = _queue(address(executor), data);
        vm.prank(guardian);
        executor.veto(changeA);

        bytes memory padded = bytes.concat(data, hex"00");
        uint256 d = _decide(executor.changeSubject(address(executor), padded), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.VetoedCall.selector);
        executor.queue(d, address(executor), padded);
        assertEq(usdg.balanceOf(attacker), 0);
    }

    /// A vetoed unpause stays vetoed under padding, so a guardian pause holds.
    function test_A_aVetoedUnpauseCannotBeReEncoded() public {
        vm.prank(guardian);
        board.setPaused(true);
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (false));
        uint256 changeA = _queue(address(board), data);
        vm.prank(guardian);
        executor.veto(changeA);

        bytes memory padded = bytes.concat(data, bytes32(0));
        uint256 d = _decide(executor.changeSubject(address(board), padded), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.VetoedCall.selector);
        executor.queue(d, address(board), padded);
        assertTrue(board.paused());
    }

    // ---- B. settle accepts a decision recorded after the proposal's deadline

    /// A decision recorded after a proposal's window cannot settle it, and the
    /// same call cannot be proposed again while it is open.
    function test_B_aDecisionAfterTheWindowCannotBurnAnUndecidedBond() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        bytes32 subject = executor.changeSubject(address(board), data);
        uint256 p1 = _propose(alice, data);
        ProposalBonds.Proposal memory p = bonds.get(p1);

        vm.warp(p.deadline + 1 days);
        brainToken.transfer(bob, 100e18);
        vm.startPrank(bob);
        brainToken.approve(address(bonds), 100e18);
        vm.expectRevert(abi.encodeWithSelector(ProposalBonds.AlreadyProposed.selector, p1));
        bonds.propose(address(board), data, "");
        vm.stopPrank();

        uint256 keep = _decide(subject, bytes32(0), 9_000);
        vm.expectRevert(ProposalBonds.BadDecision.selector);
        bonds.settle(p1, keep);
        bonds.expire(p1);
        assertEq(brainToken.balanceOf(alice), 100e18, "an undecided bond comes back");
        assertEq(bonds.openProposal(subject), 0);
    }

    // ---- C. an in-window keep is dodged once a later decision lands after the deadline

    /// Jev says keep inside Alice's window and nobody settles. The call cannot
    /// be proposed again while hers is open, so the keep stays the latest
    /// decision and settles her bond; expiring is refused.
    function test_C_anInWindowKeepCannotBeDodgedThroughASecondProposal() public {
        bytes memory data = abi.encodeCall(TaskBoard.setPaused, (true));
        bytes32 subject = executor.changeSubject(address(board), data);
        uint256 p1 = _propose(alice, data);
        uint256 keep1 = _decide(subject, bytes32(0), 9_000);
        ProposalBonds.Proposal memory p = bonds.get(p1);

        vm.warp(p.deadline + 1 days);
        brainToken.transfer(bob, 100e18);
        vm.startPrank(bob);
        brainToken.approve(address(bonds), 100e18);
        vm.expectRevert(abi.encodeWithSelector(ProposalBonds.AlreadyProposed.selector, p1));
        bonds.propose(address(board), data, "");
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(ProposalBonds.Decided.selector);
        bonds.expire(p1);
        bonds.settle(p1, keep1);
        assertEq(brainToken.balanceOf(alice), 0, "the keep burned the bond");
        uint256 p2 = _propose(bob, data);
        assertEq(bonds.openProposal(subject), p2, "once settled, the call can be proposed again");
    }

    // ---- disproofs: paths that hold

    function test_D_executorCannotExecuteOrQueueThroughItself() public {
        uint256 inner = _queue(address(executor), abi.encodeCall(DecisionExecutor.transfer, (attacker, 1e6)));
        uint256 outer = _queue(address(executor), abi.encodeCall(DecisionExecutor.execute, (inner)));
        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert();
        executor.execute(outer);
        assertEq(usdg.balanceOf(attacker), 0);

        uint256 post = _queue(
            address(executor),
            abi.encodeCall(DecisionExecutor.postHouseTask, (10e6, uint64(block.timestamp + 1 days), bytes32(0), ""))
        );
        vm.warp(block.timestamp + 2 hours + 1);
        // Blocked by the shared reentrancy lock before the brain check is even reached.
        vm.expectRevert();
        executor.execute(post);
        assertEq(board.count(), 0);
    }

    function test_D_forbiddenSelectorsHoldOnEveryTarget() public {
        bytes memory setOwner = abi.encodeCall(TaskBoard.setOwner, (attacker));
        bytes memory setGuardian = abi.encodeCall(TaskBoard.setGuardian, (attacker));
        address[3] memory targets = [address(executor), address(board), address(registry)];
        for (uint256 i; i < 3; ++i) {
            uint256 d = _decide(executor.changeSubject(targets[i], setOwner), YES, 9_000);
            vm.prank(brain);
            vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
            executor.queue(d, targets[i], setOwner);
            d = _decide(executor.changeSubject(targets[i], setGuardian), YES, 9_000);
            vm.prank(brain);
            vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
            executor.queue(d, targets[i], setGuardian);
        }
        // Padding does not help here: the selector is read from the first four bytes.
        bytes memory padded = bytes.concat(setOwner, bytes32(0));
        uint256 e = _decide(executor.changeSubject(address(board), padded), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(DecisionExecutor.ForbiddenCall.selector);
        executor.queue(e, address(board), padded);
    }

    /// A board post through a change fails: the executor holds no allowance for the board
    /// outside postHouseTask, so the house caps cannot be dodged that way.
    function test_D_houseCapsCannotBeDodgedByPostingThroughAChange() public {
        uint256 c = _queue(
            address(board),
            abi.encodeCall(TaskBoard.post, (50e6, uint64(block.timestamp + 3 hours + 1 days), bytes32(0), ""))
        );
        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert();
        executor.execute(c);
        assertEq(usdg.balanceOf(address(board)), 0);
    }
}
