// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";
import {SwitchGate, ISwitchTimelock} from "../src/SwitchGate.sol";

/// A listed target that, when the timelock calls it, tries to run another batch through the gate.
contract ReenteringLog {
    address public immutable owner;
    address internal immutable gate;
    bytes internal reentry;

    constructor(address owner_, address gate_) {
        owner = owner_;
        gate = gate_;
    }

    function arm(bytes calldata reentry_) external {
        reentry = reentry_;
    }

    function allowApp(bytes32, bool) external {
        (bool ok, bytes memory reason) = gate.call(reentry);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}

contract SwitchGateTest is Test {
    uint256 internal constant DELAY = 48 hours;
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant SALT = keccak256("enclave v17, release 13");
    bytes32 internal constant IMAGE = keccak256("image 116");
    bytes32 internal constant OLD_APP = keccak256("v16 app");
    bytes32 internal constant APP = keccak256("v17 app");

    TimelockController internal timelock;
    DecisionLog internal logA;
    DecisionLog internal logB;
    SwitchGate internal gate;
    address internal safe = makeAddr("safe");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        address[] memory seats = new address[](1);
        seats[0] = safe;
        timelock = new TimelockController(DELAY, seats, seats, address(0));
        logA = new DecisionLog(address(timelock), makeAddr("brain"));
        logB = new DecisionLog(address(timelock), makeAddr("brain"));
        address[] memory logs = new address[](2);
        logs[0] = address(logA);
        logs[1] = address(logB);
        gate = new SwitchGate(safe, ISwitchTimelock(address(timelock)), operator, guardian, logs);

        vm.startPrank(address(timelock));
        timelock.grantRole(EXECUTOR_ROLE, address(gate));
        logA.allowApp(OLD_APP, true);
        logB.allowApp(OLD_APP, true);
        vm.stopPrank();
    }

    function _release(bytes32 app, bytes32 old) internal view returns (address[] memory t, bytes[] memory p) {
        t = new address[](6);
        p = new bytes[](6);
        address[2] memory logs = [address(logA), address(logB)];
        for (uint256 i; i < 2; i++) {
            t[3 * i] = logs[i];
            t[3 * i + 1] = logs[i];
            t[3 * i + 2] = logs[i];
            p[3 * i] = abi.encodeCall(DecisionLog.allowImage, (IMAGE, true));
            p[3 * i + 1] = abi.encodeCall(DecisionLog.allowApp, (app, true));
            p[3 * i + 2] = abi.encodeCall(DecisionLog.allowApp, (old, false));
        }
    }

    function _one(address target, bytes memory payload) internal pure returns (address[] memory t, bytes[] memory p) {
        t = new address[](1);
        p = new bytes[](1);
        t[0] = target;
        p[0] = payload;
    }

    function _schedule(address[] memory t, bytes[] memory p, bytes32 predecessor, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        uint256[] memory v = new uint256[](t.length);
        vm.prank(safe);
        timelock.scheduleBatch(t, v, p, predecessor, salt, DELAY);
        id = timelock.hashOperationBatch(t, v, p, predecessor, salt);
    }

    function _arm(bytes32 id) internal {
        vm.prank(safe);
        gate.setArmed(id, true);
    }

    function _scheduleArmed(address[] memory t, bytes[] memory p, bytes32 predecessor, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        id = _schedule(t, p, predecessor, salt);
        _arm(id);
    }

    function _notReady(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            TimelockController.TimelockUnexpectedOperationState.selector,
            id,
            bytes32(1 << uint8(TimelockController.OperationState.Ready))
        );
    }

    function _notArmed(bytes32 id) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SwitchGate.NotArmed.selector, id);
    }

    function _notOwned(address log) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SwitchGate.NotTimelockOwned.selector, log);
    }

    function _assertReleased(bytes32 app, bytes32 old) internal view {
        DecisionLog[2] memory logs = [logA, logB];
        for (uint256 i; i < 2; i++) {
            assertTrue(logs[i].allowedImage(IMAGE));
            assertTrue(logs[i].allowedApp(app));
            assertFalse(logs[i].allowedApp(old));
        }
    }

    // Armed by the Safe, so only the gate's own filter stands in the way.
    function _forbidden(address[] memory t, bytes[] memory p, bytes memory err) internal {
        _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(operator);
        vm.expectRevert(err);
        gate.execute(t, p, 0, SALT);
    }

    function test_theOperatorExecutesAnArmedReleaseOnceItsDelayHasPassed() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);

        vm.expectEmit(true, true, false, true, address(gate));
        emit SwitchGate.Executed(id, operator);
        vm.prank(operator);
        gate.execute(t, p, 0, SALT);

        assertTrue(timelock.isOperationDone(id));
        _assertReleased(APP, OLD_APP);
    }

    function test_theSafeExecutesThroughTheGateToo() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);

        vm.expectEmit(true, true, false, true, address(gate));
        emit SwitchGate.Executed(id, safe);
        vm.prank(safe);
        gate.execute(t, p, 0, SALT);
        _assertReleased(APP, OLD_APP);
    }

    function test_anUnarmedBatchIsRefusedForTheOperatorAndTheSafe() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _schedule(t, p, 0, SALT);
        skip(DELAY);

        vm.prank(operator);
        vm.expectRevert(_notArmed(id));
        gate.execute(t, p, 0, SALT);
        vm.prank(safe);
        vm.expectRevert(_notArmed(id));
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationReady(id));
        assertTrue(logA.allowedApp(OLD_APP));
    }

    function test_onlyTheSafeArmsAndDisarms() public {
        bytes32 id = keccak256("an operation");
        address[3] memory others = [operator, guardian, stranger];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setArmed(id, true);
            vm.stopPrank();
        }
        assertFalse(gate.armed(id));

        vm.expectEmit(true, false, false, true, address(gate));
        emit SwitchGate.Armed(id, true);
        _arm(id);
        assertTrue(gate.armed(id));

        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setArmed(id, false);
            vm.stopPrank();
        }
        assertTrue(gate.armed(id));

        vm.expectEmit(true, false, false, true, address(gate));
        emit SwitchGate.Armed(id, false);
        vm.prank(safe);
        gate.setArmed(id, false);
        assertFalse(gate.armed(id));
    }

    function test_aDisarmedBatchIsRefused() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(safe);
        gate.setArmed(id, false);

        vm.prank(operator);
        vm.expectRevert(_notArmed(id));
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationReady(id));
    }

    function test_anArmedBatchRunsOnce() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(operator);
        gate.execute(t, p, 0, SALT);
        assertFalse(gate.armed(id));

        vm.prank(operator);
        vm.expectRevert(_notArmed(id));
        gate.execute(t, p, 0, SALT);

        _arm(id);
        vm.prank(operator);
        vm.expectRevert(_notReady(id));
        gate.execute(t, p, 0, SALT);
        assertTrue(gate.armed(id), "the failed attempt rolled the delete back");
    }

    function test_withTwoReadyReleasesTheOperatorRunsOnlyTheArmedOne() public {
        (address[] memory superseded, bytes[] memory sp) = _release(APP, OLD_APP);
        bytes32 stale = _schedule(superseded, sp, 0, SALT);
        bytes32 v18 = keccak256("v18 app");
        (address[] memory current, bytes[] memory cp) = _release(v18, OLD_APP);
        bytes32 next = _scheduleArmed(current, cp, 0, SALT);
        skip(DELAY);
        assertTrue(timelock.isOperationReady(stale));

        vm.prank(operator);
        vm.expectRevert(_notArmed(stale));
        gate.execute(superseded, sp, 0, SALT);

        vm.prank(operator);
        gate.execute(current, cp, 0, SALT);
        _assertReleased(v18, OLD_APP);

        vm.prank(operator);
        vm.expectRevert(_notArmed(stale));
        gate.execute(superseded, sp, 0, SALT);
        assertFalse(logA.allowedApp(APP));
        assertTrue(timelock.isOperationDone(next));
    }

    function test_aFailedAttemptLeavesTheArmingInPlace() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);

        skip(DELAY - 1);
        vm.prank(operator);
        vm.expectRevert(_notReady(id));
        gate.execute(t, p, 0, SALT);
        assertTrue(gate.armed(id));

        (address[] memory bad, bytes[] memory bp) =
            _one(address(logA), abi.encodePacked(DecisionLog.allowApp.selector, APP, uint256(2)));
        bytes32 badId = _scheduleArmed(bad, bp, 0, SALT);
        skip(DELAY);
        vm.prank(operator);
        vm.expectRevert(Address.FailedInnerCall.selector);
        gate.execute(bad, bp, 0, SALT);
        assertTrue(gate.armed(badId));
        assertTrue(timelock.isOperationReady(badId));
        assertFalse(logA.allowedApp(APP));

        vm.prank(operator);
        gate.execute(t, p, 0, SALT);
        assertFalse(gate.armed(id));
    }

    function test_theTimelockRefusesBeforeTheDelayAndAfterExecution() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);

        skip(DELAY - 1);
        vm.prank(operator);
        vm.expectRevert(_notReady(id));
        gate.execute(t, p, 0, SALT);
        assertTrue(logA.allowedApp(OLD_APP));

        skip(1);
        vm.prank(operator);
        gate.execute(t, p, 0, SALT);

        _arm(id);
        vm.prank(safe);
        vm.expectRevert(_notReady(id));
        gate.execute(t, p, 0, SALT);
    }

    function test_aBatchTheSafeNeverScheduledIsRefused() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);

        (address[] memory t2, bytes[] memory p2) = _release(keccak256("an app nobody approved"), OLD_APP);
        uint256[] memory v = new uint256[](t2.length);
        bytes32 madeUp = timelock.hashOperationBatch(t2, v, p2, 0, SALT);
        vm.prank(operator);
        vm.expectRevert(_notArmed(madeUp));
        gate.execute(t2, p2, 0, SALT);

        _arm(madeUp);
        vm.prank(operator);
        vm.expectRevert(_notReady(madeUp));
        gate.execute(t2, p2, 0, SALT);

        bytes32 otherSalt = bytes32(uint256(SALT) + 1);
        bytes32 resalted = timelock.hashOperationBatch(t, v, p, 0, otherSalt);
        _arm(resalted);
        vm.prank(operator);
        vm.expectRevert(_notReady(resalted));
        gate.execute(t, p, 0, otherSalt);
    }

    function test_aBatchScheduledWithValueCannotRunThroughTheGate() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        uint256[] memory v = new uint256[](t.length);
        v[1] = 1;
        vm.prank(safe);
        timelock.scheduleBatch(t, v, p, 0, SALT, DELAY);
        bytes32 paid = timelock.hashOperationBatch(t, v, p, 0, SALT);
        bytes32 unpaid = timelock.hashOperationBatch(t, new uint256[](t.length), p, 0, SALT);
        _arm(paid);
        _arm(unpaid);
        skip(DELAY);

        vm.prank(operator);
        vm.expectRevert(_notReady(unpaid));
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationReady(paid));
    }

    function test_aSingleScheduledCallCannotRunThroughTheGate() public {
        bytes memory payload = abi.encodeCall(DecisionLog.allowApp, (APP, true));
        vm.prank(safe);
        timelock.schedule(address(logA), 0, payload, 0, SALT, DELAY);
        _arm(timelock.hashOperation(address(logA), 0, payload, 0, SALT));
        skip(DELAY);

        (address[] memory t, bytes[] memory p) = _one(address(logA), payload);
        bytes32 asBatch = timelock.hashOperationBatch(t, new uint256[](1), p, 0, SALT);
        vm.prank(operator);
        vm.expectRevert(_notArmed(asBatch));
        gate.execute(t, p, 0, SALT);

        _arm(asBatch);
        vm.prank(operator);
        vm.expectRevert(_notReady(asBatch));
        gate.execute(t, p, 0, SALT);
    }

    function test_aPredecessorHoldsTheOrderThroughTheGate() public {
        (address[] memory t1, bytes[] memory p1) = _release(APP, OLD_APP);
        bytes32 first = _scheduleArmed(t1, p1, 0, SALT);
        bytes32 v18 = keccak256("v18 app");
        (address[] memory t2, bytes[] memory p2) = _release(v18, APP);
        bytes32 second = _scheduleArmed(t2, p2, first, SALT);
        skip(DELAY);

        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, first));
        gate.execute(t2, p2, first, SALT);
        assertTrue(gate.armed(second));
        gate.execute(t1, p1, 0, SALT);
        gate.execute(t2, p2, first, SALT);
        vm.stopPrank();
        _assertReleased(v18, APP);
        assertFalse(logA.allowedApp(OLD_APP));
    }

    function test_refusesALogThatIsNotListed() public {
        DecisionLog other = new DecisionLog(address(timelock), makeAddr("brain"));
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        t[4] = address(other);
        _forbidden(t, p, abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 4));
        assertFalse(other.allowedApp(APP));
    }

    function test_refusesTheTimelockAsATarget() public {
        (address[] memory t, bytes[] memory p) =
            _one(address(timelock), abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, operator)));
        _forbidden(t, p, abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 0));
        assertFalse(timelock.hasRole(PROPOSER_ROLE, operator));

        (t, p) = _one(address(timelock), abi.encodeCall(TimelockController.updateDelay, (0)));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 0));
        gate.execute(t, p, 0, SALT);
    }

    function test_refusesEveryOtherFunctionOnAListedLog() public {
        address attacker = makeAddr("attacker");
        bytes32 salt = keccak256("padded");
        bytes[3] memory calls = [
            abi.encodeCall(DecisionLog.transferOwnership, (attacker)),
            abi.encodeCall(DecisionLog.setBrain, (attacker)),
            abi.encodeCall(DecisionLog.setAttestation, (IDcapAttestation(attacker)))
        ];
        for (uint256 i; i < calls.length; i++) {
            (address[] memory t, bytes[] memory p) = _one(address(logA), calls[i]);
            vm.prank(operator);
            vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 0));
            gate.execute(t, p, 0, SALT);

            p[0] = abi.encodePacked(calls[i], bytes32(0));
            assertEq(p[0].length, 68);
            _scheduleArmed(t, p, 0, salt);
            skip(DELAY);
            vm.prank(operator);
            vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 0));
            gate.execute(t, p, 0, salt);
        }
        assertEq(logA.pendingOwner(), address(0));
        assertEq(logA.brain(), makeAddr("brain"));
    }

    function testFuzz_onlyTheTwoAllowSelectorsPass(bytes4 selector, bytes32 a, bytes32 b) public {
        vm.assume(selector != DecisionLog.allowApp.selector && selector != DecisionLog.allowImage.selector);
        (address[] memory t, bytes[] memory p) = _one(address(logB), abi.encodePacked(selector, a, b));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 0));
        gate.execute(t, p, 0, SALT);
    }

    function test_refusesAPayloadOfTheWrongLength() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        p[2] = abi.encodePacked(p[2], bytes32(0));
        _forbidden(t, p, abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 2));
        assertTrue(logA.allowedApp(OLD_APP));

        p[2] = abi.encodePacked(DecisionLog.allowApp.selector);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 2));
        gate.execute(t, p, 0, SALT);
    }

    function test_refusesAnEmptyOrMismatchedBatch() public {
        vm.prank(safe);
        timelock.scheduleBatch(new address[](0), new uint256[](0), new bytes[](0), 0, SALT, DELAY);
        _arm(timelock.hashOperationBatch(new address[](0), new uint256[](0), new bytes[](0), 0, SALT));
        skip(DELAY);
        vm.startPrank(operator);
        vm.expectRevert(SwitchGate.BadBatch.selector);
        gate.execute(new address[](0), new bytes[](0), 0, SALT);

        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        vm.expectRevert(SwitchGate.BadBatch.selector);
        gate.execute(t, new bytes[](5), 0, SALT);
        vm.expectRevert(SwitchGate.BadBatch.selector);
        gate.execute(new address[](5), p, 0, SALT);
        vm.stopPrank();
    }

    function testFuzz_onlyTheOperatorAndTheSafeExecute(address caller) public {
        vm.assume(caller != operator && caller != safe);
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        bytes32 id = _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(caller);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationReady(id));
        assertTrue(gate.armed(id));
    }

    function test_aPausedGateExecutesNothing() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(guardian);
        gate.setPaused(true, "v17 does not boot");

        vm.prank(operator);
        vm.expectRevert(SwitchGate.IsPaused.selector);
        gate.execute(t, p, 0, SALT);
        vm.prank(safe);
        vm.expectRevert(SwitchGate.IsPaused.selector);
        gate.execute(t, p, 0, SALT);

        vm.prank(safe);
        gate.setPaused(false, "fixed");
        vm.prank(operator);
        gate.execute(t, p, 0, SALT);
        _assertReleased(APP, OLD_APP);
    }

    function test_theGuardianPausesButOnlyTheSafeUnpauses() public {
        vm.expectEmit(true, true, false, true, address(gate));
        emit SwitchGate.Paused(true, guardian, "v17 does not boot");
        vm.prank(guardian);
        gate.setPaused(true, "v17 does not boot");
        assertTrue(gate.paused());

        vm.prank(guardian);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.setPaused(false, "");
        vm.prank(operator);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.setPaused(false, "");

        vm.prank(safe);
        gate.setPaused(false, "reviewed");
        assertFalse(gate.paused());
        vm.prank(safe);
        gate.setPaused(true, "");
        assertTrue(gate.paused());
    }

    function test_strangersAndTheOperatorCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.setPaused(true, "");
        vm.prank(operator);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.setPaused(true, "");
        assertFalse(gate.paused());
    }

    function test_onlyTheSafeChangesTheGate() public {
        address[3] memory others = [operator, guardian, stranger];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setOperator(others[i]);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setGuardian(others[i]);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setLog(others[i], true);
            vm.expectRevert(SwitchGate.NotSafe.selector);
            gate.setLog(address(logA), false);
            vm.stopPrank();
        }
        assertEq(gate.operator(), operator);
        assertEq(gate.guardian(), guardian);
        assertTrue(gate.isLog(address(logA)));
        assertFalse(gate.isLog(stranger));
    }

    function test_aReplacedOperatorLosesItsRightAtOnce() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        address next = makeAddr("next operator");
        vm.expectEmit(true, false, false, false, address(gate));
        emit SwitchGate.OperatorSet(next);
        vm.prank(safe);
        gate.setOperator(next);

        vm.prank(operator);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.execute(t, p, 0, SALT);
        vm.prank(next);
        gate.execute(t, p, 0, SALT);
        _assertReleased(APP, OLD_APP);
    }

    function test_aReplacedGuardianCannotPause() public {
        address next = makeAddr("next guardian");
        vm.prank(safe);
        gate.setGuardian(next);
        vm.prank(guardian);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.setPaused(true, "");
        vm.prank(next);
        gate.setPaused(true, "");
        assertTrue(gate.paused());
    }

    function test_aDelistedLogIsRefusedAndANewlyListedOneAccepted() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        _scheduleArmed(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(safe);
        gate.setLog(address(logB), false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 3));
        gate.execute(t, p, 0, SALT);

        DecisionLog other = new DecisionLog(address(timelock), makeAddr("brain"));
        (address[] memory t2, bytes[] memory p2) =
            _one(address(other), abi.encodeCall(DecisionLog.allowApp, (APP, true)));
        _scheduleArmed(t2, p2, 0, SALT);
        skip(DELAY);
        vm.prank(safe);
        gate.setLog(address(other), true);
        vm.prank(operator);
        gate.execute(t2, p2, 0, SALT);
        assertTrue(other.allowedApp(APP));

        vm.prank(safe);
        vm.expectRevert(SwitchGate.ZeroAddress.selector);
        gate.setLog(address(0), true);
    }

    function test_listingRefusesWhatTheTimelockDoesNotOwn() public {
        address undeployed = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 100);
        address eoa = makeAddr("an eoa");
        vm.deal(eoa, 1 ether);
        address foreign = address(new DecisionLog(stranger, makeAddr("brain")));
        DecisionLog handingOver = new DecisionLog(stranger, makeAddr("brain"));
        vm.prank(stranger);
        handingOver.transferOwnership(address(timelock));
        address[4] memory bad = [undeployed, eoa, foreign, address(handingOver)];

        address[] memory logs = new address[](2);
        logs[0] = address(logA);
        ISwitchTimelock tl = ISwitchTimelock(address(timelock));
        for (uint256 i; i < bad.length; i++) {
            logs[1] = bad[i];
            vm.expectRevert(_notOwned(bad[i]));
            new SwitchGate(safe, tl, operator, guardian, logs);

            vm.prank(safe);
            vm.expectRevert(_notOwned(bad[i]));
            gate.setLog(bad[i], true);
            assertFalse(gate.isLog(bad[i]));
        }

        logs[1] = address(timelock);
        vm.expectRevert();
        new SwitchGate(safe, tl, operator, guardian, logs);
        vm.prank(safe);
        vm.expectRevert();
        gate.setLog(address(timelock), true);
    }

    function test_delistingNeedsNoOwnershipCheck() public {
        address foreign = address(new DecisionLog(stranger, makeAddr("brain")));
        address[4] memory anything = [makeAddr("an eoa"), foreign, address(timelock), address(0)];
        for (uint256 i; i < anything.length; i++) {
            vm.expectEmit(true, false, false, true, address(gate));
            emit SwitchGate.LogSet(anything[i], false);
            vm.prank(safe);
            gate.setLog(anything[i], false);
            assertFalse(gate.isLog(anything[i]));
        }

        vm.prank(address(timelock));
        logA.transferOwnership(stranger);
        vm.prank(stranger);
        logA.acceptOwnership();
        vm.prank(safe);
        gate.setLog(address(logA), false);
        assertFalse(gate.isLog(address(logA)));
    }

    function test_theGateCanOnlyExecuteOnTheTimelock() public {
        (address[] memory t, bytes[] memory p) = _release(APP, OLD_APP);
        uint256[] memory v = new uint256[](t.length);
        bytes32 id = _schedule(t, p, 0, SALT);

        vm.startPrank(address(gate));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(gate), PROPOSER_ROLE
            )
        );
        timelock.scheduleBatch(t, v, p, 0, keccak256("the gate's own"), DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(gate), CANCELLER_ROLE
            )
        );
        timelock.cancel(id);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(gate), bytes32(0))
        );
        timelock.grantRole(PROPOSER_ROLE, address(gate));
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, address(gate)));
        timelock.updateDelay(0);
        vm.stopPrank();
    }

    function test_aListedTargetCannotReenterTheGate() public {
        (address[] memory inner, bytes[] memory innerCalls) = _release(APP, OLD_APP);
        bytes32 innerId = _scheduleArmed(inner, innerCalls, 0, SALT);

        ReenteringLog hostile = new ReenteringLog(address(timelock), address(gate));
        hostile.arm(abi.encodeCall(SwitchGate.execute, (inner, innerCalls, 0, SALT)));
        vm.prank(safe);
        gate.setLog(address(hostile), true);
        (address[] memory t, bytes[] memory p) =
            _one(address(hostile), abi.encodeCall(DecisionLog.allowApp, (APP, true)));
        bytes32 outer = keccak256("outer");
        bytes32 outerId = _scheduleArmed(t, p, 0, outer);
        skip(DELAY);

        vm.prank(operator);
        vm.expectRevert(SwitchGate.NotAllowed.selector);
        gate.execute(t, p, 0, outer);
        assertTrue(timelock.isOperationReady(innerId));
        assertTrue(timelock.isOperationReady(outerId));
        assertTrue(gate.armed(innerId));
        assertTrue(gate.armed(outerId));
    }

    function test_theConstructorRefusesZeroAddresses() public {
        address[] memory logs = new address[](2);
        logs[0] = address(logA);
        ISwitchTimelock tl = ISwitchTimelock(address(timelock));

        vm.expectRevert(SwitchGate.ZeroAddress.selector);
        new SwitchGate(safe, tl, operator, guardian, logs);
        logs[1] = address(logB);
        vm.expectRevert(SwitchGate.ZeroAddress.selector);
        new SwitchGate(address(0), tl, operator, guardian, logs);
        vm.expectRevert(SwitchGate.ZeroAddress.selector);
        new SwitchGate(safe, ISwitchTimelock(address(0)), operator, guardian, logs);

        SwitchGate idle = new SwitchGate(safe, tl, address(0), address(0), logs);
        assertEq(idle.operator(), address(0));
        assertEq(idle.guardian(), address(0));
        assertTrue(idle.isLog(address(logB)));
    }
}
