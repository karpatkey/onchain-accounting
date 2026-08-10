# 0011 — NAVCalculator size headroom + shared adapter/feed abstractions

Status: accepted (introduced with PR A — the ERC20DefaultBalanceAdapter externalization; PRs B/C are follow-ups, now partially landed — `BaseCustomPriceFeed`, `StaticCallLib`, `ArrayLib`, and the `BalanceAdapterBase`/`SingleAssetBalanceAdapterBase` leaf bases have shipped; the wider `_getAssetInfo`/StaticCallLib de-duplication has not)

## Context

`NAVCalculator` is the one size-constrained contract in this repo: it is the UUPS
implementation behind the proxy, so its **runtime** bytecode must stay under the EIP-170
24,576-byte limit (CI enforces it via `forge build --sizes`). Everything else either
deploys standalone (balance adapters, custom price feeds — each its own contract, plain
CREATE) or is an external library (PriceFeedLib, NAVRegistryLib — separate bytecode,
DELEGATECALL). [ADR 0010](0010-meta-balance-adapters.md) already moved the read/compute
engine and registry mutations into those libraries; after that work NAVCalculator measured
**21,403 B** — only 3,173 B (13%) of headroom.

A review of where the remaining bytecode comes from found three classes of opportunity:

1. **NAVCalculator inherits `Prices` + `Balances`**, so their code is compiled into its
   bytecode — but both are now almost entirely thin wrappers over the external libs, so
   there is little left to extract there.
2. **`NAVCalculator.initialize` ran `new ERC20DefaultBalanceAdapter(...)`.** A `new X()` embeds
   `X`'s entire *creation* bytecode into the contract that contains the `new`. Because
   `initialize` is a runtime function, ERC20DefaultBalanceAdapter's ~5 KB of creation code was
   sitting in NAVCalculator's runtime bytecode, counting against EIP-170.
3. **Pervasive copy-paste across the leaf balance adapters and the custom price feeds** —
   not a size problem for NAVCalculator (those contracts deploy standalone and are far
   under the limit), but a real maintainability/correctness problem. The June-2026 audit
   ([docs/audits/2026-06-nav-core-internal-audit.md](../audits/2026-06-nav-core-internal-audit.md))
   found the *same* `break`-outside-`if` bug copy-pasted across SparkLend and the
   Aura/Convex adapters — exactly the kind of drift shared code prevents.

## Decision

### PR A — Externalize the ERC20DefaultBalanceAdapter `new` (size; shipped)

Move the `new ERC20DefaultBalanceAdapter(address(this), initialAssets)` out of
`NAVCalculator.initialize` and into `NAVRegistryLib.deployDefaultAdapter(...)`.
NAVRegistryLib is an external library invoked via DELEGATECALL, so inside it `address(this)`
is still the NAV proxy — the adapter's immutable `NAV_CALCULATOR` is pinned correctly and
the proxy remains the CREATE deployer, so **behaviour is identical**. But the adapter's
creation bytecode is now embedded in NAVRegistryLib's bytecode, not NAVCalculator's.

Result (measured): **NAVCalculator 21,403 → 16,217 B** (headroom 3,173 → **8,359 B**, 13% →
34%). NAVRegistryLib 6,497 → 12,039 B (still well under the limit).

This was chosen over the alternative of passing a pre-deployed adapter address into
`initialize`: that would have changed the `initialize` signature and forced every deploy
path and ~15 test setups to deploy the adapter against the proxy first (a reordering at
each call site). The library route changes only two source files plus a **mechanical
regeneration of NAVRegistryLib's pinned CREATE2 address** (its bytecode changed): update
`script/utils/LibraryPins.sol` + `foundry.toml` + the `vm.etch` sites, validated by
`test/LibraryPinConsistency.t.sol`. See that test and `LibraryPins`'s NatSpec for the
regeneration procedure.

### PR B — `BaseCustomPriceFeed` (maintainability; follow-up)

Most of the ~27 custom price feeds share an identical skeleton: the 5 `ICustomPriceFeed`
thunks, the immutables, the constructor with `OracleArgumentChecks`, and the Chainlink
read + staleness preamble. Only the rate source and the multiply-and-normalize differ
(usually 1–3 lines). Introduce an `abstract BaseCustomPriceFeed` carrying the shared surface
with an abstract `_rate()` hook; concrete feeds collapse to ~30–40 LOC (8 have migrated so
far — `cbETH`, `rETH`, `ETHx`, `rsETH`, `ezETH`, `ezETH_L2`, `osToken`, `NXM`). The generic
`CrossRateCustomPriceFeed` already subsumes the pure two-Chainlink-feed L2 variants. Bespoke
outliers stay as-is: `ETHPlus_CustomPriceFeed` (no Chainlink leg), `eETH_CustomPriceFeed` (derived two-feed),
`ankrETH_CustomPriceFeed` (rate inversion).

(Added later: `eETH_CustomPriceFeed` no longer belongs on that outlier list — it has since been reshaped into a
`BaseCustomPriceFeed` subclass with a constant unit `_rate()` of `1e18` (`src/prices/protocols/eETH_CustomPriceFeed.sol:13`).
`ETHPlus_CustomPriceFeed` (`src/prices/protocols/ETHPlus_CustomPriceFeed.sol:37`) and `ankrETH_CustomPriceFeed`
(`src/prices/protocols/ankrETH_CustomPriceFeed.sol:41`) do still implement `ICustomPriceFeed` directly, as this ADR
decided.)

### PR C — `BalanceAdapterBase` base + `StaticCallLib` + `ArrayLib` helpers (maintainability; partially shipped)

- An `abstract BalanceAdapterBase` for the standalone leaf adapters (the 9 plain
  contracts in `src/balances/BalanceAdapters/`, all of which now extend it) mirroring the
  existing `MetaBalanceAdapter` base. It carries the one piece every plain adapter repeated
  verbatim — the shared `supportsInterface` advertising `IBalanceAdapter` + `IPositionDescribable`
  + `IERC165`. A thin `SingleAssetBalanceAdapterBase` subbase adds the single-underlying getter
  triad (`underlyingAssetsSupported` / `getAdapterBalanceForAsset` / `getAdapterBalances`) off one
  `_owedAmount` hook, used by the Lido/Stader/Ethena withdrawal-queue adapters. `_getAssetInfo`
  was **not** hoisted into the base — it remains a per-adapter copy (Cap, ERC20Default, …).
- A `StaticCallLib` carrying the `safeUint` / `safeAddr` staticcall-and-decode helpers
  duplicated (and already drifting) across the Convex (`ConvexCurveLPStakingMetaBalanceAdapter`)
  and `UniswapV2PairLib` call sites. (The Aura adapter, which shared the same copy, has since
  been removed from the repo entirely.) Only those two call sites have migrated so far; other
  hand-rolled copies (CurvePoolLib, FluidVaultLib, CompoundV3CometLib, AaveUmbrella) still differ
  subtly and route around the lib. The per-adapter stash-unwrap logic in the Convex adapter
  builds on `safeAddr` but stays in the adapter — it is not itself a `StaticCallLib` helper.
- `ArrayLib` for the trim-to-length copy-back: it ships `copySliceAddress` (plus
  `intersection` / `deduplicateAddresses`) over **address** arrays, used today by NAVRegistryLib
  and PriceFeedLib. The analogous PositionBalance/uint copy-backs repeated across the leaf
  adapters are still inlined and remain a candidate for future helpers.

## Consequences

- NAVCalculator has comfortable headroom (~8.3 KB) for future adapters/registry growth.
- **Any change to NAVRegistryLib's source now also shifts the ERC20DefaultBalanceAdapter creation
  code's host**, so the pinned CREATE2 address must be regenerated on any NAVRegistryLib
  edit (this was already true for the lib; the guard test catches it).
- PRs B/C reduce duplication that has already produced real copy-paste bugs, at the cost of
  redeploying the affected (immutable, individually-audited) feeds/adapters — so they are
  forward-looking: new feeds/adapters build on the base, existing ones migrate on redeploy.
- The shared base contracts become higher-value audit targets (a bug there is systemic),
  which is the deliberate trade for eliminating the per-feed copy-paste of the staleness/rounding math.
