// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IPositionDescribable
/// @notice Optional interface for balance adapters that expose a human-readable protocol name for their positions.
/// @dev NAVCalculator's verbose read methods (`getAccountPositionsVerbose`, `getAccountPositionsForAssetVerbose`,
///      `getAccountNavVerbose`) call these via a fail-open staticcall — adapters that do not implement this
///      interface simply produce an empty protocol name / label set. Labels are derived **lazily from `positionId`**
///      (a static, per-position breadcrumb), so they are computed only in the verbose reads, not carried on every
///      `PositionBalance` (that keeps display work off the NAV hot path). The ephemeral per-item id (Uniswap V3 NFT
///      id, withdrawal request id, …) is NOT a label — it is the typed `PositionBalance.positionInstanceId` field.
///      Clients MUST NOT use these strings for identity, indexing, or reconciliation; use the typed
///      `protocolId` / `positionId` / `PositionKind` fields on `PositionBalance` for those purposes.
/// @author KPK
interface IPositionDescribable {
    /// @notice Human-readable protocol name, e.g. "Aave V3", "Morpho", "Uniswap V3".
    /// @dev Per-instance adapters return a compile-time constant. Meta-adapters return a constant too
    ///      (the protocol name is the same regardless of which instance is being described).
    function protocolName() external view returns (string memory);

    /// @notice Ordered, arbitrary-depth display hierarchy for a single position, BELOW the protocol level.
    ///         Index 0 is the broadest level (category) and the last element is the position leaf, e.g.
    ///         `["Market", "wstETH/USDC"]`, `["AMM Liquidity Pool", "WETH/USDC 0.05%"]`, or `["Safety Module"]` when the
    ///         category itself is the leaf. The full breadcrumb a consumer renders is
    ///         `[protocolName(), ...positionLabels(positionId)]`. Derived purely from `positionId` (the static
    ///         anchor) — the ephemeral per-item id rides in `PositionBalance.positionInstanceId`, not here.
    /// @param positionId The ABI-encoded position identifier (same bytes as `PositionBalance.positionId`).
    /// @return An array of display segments. An empty array is acceptable when no label can be derived.
    ///         Depth varies by adapter and position; consumers must not assume a fixed length.
    function positionLabels(bytes calldata positionId) external view returns (string[] memory);
}
