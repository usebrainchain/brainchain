// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDcapAttestation} from "./DecisionLog.sol";

/// @notice Sits between a DecisionLog and the DCAP verifier and refuses a
/// quote from a TD under debug. A debug TD reports the same measurements as a
/// production one while its host can read and write its memory, and the log
/// checks only the measurements. The owner points a log here with
/// `setAttestation`; everything the verifier accepts still passes unchanged,
/// except a quote whose TD attributes say the TD can be debugged.
contract TdPolicyAttestation is IDcapAttestation {
    error ZeroAddress();

    /// @dev Offsets in the verifier's output for a TD quote: two bytes of
    /// version, two of body type, the TCB status, six of FMSPC, then the TD
    /// report, whose SEAMATTRIBUTES and TDATTRIBUTES follow its 112 bytes of
    /// TCB SVN, MRSEAM and MRSIGNERSEAM.
    uint256 private constant SEAM_ATTRIBUTES = 123;
    uint256 private constant TD_ATTRIBUTES = 131;
    uint256 private constant ATTRIBUTES_END = 139;
    uint8 private constant QUOTE_V4 = 4;
    uint8 private constant QUOTE_V5 = 5;
    uint8 private constant BODY_TD10 = 2;
    uint8 private constant BODY_TD15 = 3;

    IDcapAttestation public immutable verifier;

    constructor(IDcapAttestation verifier_) {
        if (address(verifier_) == address(0)) revert ZeroAddress();
        verifier = verifier_;
    }

    function verifyAndAttestOnChain(bytes calldata rawQuote) external payable returns (bool, bytes memory) {
        (bool ok, bytes memory out) = verifier.verifyAndAttestOnChain{value: msg.value}(rawQuote);
        return (ok && _production(out), out);
    }

    function verifyAndAttestOnChain(bytes calldata rawQuote, uint32 tcbEvaluationDataNumber)
        external
        payable
        returns (bool, bytes memory)
    {
        (bool ok, bytes memory out) =
            verifier.verifyAndAttestOnChain{value: msg.value}(rawQuote, tcbEvaluationDataNumber);
        return (ok && _production(out), out);
    }

    /// @dev True for a TD quote whose TD is not under debug. The low byte of
    /// TDATTRIBUTES is the TUD group: bit 0 is DEBUG and the rest are reserved
    /// for further debug modes, so any of them set means the TD is not to be
    /// trusted. SEAMATTRIBUTES is zero on every TDX module released.
    function _production(bytes memory out) private pure returns (bool) {
        if (out.length < ATTRIBUTES_END) return false;
        if (out[0] != 0 || (uint8(out[1]) != QUOTE_V4 && uint8(out[1]) != QUOTE_V5)) return false;
        if (out[2] != 0 || (uint8(out[3]) != BODY_TD10 && uint8(out[3]) != BODY_TD15)) return false;
        for (uint256 i = SEAM_ATTRIBUTES; i < TD_ATTRIBUTES; i++) {
            if (out[i] != 0) return false;
        }
        return out[TD_ATTRIBUTES] == 0;
    }
}
