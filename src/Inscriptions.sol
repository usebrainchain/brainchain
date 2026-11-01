// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Inscriptions
/// @notice An append-only log kept in BrainChain's own blocks. Whoever operates
/// the chain writes what they did here: releases, node changes, incidents and
/// configuration, as UTF-8 JSON. Anyone may write; readers filter by writer.
/// The contract keeps nothing in storage, so a record costs little more than
/// its bytes and can never be edited or removed.
contract Inscriptions {
    /// @param by Who wrote the record.
    /// @param kind A short word for the record, such as "service", "node", "incident" or "config".
    /// @param data The record itself, UTF-8 JSON.
    event Inscribed(address indexed by, string kind, bytes data);

    /// @notice Writes one record under the caller's address.
    function inscribe(string calldata kind, bytes calldata data) external {
        require(bytes(kind).length != 0 && bytes(kind).length <= 32, "kind");
        require(data.length != 0, "data");
        emit Inscribed(msg.sender, kind, data);
    }
}
