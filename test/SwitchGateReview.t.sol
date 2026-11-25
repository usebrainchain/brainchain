// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";
import {SwitchGate, ISwitchTimelock} from "../src/SwitchGate.sol";

// A wrong, timelock-owned target whose fallback has unrelated effects.
contract ReviewTreasury {
    address public immutable owner;
    address payable public immutable recipient;

    constructor(address owner_, address payable recipient_) {
        owner = owner_;
        recipient = recipient_;
    }

    fallback() external {
        require(msg.sender == owner);
        (bool ok,) = recipient.call{value: address(this).balance}("");
        require(ok);
    }
}

contract ReviewCallbackLog {
    address public immutable owner;
    SwitchGate public immutable gate;
    address[] private targets;
    bytes[] private calls;
    uint256 public successes;
    bytes32 public observedSlot;

    constructor(address owner_, SwitchGate gate_) {
        owner = owner_;
        gate = gate_;
    }

    function configure(address[] memory targets_, bytes[] memory calls_) external {
        targets = targets_;
        calls = calls_;
    }

    function allowApp(bytes32, bool) external {
        require(msg.sender == owner);
        observedSlot = gate.armed();
        for (uint256 i; i < targets.length; ++i) {
            (bool ok,) = targets[i].call(calls[i]);
            if (ok) ++successes;
        }
    }
}

abstract contract SwitchGateReviewFixture is Test {
    uint256 internal constant DELAY = 48 hours;
    bytes32 internal constant SALT = keccak256("independent review");
    address internal constant SAFE = address(0xA11CE);
    address internal constant OPERATOR = address(0xB0B);
    address internal constant GUARDIAN = address(0xCA11);
    address internal constant BRAIN = address(0xB123);

    TimelockController internal timelock;
    DecisionLog internal logA;
    DecisionLog internal logB;
    SwitchGate internal gate;

    function setUp() public virtual {
        vm.warp(1_000_000);
        address[] memory seats = new address[](1);
        seats[0] = SAFE;
        timelock = new TimelockController(DELAY, seats, seats, address(0));
        logA = new DecisionLog(address(timelock), BRAIN);
        logB = new DecisionLog(address(timelock), BRAIN);
        address[] memory logs = new address[](2);
        (logs[0], logs[1]) = (address(logA), address(logB));
        gate = new SwitchGate(SAFE, ISwitchTimelock(address(timelock)), OPERATOR, GUARDIAN, logs);
        bytes32 role = timelock.EXECUTOR_ROLE();
        vm.prank(address(timelock));
        timelock.grantRole(role, address(gate));
        vm.deal(address(timelock), 7 ether);
        vm.deal(address(gate), 3 ether);
    }

    function one(address target, bytes memory payload) internal pure returns (address[] memory t, bytes[] memory p) {
        t = new address[](1);
        p = new bytes[](1);
        t[0] = target;
        p[0] = payload;
    }

    function release(bytes32 key) internal view returns (address[] memory t, bytes[] memory p) {
        return one(address(logA), abi.encodeCall(DecisionLog.allowApp, (key, true)));
    }

    function schedule(address[] memory t, bytes[] memory p, bytes32 predecessor, bytes32 salt)
        internal
        returns (bytes32 id)
    {
        uint256[] memory values = new uint256[](t.length);
        id = keccak256(abi.encode(t, values, p, predecessor, salt));
        assertEq(id, timelock.hashOperationBatch(t, values, p, predecessor, salt));
        vm.prank(SAFE);
        timelock.scheduleBatch(t, values, p, predecessor, salt, DELAY);
    }

    function arm(bytes32 id) internal {
        vm.prank(SAFE);
        gate.arm(id);
    }

    function ready(address[] memory t, bytes[] memory p) internal returns (bytes32 id) {
        id = schedule(t, p, 0, SALT);
        arm(id);
        skip(DELAY);
    }

    function assertControls() internal view {
        assertEq(gate.safe(), SAFE);
        assertEq(gate.operator(), OPERATOR);
        assertEq(gate.guardian(), GUARDIAN);
        assertTrue(gate.isLog(address(logA)) && gate.isLog(address(logB)));
        assertEq(logA.owner(), address(timelock));
        assertEq(logA.pendingOwner(), address(0));
        assertEq(logA.brain(), BRAIN);
        assertEq(address(logA.attestation()), address(0));
        assertEq(logA.tcbEvaluationNumber(), 0);
        assertEq(logA.count(), 0);
        assertEq(timelock.getMinDelay(), DELAY);
        assertEq(address(timelock).balance, 7 ether);
        assertEq(address(gate).balance, 3 ether);
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(gate)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(gate)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(gate)));
        assertFalse(timelock.hasRole(bytes32(0), address(gate)));
    }
}

contract SwitchGateReviewTest is SwitchGateReviewFixture {
    function testFuzz_exactBatchOnlyChangesAllowLists(bytes32 seed, uint8 size) public {
        uint256 count = bound(size, 1, 12);
        address[] memory t = new address[](count);
        bytes[] memory p = new bytes[](count);
        bool[] memory expectedApp = new bool[](2);
        bool[] memory expectedImage = new bool[](2);
        for (uint256 i; i < count; ++i) {
            uint256 bits = uint256(keccak256(abi.encode(seed, i)));
            uint256 logIndex = bits % 2;
            bool image = bits & 2 != 0;
            bool allowed = bits & 4 != 0;
            t[i] = logIndex == 0 ? address(logA) : address(logB);
            p[i] = abi.encodeWithSelector(
                image ? DecisionLog.allowImage.selector : DecisionLog.allowApp.selector, seed, allowed
            );
            if (image) expectedImage[logIndex] = allowed;
            else expectedApp[logIndex] = allowed;
        }
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationDone(id));
        assertEq(gate.armed(), bytes32(0));
        assertEq(logA.allowedApp(seed), expectedApp[0]);
        assertEq(logB.allowedApp(seed), expectedApp[1]);
        assertEq(logA.allowedImage(seed), expectedImage[0]);
        assertEq(logB.allowedImage(seed), expectedImage[1]);
        assertControls();
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, id));
        gate.execute(t, p, 0, SALT);
    }

    function testFuzz_hashBindsEveryBatchField(bytes32 key, uint8 field) public {
        (address[] memory t, bytes[] memory p) = release(key);
        bytes32 id = ready(t, p);
        bytes32 predecessor;
        bytes32 salt = SALT;
        uint256 choice = field % 5;
        if (choice == 0) t[0] = address(logB);
        if (choice == 1) p[0] = abi.encodeCall(DecisionLog.allowImage, (key, true));
        if (choice == 2) p[0] = abi.encodeCall(DecisionLog.allowApp, (key, false));
        if (choice == 3) predecessor = bytes32(uint256(1));
        if (choice == 4) salt = bytes32(uint256(SALT) ^ 1);
        bytes32 changed = keccak256(abi.encode(t, new uint256[](1), p, predecessor, salt));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, changed));
        gate.execute(t, p, predecessor, salt);
        assertEq(gate.armed(), id);
        assertTrue(timelock.isOperationReady(id));
        assertFalse(logA.allowedApp(key));
        assertFalse(logB.allowedApp(key));
    }

    function testFuzz_arrayLengthsMustAgree(uint8 targets, uint8 payloads) public {
        uint256 n = targets % 16;
        uint256 m = payloads % 16;
        vm.assume(n == 0 || n != m);
        vm.prank(OPERATOR);
        vm.expectRevert(SwitchGate.BadBatch.selector);
        gate.execute(new address[](n), new bytes[](m), 0, SALT);
        assertControls();
    }

    function testFuzz_payloadLengthMustBeExact(uint8 length) public {
        vm.assume(length != 68);
        (address[] memory t, bytes[] memory p) = one(address(logA), new bytes(length));
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 0));
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), id);
    }

    function testFuzz_otherSelectorsNeverReachTheTimelock(bytes4 selector, bytes32 word) public {
        vm.assume(selector != DecisionLog.allowApp.selector && selector != DecisionLog.allowImage.selector);
        (address[] memory t, bytes[] memory p) = one(address(logA), abi.encodePacked(selector, word, uint256(1)));
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenCall.selector, 0));
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), id);
        assertControls();
    }

    function testFuzz_badBoolRollsBackEarlierCallsAndSlot(uint256 badBool, bytes32 key) public {
        vm.assume(badBool > 1);
        address[] memory t = new address[](2);
        bytes[] memory p = new bytes[](2);
        (t[0], t[1]) = (address(logA), address(logB));
        p[0] = abi.encodeCall(DecisionLog.allowApp, (key, true));
        p[1] = abi.encodePacked(DecisionLog.allowImage.selector, key, badBool);
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        vm.expectRevert(Address.FailedInnerCall.selector);
        gate.execute(t, p, 0, SALT);
        assertFalse(logA.allowedApp(key));
        assertFalse(logB.allowedImage(key));
        assertEq(gate.armed(), id);
        assertTrue(timelock.isOperationReady(id));
    }

    function testFuzz_nonzeroScheduledValueCannotSpendTimelockFunds(uint96 value) public {
        vm.assume(value != 0);
        (address[] memory t, bytes[] memory p) = release(SALT);
        uint256[] memory values = new uint256[](1);
        values[0] = value;
        vm.prank(SAFE);
        timelock.scheduleBatch(t, values, p, 0, SALT, DELAY);
        bytes32 id = timelock.hashOperationBatch(t, values, p, 0, SALT);
        arm(id);
        skip(DELAY);
        bytes32 zeroValueId = keccak256(abi.encode(t, new uint256[](1), p, bytes32(0), SALT));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, zeroValueId));
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), id);
        assertControls();
    }

    function testFuzz_attachedEtherIsRejected(uint96 value) public {
        vm.assume(value != 0);
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        vm.deal(OPERATOR, value);
        vm.prank(OPERATOR);
        (bool ok,) = address(gate).call{value: value}(abi.encodeCall(SwitchGate.execute, (t, p, 0, SALT)));
        assertFalse(ok);
        assertEq(gate.armed(), id);
        assertControls();
    }

    function test_outerAbiAliasesDoNotChangeTheHashedBatch() public {
        address[] memory t = new address[](2);
        bytes[] memory p = new bytes[](2);
        (t[0], t[1]) = (address(logA), address(logB));
        p[0] = abi.encodeCall(DecisionLog.allowApp, (SALT, true));
        p[1] = p[0];
        bytes32 id = ready(t, p);
        bytes memory encoded = abi.encodeCall(SwitchGate.execute, (t, p, 0, SALT));
        // Both bytes[] entries point at one payload. Hashing must use decoded values.
        assembly {
            let args := add(encoded, 36)
            let array := add(args, mload(add(args, 32)))
            mstore(add(array, 64), mload(add(array, 32)))
        }
        vm.prank(OPERATOR);
        (bool ok,) = address(gate).call(bytes.concat(encoded, hex"deadbeef"));
        assertTrue(ok);
        assertTrue(timelock.isOperationDone(id));
        assertTrue(logA.allowedApp(SALT) && logB.allowedApp(SALT));
    }

    function test_outerAbiOutOfBoundsOffsetRevertsWithoutEffects() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        bytes memory encoded = abi.encodeCall(SwitchGate.execute, (t, p, 0, SALT));
        assembly {
            mstore(add(encoded, 68), not(0))
        }
        vm.prank(OPERATOR);
        (bool ok,) = address(gate).call(encoded);
        assertFalse(ok);
        assertEq(gate.armed(), id);
        assertFalse(logA.allowedApp(SALT));
    }

    function test_pendingSingleCallIdCannotAuthorizeABatch() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        vm.prank(SAFE);
        timelock.schedule(t[0], 0, p[0], 0, SALT, DELAY);
        bytes32 id = timelock.hashOperation(t[0], 0, p[0], 0, SALT);
        arm(id);
        skip(DELAY);
        bytes32 batchId = keccak256(abi.encode(t, new uint256[](1), p, bytes32(0), SALT));
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, batchId));
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), id);
    }

    function test_wrongPendingAdminIdIsAcceptedButCannotExecute() public {
        (address[] memory t, bytes[] memory p) =
            one(address(timelock), abi.encodeCall(TimelockController.updateDelay, (0)));
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.ForbiddenTarget.selector, 0));
        gate.execute(t, p, 0, SALT);
        assertTrue(timelock.isOperationReady(id));
        assertEq(gate.armed(), id);
        assertControls();
    }

    function testFuzz_unknownIdCannotReplaceAnExistingArm(bytes32 wrong) public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        vm.assume(wrong != 0 && wrong != id);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotPending.selector, wrong));
        gate.arm(wrong);
        assertEq(gate.armed(), id);
    }

    // These reproductions assert the unsafe behavior, so a passing suite is not a sign-off.
    function testFuzz_cancelRescheduleRevivesOldAuthorization(uint32 elapsed) public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = schedule(t, p, 0, SALT);
        arm(id);
        skip(bound(elapsed, 1, 30 days));
        vm.prank(SAFE);
        timelock.cancel(id);
        assertEq(gate.armed(), id);
        vm.prank(OPERATOR);
        vm.expectRevert();
        gate.execute(t, p, 0, SALT);
        assertEq(schedule(t, p, 0, SALT), id);
        skip(DELAY - 1);
        vm.prank(OPERATOR);
        vm.expectRevert();
        gate.execute(t, p, 0, SALT);
        skip(1);
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        assertTrue(logA.allowedApp(SALT));
        assertTrue(timelock.isOperationDone(id));
    }

    function test_sameBlockRescheduleAlsoPreservesReadyTimestamp() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = schedule(t, p, 0, SALT);
        arm(id);
        uint256 timestamp = timelock.getTimestamp(id);
        vm.prank(SAFE);
        timelock.cancel(id);
        schedule(t, p, 0, SALT);
        assertEq(timelock.getTimestamp(id), timestamp);
        assertEq(gate.armed(), id);
        vm.warp(timestamp);
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        assertTrue(logA.allowedApp(SALT));
    }

    function test_disarmingBeforeCancelPreventsRevival() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = schedule(t, p, 0, SALT);
        arm(id);
        arm(0);
        vm.prank(SAFE);
        timelock.cancel(id);
        schedule(t, p, 0, SALT);
        skip(DELAY);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotArmed.selector, id));
        gate.execute(t, p, 0, SALT);
        assertFalse(logA.allowedApp(SALT));
    }

    function test_wrongOwnedLogExecutesUnrelatedTreasuryTransfer() public {
        ReviewTreasury wrong = new ReviewTreasury(address(timelock), payable(OPERATOR));
        vm.deal(address(wrong), 5 ether);
        vm.prank(SAFE);
        gate.setLog(address(wrong), true);
        (address[] memory t, bytes[] memory p) = one(address(wrong), abi.encodeCall(DecisionLog.allowApp, (SALT, true)));
        bytes32 id = ready(t, p);
        uint256 before = OPERATOR.balance;
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        assertEq(OPERATOR.balance - before, 5 ether);
        assertEq(address(wrong).balance, 0);
        assertTrue(timelock.isOperationDone(id));
        assertFalse(logA.allowedApp(SALT));
        assertControls();
    }

    function testFuzz_listingRejectsEOAsAndWrongOwners(address wrongOwner) public {
        vm.assume(wrongOwner != address(0) && wrongOwner != address(timelock));
        address eoa = address(0xEEEE);
        DecisionLog wrong = new DecisionLog(wrongOwner, BRAIN);
        vm.startPrank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotTimelockOwned.selector, eoa));
        gate.setLog(eoa, true);
        vm.expectRevert(abi.encodeWithSelector(SwitchGate.NotTimelockOwned.selector, address(wrong)));
        gate.setLog(address(wrong), true);
        vm.stopPrank();
        assertFalse(gate.isLog(eoa));
        assertFalse(gate.isLog(address(wrong)));
    }

    function test_ownershipChangeRollsBackWholeBatch() public {
        address[] memory t = new address[](2);
        bytes[] memory p = new bytes[](2);
        (t[0], t[1]) = (address(logA), address(logB));
        p[0] = abi.encodeCall(DecisionLog.allowApp, (SALT, true));
        p[1] = p[0];
        bytes32 id = ready(t, p);
        vm.prank(address(timelock));
        logB.transferOwnership(OPERATOR);
        vm.prank(OPERATOR);
        logB.acceptOwnership();
        vm.prank(OPERATOR);
        vm.expectRevert(DecisionLog.NotOwner.selector);
        gate.execute(t, p, 0, SALT);
        assertFalse(logA.allowedApp(SALT));
        assertFalse(logB.allowedApp(SALT));
        assertEq(gate.armed(), id);
    }

    function testFuzz_guardianCanOnlyPause(bool pauseFirst, uint8 action) public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        if (pauseFirst) {
            vm.prank(GUARDIAN);
            gate.setPaused(true, "hold");
        }
        bytes[7] memory calls = [
            abi.encodeCall(SwitchGate.arm, (bytes32(0))),
            abi.encodeCall(SwitchGate.setOperator, (GUARDIAN)),
            abi.encodeCall(SwitchGate.setGuardian, (GUARDIAN)),
            abi.encodeCall(SwitchGate.setLog, (address(logA), false)),
            abi.encodeCall(SwitchGate.setPaused, (false, "resume")),
            abi.encodeCall(SwitchGate.execute, (t, p, 0, SALT)),
            abi.encodeCall(SwitchGate.arm, (id))
        ];
        vm.prank(GUARDIAN);
        (bool ok,) = address(gate).call(calls[action % calls.length]);
        assertFalse(ok);
        assertEq(gate.paused(), pauseFirst);
        assertEq(gate.armed(), id);
        vm.prank(GUARDIAN);
        gate.setPaused(true, "hold again");
        assertTrue(gate.paused());
        assertControls();
    }

    function test_operatorAndGuardianCannotMutateTimelockOrLogDirectly() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        bytes[8] memory calls = [
            abi.encodeCall(TimelockController.scheduleBatch, (t, new uint256[](1), p, 0, bytes32(0), DELAY)),
            abi.encodeCall(TimelockController.cancel, (id)),
            abi.encodeCall(IAccessControl.grantRole, (timelock.PROPOSER_ROLE(), OPERATOR)),
            abi.encodeCall(IAccessControl.revokeRole, (timelock.EXECUTOR_ROLE(), address(gate))),
            abi.encodeCall(IAccessControl.renounceRole, (timelock.EXECUTOR_ROLE(), address(gate))),
            abi.encodeCall(TimelockController.updateDelay, (0)),
            abi.encodeCall(TimelockController.executeBatch, (t, new uint256[](1), p, 0, SALT)),
            abi.encodeCall(TimelockController.execute, (t[0], 0, p[0], bytes32(0), SALT))
        ];
        for (uint256 actor; actor < 2; ++actor) {
            for (uint256 i; i < calls.length; ++i) {
                vm.prank(actor == 0 ? OPERATOR : GUARDIAN);
                (bool ok,) = address(timelock).call(calls[i]);
                assertFalse(ok);
            }
            vm.prank(actor == 0 ? OPERATOR : GUARDIAN);
            vm.expectRevert(DecisionLog.NotOwner.selector);
            logA.allowApp(SALT, true);
        }
        assertEq(gate.armed(), id);
        assertControls();
    }

    function test_callbacksCannotUseTheGateOrTimelockAuthority() public {
        (address[] memory inner, bytes[] memory payloads) = release(SALT);
        bytes32 innerId = schedule(inner, payloads, 0, bytes32(0));
        ReviewCallbackLog callback = new ReviewCallbackLog(address(timelock), gate);
        address[] memory callsTo = new address[](9);
        bytes[] memory calls = new bytes[](9);
        for (uint256 i; i < 6; ++i) {
            callsTo[i] = address(gate);
        }
        calls[0] = abi.encodeCall(SwitchGate.arm, (innerId));
        calls[1] = abi.encodeCall(SwitchGate.execute, (inner, payloads, 0, bytes32(0)));
        calls[2] = abi.encodeCall(SwitchGate.setOperator, (address(callback)));
        calls[3] = abi.encodeCall(SwitchGate.setGuardian, (address(callback)));
        calls[4] = abi.encodeCall(SwitchGate.setLog, (address(logA), false));
        calls[5] = abi.encodeCall(SwitchGate.setPaused, (true, "callback"));
        callsTo[6] = address(timelock);
        calls[6] = abi.encodeCall(TimelockController.executeBatch, (inner, new uint256[](1), payloads, 0, bytes32(0)));
        callsTo[7] = address(timelock);
        calls[7] = abi.encodeCall(IAccessControl.grantRole, (timelock.EXECUTOR_ROLE(), address(callback)));
        callsTo[8] = address(logA);
        calls[8] = abi.encodeCall(DecisionLog.setBrain, (address(callback)));
        callback.configure(callsTo, calls);
        vm.prank(SAFE);
        gate.setLog(address(callback), true);
        (address[] memory t, bytes[] memory p) =
            one(address(callback), abi.encodeCall(ReviewCallbackLog.allowApp, (SALT, true)));
        bytes32 id = ready(t, p);
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        assertEq(callback.observedSlot(), bytes32(0));
        assertEq(callback.successes(), 0);
        assertTrue(timelock.isOperationDone(id));
        assertTrue(timelock.isOperationReady(innerId));
        assertFalse(logA.allowedApp(SALT));
        assertControls();
    }

    function test_predecessorMustBeDoneNotMerelyReady() public {
        (address[] memory first, bytes[] memory firstCalls) = release(SALT);
        bytes32 predecessor = schedule(first, firstCalls, 0, bytes32(0));
        (address[] memory t, bytes[] memory p) = one(address(logB), firstCalls[0]);
        bytes32 id = schedule(t, p, predecessor, SALT);
        arm(id);
        skip(DELAY);
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, predecessor));
        gate.execute(t, p, predecessor, SALT);
        assertEq(gate.armed(), id);
        vm.prank(SAFE);
        timelock.executeBatch(first, new uint256[](1), firstCalls, 0, bytes32(0));
        vm.prank(OPERATOR);
        gate.execute(t, p, predecessor, SALT);
        assertTrue(timelock.isOperationDone(id));
    }

    function test_pauseBeforeExecuteBlocksButPauseAfterCannotUndo() public {
        (address[] memory t, bytes[] memory p) = release(SALT);
        bytes32 id = ready(t, p);
        vm.prank(GUARDIAN);
        gate.setPaused(true, "hold");
        vm.prank(OPERATOR);
        vm.expectRevert(SwitchGate.IsPaused.selector);
        gate.execute(t, p, 0, SALT);
        assertEq(gate.armed(), id);
        vm.prank(SAFE);
        gate.setPaused(false, "resume");
        vm.prank(OPERATOR);
        gate.execute(t, p, 0, SALT);
        vm.prank(GUARDIAN);
        gate.setPaused(true, "too late");
        assertTrue(logA.allowedApp(SALT));
        assertTrue(timelock.isOperationDone(id));
    }

    function test_operatorAndGuardianCannotBecomeTheSameKey() public {
        vm.startPrank(SAFE);
        vm.expectRevert(SwitchGate.SameKey.selector);
        gate.setOperator(GUARDIAN);
        vm.expectRevert(SwitchGate.SameKey.selector);
        gate.setGuardian(OPERATOR);
        vm.stopPrank();
    }
}

contract SwitchGateReviewHandler is Test {
    uint256 private constant DELAY = 48 hours;
    SwitchGate public immutable gate;
    TimelockController public immutable timelock;
    DecisionLog public immutable decisionLog;
    address private immutable safe;
    address private immutable operator;
    address private immutable guardian;
    bytes32[8] public ids;
    bool[8] public expected;
    bytes32 public expectedSlot;
    bool public expectedPause;
    bool public violation;
    uint256 public executions;
    uint256 public attempts;

    constructor(SwitchGate gate_, TimelockController timelock_, DecisionLog log_) {
        gate = gate_;
        timelock = timelock_;
        decisionLog = log_;
        safe = gate_.safe();
        operator = gate_.operator();
        guardian = gate_.guardian();
        for (uint256 i; i < ids.length; ++i) {
            (address[] memory t, bytes[] memory p) = batch(i);
            ids[i] = keccak256(abi.encode(t, new uint256[](1), p, bytes32(0), bytes32(i)));
            vm.prank(safe);
            timelock_.scheduleBatch(t, new uint256[](1), p, 0, bytes32(i), DELAY);
        }
    }

    function batch(uint256 i) public view returns (address[] memory t, bytes[] memory p) {
        t = new address[](1);
        p = new bytes[](1);
        t[0] = address(decisionLog);
        p[0] = abi.encodeCall(DecisionLog.allowApp, (bytes32(i), true));
    }

    function safeArm(uint8 choice) external {
        uint256 i = choice % 9;
        bytes32 id = i == 8 ? bytes32(0) : ids[i];
        if (id != 0 && !timelock.isOperationPending(id)) return;
        vm.prank(safe);
        gate.arm(id);
        expectedSlot = id;
    }

    function advance(uint32 seconds_) external {
        skip(uint256(seconds_) % (3 days));
    }

    function pause(bool value) external {
        vm.prank(value ? guardian : safe);
        gate.setPaused(value, "invariant");
        expectedPause = value;
    }

    function cancel(uint8 choice, bool reschedule) external {
        uint256 i = choice % ids.length;
        if (!timelock.isOperationPending(ids[i])) return;
        vm.prank(safe);
        timelock.cancel(ids[i]);
        if (reschedule) {
            (address[] memory t, bytes[] memory p) = batch(i);
            vm.prank(safe);
            timelock.scheduleBatch(t, new uint256[](1), p, 0, bytes32(i), DELAY);
        }
    }

    function execute(uint8 choice, bool mutate) external {
        uint256 i = choice % ids.length;
        (address[] memory t, bytes[] memory p) = batch(i);
        if (mutate) p[0] = abi.encodeCall(DecisionLog.allowApp, (bytes32(i), false));
        bool permitted = !mutate && !expectedPause && expectedSlot == ids[i] && timelock.isOperationReady(ids[i]);
        ++attempts;
        vm.prank(operator);
        (bool ok,) = address(gate).call(abi.encodeCall(SwitchGate.execute, (t, p, 0, bytes32(i))));
        if (ok != permitted) violation = true;
        if (ok) {
            expected[i] = true;
            expectedSlot = 0;
            ++executions;
        }
    }

    function attackControls(uint8 action, bytes32 word) external {
        bytes[6] memory calls = [
            abi.encodeCall(SwitchGate.arm, (word)),
            abi.encodeCall(SwitchGate.setPaused, (true, "operator")),
            abi.encodeCall(SwitchGate.setPaused, (false, "operator")),
            abi.encodeCall(SwitchGate.setOperator, (address(uint160(uint256(word))))),
            abi.encodeCall(SwitchGate.setGuardian, (address(uint160(uint256(word))))),
            abi.encodeCall(SwitchGate.setLog, (address(decisionLog), false))
        ];
        vm.prank(operator);
        (bool ok,) = address(gate).call(calls[action % calls.length]);
        if (ok) violation = true;
    }

    function arbitraryCall(uint8 target, bytes calldata data) external {
        address to = target % 3 == 0 ? address(gate) : target % 3 == 1 ? address(timelock) : address(decisionLog);
        vm.prank(operator);
        (bool ok,) = to.call(data);
        // View calls can succeed; the invariant checks all persistent state below.
        if (ok && gate.armed() != expectedSlot) violation = true;
    }
}

contract SwitchGateReviewInvariantTest is SwitchGateReviewFixture {
    SwitchGateReviewHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SwitchGateReviewHandler(gate, timelock, logA);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.safeArm.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.pause.selector;
        selectors[3] = handler.cancel.selector;
        selectors[4] = handler.execute.selector;
        selectors[5] = handler.attackControls.selector;
        selectors[6] = handler.arbitraryCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // Trusted concrete DecisionLogs and distinct roles; cancellation generations have separate reproductions above.
    function invariant_operatorOnlyExecutesTheArmedReadyBatch() public view {
        assertFalse(handler.violation());
        assertEq(gate.armed(), handler.expectedSlot());
        assertEq(gate.paused(), handler.expectedPause());
        for (uint256 i; i < 8; ++i) {
            assertEq(logA.allowedApp(bytes32(i)), handler.expected(i));
            assertEq(timelock.isOperationDone(handler.ids(i)), handler.expected(i));
            assertFalse(logA.allowedImage(bytes32(i)));
            assertFalse(logB.allowedApp(bytes32(i)));
        }
        assertControls();
    }

    function test_handlerCanReachSuccessfulExecution() public {
        handler.safeArm(0);
        handler.advance(uint32(DELAY));
        handler.execute(0, false);
        assertEq(handler.executions(), 1);
        invariant_operatorOnlyExecutesTheArmedReadyBatch();
    }
}
