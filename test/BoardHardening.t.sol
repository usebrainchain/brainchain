// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {FeeRouter} from "../src/flywheel/FeeRouter.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {MockERC20} from "./MockERC20.sol";

/// Adversarial checks on the task board and worker staking: out-of-order
/// transitions, timing edges, decision binding, counter drift and escrow.
contract BoardHardeningTest is Test {
    bytes32 internal constant CLAUDE = keccak256("claude");
    bytes32 internal constant YES = bytes32(uint256(1));
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint128 internal constant BOUNTY = 10e6;

    address internal brain = makeAddr("brain");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal claude = makeAddr("claude");
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");

    MockERC20 internal usdg;
    TestBRAIN internal brainToken;
    DecisionLog internal decisionLog;
    ModelRegistry internal registry;
    DecisionExecutor internal executor;
    WorkerStaking internal staking;
    TaskBoard internal board;
    FeeRouter internal router;

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
        router = new FeeRouter(IERC20(address(usdg)), address(executor), address(this), brain, 5_000);
        board.setFee(300, address(router));

        usdg.mint(poster, 1_000e6);
        vm.prank(poster);
        usdg.approve(address(board), type(uint256).max);
    }

    // ---- helpers

    function _decide(DecisionLog.Kind kind, bytes32 subject, bytes32 answer, uint16 confidence)
        internal
        returns (uint256)
    {
        vm.prank(brain);
        return decisionLog.record(kind, subject, 0, answer, confidence, 0, "");
    }

    function _post() internal returns (uint256 id) {
        vm.prank(poster);
        id = board.post(BOUNTY, uint64(block.timestamp + 1 days), 0, "");
    }

    function _stake(address who, uint128 amount) internal {
        brainToken.transfer(who, amount);
        vm.startPrank(who);
        brainToken.approve(address(staking), amount);
        staking.stake(amount, 0.2e6);
        vm.stopPrank();
        board.setWorkerAllowed(who, true);
    }

    function _hire(uint256 id, bytes32 model) internal {
        uint256 d = _decide(DecisionLog.Kind.Hire, board.subjectOf(id), model, 9_000);
        vm.prank(brain);
        board.hire(id, d);
    }

    function _submit(uint256 id, address who) internal {
        vm.prank(who);
        board.submit(id, keccak256("r"), "");
    }

    function _grade(uint256 id, bool yes) internal {
        uint256 d = _decide(DecisionLog.Kind.Grade, board.subjectOf(id), yes ? YES : bytes32(0), 9_000);
        vm.prank(brain);
        board.grade(id, d);
    }

    function _rule(uint256 id, bool pay, uint16 conf) internal {
        uint256 d = _decide(DecisionLog.Kind.Ruling, board.subjectOf(id), pay ? YES : bytes32(0), conf);
        vm.prank(brain);
        board.rule(id, d);
    }

    // =====================================================================
    // 1. hold/release counter: sanity across several in-flight tasks,
    //    one lost dispute, one refund by deadline, one paid by finalize.
    //    Expectation: held returns to exactly 0 and withdraw works.
    // =====================================================================
    function test_heldReturnsToZeroAcrossMixedSettlements() public {
        _stake(agent, 1_000e18);
        uint256 a = _post();
        uint256 b = _post();
        uint256 c = _post();
        bytes32 wid = staking.idOf(agent);
        _hire(a, wid);
        _hire(b, wid);
        _hire(c, wid);
        assertEq(staking.held(agent), 3);

        // a: rejected, worker disputes, loses -> slash + release
        _submit(a, agent);
        _grade(a, false);
        vm.prank(agent);
        board.dispute(a);
        _rule(a, false, 9_000);
        assertEq(staking.held(agent), 2);
        assertEq(staking.get(agent).staked, 800e18);

        // b: accepted, finalize after dispute window -> paid + release
        _submit(b, agent);
        _grade(b, true);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(b);
        assertEq(staking.held(agent), 1);

        // c: never delivered, refund at deadline -> release
        vm.warp(block.timestamp + 1 days);
        board.finalize(c);
        assertEq(staking.held(agent), 0);

        // every settled task refuses a second settlement
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.finalize(a);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.finalize(b);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.finalize(c);

        // the worker can leave
        vm.startPrank(agent);
        staking.requestUnstake(800e18);
        vm.warp(block.timestamp + 3 days);
        staking.withdraw();
        vm.stopPrank();
        assertEq(brainToken.balanceOf(agent), 800e18);
        assertEq(usdg.balanceOf(address(board)), 0, "escrow fully drained");
    }

    // =====================================================================
    // 2. Attempted attack: worker tries to dodge the slash by moving stake
    //    into unstaking right after hire and waiting out the cooldown.
    //    Expectation: withdraw is Locked while held, slash hits unstaking.
    // =====================================================================
    function test_attack_workerCannotDodgeSlashViaUnstake() public {
        staking.setConfig(500e18, 1 hours, 2_000); // short cooldown so it elapses inside the 6h rule window
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        vm.prank(agent);
        staking.requestUnstake(500e18); // staked 0, unstaking 500
        _submit(id, agent);
        _grade(id, false);
        vm.prank(agent);
        board.dispute(id);
        // cooldown passes during the dispute, but the hold blocks withdraw
        vm.warp(block.timestamp + 1 hours);
        vm.prank(agent);
        vm.expectRevert(WorkerStaking.Locked.selector);
        staking.withdraw();
        _rule(id, false, 9_000);
        assertEq(staking.get(agent).unstaking, 400e18, "slash reached the unstaking balance");
        assertEq(brainToken.balanceOf(BURN), 100e18);
        assertEq(staking.held(agent), 0);
    }

    // =====================================================================
    // 3. Attempted attack: worker races the ruling with finalize to avoid
    //    the slash. Expectation: inside the window finalize is TooEarly;
    //    after the window rule is TooLate. No overlap. If the brain misses
    //    the window the worker is NOT slashed (operational, not a bug).
    // =====================================================================
    function test_attack_noOverlapBetweenRuleAndFinalizeWindows() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        _submit(id, agent);
        _grade(id, false);
        vm.prank(agent);
        board.dispute(id);
        uint256 edge = block.timestamp + 6 hours;

        vm.warp(edge);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        // rule still allowed at the edge
        uint256 d = _decide(DecisionLog.Kind.Ruling, board.subjectOf(id), bytes32(0), 9_000);
        vm.warp(edge + 1);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.rule(id, d);
        board.finalize(id); // grade stands: refund, and no slash
        assertEq(staking.get(agent).staked, 500e18, "missed ruling window leaves stake intact");
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    // =====================================================================
    // 4. Window boundaries: hire/submit/finalize around the deadline,
    //    grade/finalize around gradeWindow, dispute/finalize around
    //    disputeWindow. Expectation: no timestamp where two conflicting
    //    transitions are both open.
    // =====================================================================
    function test_boundaries_deadline() public {
        uint256 id = _post();
        uint64 deadline = board.get(id).deadline;
        vm.warp(deadline);
        uint256 d = _decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.hire(id, d);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        vm.warp(deadline + 1);
        board.finalize(id);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Refunded));
    }

    function test_boundaries_submitAtDeadlineThenFinalizeIsTooEarly() public {
        uint256 id = _post();
        _hire(id, CLAUDE);
        uint64 deadline = board.get(id).deadline;
        vm.warp(deadline);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        _submit(id, claude); // allowed at == deadline
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Submitted));
    }

    function test_boundaries_gradeWindow() public {
        uint256 id = _post();
        _hire(id, CLAUDE);
        _submit(id, claude);
        uint256 edge = block.timestamp + 6 hours;
        vm.warp(edge);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        _grade(id, true); // allowed at edge
        uint256 dedge = block.timestamp + 1 hours;
        vm.warp(dedge);
        vm.expectRevert(TaskBoard.TooEarly.selector);
        board.finalize(id);
        vm.prank(poster);
        board.dispute(id); // allowed at edge
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Disputed));
    }

    function test_boundaries_gradeAfterWindowIsTooLateAndRefunds() public {
        uint256 id = _post();
        _hire(id, CLAUDE);
        _submit(id, claude);
        vm.warp(block.timestamp + 6 hours + 1);
        uint256 d = _decide(DecisionLog.Kind.Grade, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.TooLate.selector);
        board.grade(id, d);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    // =====================================================================
    // 5. Decision binding probes. Expectation: all rejected.
    // =====================================================================
    function test_binding_gradeRecordedBeforeSubmitIsRejected() public {
        uint256 id = _post();
        _hire(id, CLAUDE);
        uint256 early = _decide(DecisionLog.Kind.Grade, board.subjectOf(id), YES, 9_000);
        vm.warp(block.timestamp + 10);
        _submit(id, claude);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.grade(id, early);
    }

    function test_binding_hireDecisionForOtherTaskIsRejected() public {
        uint256 a = _post();
        uint256 b = _post();
        uint256 d = _decide(DecisionLog.Kind.Hire, board.subjectOf(a), CLAUDE, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.BadDecision.selector);
        board.hire(b, d);
    }

    function test_binding_heldHireConsumesTheDecisionAndKeepsTaskOpen() public {
        uint256 id = _post();
        uint256 low = _decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 1_000);
        vm.prank(brain);
        board.hire(id, low);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Open));
        assertTrue(board.decisionUsed(low));
        vm.prank(brain);
        vm.expectRevert(TaskBoard.DecisionUsed.selector);
        board.hire(id, low);
        // a fresh, confident decision still hires
        _hire(id, CLAUDE);
        assertEq(uint8(board.get(id).status), uint8(TaskBoard.Status.Hired));
    }

    function test_binding_staleDecisionCannotHire() public {
        uint256 id = _post();
        uint256 first = _decide(DecisionLog.Kind.Hire, board.subjectOf(id), CLAUDE, 9_000);
        _decide(DecisionLog.Kind.Hire, board.subjectOf(id), bytes32(0), 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.StaleDecision.selector);
        board.hire(id, first);
    }

    // =====================================================================
    // 6. A second board on the staking contract: the first keeps releasing,
    //    so neither its bounties nor a worker's stake can be stranded.
    // =====================================================================
    /// Adding a board to the staking contract leaves the old board releasing
    /// and slashing, so neither its bounties nor a worker's stake get stranded.
    function test_addendum_aNewBoardDoesNotStrandTheOldBoardsTasks() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        assertEq(staking.held(agent), 1);

        staking.setSlasher(makeAddr("newBoard"), true);

        vm.warp(block.timestamp + 1 days + 1);
        board.finalize(id);
        assertEq(staking.held(agent), 0, "the old board released the hold");

        vm.startPrank(agent);
        staking.requestUnstake(500e18);
        vm.warp(block.timestamp + 3 days);
        staking.withdraw();
        vm.stopPrank();
        assertEq(brainToken.balanceOf(agent), 500e18);

        // A board retired on purpose can no longer hold or slash.
        staking.setSlasher(address(board), false);
        vm.prank(address(board));
        vm.expectRevert(WorkerStaking.NotSlasher.selector);
        staking.hold(agent);
    }

    // =====================================================================
    // 7. Governance footgun: a house model registered under an
    //    address-shaped id is routed to staking, never to the registry.
    //    (a) it cannot be hired at all; (b) if that address happens to be a
    //    staked, allow-listed worker, the bounty pays that address, not the
    //    registry account.
    // =====================================================================
    /// The registry refuses account-shaped ids, which the board would route to
    /// staking instead of the registry.
    function test_footgun_theRegistryRefusesAccountShapedIds() public {
        bytes32 addrShaped = bytes32(uint256(uint160(agent2)));
        vm.expectRevert(ModelRegistry.AccountShapedId.selector);
        registry.setModel(addrShaped, makeAddr("house"), 1, true);
        registry.setModel(keccak256("house"), makeAddr("house"), 1, true);
    }

    // =====================================================================
    // 8. Pausing through a dispute lets the grade stand with no ruling: the
    //    pause blocks the brain's actions, not the clock. Documented behaviour.
    // =====================================================================
    function test_variant_pauseThroughDisputeLetsGradeStand() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        _submit(id, agent);
        _grade(id, false);
        vm.prank(agent);
        board.dispute(id);
        vm.prank(guardian);
        board.setPaused(true);
        uint256 d = _decide(DecisionLog.Kind.Ruling, board.subjectOf(id), YES, 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.IsPaused.selector);
        board.rule(id, d);
        vm.warp(block.timestamp + 6 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6, "a YES ruling was recorded but the rejection stood");
        assertEq(staking.get(agent).staked, 500e18);
    }

    // =====================================================================
    // 9. Informational: requestUnstake restarts the cooldown for the whole
    //    unstaking balance.
    // =====================================================================
    function test_info_topUpUnstakeRestartsCooldownForEverything() public {
        _stake(agent, 600e18);
        vm.startPrank(agent);
        staking.requestUnstake(500e18);
        vm.warp(block.timestamp + 3 days - 1);
        staking.requestUnstake(1e18);
        vm.warp(block.timestamp + 1); // original batch would have unlocked now
        vm.expectRevert(WorkerStaking.Locked.selector);
        staking.withdraw();
        vm.stopPrank();
    }

    // =====================================================================
    // 10. Attempted attack: payee front-runs the poster's dispute. Expect:
    //     only the opener's identity changes; a confident NO then slashes
    //     the worker, so the front-run only hurts the worker.
    // =====================================================================
    function test_attack_workerFrontRunningPosterDisputeOnlyExposesWorker() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        _submit(id, agent);
        _grade(id, true);
        vm.prank(agent);
        board.dispute(id);
        vm.prank(poster);
        vm.expectRevert(TaskBoard.BadStatus.selector);
        board.dispute(id);
        _rule(id, false, 9_000);
        assertEq(staking.get(agent).staked, 400e18);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    // =====================================================================
    // 11. Attempted attack: poster disputes an acceptance and the ruling is
    //     unconfident. Expect: paid, no slash. Poster dispute is free.
    // =====================================================================
    function test_attack_posterDisputeIsFreeButCannotOverturnWithoutConfidence() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        _submit(id, agent);
        _grade(id, true);
        vm.prank(poster);
        board.dispute(id);
        _rule(id, false, 1_000);
        assertEq(usdg.balanceOf(agent), BOUNTY - 0.3e6);
        assertEq(staking.get(agent).staked, 500e18);
        assertEq(staking.held(agent), 0);
    }

    // =====================================================================
    // 12. Attempted attack: un-allow-listed worker mid-task still delivers
    //     and is paid (documented behaviour); a fresh hire is refused.
    // =====================================================================
    function test_attack_delistedWorkerFinishesCurrentTaskOnly() public {
        _stake(agent, 500e18);
        uint256 id = _post();
        _hire(id, staking.idOf(agent));
        board.setWorkerAllowed(agent, false);
        _submit(id, agent);
        _grade(id, true);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(agent), BOUNTY - 0.3e6);
        uint256 id2 = _post();
        uint256 d = _decide(DecisionLog.Kind.Hire, board.subjectOf(id2), staking.idOf(agent), 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.ModelInactive.selector);
        board.hire(id2, d);
    }

    // =====================================================================
    // 13. Escrow conservation with fee: paid path moves exactly bounty.
    // =====================================================================
    function test_escrowConservationWithFee() public {
        uint256 id = _post();
        _hire(id, CLAUDE);
        _submit(id, claude);
        _grade(id, true);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(address(board)), 0);
        assertEq(usdg.balanceOf(claude) + usdg.balanceOf(address(router)), BOUNTY);
    }
}
