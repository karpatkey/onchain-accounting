// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

interface IBalances {
    //
    // Type definitions
    //

    /// @notice Enum representing the types of balance oracles.
    /// @param ERC20 The oracle is an ERC20 token.
    /// @param Native The native token of the underlying chain.
    /// @param Custom The balance oracle is a custom oracle.
    enum BalanceType {
        ERC20,
        Native,
        Custom
    }

    /// @notice Struct representing a balance oracle.
    /// @param oracle The address of the oracle.
    /// @param balanceType The type of the oracle (ERC20, Native or Custom).
    struct BalanceOracle {
        address oracle;
        BalanceType balanceType;
    }

    /// @notice Struct representing a balance oracle with metadata.
    /// @param oracle The address of the oracle.
    /// @param protocol The protocol name.
    /// @param position The specified position within the protocol.
    /// @param positionType The type of the position (e.g., "Supplied", "Borrowed", "Staked").
    struct BalanceOracleWithMetadata {
        address oracle;
        string protocol;
        string position;
        string positionType;
    }

    //
    // Events
    //

    /// @notice Event emitted when a balance oracle is added for an underlying asset.
    /// @param underlyingAsset The address of the token for which the oracle is set.
    /// @param oracle The address of the oracle being set.
    /// @param oracleType The type of the oracle (ERC20 or Custom).
    event BalanceOracleAdd(address indexed underlyingAsset, address indexed oracle, BalanceType oracleType);

    /// @notice Event emitted when a balance oracle is removed for an underlying asset.
    /// @param underlyingAsset The address of the token for which the oracle is removed.
    /// @param oracle The address of the balance oracles to remove from the token oracle set.
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
    function balanceOracleAt(address underlyingAsset, uint256 idx) external view returns (address, BalanceType);

    /// @notice Returns all the balance oracles addresses for a given underlying asset
    /// @param underlyingAsset The address of the token.
    /// @return oracles The address of the balance oracle.
    function balanceOracles(address underlyingAsset) external view returns (address[] memory oracles);

    /// @notice Retrieve all configured balance oracles for a given underlying asset, including human‑readable metadata.
    /// @dev
    ///   - Custom oracles (BalanceType.Custom) provide metadata via their own `positionMetadata()` hook.
    ///   - Native oracles (BalanceType.Native) return a default metadata struct with:
    ///       protocol = "Portfolio balance",
    ///       position  = _nativeTokenSymbol,
    ///       positionType = "Native"
    ///   - ERC20 oracles (BalanceType.ERC20) attempt to read the underlying asset token’s `symbol()`. On failure,
    ///       the `position` field is left empty.
    ///   - The returned array order corresponds to the internal oracle set’s iteration; callers should not
    ///     assume any particular order across invocations.
    /// @param underlyingAsset The token address whose oracles you wish to query.
    /// @return list An array of `BalanceOracleWithMetadata` structs, each containing:
    ///   - oracle        The oracle contract’s address.
    ///   - protocol      The name of the protocol or system supplying the balance.
    ///   - position      A position identifier (e.g. token symbol or custom string).
    ///   - positionType  A tag describing the position (“Native”, “ERC20”, or custom type).
    function balanceOraclesWithMetadata(address underlyingAsset)
        external
        view
        returns (BalanceOracleWithMetadata[] memory);

    /// @notice Checks if the oracle supports the given oracle type.
    /// @param underlyingAsset The address of the token.
    /// @param oracle The address of the oracle.
    /// @param oracleType The type of the oracle.
    function checkBalanceOracleSupport(address underlyingAsset, address oracle, BalanceType oracleType) external view;
}
