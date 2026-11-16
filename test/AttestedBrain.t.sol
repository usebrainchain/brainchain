// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";

/// Returns whatever output the test sets, as Automata's entrypoint would after verifying a quote.
contract MockAttestation is IDcapAttestation {
    bool public ok = true;
    bytes public output;

    function set(bool ok_, bytes memory output_) external {
        ok = ok_;
        output = output_;
    }

    uint32 public pinned;

    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) {
        pinned = 0;
        return (ok, output);
    }

    function verifyAndAttestOnChain(bytes calldata, uint32 number) external payable returns (bool, bytes memory) {
        pinned = number;
        return (ok, output);
    }
}

contract AttestedBrainTest is Test {
    using stdStorage for StdStorage;

    StdStorage internal store;
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

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory part) {
        part = new bytes(length);
        for (uint256 i; i < length; ++i) {
            part[i] = data[start + i];
        }
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
        header[1] = 0x04;
        header[3] = 0x02;
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

    function test_theOwnerCanPinTheTcbEvaluationNumber() public {
        vm.prank(owner);
        decisions.setTcbEvaluationNumber(20);
        verifier.set(true, _output(0, rtmr3, decisions.attestationNonce(), enclaveKey));
        decisions.attestBrain(hex"00");
        assertEq(verifier.pinned(), 20);
        vm.expectRevert(DecisionLog.NotOwner.selector);
        decisions.setTcbEvaluationNumber(21);
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

    function test_aQuoteThatIsNotTdxNamesNothing() public {
        bytes memory out = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        // An SGX quote: version 3, and an enclave report body (type 1) under version 4.
        out[1] = 0x03;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.NotATdQuote.selector);
        decisions.attestBrain(hex"00");
        out[1] = 0x04;
        out[3] = 0x01;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.NotATdQuote.selector);
        decisions.attestBrain(hex"00");
        // Both fields are big-endian, so a set high byte is another version or type.
        out[3] = 0x02;
        out[0] = 0x01;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.NotATdQuote.selector);
        decisions.attestBrain(hex"00");
        out[0] = 0x00;
        out[2] = 0x01;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.NotATdQuote.selector);
        decisions.attestBrain(hex"00");
        assertEq(decisions.attestations(), 0);
    }

    function test_aVersion5QuoteWithATd15BodyNamesItsKey() public {
        bytes memory out = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        out[1] = 0x05;
        out[3] = 0x03;
        // A TD 1.5 body adds TEE_TCB_SVN2 and MRSERVICETD after the report data; the offsets before it hold.
        verifier.set(true, bytes.concat(out, new bytes(64)));
        assertEq(decisions.attestBrain(hex"00"), enclaveKey);

        address next = makeAddr("next");
        out = _output(0, rtmr3, decisions.attestationNonce(), next);
        out[1] = 0x05;
        verifier.set(true, out);
        assertEq(decisions.attestBrain(hex"00"), next, "version 5 with a TD 1.0 body");
        assertEq(decisions.attestations(), 2);
    }

    function test_anImageOffTheAllowlistCannotNameAKey() public {
        bytes memory out = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        out[147] = 0x12;
        bytes memory otherMrtd = bytes.concat(bytes1(0x12), _slice(mrtd, 1, 47));
        verifier.set(true, out);
        vm.expectRevert(
            abi.encodeWithSelector(DecisionLog.ImageNotAllowed.selector, keccak256(abi.encodePacked(otherMrtd, rtmrs)))
        );
        decisions.attestBrain(hex"00");

        // RTMR2 is part of the image as well.
        out = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        out[482] = 0x23;
        bytes memory otherRtmrs = bytes.concat(_slice(rtmrs, 0, 143), bytes1(0x23));
        verifier.set(true, out);
        vm.expectRevert(
            abi.encodeWithSelector(DecisionLog.ImageNotAllowed.selector, keccak256(abi.encodePacked(mrtd, otherRtmrs)))
        );
        decisions.attestBrain(hex"00");
    }

    function test_aKeyWordWithBitsAboveTheAddressIsRejected() public {
        bytes memory out = _output(0, rtmr3, decisions.attestationNonce(), enclaveKey);
        // The key is the last 20 bytes of the 32-byte word after the nonce.
        out[563] = 0x01;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.QuoteRejected.selector);
        decisions.attestBrain(hex"00");
        out[563] = 0x00;
        out[574] = 0x01;
        verifier.set(true, out);
        vm.expectRevert(DecisionLog.QuoteRejected.selector);
        decisions.attestBrain(hex"00");
        assertEq(decisions.brain(), makeAddr("brain"));
    }

    function test_aZeroKeyIsRejected() public {
        verifier.set(true, _output(0, rtmr3, decisions.attestationNonce(), address(0)));
        vm.expectRevert(DecisionLog.ZeroAddress.selector);
        decisions.attestBrain(hex"00");
        assertEq(decisions.attestations(), 0);
        assertEq(decisions.brain(), makeAddr("brain"));
    }

    /// The verifier's real output for the quote that named the live brain on BrainChain mainnet (block
    /// 2229). The fixture above is built with the log's own offsets, so it cannot catch a wrong one; this
    /// one reads the measurements out of the raw quote by Intel's layout (a 48-byte header, then the TD
    /// report: MRTD at 136, RTMR0 to RTMR2 at 328, RTMR3 at 472, report data at 520) and requires the log
    /// to arrive at the same image, app and key from the verifier's output.
    function test_theMainnetQuoteParsesToTheLiveMeasurements() public {
        string memory json = vm.readFile("test/fixtures/attest-brain-2229.json");
        bytes memory quote = vm.parseJsonBytes(json, ".quote");
        bytes memory output = vm.parseJsonBytes(json, ".output");
        address live = vm.parseJsonAddress(json, ".decisionLog");
        address named = vm.parseJsonAddress(json, ".brain");
        bytes32 image = vm.parseJsonBytes32(json, ".image");
        bytes32 app = vm.parseJsonBytes32(json, ".app");

        assertEq(keccak256(abi.encodePacked(_slice(quote, 48 + 136, 48), _slice(quote, 48 + 328, 144))), image);
        assertEq(keccak256(_slice(quote, 48 + 472, 48)), app);
        assertEq(_slice(output, 11, 584), _slice(quote, 48, 584), "the output's body is the quote's TD report");

        vm.chainId(vm.parseJsonUint(json, ".chainId"));
        deployCodeTo("DecisionLog.sol:DecisionLog", abi.encode(owner, makeAddr("brain")), live);
        DecisionLog log = DecisionLog(live);
        store.target(live).sig(log.attestations.selector).checked_write(vm.parseJsonUint(json, ".attestationsBefore"));
        assertEq(log.attestationNonce(), bytes32(_slice(quote, 48 + 520, 32)), "the quote carries the log's nonce");

        vm.startPrank(owner);
        log.setAttestation(verifier);
        log.allowImage(image, true);
        log.allowApp(app, true);
        vm.stopPrank();
        verifier.set(true, output);
        vm.expectEmit(true, false, false, false, live);
        emit DecisionLog.BrainSet(named);
        vm.expectEmit(true, true, true, false, live);
        emit DecisionLog.BrainAttested(named, image, app);
        assertEq(log.attestBrain(quote), named);
        assertEq(log.brain(), named);
    }
}
