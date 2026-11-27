// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ConditionFlat, ExecutionOptions} from "poc/fundconfig/vendor/RolesV2.sol";
import {Accounting, IPositionModule, PermissionLeaf} from "poc/fundconfig/IPositionModule.sol";

/// @notice Position module for EtherFi withdrawal requests via the assistant (`EtherFiWithdrawalQueueAssistedBalanceAdapter`).
/// @dev Single instance: the assistant contract widened to bytes32. Permissions allow the assistant's two entrypoints
///      through DELEGATECALL only, because the assistant must run in the Safe's context. Valuation is a plain adapter
///      read (`getAdapterPositions`), since the assisted adapter's cache covers the whole Safe.
contract EtherFiAssistedModule is IPositionModule {
    error InvalidInstance(bytes32 instance);

    bytes32 public constant MODULE_ID = keccak256("etherfi-withdrawal-queue");

    /// @dev Native ETH pseudo-address used by the repo's NAV and adapters.
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    bytes4 private constant SEL_REQUEST_WITHDRAW = bytes4(keccak256("requestWithdraw(uint256)"));
    bytes4 private constant SEL_CLAIM_WITHDRAW = bytes4(keccak256("claimWithdraw(uint256)"));

    /// @notice `BalanceAdapterAssistant` the Safe delegatecalls into.
    address public immutable ASSISTANT;

    /// @notice Plain adapter that values this module's positions.
    address public immutable ADAPTER;

    constructor(address assistant_, address adapter_) {
        ASSISTANT = assistant_;
        ADAPTER = adapter_;
    }

    /// @inheritdoc IPositionModule
    function moduleId() external pure returns (bytes32) {
        return MODULE_ID;
    }

    /// @inheritdoc IPositionModule
    function validate(bytes32 instance) external view {
        if (instance != bytes32(uint256(uint160(ASSISTANT)))) revert InvalidInstance(instance);
    }

    /// @inheritdoc IPositionModule
    function permissions(bytes32) external view returns (PermissionLeaf[] memory leaves) {
        ConditionFlat[] memory none = new ConditionFlat[](0);
        leaves = new PermissionLeaf[](2);
        leaves[0] = PermissionLeaf({
            target: ASSISTANT,
            selector: SEL_REQUEST_WITHDRAW,
            conditions: none,
            options: ExecutionOptions.DelegateCall
        });
        leaves[1] = PermissionLeaf({
            target: ASSISTANT,
            selector: SEL_CLAIM_WITHDRAW,
            conditions: none,
            options: ExecutionOptions.DelegateCall
        });
    }

    /// @inheritdoc IPositionModule
    function accounting(bytes32) external view returns (Accounting memory) {
        return Accounting({adapter: ADAPTER, isMeta: false, coordinate: bytes32(0), assetFilter: address(0)});
    }

    /// @inheritdoc IPositionModule
    function assets(bytes32) external pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = NATIVE_ETH;
    }
}
