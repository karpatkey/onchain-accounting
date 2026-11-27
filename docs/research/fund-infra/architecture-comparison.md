# kpk fund architecture vs the state of the art

Compares three things: **kpk today** (Safe + Zodiac Roles v2 permissions built with DeFi Kit, valued by this repo's `NAVCalculator`), **kpk + FundConfig** (the POC in `poc/fundconfig/`), and eleven other systems surveyed in [state-of-art.md](state-of-art.md). Third-party grades come from that survey; kpk grades from this repo and the POC fork tests. Cells marked `[UNVERIFIED]` in the source keep that tag.

## Matrix

Grades: ● strong · ◐ partial · ○ weak · — not applicable or not verified. Source of truth: [architecture-comparison.json](architecture-comparison.json); the table below is generated from it by `bun docs/research/fund-infra/report/build-report.ts`, which also renders it in [report/index.html](report/index.html) with the per-cell basis on hover.

<!-- matrix:start -->
| Dimension | kpk today | kpk + FundConfig | Enzyme | Sommelier | Veda | Morpho V2 | Lagoon | Aera v3 | Mellow | Euler Earn | Yearn V3 | Centrifuge | Superform |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Positions declared on-chain, per fund | ◐ | ● | ● | ● | ○ | ● | ○ | ○ | ◐ | ● | ● | ● | ◐ |
| NAV computed on-chain from positions | ● | ● | ● | ● | ○ | ● | ○ | ○ | ○ | ◐ | ◐ | ◐ | ○ |
| Manager permissions per function + arguments | ● | ● | ◐ | ○ | ● | ◐ | — | ● | ● | ◐ | ◐ | ◐ | ◐ |
| Permissions and NAV from one declaration | ○ | ● | ◐ | ◐ | ○ | ◐ | ○ | ○ | ○ | ◐ | ◐ | ◐ | ○ |
| Manager cannot open an unvalued position | ◐ | ● | ● | ◐ | ○ | ● | ○ | ○ | ○ | ● | ● | ◐ | ○ |
| Debt and multi-leg positions | ● | ◐ | ● | ● | — | ○ | — | — | — | ○ | — | — | — |
| One bad position cannot block NAV | ● | ◐ | — | — | — | ○ | — | — | — | — | — | — | — |
| Shared components immutable or timelocked | ● | ● | ◐ | ◐ | ◐ | ● | ◐ | ◐ | ◐ | ● | ◐ | ● | ◐ |
| Per-position portfolio readable on-chain by integrators | ● | ● | ● | ◐ | ○ | ◐ | ○ | ○ | ○ | ◐ | ◐ | ◐ | ○ |
<!-- matrix:end -->

## Where kpk stands today

- **Strong on the two halves separately.** NAV is computed on-chain from live adapter reads, with debt legs, a typed per-position identity schema, and per-adapter failure isolation (gas stipend, fail-open, health flags). No surveyed system combines all four; Morpho V2 is the only other fully on-chain one and its `realAssets` reverts on one bad market. Permissions are Zodiac Roles v2 function+argument scopes, as fine-grained as Veda's merkle leaves or Mellow's verifiers.
- **Weak on the link between them.** Roles (DeFi Kit) and the NAV registry are configured separately, and the registry is global per chain, not per fund. Completeness — the manager cannot open a position NAV does not see — rests on an allow-list kept outside this repo (CLAUDE.md residual risk). This is the same split Lagoon, Veda, Aera and Mellow have, minus their off-chain NAV.

## What FundConfig changes

- **Single declaration.** Each declared `(module, instance)` produces both the Roles leaves and the accounting route. `FundConfig` owns the Roles proxy and has no raw passthrough, so a permission without a valued position cannot be written through Roles. Only Enzyme (lib + parser per type), Morpho V2 (ids shared by caps and `realAssets`) and Euler/Yearn (strategy set) come close, and none of them generates a call-level allow-list.
- **Keeps kpk's strengths.** Same adapters, same Roles conditions, same per-position portfolio reads.
- **Costs and gaps** (from the fork tests): ~0.49–0.58M gas per `addPosition`, ~112k marginal; single `Accounting` per position forces pool+gauge splits and makes the borrow removal guard per asset; `fundNav` is not yet hardened like `NAVCalculator`'s per-adapter isolation; Safe owners can still add modules outside `FundConfig`.

## Patterns worth taking from others

| From | Pattern | Fit for kpk |
|---|---|---|
| Veda, Sommelier | Post-batch invariant: share supply unchanged, `totalAssets` within a deviation band after a manager call | A Roles-side or Safe-guard check around `execTransactionWithRole`; bounds value-extraction by a compromised bot ([settlement-and-threats.md](settlement-and-threats.md)) |
| Morpho V2, Euler Earn | Timelock on risk-increasing changes, none on risk-reducing (`decreaseCap`) | `addPosition` behind a delay; `removePosition` immediate (it is already value-guarded) |
| Morpho V2 (Sentinel), Euler (Guardian), Centrifuge (Supervisor) | A role that can only revoke or pause | A guardian on `FundConfig` that can only remove permissions for a position |
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
