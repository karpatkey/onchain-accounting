// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IPositionEnumerable
/// @notice Optional interface for balance adapters that can enumerate their own position **shapes** — the set of
///         `positionId`s an account could hold with this adapter, independent of any account actually holding one.
/// @dev Companion to {IPositionDescribable}, and read the same way: an optional interface, advertised via ERC-165
///      and called through a **fail-open staticcall**, so an adapter that does not implement it simply produces
///      nothing. Nothing on the NAV path calls it — like `positionLabels` it is display-only work, kept off the
///      hot path.
///
///      **The gap it closes.** A configuration view (a registry page listing what the NAVCalculator is set up to
///      account for) has no account and therefore no `positionId` to pass to `positionLabels`. For meta-adapters
///      it can enumerate `getMetaInstances(adapter)` on the NAVCalculator; for every other adapter there was no
///      enumeration primitive at all, so the only question it could ask was `positionLabels("")` — which answers
///      only for adapters whose breadcrumb happens to be positionId-independent. An adapter that derives its
///      labels per `positionId` (Cap's cUSD vs. stcUSD legs) correctly returns an empty array to that probe and
///      was therefore undescribable from a configuration view, and — since it advertises exactly the interface
///      set every other adapter does — indistinguishable from an adapter that was simply broken. `positionIds()`
///      is that missing primitive: the adapter states its shapes directly, and its ERC-165 bit is the signal that
///      the empty probe was a real answer rather than a failure.
///
///      **Shapes, not positions, and never identity.** The returned ids describe what this adapter *can* report,
///      not what any account holds — there are no amounts here, and an id being listed implies nothing about a
///      balance. They exist so a consumer can render the configured position set and pair each entry with
///      `positionLabels(id)`. As with {IPositionDescribable}, clients MUST NOT treat this enumeration as an
///      identity or indexing mechanism: reconcile on the typed `protocolSubId` / `positionId` / `PositionKind`
///      fields of `PositionBalance`. The one guarantee that does bind is stated on {positionIds} below — the
///      bytes must be the same bytes the adapter emits — precisely so the two views can be joined.
/// @author KPK
interface IPositionEnumerable {
    /// @notice The `positionId`s this adapter can report, one per distinct position shape.
    /// @dev **Each returned id MUST be byte-identical to the `PositionBalance.positionId` the adapter emits for
    ///      that shape**, so a consumer can join the configuration view against real positions. This is the whole
    ///      contract of the interface; an id that merely *labels* correctly while differing from the emitted
    ///      bytes (e.g. a meta-adapter returning its raw instance coordinate where it emits a resolved address)
    ///      silently breaks that join and does not satisfy this interface.
    ///
    ///      Implement it only where the shape set is bounded and derivable on-chain — a fixed set pinned at
    ///      construction, or a governed instance set. The test is whether an account-independent answer exists,
    ///      and it is decided per adapter, not per family: an adapter whose shapes are discovered per account
    ///      (a per-account cache of coordinates fed by the position owner) has no such answer and must not
    ///      implement this interface, while one that pins its shapes at construction does — **even if it is
    ///      assistant-fed**. `NexusMutualStakingPoolsAssistedBalanceAdapter` is the former (its positionId is a
    ///      cached pool address); `EtherFiWithdrawalQueueAssistedBalanceAdapter` is the latter (it emits a
    ///      single constant `abi.encode(WITHDRAW_REQUEST_NFT)`, so it is eligible) — the assistant feeds *which
    ///      tickets* are held, not which shapes exist.
    ///
    ///      Do NOT infer any of this from `positionLabels("")` or from the `IAssistedBalanceAdapter` marker.
    ///      Neither discriminates: the marker means "coordinates are fed externally", and two of the three
    ///      assisted adapters answer the empty probe with a CONSTANT non-empty breadcrumb. The absence of a
    ///      discriminator is precisely why this interface exists — its ERC-165 bit is the signal.
    ///
    ///      Must not revert and must not depend on caller state. Ordering is not significant and consumers must
    ///      not rely on it — in particular the returned array is NOT index-aligned with `getAdapterPositions`,
    ///      which omits shapes an account does not hold; join on the bytes, never on position. An empty array is
    ///      valid and means "no shapes to advertise".
    ///
    ///      A listed shape says the adapter can report it, NOT that the NAVCalculator is configured to value it
    ///      — an adapter may additionally require its underlying asset to be a registered NAV asset before it
    ///      emits anything. A configuration view showing these rows is showing adapter capability, not proof of
    ///      NAV coverage.
    /// @return The ABI-encoded position identifiers, in unspecified order.
    function positionIds() external view returns (bytes[] memory);
}
