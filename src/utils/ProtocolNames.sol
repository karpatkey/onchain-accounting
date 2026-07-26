// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

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
///      Meta adapters take their name as a constructor argument (`MetaBalanceAdapter._protocolName`), so their name
///      is a *deployment-time* value that no source sweep can audit. The deploy layer therefore resolves it from
///      these same constants via `script/utils/ProtocolNameResolver.sol` rather than from a per-call-site literal.
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
}
