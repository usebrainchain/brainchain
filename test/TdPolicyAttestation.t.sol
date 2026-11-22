// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DecisionLog, IDcapAttestation} from "../src/DecisionLog.sol";
import {TdPolicyAttestation} from "../src/TdPolicyAttestation.sol";

/// A verifier that accepts every quote and answers with a fixed output.
contract ReplayVerifier is IDcapAttestation {
    bool public ok = true;
    bytes public output;

    function set(bool ok_, bytes memory output_) external {
        ok = ok_;
        output = output_;
    }

    function verifyAndAttestOnChain(bytes calldata) external payable returns (bool, bytes memory) {
        return (ok, output);
    }

    function verifyAndAttestOnChain(bytes calldata, uint32) external payable returns (bool, bytes memory) {
        return (ok, output);
    }
}

contract TdPolicyAttestationTest is Test {
    /// What the Automata verifier answered for the mainnet brain's quote in
    /// 0x7ea2a0a183fe16fb14b97cd9f48cefa8b3ab55580df4038dc65064c7af8f8ec2: a
    /// production TD, whose report data names the brain on the 3.4.0 log.
    bytes private constant OUTPUT =
        hex"000400020020a06f0000000b0105000000000000000000000000007bf063280e94fb051f5dd7b1fc59ce9aac42bb961df8d44b709c9b0ff87a7b4df648657ba6d1189589feab1d5a3c9a9d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000007020000000000007fe60787222bd394cb516abca2435f22f035ab2cc9c0a4b4b3b148e46297f3d931a237b72f359052c6e657d8c1409173017a83fffa9fa660eeab06722de388d621c9684be5459f55b34096f69e4884d81d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068102e7b524af310f7b7d426ce75481e36c40f5d513a9009c046e9d37e31551f0134d954b496a3357fd61d03f07ffe964ae609807c765916a31d724786ed74bcb97e168a9d937b04936aeef2015c907eba5ac352c6bcd749c246fd62ffb659ec80e945df96ec417b68d574dba18d199a7448d66c3d0e56f073167a9513d2381601f5d614853646d2c49c5d8d58a7daf5364ea18d270c2078633f4f4ffd787cce246a7f79cf45ee6988149a15a58687aa2424ea03f8c908104b68672c065658dce10533af65c7023bbbeca10e4c143f6cc4bb00b5de40149599842a53d433a4e5000000000000000000000000db36f754f8c619cb3e191ef1e0adcbd7690e9d2a";
    address private constant LOG_340 = 0xFdFEDb376c9632A4D6F15a1697E2b6853f12B4d7;
    address private constant ENCLAVE_KEY = 0xDB36F754f8C619cB3E191ef1E0AdCBD7690E9D2A;
    uint256 private constant TD_ATTRIBUTES = 131;

    ReplayVerifier private verifier;
    TdPolicyAttestation private policy;

    function setUp() public {
        verifier = new ReplayVerifier();
        verifier.set(true, OUTPUT);
        policy = new TdPolicyAttestation(verifier);
    }

    function _with(uint256 index, bytes1 value) private pure returns (bytes memory out) {
        out = OUTPUT;
        out[index] = value;
    }

    function test_productionQuotePassesUnchanged() public {
        (bool ok, bytes memory out) = policy.verifyAndAttestOnChain("");
        assertTrue(ok);
        assertEq(out, OUTPUT);
        (ok, out) = policy.verifyAndAttestOnChain("", 17);
        assertTrue(ok);
        assertEq(out, OUTPUT);
    }

    function test_debugTdIsRefused() public {
        verifier.set(true, _with(TD_ATTRIBUTES, 0x01));
        (bool ok,) = policy.verifyAndAttestOnChain("");
        assertFalse(ok);
        (ok,) = policy.verifyAndAttestOnChain("", 17);
        assertFalse(ok);
    }

    function test_anyDebugGroupBitIsRefused() public {
        for (uint8 bit = 0; bit < 8; bit++) {
            verifier.set(true, _with(TD_ATTRIBUTES, bytes1(uint8(1) << bit)));
            (bool ok,) = policy.verifyAndAttestOnChain("");
            assertFalse(ok);
        }
    }

    function test_otherAttributesDoNotMatter() public {
        // SEPT_VE_DISABLE, bit 28, is set on the real quote; PKS and KL sit beside it.
        verifier.set(true, _with(TD_ATTRIBUTES + 3, 0xd0));
        (bool ok,) = policy.verifyAndAttestOnChain("");
        assertTrue(ok);
    }

    function test_seamAttributesMustBeZero() public {
        verifier.set(true, _with(123, 0x01));
        (bool ok,) = policy.verifyAndAttestOnChain("");
        assertFalse(ok);
    }

    function test_refusedByTheVerifierStaysRefused() public {
        verifier.set(false, OUTPUT);
        (bool ok,) = policy.verifyAndAttestOnChain("");
        assertFalse(ok);
    }

    function test_shortOrForeignOutputIsRefused() public {
        verifier.set(true, hex"0004000200");
        (bool ok,) = policy.verifyAndAttestOnChain("");
        assertFalse(ok);
        // An SGX body type would be read at the wrong offsets.
        verifier.set(true, _with(3, 0x01));
        (ok,) = policy.verifyAndAttestOnChain("");
        assertFalse(ok);
    }

    function test_zeroVerifierIsRefused() public {
        vm.expectRevert(TdPolicyAttestation.ZeroAddress.selector);
        new TdPolicyAttestation(IDcapAttestation(address(0)));
    }

    /// The mainnet log, at its own address and chain id so the quote's nonce
    /// holds, behind the policy: the real quote names the enclave, and the same
    /// quote with the debug bit set is turned away.
    function _log() private returns (DecisionLog log) {
        vm.chainId(274663);
        deployCodeTo("DecisionLog.sol:DecisionLog", abi.encode(address(this), address(0xdEaD)), LOG_340);
        log = DecisionLog(LOG_340);
        log.setAttestation(policy);
        bytes memory out = OUTPUT;
        bytes memory mrtd = new bytes(48);
        bytes memory rtmrs = new bytes(144);
        bytes memory rtmr3 = new bytes(48);
        for (uint256 i = 0; i < 48; i++) {
            mrtd[i] = out[147 + i];
            rtmr3[i] = out[483 + i];
        }
        for (uint256 i = 0; i < 144; i++) {
            rtmrs[i] = out[339 + i];
        }
        log.allowImage(keccak256(abi.encodePacked(mrtd, rtmrs)), true);
        log.allowApp(keccak256(rtmr3), true);
    }

    function test_logNamesTheEnclaveThroughThePolicy() public {
        DecisionLog log = _log();
        assertEq(log.attestBrain(""), ENCLAVE_KEY);
        assertEq(log.brain(), ENCLAVE_KEY);
        assertEq(log.attestations(), 1);
    }

    function test_logRefusesADebugTdThroughThePolicy() public {
        DecisionLog log = _log();
        verifier.set(true, _with(TD_ATTRIBUTES, 0x01));
        vm.expectRevert(DecisionLog.QuoteRejected.selector);
        log.attestBrain("");
        assertEq(log.brain(), address(0xdEaD));
    }

    /// Without the policy the same debug quote is accepted: the gap it closes.
    function test_withoutThePolicyTheLogAcceptsADebugTd() public {
        DecisionLog log = _log();
        log.setAttestation(verifier);
        verifier.set(true, _with(TD_ATTRIBUTES, 0x01));
        assertEq(log.attestBrain(""), ENCLAVE_KEY);
    }
}
