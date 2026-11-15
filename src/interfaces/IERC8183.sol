// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice The ERC-8183 hook interface, as in the reference implementation:
/// github.com/erc-8183/base-contracts at 142e669, contracts/IERC8183Hook.sol.
interface IERC8183Hook is IERC165 {
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

/// @notice The part of the reference ERC-8183 job contract (`ERC8183` at the
/// same commit) that the evaluator and its hook call. `Job` keeps the
/// reference field order so `getJob` decodes against a deployed instance.
interface IERC8183 {
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        address client;
        JobStatus status;
        address provider;
        uint48 expiredAt;
        address evaluator;
        uint48 submittedAt;
        uint256 budget;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        string description;
        uint256 settledAmount;
        address payoutReceiver;
    }

    function getJob(uint256 jobId) external view returns (Job memory);

    function fund(uint256 jobId, address expectedToken, uint256 expectedBudget, bytes calldata optParams) external;

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;

    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}
