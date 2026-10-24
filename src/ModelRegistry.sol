// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The worker models Jev can hire, each with the account that submits
/// its work and receives its pay. Owned by the DecisionExecutor.
contract ModelRegistry {
    struct Model {
        address account;
        uint128 price;
        bool active;
    }

    error NotOwner();
    error ZeroAddress();
    error UnknownModel();

    event ModelSet(bytes32 indexed id, address indexed account, uint128 price, bool active);
    event OwnerSet(address indexed owner);

    address public owner;
    mapping(bytes32 => Model) private _models;
    bytes32[] private _ids;

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    function setModel(bytes32 id, address account, uint128 price, bool active) external {
        if (msg.sender != owner) revert NotOwner();
        if (id == bytes32(0) || account == address(0)) revert ZeroAddress();
        if (_models[id].account == address(0)) _ids.push(id);
        _models[id] = Model(account, price, active);
        emit ModelSet(id, account, price, active);
    }

    function setOwner(address owner_) external {
        if (msg.sender != owner) revert NotOwner();
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnerSet(owner_);
    }

    function get(bytes32 id) external view returns (Model memory model) {
        model = _models[id];
        if (model.account == address(0)) revert UnknownModel();
    }

    function ids() external view returns (bytes32[] memory) {
        return _ids;
    }
}
