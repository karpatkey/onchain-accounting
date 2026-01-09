// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import "src/errors.sol";

/// @title BridgeAware
/// @author kpk
/// @notice A contract to be called alongside briding operations, and notifying listener contracts when such operations
/// are started/finalized
///
/// @notice The end goal for this feature is to tag bridged funds in the NAV Calculator logic, so that historical data
/// can be used instead while funds are in transit, in order to prevent undercounting or double-counting funds.
/// @notice Through Zodiac Pilot, it should be enforced that all bridge operations must also include a call to this
/// contract, thereby ensuring the NAVCalculator correctly accounts for the operation.
///
/// @notice Bridging operations are then expected to be manually marked as finished by an operator (which can be human
/// or automated), once it is verified that the funds have reached the destination chain, and accounting can proceed
/// normally
abstract contract BridgeAware {
    //
    // Type definitions
    //

    /// @notice Record of a pending bridge operation
    /// @param id Unique identifier for the operation
    /// @param asset ERC20 Asset to bridge
    /// @param blockNumber Block number where operation started
    struct BridgeOperation {
        bytes32 id;
        address asset;
        uint96 blockNumber;
    }

    //
    // Storage
    //

    /// @notice Mapping of bridge operations
    mapping(bytes32 id => BridgeOperation operation) public bridgeOperations;

    /// @notice How many bridge operations currently taking place for a given token
    mapping(address token => uint256 bridgingCount) public assetBridgingCounts;

    //
    // Events
    //

    /// @notice Emitted when a bridge operation is requested
    /// @param id The unique identifier of the operation
    /// @param asset ERC20 Asset to bridge
    event BridgeOperationStarted(bytes32 id, address asset);

    /// @notice Emitted when a bridge operation is manually finalized
    /// @param id The unique identifier of the
    event BridgeOperationFinalized(bytes32 id);

    //
    // External API
    //

    /// @notice Start a bridge operation
    /// @param underlyingAsset ERC20 Asset to bridge
    /// @return id Unique identifier for the operation
    function bridgeStart(address underlyingAsset) external returns (bytes32 id) {
        _bridgeAware_ensureCanCall(this.bridgeStart.selector);

        id = keccak256(abi.encodePacked(uint96(block.number), underlyingAsset));
        BridgeOperation memory op = BridgeOperation({id: id, asset: underlyingAsset, blockNumber: uint96(block.number)});

        // prevent duplicate operations (in the same block)
        BridgeOperation memory existing = bridgeOperations[id];

        if (existing.id != 0 || existing.blockNumber != 0 || existing.asset != address(0)) {
            revert DuplicateBridgeOperation();
        }

        // updates state
        bridgeOperations[id] = op;
        unchecked {
            assetBridgingCounts[op.asset]++;
        }

        emit BridgeOperationStarted(id, underlyingAsset);
        return id;
    }

    /// @notice Indicates a bridge operation has been completed
    ///   This voluntarily unfreezes the asset count for that token (unless other operations with the same token are
    /// also pending), causing the NAV calculator to start updating the value once again
    /// @param id The unique identifier of the operation
    function bridgeFinalize(bytes32 id) external {
        _bridgeAware_ensureCanCall(this.bridgeFinalize.selector);

        BridgeOperation memory op = bridgeOperations[id];

        if (op.id == 0 && op.blockNumber == 0 && op.asset == address(0)) {
            revert BridgeOperationNotFound();
        }
        if (op.blockNumber == block.number) {
            revert CantFinalizeOnSameBlock();
        }

        // update state
        assetBridgingCounts[op.asset]--;
        delete bridgeOperations[id];

        emit BridgeOperationFinalized(id);
    }

    /// @notice Check if a given asset is currently undergoing a bridge operation
    /// @param underlyingAsset The asset to check
    /// @return true if the asset is currently undergoing a bridge operation
    function isAssetBridging(address underlyingAsset) public view returns (bool) {
        return assetBridgingCounts[underlyingAsset] > 0;
    }

    /// @notice Overridable function to include permissions specifying permissions for calling `bridgeStart` and
    /// `bridgeFinalize`
    /// @notice By default, the function allows all calls
    ///
    /// @param selector The selector of the function being called
    //solhint-disable-next-line func-name-mixedcase, no-empty-blocks
    function _bridgeAware_ensureCanCall(bytes4 selector) internal virtual {}

    /// @notice Gap for upgradeability
    uint256[50] private __gap;
}
