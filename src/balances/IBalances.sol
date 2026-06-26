// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @author KPK
interface IBalances {
    //
    // Type definitions
    //

    enum AdapterType {
        Default,
        Custom
    }

    struct BalanceAdapter {
        address adapter;
        AdapterType adapterType;
        string protocol;
    }

    //
    // Events
    //

    /// @notice Event emitted when a balance adapter is added to the global registry.
    /// @param underlyingAsset Reserved; currently address(0) as adapters are registered globally, not per asset.
    /// @param adapter The address of the adapter being added.
    /// @param adapterType The type of the adapter (Default or Custom).
    event BalanceAdapterAdded(address indexed underlyingAsset, address indexed adapter, AdapterType adapterType);

    /// @notice Event emitted when a balance adapter is removed from the global registry.
    /// @param underlyingAsset Reserved; currently address(0) as adapters are global.
    /// @param adapter The address of the balance adapter being removed.
    event BalanceAdapterRemoved(address indexed underlyingAsset, address adapter);

    //
    // Errors
    //

    /// @notice Error when the balance adapter is not set.
    error BalanceAdapterNotSet();

    /// @notice Error when the balance adapter is not valid
    error InvalidBalanceAdapter();

    /// @notice Error when the balance adapter type is not valid
    error InvalidBalanceAdapterType();

    /// @notice Error when the same balance adapter is already set.
    error DuplicateBalanceAdapter();

    /// @notice Error when adding a meta-instance coordinate that is already present (would double-count NAV).
    error DuplicateMetaInstance();

    /// @notice Error when removing a meta-instance coordinate that is not present in the adapter's set.
    error MetaInstanceNotFound();

    /// @notice Error when a meta-adapter (implements IMetaBalanceAdapter) is registered via the plain
    ///         addBalanceAdapters path; meta-adapters must use addMetaBalanceAdapter.
    error MetaAdapterNotAllowed();

    /// @notice Error when a meta-instance operation targets an adapter that is not a meta-adapter
    ///         (does not implement IMetaBalanceAdapter).
    error NotMetaAdapter();

    /// @notice Validates that the adapter implements IBalanceAdapter (reverts with InvalidBalanceAdapter if not).
    /// @param adapter The address of the adapter to check.
    function checkBalanceAdapterSupport(address adapter) external view;

    //
    // Global Adapter Registry
    //

    /// @notice Returns all registered adapters in the global registry
    /// @return adapters Array of all adapter addresses
    function getAllAdapters() external view returns (address[] memory adapters);

    /// @notice Returns the total number of registered adapters
    /// @return count Total number of adapters
    function getAdapterCount() external view returns (uint256 count);

    /// @notice Checks if an adapter is registered in the global registry
    /// @param adapter The adapter address to check
    /// @return registered True if the adapter is registered
    function isAdapterRegistered(address adapter) external view returns (bool registered);

    /// @notice Returns the type of a registered adapter
    /// @param adapter The adapter address
    /// @return adapterType The type of the adapter
    function getAdapterType(address adapter) external view returns (AdapterType adapterType);

    /// @notice Returns all adapters that support the given asset
    /// @dev Loops through all global adapters and checks if the asset is in their underlyingAssetsSupported() list
    /// @param asset The asset address to check
    /// @return adapters Array of adapter addresses that support the asset
    function getAdaptersForAsset(address asset) external view returns (address[] memory adapters);

    //
    // Meta-adapter instance registry (ADR 0010)
    //

    /// @notice Returns the configured meta-adapter instance coordinates for an adapter (empty for non-meta adapters).
    /// @param adapter The adapter address.
    /// @return instances The instance coordinates currently configured for the adapter.
    function getMetaInstances(address adapter) external view returns (bytes32[] memory instances);
}
