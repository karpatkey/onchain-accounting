// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IBalances {
    //
    // Type definitions
    //

    enum OracleType {
        ERC20,
        Native,
        Custom
    }

    struct BalanceOracle {
        address oracle;
        OracleType oracleType;
        string protocol;
    }

    //
    // Events
    //

    /// @notice Event emitted when a balance oracle is added for an underlying asset.
    /// @param underlyingAsset The address of the token for which the oracle is set.
    /// @param oracle The address of the oracle being set.
    /// @param oracleType The type of the oracle.
    event BalanceOracleAdded(address indexed underlyingAsset, address indexed oracle, OracleType oracleType);

    /// @notice Event emitted when a balance oracle is removed for an underlying asset.
    /// @param underlyingAsset The address of the token for which the oracle is unset.
    /// @param oracle The address of the balance oracle being unset.
    event BalanceOracleRemoved(address indexed underlyingAsset, address oracle);

    //
    // Errors
    //

    /// @notice Error when the balance oracle is not set.
    error BalanceOracleNotSet();

    /// @notice Error when the balance oracle is not valid
    error InvalidBalanceOracle();

    /// @notice Error when the balance oracle type is not valid
    error InvalidBalanceOracleType();

    /// @notice Error when the same balance oracle is already set.
    error DuplicateBalanceOracle();

    /// @notice Returns the latest balance for the given underlying asset and account.
    ///
    /// Important :
    /// - The ordering of assets in the underlying data structure is not guaranteed. Entries may change order as
    ///    oracles are added or removed . It is not safe to assume a fixed order or that the same
    ///    query will yield a consistent oracle order.
    ///
    /// - Ensure that any external integrations using
    ///    the oracle data accounts for potential reordering, and calls `balanceOracleAt` directly for
    ///    verification if needed.
    ///
    /// @param underlyingAsset The address of the token.
    /// @param idx The index of the balance oracle.
    /// @param account The address of the account.
    /// @return balance The latest balance of the account for the token.
    function balanceOf(address underlyingAsset, uint256 idx, address account) external view returns (int256 balance);

    /// @notice Returns the amount of balance oracles defined for a given underlying asset
    /// @param underlyingAsset The address of the token.
    /// @return count The amount of balance oracles defined for the token.
    function balanceOracleCountFor(address underlyingAsset) external view returns (uint256 count);

    /// @notice Returns the balance oracle and type for a given underlying asset
    /// @param underlyingAsset The address of the token.
    /// @param idx The index of the balance oracle.
    /// @return oracle The address of the balance oracle.
    /// @return balanceType The type of the balance oracle.
    function balanceOracleAt(address underlyingAsset, uint256 idx) external view returns (address, OracleType);

    /// @notice Returns all the balance oracles addresses for a given underlying asset
    /// @param underlyingAsset The address of the token.
    /// @return oracles The address of the balance oracle.
    function balanceOracles(address underlyingAsset) external view returns (address[] memory oracles);

    /// @notice Checks if the oracle supports the given oracle type.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param oracleType The type of the oracle.
    function checkBalanceOracleSupport(address underlyingAsset, address oracle, OracleType oracleType) external view;

    //
    // Global Oracle Registry
    //

    /// @notice Returns all registered oracles in the global registry
    /// @return oracles Array of all oracle addresses
    function getAllOracles() external view returns (address[] memory oracles);

    /// @notice Returns the total number of registered oracles
    /// @return count Total number of oracles
    function getOracleCount() external view returns (uint256 count);

    /// @notice Checks if an oracle is registered in the global registry
    /// @param oracle The oracle address to check
    /// @return registered True if the oracle is registered
    function isOracleRegistered(address oracle) external view returns (bool registered);

    /// @notice Returns the type of a registered oracle
    /// @param oracle The oracle address
    /// @return oracleType The type of the oracle
    function getOracleType(address oracle) external view returns (OracleType oracleType);

    //
    // Asset Registry (shared with Prices and NAVCalculator)
    //

    /// @notice Checks if an asset is registered
    /// @param asset The asset address to check
    /// @return registered True if the asset is registered
    function isAssetRegistered(address asset) external view returns (bool registered);

    /// @notice Returns all registered assets
    /// @return assets Array of all registered asset addresses
    function getAssets() external view returns (address[] memory assets);

    /// @notice Returns the total number of registered assets
    /// @return count Total number of assets
    function getAssetCount() external view returns (uint256 count);

    /// @notice Returns the decimals for a registered asset
    /// @param asset The asset address
    /// @return decimals The number of decimals for the asset
    function getAssetDecimals(address asset) external view returns (uint8 decimals);

    /// @notice Returns the symbol for a registered asset
    /// @param asset The asset address
    /// @return symbol The asset symbol
    function getAssetSymbol(address asset) external view returns (string memory symbol);
}
