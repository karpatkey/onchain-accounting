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
///      `protocolSubId` / `positionId` / `PositionKind` fields on `PositionBalance` for those purposes.
/// @author KPK
interface IPositionDescribable {
    /// @notice Human-readable name of the PROTOCOL, e.g. "Aave V3", "Morpho", "Uniswap V3".
    /// @dev **This names the protocol, never the product.** A protocol's individual products — Aave V3's Safety
    ///      Module and Umbrella, Morpho's vaults and markets, Balancer's pools and gauges — all return the SAME
    ///      string here; what distinguishes them is `positionLabels()` (`["Umbrella Module"]`, `["Safety Module"]`,
    ///      `["Market", "wstETH/USDC"]`) and the typed `protocolSubId`. Equivalently: every adapter sharing a
    ///      `ProtocolIds` protocol id MUST return the same name. Pull it from `src/utils/ProtocolNames.sol` rather
    ///      than writing a literal — new and changed adapters should reference the constant; the pre-existing
    ///      literals are being migrated adapter by adapter and are meanwhile pinned to their constants by
    ///      `test/ProtocolNameConsistency.t.sol`. Meta-adapters need no literal at all (see below).
    ///
    ///      Why the distinction is load-bearing rather than cosmetic: consumers group *configured adapters* by this
    ///      string. The typed `protocolBrand`/`protocolId`/`protocolSubId` would group them correctly, but they are
    ///      `private constant` and only ride on `PositionBalance` structs returned by an **account** read — a
    ///      consumer enumerating registered adapters never sees them, so the display name is the only protocol
    ///      identity it has. An adapter that returns its product name here splits itself out into a phantom sibling
    ///      protocol (`AaveUmbrellaBalanceAdapter` returned "Aave Umbrella" and did exactly that).
    ///
    ///      Per-instance adapters return a compile-time constant. Meta-adapters **derive** it —
    ///      `MetaBalanceAdapter.protocolName()` is `ProtocolNames.forProtocolId(_protocolId())` — so for the whole
    ///      meta family the invariant holds by construction: the name is a pure function of the typed identity the
    ///      adapter already declares, with no constructor argument or config value that could disagree with it.
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
    ///
    ///      **When there is no account to get a positionId from** — a configuration view listing what the
    ///      NAVCalculator is set up to account for — an adapter whose breadcrumb is positionId-independent
    ///      answers `positionLabels("")` with its full constant breadcrumb, and that is the whole answer. An
    ///      adapter whose breadcrumb is derived per positionId returns `[]` instead and should implement
    ///      {IPositionEnumerable}, whose `positionIds()` lists the shapes to pair with this function and whose
    ///      ERC-165 bit is what distinguishes that `[]` from a broken adapter. See {IPositionEnumerable}.
    function positionLabels(bytes calldata positionId) external view returns (string[] memory);
}
