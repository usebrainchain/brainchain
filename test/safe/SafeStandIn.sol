// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// The module surface of a Safe 1.4.1: modules are enabled by the Safe itself, and a module call that fails
/// returns false instead of reverting. A prank as this contract stands in for a transaction the owners signed.
contract SafeStandIn {
    mapping(address module => bool) public isModuleEnabled;

    function enableModule(address module) external {
        require(msg.sender == address(this), "GS031");
        isModuleEnabled[module] = true;
    }

    function disableModule(address module) external {
        require(msg.sender == address(this), "GS031");
        isModuleEnabled[module] = false;
    }

    function execTransactionFromModule(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success)
    {
        require(isModuleEnabled[msg.sender], "GS104");
        if (operation == 1) (success,) = to.delegatecall(data);
        else (success,) = to.call{value: value}(data);
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes memory data, uint8 operation)
        external
        returns (bool success, bytes memory returnData)
    {
        require(isModuleEnabled[msg.sender], "GS104");
        if (operation == 1) (success, returnData) = to.delegatecall(data);
        else (success, returnData) = to.call{value: value}(data);
    }

    receive() external payable {}
}
