// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

import {ProtocolIds} from "./ProtocolIds.sol";

/// @notice Canonical human-readable protocol display names — the string every adapter returns from
///         `IPositionDescribable.protocolName()`, one constant per `ProtocolIds` *protocol id*.
/// @dev **The contract this library exists to enforce:** `protocolName()` names the PROTOCOL, never the product.
///      Adapters that are different products of one protocol (Aave V3 lending / Safety Module / Umbrella; Morpho
///      vaults / markets; Balancer pools / gauges; …) share a `protocolId` and MUST therefore return the *same*
///      display name. What distinguishes the product is `positionLabels()` (`["Umbrella Module"]`,
///      `["Safety Module"]`, `["Market", "wstETH/USDC"]`) and the typed `protocolSubId`.
///
///      Why a shared constant and not a literal per adapter: consumers group configured adapters by
///      `protocolName()`. The typed `protocolBrand` / `protocolId` / `protocolSubId` would group them correctly, but
///      those are `private constant` and only ride on `PositionBalance` structs returned by an *account* read — a
///      consumer listing configured adapters never sees them. The display name is the only protocol identity such a
///      consumer has, so an adapter that returns its product name splits itself out into a bogus sibling protocol.
///      That is exactly what `AaveUmbrellaBalanceAdapter` did by returning "Aave Umbrella" (fixed to `AAVE_V3`).
///
///      Naming is one constant per **protocol id**, not per sub-id — there is deliberately no `AAVE_V3_UMBRELLA`
///      here. If you find yourself wanting one, the string you want belongs in `positionLabels()`.
///
///      These are `string internal constant`, so they are inlined at compile time exactly as a literal would be:
///      switching an adapter from `"Aave V3"` to `ProtocolNames.AAVE_V3` is bytecode-neutral.
///
///      Meta adapters do not hold a name at all: `MetaBalanceAdapter.protocolName()` returns
///      `forProtocolId(_protocolId())`, deriving it from the typed identity the adapter already declares. That is
///      what makes the invariant structural for that whole family — there is no second value to keep in sync.
/// @author KPK
library ProtocolNames {
    /// @dev Plain ERC20 holdings (`ERC20DefaultBalanceAdapter`, `ProtocolIds.WALLET`) — not a protocol as such.
    string internal constant WALLET = "Wallet";

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Lending / money markets
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `ProtocolIds.AAVE_V3` — shared by lending instances, the Safety Module, and Umbrella.
    string internal constant AAVE_V3 = "Aave V3";
    /// @dev `ProtocolIds.SPARK`.
    string internal constant SPARK = "Spark";
    /// @dev `ProtocolIds.MORPHO` — shared by vaults and markets. "Morpho", never "Morpho Blue" (see CLAUDE.md).
    string internal constant MORPHO = "Morpho";
    /// @dev `ProtocolIds.EULER`.
    string internal constant EULER = "Euler";
    /// @dev `ProtocolIds.SYMBIOTIC`.
    string internal constant SYMBIOTIC = "Symbiotic";
    /// @dev `ProtocolIds.COMPOUND_V3`.
    string internal constant COMPOUND_V3 = "Compound V3";
    /// @dev `ProtocolIds.FLUID` — shared by fTokens and T1 vaults.
    string internal constant FLUID = "Fluid";
    /// @dev `ProtocolIds.GEARBOX_V3` — shared by markets and credit accounts.
    string internal constant GEARBOX_V3 = "Gearbox";
    /// @dev `ProtocolIds.CAP`.
    string internal constant CAP = "Cap";

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // AMMs / LP staking
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `ProtocolIds.BALANCER_V2` — shared by pools and gauges.
    string internal constant BALANCER_V2 = "Balancer V2";
    /// @dev `ProtocolIds.BALANCER_V3` — shared by pools and gauges.
    string internal constant BALANCER_V3 = "Balancer V3";
    /// @dev `ProtocolIds.CURVE` — shared by pools and gauges.
    string internal constant CURVE = "Curve";

    /// @dev `ProtocolIds.POLYGON` — Polygon PoS staking, settled on Ethereum L1.
    ///      Named for the PRODUCT ("Polygon Staking"), not the brand, because that is what the position is: the
    ///      chain is not the protocol here, and "Polygon" alone reads as a network row in a portfolio. Matches the
    ///      label DeBank uses and the product at https://staking.polygon.technology/.
    string internal constant POLYGON = "Polygon Staking";
    /// @dev `ProtocolIds.CONVEX`.
    string internal constant CONVEX = "Convex";
    /// @dev `ProtocolIds.UNISWAP_V2`.
    string internal constant UNISWAP_V2 = "Uniswap V2";
    /// @dev `ProtocolIds.UNISWAP_V3`.
    string internal constant UNISWAP_V3 = "Uniswap V3";
    /// @dev `ProtocolIds.PANCAKESWAP_V2`.
    string internal constant PANCAKESWAP_V2 = "PancakeSwap V2";
    /// @dev `ProtocolIds.PANCAKESWAP_V3`.
    string internal constant PANCAKESWAP_V3 = "PancakeSwap V3";

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Staking / LSTs / withdrawal queues
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `ProtocolIds.STAKEWISE_V3` — shared by the vaults meta-adapter and the exit-queue adapter.
    string internal constant STAKEWISE_V3 = "StakeWise V3";
    /// @dev `ProtocolIds.LIDO`.
    string internal constant LIDO = "Lido";
    /// @dev `ProtocolIds.KELP`.
    string internal constant KELP = "Kelp DAO";
    /// @dev `ProtocolIds.STADER`.
    string internal constant STADER = "Stader";
    /// @dev `ProtocolIds.ETHERFI` — lowercase is the protocol's own styling.
    string internal constant ETHERFI = "ether.fi";
    /// @dev `ProtocolIds.ETHENA`.
    string internal constant ETHENA = "Ethena";

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Other
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev `ProtocolIds.NEXUS_MUTUAL`.
    string internal constant NEXUS_MUTUAL = "Nexus Mutual";
    /// @dev `ProtocolIds.BRIDGE_ESCROW` — the destination bridge-escrow held-custody adapter (ADR 0027).
    string internal constant BRIDGE_ESCROW = "Bridge Escrow";

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // protocolId → display name
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a protocol id has no display name. Add the constant above and a branch below.
    error UnknownProtocolId(bytes32 protocolId);

    /// @notice The canonical display name for a `ProtocolIds` protocol id.
    /// @dev This is what makes "same `protocolId` ⇒ same `protocolName()`" true **by construction** rather than by
    ///      convention: `MetaBalanceAdapter.protocolName()` is `ProtocolNames.forProtocolId(_protocolId())`, so a
    ///      meta adapter cannot report a name that disagrees with its own typed identity — there is no separate
    ///      value to get wrong, and no deployment-time input to mis-supply. Adapters that hardcode their name
    ///      (the plain/assisted families) are pinned to the same table by `test/ProtocolNameConsistency.t.sol`.
    ///
    ///      Reverting on an unknown id is deliberate: the alternative — returning "" — would let a new meta adapter
    ///      deploy permanently nameless (adapters are immutable), and `protocolName()` is only ever reached through
    ///      NAVCalculator's fail-open staticcall, so a revert here degrades to an empty display name on a verbose
    ///      read rather than breaking a NAV read.
    /// @param protocolId The adapter's `ProtocolIds` protocol id (the middle taxonomy level).
    /// @return The display name every adapter under that protocol id must report.
    function forProtocolId(bytes32 protocolId) internal pure returns (string memory) {
        if (protocolId == ProtocolIds.AAVE_V3) return AAVE_V3;
        if (protocolId == ProtocolIds.MORPHO) return MORPHO;
        if (protocolId == ProtocolIds.SPARK) return SPARK;
        if (protocolId == ProtocolIds.EULER) return EULER;
        if (protocolId == ProtocolIds.SYMBIOTIC) return SYMBIOTIC;
        if (protocolId == ProtocolIds.COMPOUND_V3) return COMPOUND_V3;
        if (protocolId == ProtocolIds.FLUID) return FLUID;
        if (protocolId == ProtocolIds.GEARBOX_V3) return GEARBOX_V3;
        if (protocolId == ProtocolIds.CAP) return CAP;

        if (protocolId == ProtocolIds.BALANCER_V2) return BALANCER_V2;
        if (protocolId == ProtocolIds.BALANCER_V3) return BALANCER_V3;
        if (protocolId == ProtocolIds.CURVE) return CURVE;
        if (protocolId == ProtocolIds.CONVEX) return CONVEX;
        if (protocolId == ProtocolIds.UNISWAP_V2) return UNISWAP_V2;
        if (protocolId == ProtocolIds.UNISWAP_V3) return UNISWAP_V3;
        if (protocolId == ProtocolIds.PANCAKESWAP_V2) return PANCAKESWAP_V2;
        if (protocolId == ProtocolIds.PANCAKESWAP_V3) return PANCAKESWAP_V3;

        if (protocolId == ProtocolIds.STAKEWISE_V3) return STAKEWISE_V3;
        if (protocolId == ProtocolIds.POLYGON) return POLYGON;
        if (protocolId == ProtocolIds.LIDO) return LIDO;
        if (protocolId == ProtocolIds.KELP) return KELP;
        if (protocolId == ProtocolIds.STADER) return STADER;
        if (protocolId == ProtocolIds.ETHERFI) return ETHERFI;
        if (protocolId == ProtocolIds.ETHENA) return ETHENA;
        if (protocolId == ProtocolIds.NEXUS_MUTUAL) return NEXUS_MUTUAL;

        if (protocolId == ProtocolIds.BRIDGE_ESCROW) return BRIDGE_ESCROW;

        if (protocolId == ProtocolIds.WALLET) return WALLET;

        revert UnknownProtocolId(protocolId);
    }
}
