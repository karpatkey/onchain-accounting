// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IBalanceAdapterRegistry
/// @author kpk
/// @notice Minimal interface used by per-protocol adapter factories to notify the
///         central registry when an adapter is deployed or registered externally.
/// @dev The registry resolves the protocol key from `msg.sender` (must be a registered
///      protocol factory), records the adapter, and forwards to NAVCalculator.
interface IBalanceAdapterRegistry {
    /// @notice Register an adapter under the protocol key associated with `msg.sender`.
    /// @dev Reverts if the caller is not a registered protocol factory or if the
    ///      adapter is already tracked. Idempotently calls `NAVCalculator.addBalanceOracle`
    ///      only when the adapter is not yet registered there.
    /// @param adapter Address of the IBalanceOracleAdapter implementation to record.
    function register(address adapter) external;
}
