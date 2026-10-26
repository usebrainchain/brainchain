// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DecisionLog} from "../src/DecisionLog.sol";
import {FeeRouter} from "../src/flywheel/FeeRouter.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {IDecisionExecutor, ProposalBonds} from "../src/flywheel/ProposalBonds.sol";
import {WorkerStaking} from "../src/flywheel/WorkerStaking.sol";
import {FlywheelTest} from "./Flywheel.t.sol";

contract WorkerStakingCoverage is FlywheelTest {
    event Staked(address indexed account, uint256 amount, uint128 price);
    event UnstakeRequested(address indexed account, uint256 amount, uint64 unlocksAt);
    event Withdrawn(address indexed account, uint256 amount);
    event Slashed(address indexed account, uint256 amount);
    event PriceSet(address indexed account, uint128 price);
    event ConfigSet(uint128 minStake, uint64 cooldown, uint16 slashBps);
    event SlasherSet(address indexed slasher);

    function _fund(uint256 amount) internal {
        brainToken.transfer(agent, amount);
        vm.prank(agent);
        brainToken.approve(address(staking), type(uint256).max);
    }

    function test_constructorRejectsZeroAndBadConfig() public {
        vm.expectRevert(WorkerStaking.ZeroAddress.selector);
        new WorkerStaking(IERC20(address(0)), address(this), 1, 1, 0);
        vm.expectRevert(WorkerStaking.ZeroAddress.selector);
        new WorkerStaking(IERC20(address(brainToken)), address(0), 1, 1, 0);
        vm.expectRevert(WorkerStaking.BadConfig.selector);
        new WorkerStaking(IERC20(address(brainToken)), address(this), 0, 1, 0);
        vm.expectRevert(WorkerStaking.BadConfig.selector);
        new WorkerStaking(IERC20(address(brainToken)), address(this), 1, 0, 0);
        vm.expectRevert(WorkerStaking.BadConfig.selector);
        new WorkerStaking(IERC20(address(brainToken)), address(this), 1, 1, 10_001);
        new WorkerStaking(IERC20(address(brainToken)), address(this), 1, 1, 10_000);
    }

    function test_stakeAddsUpRecordsPriceAndAnnounces() public {
        _fund(1_000e18);
        vm.startPrank(agent);
        vm.expectEmit(true, false, false, true, address(staking));
        emit Staked(agent, 300e18, 0.2e6);
        staking.stake(300e18, 0.2e6);
        staking.stake(300e18, 0.25e6);
        vm.stopPrank();
        WorkerStaking.Worker memory w = staking.get(agent);
        assertEq(w.staked, 600e18);
        assertEq(w.price, 0.25e6);
        assertTrue(w.registered);
        (address account, bool active, uint128 price) = staking.worker(staking.idOf(agent));
        assertEq(account, agent);
        assertTrue(active);
        assertEq(price, 0.25e6);
        assertEq(brainToken.balanceOf(address(staking)), 600e18);
    }

    function test_zeroStakeIsRejected() public {
        vm.prank(agent);
        vm.expectRevert(WorkerStaking.BadAmount.selector);
        staking.stake(0, 1);
    }

    function test_setPriceAnnounces() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit PriceSet(agent, 7);
        vm.prank(agent);
        staking.setPrice(7);
        assertEq(staking.get(agent).price, 7);
    }

    function test_workerLookupForNonWorkerIds() public view {
        (address account, bool active, uint128 price) = staking.worker(CLAUDE);
        assertEq(account, address(0));
        assertFalse(active);
        assertEq(price, 0);
        assertFalse(staking.isWorkerId(bytes32(0)));
    }

    function test_unstakeMovesStakeRestartsCooldownAndAnnounces() public {
        _fund(1_000e18);
        vm.startPrank(agent);
        staking.stake(1_000e18, 1);
        vm.warp(1_000_000);
        vm.expectEmit(true, false, false, true, address(staking));
        emit UnstakeRequested(agent, 400e18, uint64(1_000_000 + 3 days));
        staking.requestUnstake(400e18);
        vm.warp(1_000_000 + 1 days);
        staking.requestUnstake(100e18);
        vm.stopPrank();
        WorkerStaking.Worker memory w = staking.get(agent);
        assertEq(w.staked, 500e18);
        assertEq(w.unstaking, 500e18);
        assertEq(w.unlocksAt, 1_000_000 + 1 days + 3 days);
    }

    function test_unstakeRejectsZeroAndTooMuch() public {
        _fund(100e18);
        vm.startPrank(agent);
        staking.stake(100e18, 1);
        vm.expectRevert(WorkerStaking.BadAmount.selector);
        staking.requestUnstake(0);
        vm.expectRevert(WorkerStaking.BadAmount.selector);
        staking.requestUnstake(101e18);
        vm.stopPrank();
    }

    function test_withdrawUnlocksAtTheExactTimeAndOnlyOnce() public {
        _fund(600e18);
        vm.startPrank(agent);
        staking.stake(600e18, 1);
        vm.warp(2_000_000);
        staking.requestUnstake(600e18);
        vm.warp(2_000_000 + 3 days - 1);
        vm.expectRevert(WorkerStaking.Locked.selector);
        staking.withdraw();
        vm.warp(2_000_000 + 3 days);
        vm.expectEmit(true, false, false, true, address(staking));
        emit Withdrawn(agent, 600e18);
        staking.withdraw();
        vm.expectRevert(WorkerStaking.BadAmount.selector);
        staking.withdraw();
        vm.stopPrank();
        assertEq(brainToken.balanceOf(agent), 600e18);
        assertEq(staking.get(agent).unstaking, 0);
    }

    function test_withdrawWithNothingUnstakingFails() public {
        vm.prank(agent);
        vm.expectRevert(WorkerStaking.BadAmount.selector);
        staking.withdraw();
    }

    function test_slashTakesTheShareOfStakedAndUnstaking() public {
        _fund(1_000e18);
        vm.startPrank(agent);
        staking.stake(1_000e18, 1);
        staking.requestUnstake(400e18);
        vm.stopPrank();
        vm.expectEmit(true, false, false, true, address(staking));
        emit Slashed(agent, 200e18);
        vm.prank(address(board));
        assertEq(staking.slash(agent), 200e18);
        WorkerStaking.Worker memory w = staking.get(agent);
        assertEq(w.staked, 480e18);
        assertEq(w.unstaking, 320e18);
        assertEq(brainToken.balanceOf(BURN), 200e18);
        (, bool active,) = staking.worker(staking.idOf(agent));
        assertFalse(active);
    }

    function test_slashingNothingTransfersNothing() public {
        vm.prank(address(board));
        assertEq(staking.slash(agent), 0);
        assertEq(brainToken.balanceOf(BURN), 0);
    }

    function test_adminIsOwnerOnlyAndAnnounced() public {
        vm.startPrank(agent);
        vm.expectRevert(WorkerStaking.NotOwner.selector);
        staking.setSlasher(agent);
        vm.expectRevert(WorkerStaking.NotOwner.selector);
        staking.setConfig(1, 1, 1);
        vm.expectRevert(WorkerStaking.NotOwner.selector);
        staking.setOwner(agent);
        vm.stopPrank();

        vm.expectRevert(WorkerStaking.ZeroAddress.selector);
        staking.setSlasher(address(0));
        vm.expectEmit(true, false, false, false, address(staking));
        emit SlasherSet(agent);
        staking.setSlasher(agent);

        vm.expectEmit(false, false, false, true, address(staking));
        emit ConfigSet(10, 20, 30);
        staking.setConfig(10, 20, 30);
        assertEq(staking.minStake(), 10);
        assertEq(staking.cooldown(), 20);
        assertEq(staking.slashBps(), 30);

        vm.expectRevert(WorkerStaking.ZeroAddress.selector);
        staking.setOwner(address(0));
        staking.setOwner(agent);
        assertEq(staking.owner(), agent);
    }
}

contract FeeRouterCoverage is FlywheelTest {
    event BrainSet(address indexed brain);
    event AdapterSet(address indexed adapter);
    event KeeperSet(address indexed keeper);
    event BurnShareSet(uint16 burnBps);
    event BoughtBack(uint256 feeIn, uint256 brainOut, uint256 burned, uint256 toTreasury);

    function test_constructorRejectsZeroAndBadShare() public {
        IERC20 t = IERC20(address(usdg));
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(IERC20(address(0)), address(executor), address(this), brain, 0);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(t, address(0), address(this), brain, 0);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(t, address(executor), address(0), brain, 0);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        new FeeRouter(t, address(executor), address(this), address(0), 0);
        vm.expectRevert(FeeRouter.BadShare.selector);
        new FeeRouter(t, address(executor), address(this), brain, 10_001);
        new FeeRouter(t, address(executor), address(this), brain, 10_000);
    }

    function test_settersAreOwnerOnlyValidatedAndAnnounced() public {
        vm.startPrank(poster);
        vm.expectRevert(FeeRouter.NotOwner.selector);
        router.setBrain(IERC20(address(brainToken)));
        vm.expectRevert(FeeRouter.NotOwner.selector);
        router.setAdapter(swap);
        vm.expectRevert(FeeRouter.NotOwner.selector);
        router.setKeeper(poster);
        vm.expectRevert(FeeRouter.NotOwner.selector);
        router.setBurnShare(1);
        vm.expectRevert(FeeRouter.NotOwner.selector);
        router.setOwner(poster);
        vm.stopPrank();

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.setBrain(IERC20(address(0)));
        vm.expectEmit(true, false, false, false, address(router));
        emit BrainSet(address(brainToken));
        router.setBrain(IERC20(address(brainToken)));

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.setAdapter(ISwapAdapter(address(0)));
        vm.expectEmit(true, false, false, false, address(router));
        emit AdapterSet(address(swap));
        router.setAdapter(swap);

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.setKeeper(address(0));
        vm.expectEmit(true, false, false, false, address(router));
        emit KeeperSet(poster);
        router.setKeeper(poster);
        assertEq(router.keeper(), poster);

        vm.expectRevert(FeeRouter.BadShare.selector);
        router.setBurnShare(10_001);
        vm.expectEmit(false, false, false, true, address(router));
        emit BurnShareSet(10_000);
        router.setBurnShare(10_000);
        assertEq(router.burnBps(), 10_000);

        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.setOwner(address(0));
        router.setOwner(poster);
        assertEq(router.owner(), poster);
    }

    function test_buybackNeedsBothTokenAndAdapter() public {
        _runToPaid(CLAUDE, claude);
        router.setAdapter(swap);
        vm.prank(brain);
        vm.expectRevert(FeeRouter.NotReady.selector);
        router.buyback(1, 0);
    }

    function test_buybackCapsAtTheBalanceAnnouncesAndClearsApproval() public {
        _runToPaid(CLAUDE, claude);
        router.setBrain(IERC20(address(brainToken)));
        router.setAdapter(swap);
        // A stray tBRAIN balance on the router is not counted as bought.
        brainToken.transfer(address(router), 1e18);
        vm.expectEmit(false, false, false, true, address(router));
        emit BoughtBack(0.3e6, 0.3e18, 0.15e18, 0.15e18);
        vm.prank(brain);
        assertEq(router.buyback(1_000e6, 0.3e18), 0.3e18);
        assertEq(usdg.allowance(address(router), address(swap)), 0);
        assertEq(brainToken.balanceOf(address(router)), 1e18);
    }

    function test_ownerCanBuyBack() public {
        _runToPaid(CLAUDE, claude);
        router.setBrain(IERC20(address(brainToken)));
        router.setAdapter(swap);
        router.buyback(0.3e6, 0.3e18);
        assertEq(brainToken.balanceOf(address(executor)), 0.15e18);
    }
}

contract ProposalBondsCoverage is FlywheelTest {
    event Proposed(
        uint256 indexed id, address indexed proposer, address indexed target, bytes data, uint128 bond, string uri
    );
    event Settled(uint256 indexed id, uint256 indexed decisionId, bool adopted);
    event Expired(uint256 indexed id);
    event ConfigSet(uint128 bond, uint64 decideWithin);

    bytes internal data = abi.encodeWithSignature("setPaused(bool)", true);

    function _proposeAt(uint256 at) internal returns (uint256 id) {
        vm.warp(at);
        brainToken.transfer(agent, 100e18);
        vm.startPrank(agent);
        brainToken.approve(address(bonds), 100e18);
        id = bonds.propose(address(board), data, "uri");
        vm.stopPrank();
    }

    function _changeDecision(bytes32 answer, uint16 confidence) internal returns (uint256) {
        return _decide(DecisionLog.Kind.Change, executor.changeSubject(address(board), data), answer, confidence);
    }

    function test_constructorRejectsZeroAndBadConfig() public {
        IERC20 t = IERC20(address(brainToken));
        IDecisionExecutor e = IDecisionExecutor(address(executor));
        vm.expectRevert(ProposalBonds.ZeroAddress.selector);
        new ProposalBonds(IERC20(address(0)), decisionLog, e, address(this), 1, 1);
        vm.expectRevert(ProposalBonds.ZeroAddress.selector);
        new ProposalBonds(t, DecisionLog(address(0)), e, address(this), 1, 1);
        vm.expectRevert(ProposalBonds.ZeroAddress.selector);
        new ProposalBonds(t, decisionLog, IDecisionExecutor(address(0)), address(this), 1, 1);
        vm.expectRevert(ProposalBonds.ZeroAddress.selector);
        new ProposalBonds(t, decisionLog, e, address(0), 1, 1);
        vm.expectRevert(ProposalBonds.BadConfig.selector);
        new ProposalBonds(t, decisionLog, e, address(this), 0, 1);
        vm.expectRevert(ProposalBonds.BadConfig.selector);
        new ProposalBonds(t, decisionLog, e, address(this), 1, 0);
        ProposalBonds fresh = new ProposalBonds(t, decisionLog, e, address(this), 1, 1);
        assertEq(fresh.owner(), address(this));
    }

    function test_proposeStoresNumbersAndAnnounces() public {
        vm.warp(5_000_000);
        brainToken.transfer(agent, 200e18);
        vm.startPrank(agent);
        brainToken.approve(address(bonds), 200e18);
        vm.expectEmit(true, true, true, true, address(bonds));
        emit Proposed(1, agent, address(board), data, 100e18, "uri");
        assertEq(bonds.propose(address(board), data, "uri"), 1);
        assertEq(bonds.propose(address(board), data, "uri"), 2);
        vm.expectRevert(ProposalBonds.ZeroAddress.selector);
        bonds.propose(address(0), data, "uri");
        vm.stopPrank();
        ProposalBonds.Proposal memory p = bonds.get(1);
        assertEq(p.proposer, agent);
        assertEq(p.bond, 100e18);
        assertEq(p.createdAt, 5_000_000);
        assertEq(uint8(p.state), uint8(ProposalBonds.State.Open));
        assertEq(p.subject, executor.changeSubject(address(board), data));
        assertEq(bonds.count(), 2);
    }

    function test_settleAnnouncesAndCannotRepeat() public {
        uint256 id = _proposeAt(6_000_000);
        uint256 d = _changeDecision(YES, 9_000);
        vm.expectEmit(true, true, false, true, address(bonds));
        emit Settled(id, d, true);
        bonds.settle(id, d);
        assertEq(uint8(bonds.get(id).state), uint8(ProposalBonds.State.Returned));
        vm.expectRevert(ProposalBonds.BadState.selector);
        bonds.settle(id, d);
        vm.expectRevert(ProposalBonds.BadState.selector);
        bonds.expire(id);
        assertEq(brainToken.balanceOf(agent), 100e18);
    }

    function test_burnedProposalIsClosed() public {
        uint256 id = _proposeAt(6_100_000);
        bonds.settle(id, _changeDecision(bytes32(0), 9_000));
        assertEq(uint8(bonds.get(id).state), uint8(ProposalBonds.State.Burned));
        uint256 again = _changeDecision(YES, 9_000);
        vm.expectRevert(ProposalBonds.BadState.selector);
        bonds.settle(id, again);
    }

    function test_settleAcceptsTheExactThresholdAndRejectsOtherKinds() public {
        uint256 id = _proposeAt(6_200_000);
        uint256 hire = _decide(DecisionLog.Kind.Hire, executor.changeSubject(address(board), data), YES, 9_000);
        vm.expectRevert(ProposalBonds.BadDecision.selector);
        bonds.settle(id, hire);
        bonds.settle(id, _changeDecision(YES, 8_500));
        assertEq(uint8(bonds.get(id).state), uint8(ProposalBonds.State.Returned));
    }

    function test_decisionRecordedBeforeTheProposalDoesNotCount() public {
        vm.warp(6_300_000);
        uint256 early = _changeDecision(bytes32(0), 9_000);
        uint256 id = _proposeAt(6_300_001);
        vm.expectRevert(ProposalBonds.BadDecision.selector);
        bonds.settle(id, early);
        uint256 sameTime = _changeDecision(YES, 9_000);
        bonds.settle(id, sameTime);
    }

    function test_expireBoundaryAnnounceAndUnknownProposals() public {
        uint256 id = _proposeAt(7_000_000);
        vm.warp(7_000_000 + 7 days);
        vm.expectRevert(ProposalBonds.TooEarly.selector);
        bonds.expire(id);
        vm.warp(7_000_000 + 7 days + 1);
        vm.expectEmit(true, false, false, false, address(bonds));
        emit Expired(id);
        bonds.expire(id);
        assertEq(uint8(bonds.get(id).state), uint8(ProposalBonds.State.Returned));
        vm.expectRevert(ProposalBonds.BadState.selector);
        bonds.expire(id);
        vm.expectRevert(ProposalBonds.BadState.selector);
        bonds.expire(99);
    }

    function test_setConfigIsOwnerOnlyValidatedAndAnnounced() public {
        ProposalBonds own = new ProposalBonds(
            IERC20(address(brainToken)), decisionLog, IDecisionExecutor(address(executor)), address(this), 1, 1
        );
        vm.prank(agent);
        vm.expectRevert(ProposalBonds.NotOwner.selector);
        own.setConfig(2, 2);
        vm.expectRevert(ProposalBonds.BadConfig.selector);
        own.setConfig(0, 2);
        vm.expectRevert(ProposalBonds.BadConfig.selector);
        own.setConfig(2, 0);
        vm.expectEmit(false, false, false, true, address(own));
        emit ConfigSet(5, 6);
        own.setConfig(5, 6);
        assertEq(own.bond(), 5);
        assertEq(own.decideWithin(), 6);
    }
}
