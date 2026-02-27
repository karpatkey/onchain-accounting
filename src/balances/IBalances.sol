// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IBalances {
    //
    // Type definitions
    //

    enum OracleType {
        Default,
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

    /// @notice Event emitted when a balance oracle is added to the global registry.
    /// @param underlyingAsset Reserved; currently address(0) as oracles are registered globally, not per asset.
    /// @param oracle The address of the oracle being added.
    /// @param oracleType The type of the oracle (Default or Custom).
    event BalanceOracleAdded(address indexed underlyingAsset, address indexed oracle, OracleType oracleType);

    /// @notice Event emitted when a balance oracle is removed from the global registry.
    /// @param underlyingAsset Reserved; currently address(0) as oracles are global.
    /// @param oracle The address of the balance oracle being removed.
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

    /// @notice Validates that the oracle implements IBalanceOracleAdapter (reverts with InvalidBalanceOracle if not).
    /// @param oracle The address of the oracle to check.
    function checkBalanceOracleSupport(address oracle) external view;

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

    /// @notice Returns all oracles that support the given asset
    /// @dev Loops through all global oracles and checks if the asset is in their underlyingAssetsSupported() list
    /// @param asset The asset address to check
    /// @return oracles Array of oracle addresses that support the asset
    function getOraclesForAsset(address asset) external view returns (address[] memory oracles);
}
