// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title IComputedLabelSegments
/// @author KPK
/// @notice Optional interface for balance adapters that DERIVE one or more of their `positionLabels` segments from
///         live on-chain state, so `AssetKindRegistry` can refuse to freeze a derived segment behind a literal.
/// @dev **Why this exists: before it, the protection for a computed segment was a markdown table.**
///      `AssetKindRegistry.setAdapterLabels` guards the adapter's registration, the segment count, each string's
///      length, and not-all-empty. It has never guarded WHICH INDEX may be written, and it has no way to know which
///      of an adapter's segments are literals and which are computed. `BALANCE_ADAPTERS.md` §6.2 enumerates the
///      answer for every adapter and states plainly that the two safety rules are "properties of the ADAPTER rather
///      than of the mechanism" — i.e. operator discipline, checked by nobody.
///
///      That was tolerable while only segment 0 was writable. It is not tolerable now: the per-segment
///      `setAdapterLabels` widened the surface to ANY depth, so every computed leaf in the fleet became reachable
///      by a single MANAGER call. **The worst case is also the one the docs shout loudest about.**
///      `ERC20DefaultBalanceAdapter` is registered on every chain and its segment 0 is not a category at all — it
///      IS the computed token symbol. One override stamps a single frozen symbol onto every ERC20 wallet position
///      on that chain, and it renders as a plausible label rather than as an error.
///
///      **A permanent expected-anomaly that an operator has to remember is a fail-open with a human in the loop.**
///      This moves the fact on-chain, where the same repo already puts protocol identity: derived, not asserted in
///      prose.
///
///      **Optional, and ERC-165-gated, for a reason that is not stylistic.** Twenty-three contracts implement
///      {IPositionDescribable}; adding a method there would fail to compile every one of them, and every adapter
///      already deployed is IMMUTABLE and could never adopt it. So this mirrors {IPositionEnumerable} exactly — a
///      separate optional interface whose ERC-165 bit is itself the signal that the adapter has thought about the
///      question. An adapter that does not advertise it is treated as declaring nothing, which preserves today's
///      behaviour rather than bricking the override feature for every already-deployed adapter.
///
///      ⚠️ **The consequence of that choice, stated rather than buried: the guard is only as complete as adoption.**
///      An adapter that does not implement this interface gets NO index protection, exactly as before. It is not a
///      fail-closed guard and cannot be, because fail-closed would block every override on every existing adapter.
///      Coverage becomes complete when each adapter next ships — which for this repo is the pending full redeploy.
interface IComputedLabelSegments {
    /// @notice Bitmask of `positionLabels` indices this adapter DERIVES from on-chain state. Bit `i` set means
    ///         segment `i` is computed and must not be frozen behind a literal.
    /// @dev A mask rather than an array: the ceiling is `AssetKindRegistry.MAX_ADAPTER_LABEL_SEGMENTS` (8), so a
    ///      single word is generous, costs one `SLOAD`-free `pure` return, and needs no memory allocation on a path
    ///      the registry reads through a gas-capped staticcall.
    ///
    ///      Return `0` to declare that every segment is a literal — which is a real, useful declaration and NOT the
    ///      same as not implementing the interface. `0` says "I considered this and nothing of mine is derived";
    ///      absent says "nobody has considered it". Both permit any override, but only the first is a statement.
    ///
    ///      MUST be `pure` or `view` and MUST NOT revert — the registry reads it behind a bounded staticcall and
    ///      treats a failure as "declares nothing", so a reverting implementation silently forfeits its own
    ///      protection.
    function computedLabelSegments() external view returns (uint256 mask);
}
