// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title IPositionDescribable
/// @notice Optional interface for balance adapters that can provide human-readable labels for their positions.
/// @dev NAVCalculator's verbose read methods (`getAccountPositionsVerbose`, `getAccountPositionsForAssetVerbose`,
///      `getAccountNavVerbose`) call these via a fail-open staticcall — adapters that do not implement this
///      interface simply produce empty label strings.
///      Clients MUST NOT use these strings for identity, indexing, or reconciliation; use the typed
///      `protocolId` / `positionId` / `PositionKind` fields on `PositionBalance` for those purposes.
/// @author KPK
interface IPositionDescribable {
    /// @notice Human-readable protocol name, e.g. "Aave V3", "Morpho", "Uniswap V3".
    /// @dev Per-instance adapters return a compile-time constant. Meta-adapters return a constant too
    ///      (the protocol name is the same regardless of which instance is being described).
    function protocolName() external view returns (string memory);

    /// @notice Human-readable label for a single position identified by `positionId`.
    /// @param positionId The ABI-encoded position identifier (same bytes as `PositionBalance.positionId`).
    /// @return A short display string, e.g. "USDC supply", "USDC/WETH 0.05% LP", "Steakhouse USDC vault".
    ///         Empty string is acceptable if a description cannot be derived.
    function describePosition(bytes calldata positionId) external view returns (string memory);
}
