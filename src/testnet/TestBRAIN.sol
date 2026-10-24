// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for $BRAIN on BrainChain testnet. It has no value and is
/// not $BRAIN. Anyone can claim a fixed amount once a day.
contract TestBRAIN is ERC20 {
    error TooSoon(uint256 nextClaimAt);

    uint256 public constant FAUCET_AMOUNT = 1_000e18;
    uint256 public constant FAUCET_INTERVAL = 1 days;

    mapping(address => uint256) public lastClaim;

    constructor(address reserve, uint256 reserveAmount) ERC20("BrainChain Test BRAIN", "tBRAIN") {
        _mint(reserve, reserveAmount);
    }

    function faucet() external {
        uint256 last = lastClaim[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_INTERVAL) revert TooSoon(last + FAUCET_INTERVAL);
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
