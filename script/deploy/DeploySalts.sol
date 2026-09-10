// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8;

/// @title DeploySalts
/// @author kpk
/// @notice Single source of truth for the CREATE2 salt *versions* used to derive the deterministic
///         placeholder/proxy/implementation addresses. The canonical addresses must be identical on every chain
///         AND across both deploy paths — the full path (`01_DeployImplementations` + `02_DeployProxies` +
///         `AtomicProxyDeployer`) and the NAV-only path (`01_2_DeployNAVImplementation` + `02_2_DeployNAVProxy` +
///         `AtomicNAVProxyDeployer`). They only stay identical if every file that derives a given salt uses the
///         SAME version.
/// @dev These versions used to be hand-written literals scattered across six files; they drifted (the proxy
///      layer was `2` in the full path but `3` in the NAV-only path), which would have produced a *different*
///      NAVCalculator proxy address depending on which script deployed a chain — silently breaking the
///      "same canonical address on every chain" guarantee. Centralizing them here makes that drift impossible:
///      a version bump (e.g. to dodge a front-run) is one edit that updates every deriving site at once.
///
///      Pure constants only (no cheatcodes / no Vm), so this is safe to import into the on-chain atomic deployer
///      CONTRACTS as well as the forge scripts. Each contract's salt string is its name; the salt is
///      `keccak256(abi.encodePacked(name, version))` — identical whether derived via `ConfigReader.computeSalt`
///      (scripts) or inline (atomic deployers).
///
///      NOTE: the external-library salts (`PriceFeedLib`, `NAVRegistryLib`, both version 1) are intentionally
///      NOT centralized here — their addresses are separately pinned in `foundry.toml`/`LibraryPins.sol`, so
///      bumping them must be done in lockstep with a pin regeneration and is deliberately kept local to the
///      implementation scripts to avoid implying they are freely bumpable.
library DeploySalts {
    /// @notice Placeholder UUPS implementation the proxies are CREATE2-deployed against (then upgraded).
    ///         Used by all four proxy-deploy files; feeds every proxy's bytecode, so it must be unified.
    uint256 internal constant PLACEHOLDER_IMPL = 3;

    /// @notice NAVCalculator UUPS proxy salt. Used by 02_DeployProxies, 02_2_DeployNAVProxy, and both atomic deployers.
    uint256 internal constant NAV_PROXY = 7;

    /// @notice BridgeEscrow UUPS proxy salt. Used by the full path (02_DeployProxies + AtomicProxyDeployer).
    uint256 internal constant BRIDGE_PROXY = 3;

    /// @notice NAVCalculator implementation salt. Used by 01_DeployImplementations and 01_2_DeployNAVImplementation.
    uint256 internal constant NAV_IMPL = 3;

    /// @notice `AssetKindRegistry` salt. Used by 08_DeployAssetKindRegistry.
    /// @dev **Version 2, not 1, and the reason is the whole point of this constant.** The 2026-08-18 deploy created
    ///      the registry with a plain `new AssetKindRegistry(nav)` — CREATE, not CREATE2 — so its address followed the
    ///      deployer's nonce and came out DIFFERENT on 14 of the 24 chains, with a few chains colliding on one address
    ///      purely because their nonces matched. That collision is not harmless: an address-keyed map of
    ///      (address -> contract) built from the broadcast artifacts mislabels those registries as whatever contract
    ///      shares the address on another chain, which is exactly how five of them were mis-verified.
    ///
    ///      Version 1 is deliberately skipped so the CREATE2 address cannot be confused with any first-generation
    ///      registry, and so a future reader sees at a glance that generation 1 was not CREATE2-derived at all.
    ///      The constructor takes only `nav`, and the NAV proxy is itself CREATE2-identical on every chain, so the
    ///      init-code hash is identical fleet-wide and this salt yields ONE address everywhere.
    uint256 internal constant ASSET_KIND_REGISTRY = 2;

    //
    // NAV-only balance adapters (CREATE2 same-address across chains)
    //
    // These adapters take the NAV proxy as their ONLY constructor argument. The NAV proxy is itself
    // CREATE2-identical fleet-wide, so each adapter's init-code hash is the same on every chain and one salt
    // yields ONE address everywhere — the same property that lets `ASSET_KIND_REGISTRY` above collapse to a
    // single address. Adapters whose constructor takes a chain-specific protocol address (Morpho's `morpho`,
    // SparkLend's `dataProvider`, Compound's `compoundRewards`, …) are deliberately NOT here: their init code
    // genuinely differs per chain, so CREATE2 could not give them one address and plain CREATE is correct.
    //
    // **Version 2, not 1, for the same reason as the registry.** Generation 1 of each of these was deployed
    // with plain `new` (CREATE), so its address followed the deployer's nonce and differed on every chain.
    // Skipping version 1 keeps the numbering aligned with `ASSET_KIND_REGISTRY` and signals at a glance that
    // generation 1 was not CREATE2-derived. Bumping one of these re-derives that adapter's address on every
    // chain at once — which means a redeploy AND a re-registration on the NAV, since the NAV's balance-adapter
    // set and each meta-adapter's instance set are keyed by adapter ADDRESS.
    uint256 internal constant AAVE_V3_INSTANCES_META = 2;
    /// @dev **Version 1, not 2, and that is not an oversight.** Every constant around it skips version 1 because
    ///      generation 1 of that adapter was deployed with plain `new` (CREATE), so 1 would name a nonce-derived
    ///      address. `AaveV4SpokesMeta` has no generation 1: it was CREATE2 from birth (mainnet
    ///      `0x79cad958...`, deployed 2026-09-08 by the canonical deployer), so version 1 is its FIRST
    ///      generation and bumping it to 2 would move the live address. Do not "align" it with its neighbours.
    uint256 internal constant AAVE_V4_SPOKES_META = 1;
    uint256 internal constant AAVE_V3_SAFETY_MODULE = 2;
    uint256 internal constant BALANCER_V3_POOLS_META = 2;
    uint256 internal constant CURVE_POOLS_META = 2;
    uint256 internal constant EULER_VAULTS_META = 2;
    uint256 internal constant FLUID_FTOKENS_META = 2;
    uint256 internal constant GEARBOX_V3_MARKETS_META = 2;
    uint256 internal constant MORPHO_VAULTS_META = 2;
    uint256 internal constant PANCAKESWAP_V2_POOLS_META = 2;
    uint256 internal constant SYMBIOTIC_VAULTS_META = 2;
    uint256 internal constant UNISWAP_V2_POOLS_META = 2;

    //
    // Meta adapters taking ONE chain-specific protocol address (CREATE2 — same address wherever that
    // address is the same)
    //
    // These take `(protocolAddress, navCalculator)`. The NAV proxy is CREATE2-identical fleet-wide, so the
    // init-code hash is a pure function of the protocol address — identical on every chain where the protocol
    // lives at the same address, and legitimately different where it does not. That is a WEAKER guarantee than
    // the NAV-only group above, and the difference is the whole reason these carry their own section:
    //
    //   * `UniswapV3PoolsMeta` — the NonfungiblePositionManager is `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`
    //     on Ethereum, Optimism, Polygon and Arbitrum (verified by `name()` + `factory()`, not by codehash: the
    //     NPM bakes `factory`/`WETH9` into immutables, so identical contracts hash differently per chain). Several
    //     other chains have unrelated code AT that address — Base's real NPM is elsewhere — so a same-address
    //     deploy there would bind the adapter to a foreign contract. Never assume; re-check `name()` per chain.
    //
    //   * `MorphoMarketsMeta` — Morpho is at `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` on Ethereum and Base
    //     (same `owner()`, so the same governance), but Arbitrum deployed later at
    //     `0x6c247b1F6182318877311737BaC0844bAa518F5e`. Ethereum and Base therefore SHARE one adapter address
    //     while Arbitrum gets its own — still deterministic and pre-computable, just not fleet-wide.
    //
    // **Version 2, not 1**, matching the groups above: generation 1 was plain CREATE, so skipping 1 keeps a
    // CREATE2 address from ever being confused with a nonce-derived one. Bumping either re-derives that
    // adapter's address on every chain at once — a redeploy AND a NAV re-registration, since the balance-adapter
    // set and each meta-adapter's instance set are keyed by adapter ADDRESS.
    //   * `FluidVaultsMeta` — Fluid's VaultResolver is at `0xa5c3e16523eeEDdCC34706b0e6be88b4C6Ea95cC` on
    //     Ethereum, BNB, Polygon, Base, Plasma and Arbitrum (verified by calling `FACTORY()` and
    //     `getAllVaultsAddresses()` — same factory `0x324c5Dc1…`, real per-chain vault sets). Fluid deploys its
    //     resolver deterministically, so this adapter is one address across all six.
    uint256 internal constant UNISWAP_V3_POOLS_META = 2;
    uint256 internal constant MORPHO_MARKETS_META = 2;
    uint256 internal constant FLUID_VAULTS_META = 2;

    //
    // Attested balance adapters (ADR 0022) — CREATE2 same-address across chains
    //
    // `MerklRewardsAttestedBalanceAdapter` takes (distributor, navCalculator, admin), and all three are
    // fleet-identical, which is what makes ONE address possible for a protocol-arg adapter:
    //   * distributor — Merkl deploys its Distributor deterministically at
    //     `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`. VERIFIED by `eth_getCode` on every chain in this repo:
    //     present on 24 of 25 (absent only on opBNB/204, which therefore cannot carry this adapter).
    //   * navCalculator — the NAV proxy is CREATE2-identical at `0x54EaD2A1…` on 24 of 25 (absent on
    //     polygon-zkevm/1101, which has no deployment at all).
    //   * admin — the deployer EOA, read from `DEPLOYER_EOA`, identical across chains.
    // The canonical CREATE2 deployer was likewise verified present on all 23 chains in the intersection.
    //
    // ⚠️ The admin is a CONSTRUCTOR ARG, so it is part of the init code and therefore part of the address.
    // Deploying from a different `DEPLOYER_EOA`, or handing admin to the security council at construction
    // instead, yields a DIFFERENT address on that chain. Hand over the admin ROLE post-deploy
    // (`grantRole`/`renounceRole`) rather than by changing this argument.
    uint256 internal constant MERKL_REWARDS = 1;

    //
    // Bridge adapters (ADR 0012, D7 — CREATE2 same-address across chains)
    //
    // Each bridge adapter is a plain (non-proxied) AccessControl contract deployed via the canonical CREATE2
    // deployer in 05_DeployBridgeAdapters. Adapters take their constructor args via `initialize(...)` (not the
    // constructor), so their creation bytecode carries no per-chain arguments and the same salt yields the SAME
    // address on every chain. That same-address guarantee is what `trustedRemoteAdapter` (D2) and the CCTP
    // `mintRecipient`/`destinationCaller` + Superchain `receiver` assumptions rely on, so these salts MUST stay
    // identical across the 7 target chains (1, 10, 100, 137, 42161, 56, 8453). Bumping a version (e.g. to dodge a
    // front-run of the deterministic address) re-derives that adapter's address on every chain at once.
    uint256 internal constant CCIP_ADAPTER = 1;
    uint256 internal constant ACROSS_ADAPTER = 1;
    uint256 internal constant STARGATE_ADAPTER = 1;
    uint256 internal constant GNOSIS_ADAPTER = 1;
    uint256 internal constant CCTP_ADAPTER = 1;
    uint256 internal constant SUPERCHAIN_ADAPTER = 1;
}
