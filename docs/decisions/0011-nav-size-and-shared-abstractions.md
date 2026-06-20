# 0011 — NAVCalculator size headroom + shared adapter/feed abstractions

Status: accepted (introduced with PR A — the ERC20DefaultAdapter externalization; PRs B/C are follow-ups, now partially landed — `BaseCustomPriceFeed`, `StaticCallLib`, and `ArrayLib` have shipped, the `BalanceAdapter` base has not)

## Context

`NAVCalculator` is the one size-constrained contract in this repo: it is the UUPS
implementation behind the proxy, so its **runtime** bytecode must stay under the EIP-170
24,576-byte limit (CI enforces it via `forge build --sizes`). Everything else either
deploys standalone (balance adapters, custom price feeds — each its own contract, plain
CREATE) or is an external library (PriceFeedLib, NavRegistryLib — separate bytecode,
DELEGATECALL). [ADR 0010](0010-meta-balance-adapters.md) already moved the read/compute
engine and registry mutations into those libraries; after that work NAVCalculator measured
**21,403 B** — only 3,173 B (13%) of headroom.

A review of where the remaining bytecode comes from found three classes of opportunity:

1. **NAVCalculator inherits `Prices` + `Balances`**, so their code is compiled into its
   bytecode — but both are now almost entirely thin wrappers over the external libs, so
   there is little left to extract there.
2. **`NAVCalculator.initialize` ran `new ERC20DefaultAdapter(...)`.** A `new X()` embeds
   `X`'s entire *creation* bytecode into the contract that contains the `new`. Because
   `initialize` is a runtime function, ERC20DefaultAdapter's ~5 KB of creation code was
   sitting in NAVCalculator's runtime bytecode, counting against EIP-170.
3. **Pervasive copy-paste across the leaf balance adapters and the custom price feeds** —
   not a size problem for NAVCalculator (those contracts deploy standalone and are far
   under the limit), but a real maintainability/correctness problem. The June-2026 audit
   ([docs/audits/2026-06-nav-core-internal-audit.md](../audits/2026-06-nav-core-internal-audit.md))
   found the *same* `break`-outside-`if` bug copy-pasted across SparkLend and the
   Aura/Convex adapters — exactly the kind of drift shared code prevents.

## Decision

### PR A — Externalize the ERC20DefaultAdapter `new` (size; shipped)

Move the `new ERC20DefaultAdapter(address(this), initialAssets)` out of
`NAVCalculator.initialize` and into `NavRegistryLib.deployDefaultAdapter(...)`.
NavRegistryLib is an external library invoked via DELEGATECALL, so inside it `address(this)`
is still the NAV proxy — the adapter's immutable `NAV_CALCULATOR` is pinned correctly and
the proxy remains the CREATE deployer, so **behaviour is identical**. But the adapter's
creation bytecode is now embedded in NavRegistryLib's bytecode, not NAVCalculator's.

Result (measured): **NAVCalculator 21,403 → 16,217 B** (headroom 3,173 → **8,359 B**, 13% →
34%). NavRegistryLib 6,497 → 12,039 B (still well under the limit).

This was chosen over the alternative of passing a pre-deployed adapter address into
`initialize`: that would have changed the `initialize` signature and forced every deploy
path and ~15 test setups to deploy the adapter against the proxy first (a reordering at
each call site). The library route changes only two source files plus a **mechanical
regeneration of NavRegistryLib's pinned CREATE2 address** (its bytecode changed): update
`script/utils/LibraryPins.sol` + `foundry.toml` + the `vm.etch` sites, validated by
`test/LibraryPinConsistency.t.sol`. See that test and `LibraryPins`'s NatSpec for the
regeneration procedure.

### PR B — `BaseCustomPriceFeed` (maintainability; follow-up)

~24 of the 25 custom price feeds share an identical skeleton: the 5 `IPriceFeedCustom`
thunks, the immutables, the constructor with `OracleArgumentChecks`, and the Chainlink
read + staleness preamble. Only the rate source and the multiply-and-normalize differ
(usually 1–3 lines). Introduce an `abstract BaseCustomPriceFeed` carrying the shared surface
with an abstract `_rate()` hook; concrete feeds collapse to ~30–40 LOC. The generic
`CrossRate_Price` already subsumes the pure two-Chainlink-feed L2 variants. Bespoke
outliers stay as-is: `ETHPlus_Price` (no Chainlink leg), `eETH_Price` (derived two-feed),
`NXM_Price` (RAMM + liveness assert), `ankrETH_Price` (rate inversion).

### PR C — `BalanceAdapter` base + `StaticCallLib` + `ArrayLib` helpers (maintainability; follow-up)

- An `abstract BalanceAdapter` base for the ~12 standalone leaf adapters mirroring the
  existing `MetaBalanceAdapter` base — shared `supportsInterface`, one canonical
  `_getAssetInfo`, and the empty `getAdapterBalances*` stubs.
- A `StaticCallLib` carrying the `safeUint` / `safeAddr` staticcall-and-decode helpers
  duplicated (and already drifting) across AuraRewardsMeta, ConvexRewardsMeta, and
  UniswapV2PairLib. Only those three call sites have migrated so far; other hand-rolled
  copies (CurvePoolLib, FluidVaultLib, CompoundV3CometLib, AaveUmbrella) still differ subtly
  and route around the lib. The per-adapter stash-unwrap logic in the Aura/Convex adapters
  builds on `safeAddr` but stays in the adapters — it is not itself a `StaticCallLib` helper.
- `ArrayLib` for the trim-to-length copy-back: it ships `copySliceAddress` (plus
  `intersection` / `deduplicateAddresses`) over **address** arrays, used today by NavRegistryLib
  and PriceFeedLib. The analogous PositionBalance/uint copy-backs repeated across the leaf
  adapters are still inlined and remain a candidate for future helpers.

## Consequences

- NAVCalculator has comfortable headroom (~8.3 KB) for future adapters/registry growth.
- **Any change to NavRegistryLib's source now also shifts the ERC20DefaultAdapter creation
  code's host**, so the pinned CREATE2 address must be regenerated on any NavRegistryLib
  edit (this was already true for the lib; the guard test catches it).
- PRs B/C reduce duplication that has already produced real copy-paste bugs, at the cost of
  redeploying the affected (immutable, individually-audited) feeds/adapters — so they are
  forward-looking: new feeds/adapters build on the base, existing ones migrate on redeploy.
- The shared base contracts become higher-value audit targets (a bug there is systemic),
  which is the deliberate trade for eliminating 24× copy-paste of the staleness/rounding math.
