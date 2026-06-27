// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IPositionDescribable
/// @notice Optional interface for balance adapters that expose a human-readable protocol name for their positions.
/// @dev NAVCalculator's verbose read methods (`getAccountPositionsVerbose`, `getAccountPositionsForAssetVerbose`,
///      `getAccountNavVerbose`) call `protocolName()` via a fail-open staticcall — adapters that do not implement
///      this interface simply produce an empty protocol name. The per-position display hierarchy (the `labels`
///      breadcrumb below the protocol) is **not** part of this interface: every adapter fills it directly on each
///      `PositionBalance.labels` it returns, and the verbose reads use that field. The full breadcrumb a consumer
///      renders is `[protocolName(), ...PositionBalance.labels]`.
///      Clients MUST NOT use these strings for identity, indexing, or reconciliation; use the typed
///      `protocolId` / `positionId` / `PositionKind` fields on `PositionBalance` for those purposes.
/// @author KPK
interface IPositionDescribable {
    /// @notice Human-readable protocol name, e.g. "Aave V3", "Morpho", "Uniswap V3".
    /// @dev Per-instance adapters return a compile-time constant. Meta-adapters return a constant too
    ///      (the protocol name is the same regardless of which instance is being described).
    function protocolName() external view returns (string memory);
}
