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
///        MORPHO_VAULTS / GEARBOX_V3 / EULER_VAULTS / ERC4626 / STAKEWISE_V3 / FLUID_VAULTS → (address vault)
///        CAP                             → (address token: cUSD or stcUSD) — one leg per token
///        MORPHO_MARKETS                  → (bytes32 marketId)
///        BALANCER_V3_POOL                → (address pool)
///        BALANCER_V3_GAUGE / V2_GAUGE                  → (address gauge)
///        CONVEX                                         → (address rewarder)
///        CURVE_POOL                              → (address pool)
///        CURVE_GAUGE                             → (address gauge)
///        BALANCER_V2_POOL                → (bytes32 poolId)
///        UNISWAP_V3 / PANCAKESWAP_V3     → (address npm, uint256 tokenId)
///        UNISWAP_V2 / PANCAKESWAP_V2     → (address pair)
///        COMPOUND_V3 / FLUID_FTOKENS     → (address market)
///        MERKL                           → (address distributor) — reward token is in balanceAsset, not positionId
///        NEXUS_MUTUAL_STAKING            → (uint256 tokenId, uint256 poolId)
///        STADER_WITHDRAWAL              → (address userWithdrawalManager) — static coordinate
///        KELP_WITHDRAWAL                → (address withdrawalManager)     — static coordinate; payout asset in balanceAsset
///        LIDO_WITHDRAWAL                → (address withdrawalQueue)        — static coordinate
///        ETHENA_COOLDOWN                → (address sUSDe)                  — static coordinate
///        ETHERFI_WITHDRAWAL             → (address withdrawRequestNFT)     — static coordinate
///        STAKEWISE_EXIT                 → (address vault)                 — static, per vault
///          (for these: a static positionId with up to two legs — claimable (isLocked=false) + locked
///           (isLocked=true) — sharing it, told apart by isLocked; owed asset is in balanceAsset. isLocked
///           is part of the identity key. See docs/decisions/0016-islocked-position-status.md.)
///        BRIDGE_ESCROW                   → (address escrow, address token)
/// @author KPK
library ProtocolIds {
    bytes32 internal constant WALLET = keccak256("wallet");

    // Aave family
    bytes32 internal constant AAVE_V3_LENDING = keccak256("aave-v3-lending");
    bytes32 internal constant AAVE_V3_SAFETY_MODULE = keccak256("aave-v3-safety-module");
    bytes32 internal constant AAVE_V3_UMBRELLA = keccak256("aave-v3-umbrella");

    // Morpho
    bytes32 internal constant MORPHO_VAULTS = keccak256("morpho-vaults");
    bytes32 internal constant MORPHO_MARKETS = keccak256("morpho-markets");

    // Balancer
    bytes32 internal constant BALANCER_V3_POOL = keccak256("balancer-v3-pool");
    bytes32 internal constant BALANCER_V3_GAUGE = keccak256("balancer-v3-gauge");
    bytes32 internal constant BALANCER_V2_POOL = keccak256("balancer-v2-pool");
    bytes32 internal constant BALANCER_V2_GAUGE = keccak256("balancer-v2-gauge");

    // Uniswap / PancakeSwap
    bytes32 internal constant UNISWAP_V3 = keccak256("uniswap-v3");
    bytes32 internal constant UNISWAP_V2 = keccak256("uniswap-v2");
    bytes32 internal constant PANCAKESWAP_V3 = keccak256("pancakeswap-v3");
    bytes32 internal constant PANCAKESWAP_V2 = keccak256("pancakeswap-v2");

    // StakeWise
    bytes32 internal constant STAKEWISE_V3 = keccak256("stakewise-v3");

    // Nexus Mutual
    bytes32 internal constant NEXUS_MUTUAL_STAKING = keccak256("nexus-mutual-staking");

    // Gearbox
    bytes32 internal constant GEARBOX_V3 = keccak256("gearbox-v3");

    // Euler
    bytes32 internal constant EULER_VAULTS = keccak256("euler-vaults");

    // Compound
    bytes32 internal constant COMPOUND_V3 = keccak256("compound-v3");

    // Fluid
    bytes32 internal constant FLUID_FTOKENS = keccak256("fluid-ftokens");
    bytes32 internal constant FLUID_VAULTS = keccak256("fluid-vaults");

    // Spark
    bytes32 internal constant SPARK_LEND = keccak256("spark-lend");

    // Curve / Convex
    bytes32 internal constant CURVE = keccak256("curve"); // per-instance adapter (legacy)
    bytes32 internal constant CURVE_POOL = keccak256("curve-pool"); // wallet LP → (address pool)
    bytes32 internal constant CURVE_GAUGE = keccak256("curve-gauge"); // gauge-staked LP → (address gauge)
    bytes32 internal constant CONVEX = keccak256("convex");

    // Cap
    bytes32 internal constant CAP = keccak256("cap");

    // Generic ERC4626 wrapper
    bytes32 internal constant ERC4626 = keccak256("erc4626");

    // Withdrawal / cooldown queues
    // positionId = `abi.encode(<anchor contract>)` (the queue/manager — Lido queue, Stader/Kelp
    // manager, ether.fi NFT, StakeWise registry, sUSDe). Up to two legs share it, told apart by
    // isLocked (the owed/payout asset is in balanceAsset, not the positionId).
    bytes32 internal constant STADER_WITHDRAWAL = keccak256("stader-withdrawal");
    bytes32 internal constant KELP_WITHDRAWAL = keccak256("kelp-withdrawal");
    bytes32 internal constant LIDO_WITHDRAWAL = keccak256("lido-withdrawal");
    bytes32 internal constant ETHENA_COOLDOWN = keccak256("ethena-cooldown");
    bytes32 internal constant ETHERFI_WITHDRAWAL = keccak256("etherfi-withdrawal");
    bytes32 internal constant STAKEWISE_EXIT = keccak256("stakewise-exit");

    // Merkl rewards distributor
    bytes32 internal constant MERKL = keccak256("merkl");

    // Bridge escrow
    bytes32 internal constant BRIDGE_ESCROW = keccak256("bridge-escrow");
}
