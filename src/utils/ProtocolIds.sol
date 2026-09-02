// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @notice Canonical protocol-taxonomy constants — `protocolBrand`, `protocolId`, and `protocolSubId`
///         — for every balance adapter family.
/// @dev Each constant is `keccak256` of a lowercase-ASCII, kebab-case slug; the protocol version is
///      baked into the slug only where the protocol is a distinct versioned system (e.g. `aave-v3`,
///      `balancer-v2`/`-v3`), so unversioned protocols carry no version.  A single `protocolSubId`
///      maps to exactly one `positionId` ABI-decode schema — narrow enough that the client knows how
///      to decode without runtime sniffing.
///
///      positionId schemas (all are `abi.encode(...)`):
///        WALLET                          → (address asset)
///        AAVE_V3_LENDING / SPARK_LEND    → (address pool) — one position per instance; reserve in balanceAsset
///        AAVE_V3_SAFETY_MODULE / UMBRELLA→ (address stakeToken) for BOTH staking legs (no discriminator);
///                                          isLocked=non-withdrawable splits them — active stake is LOCKED
///                                          (isLocked=true), only a cooldown elapsed-and-in-window is UNLOCKED;
///                                          the reward leg shares it too, told apart by positionKind=Rewards
///        MORPHO_VAULTS / GEARBOX_V3_MARKETS / GEARBOX_V3_CREDIT_ACCOUNTS / EULER_VAULTS / ERC4626 /
///        STAKEWISE_V3_VAULTS / FLUID_VAULTS / SYMBIOTIC_VAULTS → (address vault / market / credit account)
///        CAP                             → (address token: cUSD or stcUSD) — one leg per token
///        MORPHO_MARKETS                  → (bytes32 marketId)
///        BALANCER_V3_POOLS                → (address pool)
///        BALANCER_V3_GAUGES / V2_GAUGES                  → (address gauge)
///        CONVEX_CURVE_LP_STAKING                        → (address rewarder)
///        CURVE_POOLS                              → (address pool)
///        POLYGON_STAKING                          → (address validatorShare) — ONE positionId, two legs
///                                                    (Staking principal + Rewards) told apart by positionKind
///        CURVE_GAUGES                             → (address gauge)
///        BALANCER_V2_POOLS                → (bytes32 poolId)
///        UNISWAP_V3 / PANCAKESWAP_V3     → (address pool); NFT tokenId in positionInstanceId (bytes32(tokenId))
///        UNISWAP_V2 / PANCAKESWAP_V2     → (address pair)
///        COMPOUND_V3_COMETS / FLUID_FTOKENS     → (address comet / fToken)
///        MERKL                           → (address distributor) — reward token is in balanceAsset, not positionId
///        NEXUS_MUTUAL_STAKING_POOLS      → (address stakingPool); StakingNFT tokenId in positionInstanceId
///        STADER_WITHDRAWAL              → (address userWithdrawalManager) — static coordinate
///        KELP_WITHDRAWAL                → (address withdrawalManager)     — static coordinate; payout asset in balanceAsset
///        LIDO_WITHDRAWAL                → (address withdrawalQueue)        — static coordinate
///        ETHENA_COOLDOWN                → (address sUSDe)                  — static coordinate
///        ETHERFI_WITHDRAWAL             → (address withdrawRequestNFT)     — static coordinate
///        LIDO_STAKED_ETH                → (address token: wstETH | stETH)  — wallet-held, one leg per token
///        ETHERFI_STAKED_ETH             → (address token: eETH | weETH)
///        ROCKET_POOL_STAKED_ETH         → (address token: rETH)
///        RENZO_RESTAKED_ETH             → (address token: ezETH)
///        KELP_RESTAKED_ETH              → (address token: rsETH)
///        STADER_STAKED_ETH              → (address token: ETHx)
///        STAKEWISE_V3_OS_TOKENS         → (address token: osETH | osGNO)
///        LIQUID_COLLECTIVE_STAKED_ETH   → (address token: lsETH)
///        ANKR_STAKED_ETH                → (address token: ankrETH)
///        COINBASE_STAKED_ETH            → (address token: cbETH)
///        RESERVE_BASKETS                → (address token: ETH+)
///        ETHENA_SAVINGS                 → (address token: sUSDe)
///        SKY_SAVINGS                    → (address token: sDAI | sUSDS)
///        AAVE_V3_SAVINGS                → (address token: sGHO)
///        SPARK_SAVINGS                  → (address token: spUSDC | spUSDT | spETH)
///        MAPLE_SAVINGS                  → (address token: syrupUSDC)
///        NEXUS_MUTUAL_VAULTS            → (address token: RWIV)
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
    // (e.g. UNISWAP_V3, CAP, MERKL, WALLET, ERC4626) — no separate ecosystem constant needed. (CONVEX and CURVE keep
    // distinct per-product subIds — CONVEX_CURVE_LP_STAKING, CURVE_POOLS/CURVE_GAUGES — so for them protocolId differs
    // from protocolSubId even though they roll up to the CONVEX/CURVE ecosystem id.)
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
    bytes32 internal constant SYMBIOTIC = keccak256("symbiotic");
    bytes32 internal constant LIDO = keccak256("lido");
    bytes32 internal constant POLYGON = keccak256("polygon"); // Polygon ecosystem id; unversioned, so this is also the brand
    bytes32 internal constant KELP = keccak256("kelp");
    bytes32 internal constant STADER = keccak256("stader");
    bytes32 internal constant ETHERFI = keccak256("etherfi");
    bytes32 internal constant ETHENA = keccak256("ethena");
    bytes32 internal constant SPARK = keccak256("spark");
    bytes32 internal constant ROCKET_POOL = keccak256("rocket-pool");
    bytes32 internal constant RENZO = keccak256("renzo");
    bytes32 internal constant LIQUID_COLLECTIVE = keccak256("liquid-collective");
    bytes32 internal constant ANKR = keccak256("ankr");
    bytes32 internal constant COINBASE = keccak256("coinbase");
    bytes32 internal constant RESERVE = keccak256("reserve");
    bytes32 internal constant SKY = keccak256("sky");
    bytes32 internal constant MAPLE = keccak256("maple");
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

    // Polygon PoS staking (Ethereum L1 StakeManager / ValidatorShare)
    bytes32 internal constant POLYGON_STAKING = keccak256("polygon-staking"); // delegation → (address validatorShare)

    // Nexus Mutual
    bytes32 internal constant NEXUS_MUTUAL_STAKING_POOLS = keccak256("nexus-mutual-staking-pools");

    // Gearbox
    bytes32 internal constant GEARBOX_V3_MARKETS = keccak256("gearbox-v3-markets");
    bytes32 internal constant GEARBOX_V3_CREDIT_ACCOUNTS = keccak256("gearbox-v3-credit-accounts");

    // Euler
    bytes32 internal constant EULER_VAULTS = keccak256("euler-vaults");

    // Symbiotic
    bytes32 internal constant SYMBIOTIC_VAULTS = keccak256("symbiotic-vaults");

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

    // Wallet-held yield-bearing tokens (WalletTokenMetaBalanceAdapterBase family). The token is itself the
    // registered, priced NAV asset, so every positionId here is `abi.encode(address token)` and the
    // balanceAsset is that same token. One subId per PROTOCOL, not per token: several tokens share a subId
    // (wstETH + stETH under Lido) because they are the same product, and the positionId separates them.
    bytes32 internal constant LIDO_STAKED_ETH = keccak256("lido-staked-eth");
    bytes32 internal constant ETHERFI_STAKED_ETH = keccak256("etherfi-staked-eth");
    bytes32 internal constant ROCKET_POOL_STAKED_ETH = keccak256("rocket-pool-staked-eth");
    bytes32 internal constant RENZO_RESTAKED_ETH = keccak256("renzo-restaked-eth");
    bytes32 internal constant KELP_RESTAKED_ETH = keccak256("kelp-restaked-eth");
    bytes32 internal constant STADER_STAKED_ETH = keccak256("stader-staked-eth");
    bytes32 internal constant STAKEWISE_V3_OS_TOKENS = keccak256("stakewise-v3-os-tokens");
    bytes32 internal constant LIQUID_COLLECTIVE_STAKED_ETH = keccak256("liquid-collective-staked-eth");
    bytes32 internal constant ANKR_STAKED_ETH = keccak256("ankr-staked-eth");
    bytes32 internal constant COINBASE_STAKED_ETH = keccak256("coinbase-staked-eth");
    bytes32 internal constant RESERVE_BASKETS = keccak256("reserve-baskets");
    bytes32 internal constant ETHENA_SAVINGS = keccak256("ethena-savings");
    bytes32 internal constant SKY_SAVINGS = keccak256("sky-savings");
    bytes32 internal constant AAVE_V3_SAVINGS = keccak256("aave-v3-savings");
    bytes32 internal constant SPARK_SAVINGS = keccak256("spark-savings");
    bytes32 internal constant MAPLE_SAVINGS = keccak256("maple-savings");
    bytes32 internal constant NEXUS_MUTUAL_VAULTS = keccak256("nexus-mutual-vaults");
    bytes32 internal constant STAKEWISE_V3_EXIT = keccak256("stakewise-v3-exit");

    // Merkl rewards distributor
    bytes32 internal constant MERKL = keccak256("merkl");

    // Bridge escrow
    bytes32 internal constant BRIDGE_ESCROW = keccak256("bridge-escrow");
}
