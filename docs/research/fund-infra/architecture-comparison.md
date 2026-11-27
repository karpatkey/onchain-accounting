# kpk fund architecture vs the state of the art

Compares **kpk today** (Safe + Zodiac Roles v2 permissions built with DeFi Kit, valued by this repo's `NAVCalculator`) and **kpk + FundConfig** (the POC in `poc/fundconfig/`) with the **NAV-based funds** surveyed in [state-of-art.md](state-of-art.md): systems where a manager runs a multi-protocol portfolio and shares are priced from a fund NAV — Enzyme, Sommelier, Veda, Lagoon, Aera v3, Mellow, Centrifuge. Allocator and meta-vaults (Morpho V2, Euler Earn, Yearn V3, Superform) are left out: they allocate one asset across same-kind strategies and value through ERC-4626 reads, so they solve a narrower problem. Third-party grades come from the survey; kpk grades from this repo and the POC fork tests. Cells marked `[UNVERIFIED]` in the source are graded "—".

## Matrix

Grades: ● strong · ◐ partial · ○ weak · — not applicable or not verified. Source of truth: [architecture-comparison.json](architecture-comparison.json); the table below is generated from it by `bun docs/research/fund-infra/report/build-report.ts`, which also renders it in [report/index.html](report/index.html) with the per-cell basis on hover.

<!-- matrix:start -->
| Dimension | kpk today | kpk + FundConfig | Enzyme | Sommelier | Veda | Lagoon | Aera v3 | Mellow | Centrifuge |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Positions declared on-chain, per fund | ◐ | ● | ● | ● | ○ | ○ | ○ | ◐ | ● |
| NAV computed on-chain from positions | ● | ● | ● | ● | ○ | ○ | ○ | ○ | ◐ |
| Manager permissions per function + arguments | ● | ● | ◐ | ○ | ◐ | ● | ● | ● | ◐ |
| Permissions and NAV from one declaration | ○ | ● | ◐ | ◐ | ○ | ○ | ○ | ○ | ○ |
| Manager cannot open an unvalued position | ◐ | ● | ◐ | ◐ | ○ | ○ | ○ | ○ | — |
| Debt and multi-leg positions | ● | ◐ | ● | ● | — | — | — | — | ◐ |
| One bad position cannot block NAV | ● | ◐ | ○ | ○ | — | — | — | — | — |
| Shared components immutable or timelocked | ● | ● | ◐ | ◐ | ◐ | ◐ | ◐ | ◐ | ● |
| Per-position portfolio readable on-chain by integrators | ● | ● | ◐ | ◐ | ○ | ○ | ○ | ◐ | ◐ |
<!-- matrix:end -->

## Where kpk stands today

- **Strong on the two halves separately.** NAV is computed on-chain from live adapter reads, with debt legs, a typed per-position identity schema, and per-adapter failure isolation (gas stipend, fail-open, health flags). Among the NAV-based peers only Enzyme and Sommelier also value on-chain from positions, and neither isolates failures: Enzyme's `calcGav` and Sommelier's `totalAssets` revert when one position's valuation reverts ([peers/enzyme-sommelier.md](peers/enzyme-sommelier.md)). Veda, Lagoon, Aera and Mellow price from an off-chain push bounded by guardrails; Centrifuge keeps an on-chain holdings ledger with feeder-pushed prices. Permissions are Zodiac Roles v2 function+argument scopes; Veda's merkle leaves bind addresses but never amounts ([peers/veda-aera-mellow.md](peers/veda-aera-mellow.md)).
- **Weak on the link between them.** Roles (DeFi Kit) and the NAV registry are configured separately, and the registry is global per chain, not per fund. Completeness — the manager cannot open a position NAV does not see — rests on an allow-list kept outside this repo (CLAUDE.md residual risk). Lagoon is the closest peer structurally: a Safe with Zodiac Roles v2 permissions per its docs, but with a pushed NAV ([peers/lagoon-centrifuge.md](peers/lagoon-centrifuge.md)).
- **NAV read cost.** Today's `getAccountNav` scans the whole per-chain registry: for three large production accounts it costs 17.5–18.9M gas cold, above the 16,777,216 per-tx cap, so it cannot run inside a subscription tx ([nav-read-gas.md](nav-read-gas.md)). It works as an off-chain `eth_call`.

## What FundConfig changes

- **Single declaration.** Each declared `(module, instance)` produces both the Roles leaves and the accounting route. `FundConfig` owns the Roles proxy and has no raw passthrough, so a permission without a valued position cannot be written through Roles. Among the NAV-based peers, Enzyme (lib + parser per external-position type) and Sommelier (one adaptor holds `balanceOf` and the callable functions) come closest; neither generates a call-level allow-list (Sommelier allows any function on a catalogued adaptor).
- **Keeps kpk's strengths.** Same adapters, same Roles conditions, same per-position portfolio reads.
- **Costs and gaps** (from the fork tests): ~0.49–0.58M gas per `addPosition`, ~112k marginal; single `Accounting` per position forces pool+gauge splits and makes the borrow removal guard per asset; `fundNav` is not yet hardened like `NAVCalculator`'s per-adapter isolation; Safe owners can still add modules outside `FundConfig`.

## Patterns worth taking from others

| From | Pattern | Fit for kpk |
|---|---|---|
| Veda, Sommelier | Post-batch invariant: share supply unchanged, `totalAssets` within a deviation band after a manager call | A Roles-side or Safe-guard check around `execTransactionWithRole`; bounds value-extraction by a compromised bot ([settlement-and-threats.md](settlement-and-threats.md)) |
| Centrifuge (timelocked authorization) | Timelock on actions outside the declared policy; none inside it | `addPosition` behind a delay; `removePosition` immediate (it is already value-guarded) |
| Centrifuge (Supervisor), Aera (guardian removal) | A role that can only veto, revoke or pause | A guardian on `FundConfig` that can only remove permissions for a position |
| Sommelier | Two-party registry admission (registry multisig + governance) | `ModuleRegistry` admission by Security Council + timelock |
| Lagoon | Rate guardrail on NAV moves between settlements | Settlement layer cross-check on `fundNav` jumps |
| Enzyme | Test that the permission-side asset set equals the accounting-side asset set | CI check over every module: assets reachable by `permissions()` ⊆ `assets()` |

## Standard proposal: NAV-linked tokenized funds

The design chat proposed a fund standard (working name: *NAV-linked tokenized funds*) split into three interfaces on the share token. The ERC survey ([erc-landscape.md](erc-landscape.md)) places it against existing work:

| Interface | What it standardizes | Closest existing ERC | Gap | How this architecture supplies it |
|---|---|---|---|---|
| (a) Fund discovery | Share token → fund metadata, NAV source, lifecycle | ERC-7575 `share()`/`vault(asset)`; ERC-8318 (open draft PR #1845, metadata) | No standard binds a share token to its metadata or NAV oracle | Small ERC-165 view on the share token pointing at `FundConfig` / `NAVCalculator` |
| (b) NAV-bound settlement | Subscriptions/redemptions settled only against an authorized NAV snapshot, with min-out | ERC-7540 (async, no min-out by design); ERC-8330 (NAV snapshots, Last Call vs Review unresolved); ERC-7621 (sync min-out) | Nothing binds an async request to a snapshot or max deviation | Settlement layer above NAV (not in this repo); invariants in [settlement-and-threats.md](settlement-and-threats.md) |
| (c) Portfolio accounting | Per-position assets, liabilities, protocol exposures, filtered queries | None: ERC-8330 and ERC-8318 carry totals only | **Uncovered by any ERC** | `PositionBalance` + the position identity schema; with FundConfig, scoped to the fund's declared positions, so an integrator (e.g. a lender taking fund shares as collateral) can read leverage and exposures on-chain |

Interface (c) is where kpk has something no one else standardizes, and the matrix row "per-position portfolio readable on-chain" shows why: only kpk and Enzyme expose a typed per-position breakdown on-chain. FundConfig makes it fund-scoped and complete by construction, which is what makes it worth standardizing.

Recommendation carried from the ERC survey: do not open a fourth fund-metadata ERC now. Propose a share-binding extension on ERC-8318, use ERC-8330 as the NAV snapshot source, keep NAV-bound settlement as kpk's own interface, and bring the portfolio-accounting interface (c) to the 8318/8330 authors as an extension once FundConfig's interface stabilizes (per-leg accounting first). Dividends: accounting of declared distributions as liabilities is required, payout optional; a record-date rule for pending ERC-7540 redemptions is missing from every standard.
