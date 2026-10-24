// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionExecutor} from "../src/DecisionExecutor.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TaskBoard} from "../src/TaskBoard.sol";
import {FeeRouter} from "../src/flywheel/FeeRouter.sol";
import {ProposalBonds, IChangeThreshold} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {TestBRAIN} from "../src/testnet/TestBRAIN.sol";
import {TestSwap} from "../src/testnet/TestSwap.sol";
import {MockERC20} from "./MockERC20.sol";

contract FlywheelTest is Test {
    bytes32 internal constant CLAUDE = keccak256("claude");
    bytes32 internal constant YES = bytes32(uint256(1));
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint128 internal constant BOUNTY = 10e6;

    address internal brain = makeAddr("brain");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal claude = makeAddr("claude");
    address internal agent = makeAddr("agent");

    MockERC20 internal usdg;
    TestBRAIN internal brainToken;
    DecisionLog internal decisionLog;
    ModelRegistry internal registry;
    DecisionExecutor internal executor;
    WorkerStaking internal staking;
    TaskBoard internal board;
    FeeRouter internal router;
    TestSwap internal swap;
    ProposalBonds internal bonds;

    function setUp() public {
        usdg = new MockERC20();
        brainToken = new TestBRAIN(address(this), 1_000_000e18);
        decisionLog = new DecisionLog(address(this), brain);
        executor = new DecisionExecutor(decisionLog, IERC20(address(usdg)), guardian, 8_500, 2 hours, 5);
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
        staking.setSlasher(address(board));
        router = new FeeRouter(IERC20(address(usdg)), address(executor), address(this), brain, 5_000);
        board.setFee(300, address(router));
        swap = new TestSwap(IERC20(address(usdg)), IERC20(address(brainToken)), 1e12);
        brainToken.transfer(address(swap), 500_000e18);
        bonds = new ProposalBonds(
            IERC20(address(brainToken)), decisionLog, IChangeThreshold(address(executor)), address(this), 100e18, 7 days
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

    function _post() internal returns (uint256 id) {
        vm.prank(poster);
        id = board.post(BOUNTY, uint64(block.timestamp + 1 days), 0, "");
    }

    function _runToPaid(bytes32 model, address account) internal returns (uint256 id) {
        id = _post();
        uint256 d = _decide(DecisionLog.Kind.Hire, bytes32(id), model, 9_000);
        vm.prank(brain);
        board.hire(id, d);
        vm.prank(account);
        board.submit(id, 0, "");
        d = _decide(DecisionLog.Kind.Grade, bytes32(id), YES, 9_000);
        vm.prank(brain);
        board.grade(id, d);
        vm.warp(block.timestamp + 1 hours + 1);
        board.finalize(id);
    }

    // ---- fee

    function test_paidBountySendsTheFeeToTheRouter() public {
        _runToPaid(CLAUDE, claude);
        assertEq(usdg.balanceOf(address(router)), 0.3e6);
        assertEq(usdg.balanceOf(claude), BOUNTY - 0.3e6);
    }

    function test_refundsPayNoFee() public {
        uint256 id = _post();
        vm.warp(block.timestamp + 1 days + 1);
        board.finalize(id);
        assertEq(usdg.balanceOf(poster), 1_000e6);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    function test_feeIsCapped() public {
        vm.expectRevert(TaskBoard.BadFee.selector);
        board.setFee(1_001, address(router));
    }

    // ---- buyback

    function test_buybackWaitsForTheTokenAddress() public {
        _runToPaid(CLAUDE, claude);
        vm.prank(brain);
        vm.expectRevert(FeeRouter.NotReady.selector);
        router.buyback(0.3e6, 0);
    }

    function test_buybackBurnsHalfAndFundsTheTreasury() public {
        _runToPaid(CLAUDE, claude);
        router.setBrain(IERC20(address(brainToken)));
        router.setAdapter(swap);
        vm.prank(brain);
        uint256 out = router.buyback(0.3e6, 0.3e18);
        assertEq(out, 0.3e18);
        assertEq(brainToken.balanceOf(BURN), 0.15e18);
        assertEq(brainToken.balanceOf(address(executor)), 0.15e18);
        assertEq(usdg.balanceOf(address(router)), 0);
    }

    function test_buybackRespectsMinOut() public {
        _runToPaid(CLAUDE, claude);
        router.setBrain(IERC20(address(brainToken)));
        router.setAdapter(swap);
        vm.prank(brain);
        vm.expectRevert(TestSwap.Slippage.selector);
        router.buyback(0.3e6, 1e18);
    }

    function test_tokenAddressIsSetOnce() public {
        router.setBrain(IERC20(address(brainToken)));
        vm.expectRevert(FeeRouter.AlreadySet.selector);
        router.setBrain(IERC20(address(usdg)));
    }

    function test_onlyKeeperOrOwnerBuysBack() public {
        vm.prank(poster);
        vm.expectRevert(FeeRouter.NotKeeper.selector);
        router.buyback(1, 0);
    }

    // ---- staking

    function _stake(uint128 amount) internal {
        brainToken.transfer(agent, amount);
        vm.startPrank(agent);
        brainToken.approve(address(staking), amount);
        staking.stake(amount, 0.2e6);
        vm.stopPrank();
    }

    function test_stakedWorkerCanBeHiredAndPaid() public {
        _stake(500e18);
        _runToPaid(staking.idOf(agent), agent);
        assertEq(usdg.balanceOf(agent), BOUNTY - 0.3e6);
    }

    function test_understakedWorkerCannotBeHired() public {
        _stake(499e18);
        uint256 id = _post();
        uint256 d = _decide(DecisionLog.Kind.Hire, bytes32(id), staking.idOf(agent), 9_000);
        vm.prank(brain);
        vm.expectRevert(TaskBoard.ModelInactive.selector);
        board.hire(id, d);
    }

    function test_workerThatDisputesAndLosesIsSlashed() public {
        _stake(1_000e18);
        uint256 id = _post();
        uint256 d = _decide(DecisionLog.Kind.Hire, bytes32(id), staking.idOf(agent), 9_000);
        vm.prank(brain);
        board.hire(id, d);
        vm.prank(agent);
        board.submit(id, 0, "");
        d = _decide(DecisionLog.Kind.Grade, bytes32(id), bytes32(0), 9_000);
        vm.prank(brain);
        board.grade(id, d);
        vm.prank(agent);
        board.dispute(id);
        d = _decide(DecisionLog.Kind.Ruling, bytes32(id), bytes32(0), 9_000);
        vm.prank(brain);
        board.rule(id, d);

        assertEq(staking.get(agent).staked, 800e18);
        assertEq(brainToken.balanceOf(BURN), 200e18);
        assertEq(usdg.balanceOf(poster), 1_000e6);
    }

    function test_unstakeWaitsForTheCooldown() public {
        _stake(600e18);
        vm.startPrank(agent);
        staking.requestUnstake(600e18);
        vm.expectRevert(WorkerStaking.Locked.selector);
        staking.withdraw();
        vm.warp(block.timestamp + 3 days);
        staking.withdraw();
        vm.stopPrank();
        assertEq(brainToken.balanceOf(agent), 600e18);
    }

    function test_onlyTheBoardSlashes() public {
        vm.expectRevert(WorkerStaking.NotSlasher.selector);
        staking.slash(agent);
    }

    function test_houseIdsAreNeverWorkerIds() public view {
        assertFalse(staking.isWorkerId(CLAUDE));
        assertTrue(staking.isWorkerId(staking.idOf(agent)));
    }

    // ---- proposal bonds

    function _propose() internal returns (uint256 id, bytes memory data) {
        data = abi.encodeCall(TaskBoard.setPaused, (true));
        brainToken.transfer(agent, 100e18);
        vm.startPrank(agent);
        brainToken.approve(address(bonds), 100e18);
        id = bonds.propose(address(board), data, "ipfs://proposal");
        vm.stopPrank();
    }

    function test_adoptedProposalReturnsTheBond() public {
        (uint256 id, bytes memory data) = _propose();
        uint256 d = _decide(DecisionLog.Kind.Change, keccak256(abi.encode(address(board), data)), YES, 9_000);
        bonds.settle(id, d);
        assertEq(brainToken.balanceOf(agent), 100e18);
    }

    function test_rejectedProposalBurnsTheBond() public {
        (uint256 id, bytes memory data) = _propose();
        uint256 d = _decide(DecisionLog.Kind.Change, keccak256(abi.encode(address(board), data)), bytes32(0), 9_000);
        bonds.settle(id, d);
        assertEq(brainToken.balanceOf(BURN), 100e18);
    }

    function test_lowConfidenceAdoptStillBurns() public {
        (uint256 id, bytes memory data) = _propose();
        uint256 d = _decide(DecisionLog.Kind.Change, keccak256(abi.encode(address(board), data)), YES, 8_000);
        bonds.settle(id, d);
        assertEq(brainToken.balanceOf(BURN), 100e18);
    }

    function test_decisionMustBeAboutTheProposal() public {
        (uint256 id,) = _propose();
        uint256 d = _decide(DecisionLog.Kind.Change, keccak256("other"), YES, 9_000);
        vm.expectRevert(ProposalBonds.BadDecision.selector);
        bonds.settle(id, d);
    }

    function test_undecidedProposalIsReturnedAfterTheWindow() public {
        (uint256 id,) = _propose();
        vm.expectRevert(ProposalBonds.TooEarly.selector);
        bonds.expire(id);
        vm.warp(block.timestamp + 7 days + 1);
        bonds.expire(id);
        assertEq(brainToken.balanceOf(agent), 100e18);
    }
}
