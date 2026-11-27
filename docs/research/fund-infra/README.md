# Fund infrastructure research (2026-11)

Research behind a kpk fund stack built on this repo: per fund a Safe, a Zodiac Roles modifier, and NAV from `NAVCalculator`. Facts marked `[UNVERIFIED]` inside each file were not checked against a primary source.

|File|Question|Headline|
|---|---|---|
|[fundconfig-poc.md](fundconfig-poc.md)|Can one per-fund declaration of positions derive both Roles permissions and NAV coverage?|Yes on a mainnet fork (7 tests pass). Measured `addPosition` ≈0.76–0.88M gas each; an identical second fund costs 8.8% less (cause not isolated). Narrows, does not close, the roles-vs-accounting gap: Safe-owner module changes remain outside it|
|[zodiac-roles-v2.md](zodiac-roles-v2.md)|Roles v2 API, storage, cross-fund sharing, deployment, gas|Identical condition trees dedupe across funds via `WriteOnce` (CREATE2); `EqualToAvatar` keeps them fund-agnostic. Gas reported by the research agent from an anvil fork with `cast` (scripts were scratch, not kept): `scopeFunction` ≈107k (buffer already stored) vs ≈169k (first write), `deployModule` ≈190k|
|[repo-accounting-map.md](repo-accounting-map.md)|Where accounting registration lives in this repo|Registry is global per chain; `account` only filters. No per-fund config, no permission data in repo|
|[state-of-art.md](state-of-art.md)|How Enzyme, Sommelier, Veda, Morpho V2, Aera, Lagoon, Mellow, … tie permissions to accounting|None derives both NAV coverage and the manager allow-list from one declaration. Closest: Enzyme (per-type lib + parser), Morpho V2 (adapter ids for caps + `realAssets`)|
|[erc-landscape.md](erc-landscape.md)|Existing fund ERCs, gaps, dividends|ERC-8318 is an open draft PR (not merged; "uFund" name dropped); ERC-8330 Last Call/Review conflict; ERC-1726/2222 never merged. Portfolio accounting (per-position breakdown) is uncovered by any ERC. Recommendation: extend 8318/8330, keep NAV-bound settlement as our own interface|
|[settlement-and-threats.md](settlement-and-threats.md)|Proof-based NAV, strict settlement accounting, compromised-bot threat model|ZK proofs prove read integrity, not completeness. Settlement invariants: snapshot block ≤ cutoff, pending flows excluded, fees crystallized first, revert on failed read. Top bot risks: unpinned recipients, unbounded approvals, roles changes adding non-assistant paths|
