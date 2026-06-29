// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Canonical `protocolId` constants for every balance adapter family.
/// @dev Each constant is `keccak256` of a lowercase-ASCII, kebab-case slug that includes the
///      protocol version.  A single `protocolId` maps to exactly one `positionId` ABI-decode schema
///      — narrow enough that the client knows how to decode without runtime sniffing.
///
///      positionId schemas (all are `abi.encode(...)`):
///        WALLET                          → (address asset)
///        AAVE_V3_LENDING / SPARK_LEND    → (address pool) — one position per instance; reserve in balanceAsset
///        AAVE_V3_SAFETY_MODULE / UMBRELLA→ (address stakeToken) for BOTH staking legs (no discriminator);
///                                          isLocked=non-withdrawable splits them — active stake is LOCKED
///                                          (isLocked=true), only a cooldown elapsed-and-in-window is UNLOCKED;
///                                          the reward leg shares it too, told apart by positionKind=Rewards
///        MORPHO_VAULTS / GEARBOX_V3_MARKETS / GEARBOX_V3_CREDIT_ACCOUNTS / EULER_VAULTS / ERC4626 /
///        STAKEWISE_V3_VAULTS / FLUID_VAULTS → (address vault / market / credit account)
///        CAP                             → (address token: cUSD or stcUSD) — one leg per token
///        MORPHO_MARKETS                  → (bytes32 marketId)
///        BALANCER_V3_POOLS                → (address pool)
///        BALANCER_V3_GAUGES / V2_GAUGES                  → (address gauge)
///        CONVEX_CURVE_LP_STAKING                        → (address rewarder)
///        CURVE_POOLS                              → (address pool)
///        CURVE_GAUGES                             → (address gauge)
///        BALANCER_V2_POOLS                → (bytes32 poolId)
///        UNISWAP_V3 / PANCAKESWAP_V3     → (address pool); NFT tokenId in positionInstanceId (bytes32(tokenId))
///        UNISWAP_V2 / PANCAKESWAP_V2     → (address pair)
///        COMPOUND_V3_COMETS / FLUID_FTOKENS     → (address market)
///        MERKL                           → (address distributor) — reward token is in balanceAsset, not positionId
///        NEXUS_MUTUAL_STAKING_POOLS      → (address stakingPool); StakingNFT tokenId in positionInstanceId
///        STADER_WITHDRAWAL              → (address userWithdrawalManager) — static coordinate
///        KELP_WITHDRAWAL                → (address withdrawalManager)     — static coordinate; payout asset in balanceAsset
///        LIDO_WITHDRAWAL                → (address withdrawalQueue)        — static coordinate
///        ETHENA_COOLDOWN                → (address sUSDe)                  — static coordinate
///        ETHERFI_WITHDRAWAL             → (address withdrawRequestNFT)     — static coordinate
///        STAKEWISE_V3_EXIT              → (address vault)                 — static, per vault
///          (for these: a static positionId with up to two legs — claimable (isLocked=false) + locked
///           (isLocked=true) — sharing it, told apart by isLocked; owed asset is in balanceAsset. isLocked
///           is part of the identity key. See docs/decisions/0016-islocked-position-status.md.)
///        BRIDGE_ESCROW                   → (address escrow, address token)
/// @author KPK
library ProtocolIds {
    bytes32 internal constant WALLET = keccak256("wallet");

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Brand ids — the broadest `PositionBalance.protocolBrand` layer (the protocol brand, version-stripped). Several
    // ecosystem ids roll up to one brand: AAVE_V3 → AAVE; BALANCER_V2 + BALANCER_V3 → BALANCER; UNISWAP_V2 +
    // UNISWAP_V3 → UNISWAP; etc. For unversioned protocols the brand equals the ecosystem id (CURVE, MORPHO, FLUID,
    // EULER, LIDO, KELP, …) — those reuse the same constant; only the versioned brands need a dedicated constant here.
    // Display/grouping only; NOT part of the stable identity key (that uses `protocolSubId`).
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    bytes32 internal constant AAVE = keccak256("aave");
    bytes32 internal constant BALANCER = keccak256("balancer");
    bytes32 internal constant UNISWAP = keccak256("uniswap");
    bytes32 internal constant PANCAKESWAP = keccak256("pancakeswap");
    bytes32 internal constant GEARBOX = keccak256("gearbox");
    bytes32 internal constant STAKEWISE = keccak256("stakewise");
    bytes32 internal constant COMPOUND = keccak256("compound");

    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    // Ecosystem ids — the broad `PositionBalance.protocolId` (grouping / roll-up layer). Several per-product slugs
    // below (the `protocolSubId`s) roll up to one of these, e.g. AAVE_V3_LENDING + AAVE_V3_SAFETY_MODULE + AAVE_V3_UMBRELLA
    // → AAVE_V3. For single-product ecosystems the adapter uses the SAME constant for both protocolId and protocolSubId
    // (e.g. CONVEX, UNISWAP_V3, CAP, MERKL, WALLET, ERC4626, CURVE) — no separate ecosystem constant needed.
    // The version is kept in the ecosystem id where the protocol is a distinct system (aave-v3, balancer-v2/-v3,
    // uniswap-v2/-v3), so different versions are different `protocolId`s. NOT part of the stable identity key — that
    // uses `protocolSubId`. See INAVCalculator.PositionBalance.
    // ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
    bytes32 internal constant AAVE_V3 = keccak256("aave-v3");
    bytes32 internal constant GEARBOX_V3 = keccak256("gearbox-v3");
    bytes32 internal constant STAKEWISE_V3 = keccak256("stakewise-v3");
    bytes32 internal constant MORPHO = keccak256("morpho");
    bytes32 internal constant BALANCER_V2 = keccak256("balancer-v2");
    bytes32 internal constant BALANCER_V3 = keccak256("balancer-v3");
    bytes32 internal constant FLUID = keccak256("fluid");
    bytes32 internal constant EULER = keccak256("euler");
    bytes32 internal constant LIDO = keccak256("lido");
    bytes32 internal constant KELP = keccak256("kelp");
    bytes32 internal constant STADER = keccak256("stader");
    bytes32 internal constant ETHERFI = keccak256("etherfi");
    bytes32 internal constant ETHENA = keccak256("ethena");
    bytes32 internal constant SPARK = keccak256("spark");
    bytes32 internal constant NEXUS_MUTUAL = keccak256("nexus-mutual");
    // (CURVE below doubles as the Curve ecosystem id for CURVE_POOLS/CURVE_GAUGES.)

    // ── Per-product slugs (`protocolSubId`; selects the positionId decode schema) ──

    // Aave family
    bytes32 internal constant AAVE_V3_LENDING = keccak256("aave-v3-lending");
    bytes32 internal constant AAVE_V3_SAFETY_MODULE = keccak256("aave-v3-safety-module");
    bytes32 internal constant AAVE_V3_UMBRELLA = keccak256("aave-v3-umbrella");

    // Morpho
    bytes32 internal constant MORPHO_VAULTS = keccak256("morpho-vaults");
    bytes32 internal constant MORPHO_MARKETS = keccak256("morpho-markets");

    // Balancer
    bytes32 internal constant BALANCER_V3_POOLS = keccak256("balancer-v3-pools");
    bytes32 internal constant BALANCER_V3_GAUGES = keccak256("balancer-v3-gauges");
    bytes32 internal constant BALANCER_V2_POOLS = keccak256("balancer-v2-pools");
    bytes32 internal constant BALANCER_V2_GAUGES = keccak256("balancer-v2-gauges");

    // Uniswap / PancakeSwap
    bytes32 internal constant UNISWAP_V3 = keccak256("uniswap-v3");
    bytes32 internal constant UNISWAP_V2 = keccak256("uniswap-v2");
    bytes32 internal constant PANCAKESWAP_V3 = keccak256("pancakeswap-v3");
    bytes32 internal constant PANCAKESWAP_V2 = keccak256("pancakeswap-v2");

    // StakeWise
    bytes32 internal constant STAKEWISE_V3_VAULTS = keccak256("stakewise-v3-vaults");

    // Nexus Mutual
    bytes32 internal constant NEXUS_MUTUAL_STAKING_POOLS = keccak256("nexus-mutual-staking-pools");

    // Gearbox
    bytes32 internal constant GEARBOX_V3_MARKETS = keccak256("gearbox-v3-markets");
    bytes32 internal constant GEARBOX_V3_CREDIT_ACCOUNTS = keccak256("gearbox-v3-credit-accounts");

    // Euler
    bytes32 internal constant EULER_VAULTS = keccak256("euler-vaults");

    // Compound
    bytes32 internal constant COMPOUND_V3 = keccak256("compound-v3");
    bytes32 internal constant COMPOUND_V3_COMETS = keccak256("compound-v3-comets");

    // Fluid
    bytes32 internal constant FLUID_FTOKENS = keccak256("fluid-ftokens");
    bytes32 internal constant FLUID_VAULTS = keccak256("fluid-vaults");

    // Spark
    bytes32 internal constant SPARK_LEND = keccak256("spark-lend");

    // Curve / Convex
    bytes32 internal constant CURVE = keccak256("curve"); // Curve ecosystem id (protocolId for CURVE_POOLS/CURVE_GAUGES)
    bytes32 internal constant CURVE_POOLS = keccak256("curve-pools"); // wallet LP → (address pool)
    bytes32 internal constant CURVE_GAUGES = keccak256("curve-gauges"); // gauge-staked LP → (address gauge)
    bytes32 internal constant CONVEX = keccak256("convex");
    bytes32 internal constant CONVEX_CURVE_LP_STAKING = keccak256("convex-curve-lp-staking");

    // Cap
    bytes32 internal constant CAP = keccak256("cap");

    // Generic ERC4626 wrapper
    bytes32 internal constant ERC4626 = keccak256("erc4626");

    // Withdrawal / cooldown queues
    // positionId = `abi.encode(<anchor contract>)` (the queue/manager — Lido queue, Stader/Kelp
    // manager, ether.fi NFT, StakeWise vault, sUSDe). Up to two legs share it, told apart by
    // isLocked (the owed/payout asset is in balanceAsset, not the positionId).
    bytes32 internal constant STADER_WITHDRAWAL = keccak256("stader-withdrawal");
    bytes32 internal constant KELP_WITHDRAWAL = keccak256("kelp-withdrawal");
    bytes32 internal constant LIDO_WITHDRAWAL = keccak256("lido-withdrawal");
    bytes32 internal constant ETHENA_COOLDOWN = keccak256("ethena-cooldown");
    bytes32 internal constant ETHERFI_WITHDRAWAL = keccak256("etherfi-withdrawal");
    bytes32 internal constant STAKEWISE_V3_EXIT = keccak256("stakewise-v3-exit");

    // Merkl rewards distributor
    bytes32 internal constant MERKL = keccak256("merkl");

    // Bridge escrow
    bytes32 internal constant BRIDGE_ESCROW = keccak256("bridge-escrow");
}
