// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAllowanceHolderPull {
    function transferFrom(address token, address owner, address recipient, uint256 amount) external returns (bool);
}

/// 0x's Settler registry as the mandate reads it: the live taker Settler for feature 2, the one before
/// it, and a pause that makes `ownerOf` revert as the real registry does.
contract MockSettlerRegistry {
    address public current;
    address public previous;
    bool public paused;

    error SettlerPaused();
    error NoInstance();

    function set(address current_, address previous_) external {
        current = current_;
        previous = previous_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(tokenId == 2);
        if (paused) revert SettlerPaused();
        return current;
    }

    function prev(uint128 featureId) external view returns (address) {
        require(featureId == 2);
        if (previous == address(0)) revert NoInstance();
        return previous;
    }
}

/// A Settler behind the real AllowanceHolder. It reads the taker AllowanceHolder appends to every call,
/// pulls from it through AllowanceHolder and pays out whatever the test asks, honestly or not.
contract MockSettler {
    address internal constant ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    uint256 public allowanceSeen;

    function fill(address sellToken, uint256 pull, address buyToken, uint256 out, address recipient) external {
        address taker = _taker();
        allowanceSeen = IERC20(sellToken).allowance(taker, ALLOWANCE_HOLDER);
        IAllowanceHolderPull(ALLOWANCE_HOLDER).transferFrom(sellToken, taker, address(this), pull);
        if (out != 0) IERC20(buyToken).transfer(recipient, out);
    }

    function fillInEth(address sellToken, uint256 pull, uint256 out) external {
        address taker = _taker();
        IAllowanceHolderPull(ALLOWANCE_HOLDER).transferFrom(sellToken, taker, address(this), pull);
        (bool ok, bytes memory ret) = taker.call{value: out}("");
        if (!ok) _bubble(ret);
    }

    function reenter(bytes calldata call) external {
        (bool ok, bytes memory ret) = _taker().call(call);
        if (!ok) _bubble(ret);
    }

    function _taker() internal pure returns (address) {
        return address(bytes20(msg.data[msg.data.length - 20:]));
    }

    function _bubble(bytes memory ret) internal pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}

/// A token that takes `feeBps` of every transfer: out of what arrives, or with `onTop` from the sender
/// on top of the amount.
contract MockFeeToken is ERC20 {
    uint256 public feeBps;
    bool public onTop;

    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 feeBps_, bool onTop_) external {
        feeBps = feeBps_;
        onTop = onTop_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, onTop ? value : value - fee);
    }
}

/// A token whose `transferFrom` checks the allowance but never spends it.
contract MockStickyAllowanceToken is ERC20 {
    constructor() ERC20("Sticky", "STK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal view override {
        if (allowance(owner, spender) < value) {
            revert ERC20InsufficientAllowance(spender, allowance(owner, spender), value);
        }
    }
}
