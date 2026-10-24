// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test stablecoin for BrainChain testnet bounties. It has no value.
/// Anyone can claim a fixed amount once a day from the faucet.
contract TestUSDG is ERC20 {
    error TooSoon(uint256 nextClaimAt);

    uint256 public constant FAUCET_AMOUNT = 100e6;
    uint256 public constant FAUCET_INTERVAL = 1 days;

    mapping(address => uint256) public lastClaim;

    constructor(address treasury, uint256 treasuryAmount) ERC20("BrainChain Test USDG", "tUSDG") {
        _mint(treasury, treasuryAmount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet() external {
        uint256 last = lastClaim[msg.sender];
        if (last != 0 && block.timestamp < last + FAUCET_INTERVAL) revert TooSoon(last + FAUCET_INTERVAL);
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
    }
}
