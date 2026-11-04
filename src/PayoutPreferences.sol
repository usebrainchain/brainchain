// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Where a worker wants its pay: USDG on BrainChain (the default, asset zero) or a stock token on
/// Robinhood Chain, sent to an address there. The board reads it when work is delivered and pays the house
/// instead of the worker; the house pays the stock on the parent chain and records the fill.
contract PayoutPreferences {
    struct Preference {
        address asset;
        address to;
    }

    mapping(address worker => Preference) public preferences;

    event PayoutSet(address indexed worker, address indexed asset, address to);

    error NoRecipient();

    function set(address asset, address to) external {
        if (asset != address(0) && to == address(0)) revert NoRecipient();
        preferences[msg.sender] = Preference(asset, to);
        emit PayoutSet(msg.sender, asset, to);
    }

    function inStock(address worker) external view returns (bool) {
        return preferences[worker].asset != address(0);
    }
}
