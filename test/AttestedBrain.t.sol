// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";

/// Returns whatever output the test sets, as Automata's entrypoint would after verifying a quote.
contract MockAttestation is IDcapAttestation {
    bool public ok = true;
    bytes public output;

    function set(bool ok_, bytes memory output_) external {
        ok = ok_;
        output = output_;
    }

    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) {
        return (ok, output);
    }
}

contract AttestedBrainTest is Test {
    DecisionLog internal decisions;
    MockAttestation internal verifier;
    address internal owner = makeAddr("owner");
    address internal enclaveKey = makeAddr("enclave");

    bytes internal mrtd = _fill(48, 0x11);
    bytes internal rtmrs = _fill(144, 0x22);
    bytes internal rtmr3 = _fill(48, 0x33);

    function setUp() public {
        decisions = new DecisionLog(owner, makeAddr("brain"));
        verifier = new MockAttestation();
        vm.startPrank(owner);
        decisions.setAttestation(verifier);
        decisions.allowImage(keccak256(abi.encodePacked(mrtd, rtmrs)), true);
        decisions.allowApp(keccak256(rtmr3), true);
        vm.stopPrank();
    }

    function _fill(uint256 length, bytes1 value) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = value;
        }
    }

    /// The verifier's output: 11-byte header with the TCB status at byte 4, then the TD report body.
    function _output(uint8 tcb, bytes memory rtmr3_, bytes32 nonce, address key) internal view returns (bytes memory) {
        bytes memory header = new bytes(11);
        header[4] = bytes1(tcb);
        bytes memory beforeMrtd = new bytes(136);
        bytes memory between = new bytes(0);
        return abi.encodePacked(
            header, beforeMrtd, mrtd, _fill(144, 0x00), rtmrs, rtmr3_, nonce, bytes32(uint256(uint160(key))), between
        );
    }

    function test_anAttestedEnclaveNamesItsKey() public {
        verifier.set(true, _output(0, rtmr3, decisions.attestationNonce(), enclaveKey));
        address named = decisions.attestBrain(hex"00");
        assertEq(named, enclaveKey);
        assertEq(decisions.brain(), enclaveKey);
        assertEq(decisions.attestations(), 1);
    }

    function test_softwareHardeningNeededIsAcceptedOutOfDateIsNot() public {
        verifier.set(true, _output(1, rtmr3, decisions.attestationNonce(), enclaveKey));
        decisions.attestBrain(hex"00");
        verifier.set(true, _output(4, rtmr3, decisions.attestationNonce(), enclaveKey));
        vm.expectRevert(abi.encodeWithSelector(DecisionLog.TcbNotAccepted.selector, uint8(4)));
        decisions.attestBrain(hex"00");
    }

    function test_anAppOffTheAllowlistCannotNameAKey() public {
        bytes memory other = _fill(48, 0x44);
        verifier.set(true, _output(0, other, decisions.attestationNonce(), enclaveKey));
        vm.expectRevert(abi.encodeWithSelector(DecisionLog.AppNotAllowed.selector, keccak256(other)));
        decisions.attestBrain(hex"00");
    }

    function test_anOldQuoteCannotBeReplayed() public {
        bytes memory first = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        verifier.set(true, first);
        decisions.attestBrain(hex"00");
        // The same quote again, or any quote made for the spent nonce, names nothing.
        vm.expectRevert(DecisionLog.StaleQuote.selector);
        decisions.attestBrain(hex"00");
        verifier.set(true, _output(0, rtmr3, bytes32(0), makeAddr("attacker")));
        vm.expectRevert(DecisionLog.StaleQuote.selector);
        decisions.attestBrain(hex"00");
    }

    function test_aRejectedOrShortQuoteNamesNothing() public {
        verifier.set(false, _output(0, rtmr3, decisions.attestationNonce(), enclaveKey));
        vm.expectRevert(DecisionLog.QuoteRejected.selector);
        decisions.attestBrain(hex"00");
        verifier.set(true, hex"0102");
        vm.expectRevert(DecisionLog.QuoteRejected.selector);
        decisions.attestBrain(hex"00");
    }

    function test_withoutAVerifierOnlyTheOwnerSetsTheBrain() public {
        DecisionLog bare = new DecisionLog(owner, makeAddr("brain"));
        vm.expectRevert(DecisionLog.NoAttestation.selector);
        bare.attestBrain(hex"00");
        vm.expectRevert(DecisionLog.NotOwner.selector);
        bare.setAttestation(verifier);
        vm.expectRevert(DecisionLog.NotOwner.selector);
        bare.allowApp(keccak256(rtmr3), true);
    }
}
