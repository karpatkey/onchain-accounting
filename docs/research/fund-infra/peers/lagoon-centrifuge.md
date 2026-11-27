# Settlement-NAV peers: Lagoon and Centrifuge V3

Scope: Lagoon (hopperlabsxyz/lagoon-v0) and Centrifuge V3 (centrifuge/protocol). Read-only; no repo files edited.
Pins:
- Lagoon: main `c39fe2ba60e78790558c271f38e01ed300144abd` (2026-10-02); tag `v0.6.0` = `8dbdfa27cee6ac41518f0f86fa33322d5112107a`. Links below use the tag. Base: `https://github.com/hopperlabsxyz/lagoon-v0/blob/8dbdfa27cee6ac41518f0f86fa33322d5112107a/`
- Centrifuge: main `72a8acfdbb2510da72aba6045c054f6b9a8afe7e` (2026-11-04, "sync: v3.3"). Base: `https://github.com/centrifuge/protocol/blob/72a8acfdbb2510da72aba6045c054f6b9a8afe7e/`

Legend: `[UNVERIFIED]` = not read from a primary source. `[INFERENCE]` = my derivation from code, not stated elsewhere.

---

## 0. Corrections to the survey

1. **Lagoon audit history.** The survey's "v0.5.0 critical mint-without-assets (fixed) and high pending-assets-moved" is not supported. Nethermind NM-0534 (v0.5.0, May 2025, `NethermindEth/PublicAuditReports` NM0534-FINAL_LAGOON.pdf): Critical 0, High 1, Medium 1, Low 1, Info 2.
   - 6.1 [High] native-token deposits lost when sync deposits are available (Fixed, 85ab53).
   - 6.2 [Medium] NAV proposals may ignore sync-deposit increases to totalAssets (Mitigated, ca04ed, via `expireTotalAssets`).
   - 6.3 [Low] share price inflated via sync deposits plus burn (Fixed, d05006).
2. **Lagoon line refs.** Survey L462-491 does not match the v0.6.0 tag file. At the tag, `updateNewTotalAssets` is L456, `securityCouncilUpdateTotalAssets` L490, `settleDeposit` L507, `expireTotalAssets` L607, `isTotalAssetsValid` L719, `updateTotalAssetsLifespan` L447 (all in `src/v0.6.0/vault/Vault-v0.6.0.sol`). Roles is `src/v0.6.0/Roles.sol`, not `v0.6.0/vault/Roles.sol`; `src/v0.5.2` path was 404.
3. **Centrifuge audits.** The survey's list is incomplete for 2026. The `docs.centrifuge.io/developer/security/audits` page lists 2026 reports (yAudit v3.3 Jun 2026; BurraSec v3.3 Jul and Aug 2026; Sherlock v3.3 Aug 2026; Sherlock Sep 2026; BurraSec Sep 2026; AlexZoid FV Aug-Sep 2026; others). Read in this pass: section 7.
4. **Centrifuge code vs audited code.** The 2026 v3.3 audits review a `StdManifest` policy (`src/manifests/StdManifest.sol`, audited commits 23b3e96 and cbb4025). The pinned tree has no `manifests/` directory; its policy is `src/policies/hub/StdHubPolicy.sol`. `[UNVERIFIED]` that StdManifest is the same code as StdHubPolicy at the pin. Policy findings below cite StdHubPolicy for code reads and the audits for findings, and are not mapped one-to-one.

---

## 1. Lagoon

### 1.1 Position declaration
- No on-chain position declaration. The vault holds one `totalAssets` number, and the valuation manager pushes it (`updateNewTotalAssets`, `Vault-v0.6.0.sol` L456-485).
- No per-fund position list, no limit on count or assets in the repo. Positions live in the Safe; accounting does not read them.
- Roles, fee receiver, Safe, valuation manager, Security Council and super operator are stored in `src/v0.6.0/Roles.sol` (storage and modifiers `onlySafe`, `onlyValuationManager`, `onlySecurityCouncil`; owner-only setters, L87-146). `[INFERENCE]` no Zodiac code in the repo.

### 1.2 NAV computation, timing, gas, reverts
- **Computed off-chain, pushed on-chain.** `updateNewTotalAssets` (onlyValuationManager, L456) reverts if the vault is Closed or `isTotalAssetsValid()` (L719). It computes `nextPps = oneShare.mulDiv(newTA+1, totalSupply()+10**decimalsOffset, Floor)`, runs the guardrail check (only if `lastFeeTime != 0`), and stores `newTotalAssets`.
- **Settlement binds to the proposal.** `settleDeposit` (onlySafe, onlyOpen, L507) and `settleRedeem` (L522) call `ERC7540Lib.updateTotalAssets`, which requires equality with the stored `newTotalAssets` (`WrongNewTotalAssets` / `NewTotalAssetsMissing`). It then sets `totalAssets`, resets expiry to `now + totalAssetsLifespan`, and calls `FeeLib.takeManagementAndPerformanceFees` (`src/v0.6.0/libraries/FeeLib.sol` ~L178-225; mgmt fee on average of totalAssets and previousTotalAssets ~L189; HWM perf ~L203; sets `lastFeeTime`).
- **Timing.** NAV is pushed at valuation time, settled at settlement time (epoch-style, not per deposit/redeem). `expireTotalAssets` (onlySafe, L607) clears validity. `isTotalAssetsValid` = `block.timestamp < totalAssetsExpiration` (L719). `updateTotalAssetsLifespan` (L447) reverts when async-only.
- **Gas.** Single `totalAssets` read: constant, independent of position count. No loops over positions. No gas-driven cap in the repo.
- **Guardrail** (`src/v0.6.0/libraries/GuardrailsLib.sol`; `GuardRailsManager.sol`):
  - `ONE_YEAR = 31_556_952` (L14), `SCALE = 1e18` (L16), `isCompliant` (L42-84), `scaleToOneYear = ONE_YEAR / _timePast` (L49, integer division), `variation = (nextPps - currentPps) * scaleToOneYear * SCALE / currentPps` (L54).
  - Increases: if `lowerRate < 0`, require `upperRate >= variation`; else also `variation >= lowerRate`. Decreases: require `lowerRate < 0` and `variation <= -lowerRate`.
  - `isCompliant` reverts on `_timePast == 0`. Guardrail is inactive if not activated (`updateActivated`, onlySecurityCouncil). `updateGuardrails` is onlySecurityCouncil.
  - `[INFERENCE]` truncation: `scaleToOneYear` is floor(ONE_YEAR/t). Examples: 30d → 12 (true 12.18); 182d → 2 (true 2.01); 200d → 1 (true 1.83, so a +5% PPS over 200 days annualizes to 5% against a true linear 9.1%); 300d → 1 (true 1.22); 365d → 1; 400d → 0 (true 0.91), so `variation = 0`. A ≥1-year gap since last settle disables the rate check for that step. Not in NM-0822 or the other audits read.
  - `[INFERENCE]` first update after a fresh init (`lastFeeTime == 0`) is unguarded.
- **Failure behaviour.** There is no per-position valuation, so no per-position revert. A failing valuation is a failed `updateNewTotalAssets` tx; the old `totalAssets` stays valid until expiry, then settlement stops (`isTotalAssetsValid` false). No fail-open path in the repo.

### 1.3 Permissions
- Permissions are on the Safe via Zodiac Roles v2 (per docs.lagoon.finance: per contract, function, argument). Not in the repo; `[UNVERIFIED]` as a configured deployment.
- In-repo gating: `onlySafe` (settle, expire), `onlyValuationManager` (NAV proposal), `onlySecurityCouncil` (guardrail config, bypass `securityCouncilUpdateTotalAssets` L490-502 that skips guardrails), `onlyWhitelistManager`.
- Binding: none. Roles config is not derived from, and does not reference, any NAV declaration.

### 1.4 Single declaration? unvalued positions?
- No. Permissions and accounting are unlinked; a manager can open any position the Roles config allows, and NAV reflects it only when the valuation manager re-prices the total. Nothing in the contracts makes an opened position visible to NAV; the guardrail limits only the PPS change per update.
- Security Council can bypass the guardrail on update (`securityCouncilUpdateTotalAssets`), and `updateActivated` can disable it. Sigma Prime governance note (secondary, `[UNVERIFIED]`): owner alone appoints the asset-manager Safe and valuation manager, and can switch off the NAV guardrail.

### 1.5 Debt, multi-leg, readability
- No per-position model; debt and multi-leg are not declared. Net NAV is a single number.
- Readability: `totalAssets`, PPS, `newTotalAssets`, expiry are public. No per-position state.

### 1.6 Governance, upgradeability, deployment
- Transparent-style opt-in proxy (`LagoonVaultProxy`). DelayProxyAdmin: upgrade delay 24h to 30d set by the vault admin. ProtocolRegistry `canUseLogic` whitelist; downgrades allowed; renounce makes the vault immutable (docs.lagoon.finance; `[UNVERIFIED]` against deployed contracts).
- Per-vault deployment: each fund has its own vault proxy and Safe; the implementation and registry are shared.
- Owner-set roles (Security Council, valuation manager, whitelist manager, Safe; `Roles.sol` owner setters).

### 1.7 Audits and incidents (read from PDFs)
- **NM-0534** (v0.5.0, Nethermind, May 2025): see section 0.1.
- **NM-0822** (v0.6.0, Nethermind, draft Mar 6 2026 → final May 25 2026, commit 93983b8 → a8e73f5): Critical 0, High 0, Medium 0, Low 1 (maxCap bypass for native ETH in `syncDeposit`; Fixed), Best Practices 1. States: guardrail violations revert `GuardrailsViolation`; Security Council can bypass or disable via `updateActivated`; MaxCap not enforced during valuation updates. Note: a8e73f5 ≠ tag 8dbdfa2; claims apply to the audited commit.
- **NM-1091** (v0.5.2/PR#51, Oct 2 2026, 94d2ad1 → c39fe2b): Info 1 (owner can advance epochs without the valuation manager via `initiateClosing` / `cancelClosing`).
- Trail of Bits v0.5.0 (2026-03-04) and v0.6.0 (2026-05-11) are listed on docs.lagoon.finance but NOT read `[UNVERIFIED]`.
- No known NAV-manipulation incident found in search `[UNVERIFIED]`.

### 1.8 Proposed grades (Lagoon)

| dim | current | proposed | basis | source |
|---|---|---|---|---|
| declared | 0 | 0 | No on-chain declaration; one pushed number. | Vault-v0.6.0.sol L456-485 |
| nav | 0 | 0 | Operator-pushed total; guardrail bounds change; settlement equality check. | Vault-v0.6.0.sol L507; GuardrailsLib.sol L42-84 |
| granularity | null | **2** [CHANGE] | Roles v2 scopes by contract, function and args per docs; config not in repo. | docs.lagoon.finance Roles; `[UNVERIFIED]` deployment config |
| single | 0 | 0 | Roles config not linked to NAV; a position can be opened without a valuation effect. | Roles.sol (no link) |
| complete | 0 | 0 | Pushed total; no completeness check; guardrail limits only PPS delta. | GuardrailsLib.sol L42-84 |
| debt | null | null | No per-position debt; no evidence either way. | — |
| isolation | null | **1** [CHANGE, low confidence] | Per-vault proxy and Safe; shared implementation and ProtocolRegistry upgrade path. The survey rubric anchor is undefined. | LagoonVaultProxy; docs |
| trust | null | **1** [CHANGE] | Owner appoints valuation manager and Security Council; SC can bypass guardrail; upgrades delayed (24h–30d) and renounceable. | Roles.sol; GuardRailsManager.sol; docs |
| readable | 0 | 0 | Only total NAV and PPS on-chain. | Vault-v0.6.0.sol |

---

## 2. Centrifuge V3

Code paths: Hub = `src/core/hub/Hub.sol`; Holdings = `src/core/hub/Holdings.sol`; Accounting = `src/core/hub/Accounting.sol`; policy = `src/policies/hub/StdHubPolicy.sol`; NAV = `src/hooks/accounting/NAVManager.sol`; price = `src/hooks/accounting/SimplePriceManager.sol`; oracle = `src/valuations/OracleValuation.sol`; guards = `src/managers/hub/Supervisor.sol`.

### 2.1 Position declaration
- Each holding = (poolId, scId, assetId). `Hub.initializeHolding` (L329-349) requires the share class and asset to exist, initializes Holdings (`holdings.initialize`, L43), reads the value (`holdings.update`), then `_updateAccountingAmount` with initial value as principal.
- Liabilities declared similarly (`initializeLiability`, NAVManager `fromHub`).
- Per pool, per network: accounts Asset/Gain/Loss/Equity/Liability/Expense (`withCentrifugeId(centrifugeId, NAVAccount.X)`).
- No hard limit on holdings count found in read code `[UNVERIFIED]` for Holdings/Accounting loops beyond those read (Accounting `updateJournal` loops debits/credits L117-121).

### 2.2 NAV computation, timing, gas, reverts
- **On-chain from ledger.** `NAVManager.netAssetValue(poolId, centrifugeId)` (L262-292) = equity + gain − loss − liability over 4 accounts via `accounting.accountValue` (`Accounting.sol` L131-146; reverts `AccountDoesNotExist` if never updated). Returns 0 if negative. O(1) per network; independent of holding count.
- **Share price is pushed by a hook, not computed in the hub.** `NAVManager.onSync` (L169-192) computes NAV and calls `navHook.onUpdate`. `SimplePriceManager.onUpdate` (L34-63; navUpdater-only, immutable) aggregates per-network NAV and issuance deltas and calls `hub.updateSharePrice` (price = NAV/issuance; 1.0 if issuance 0, L87-89).
- **When it runs.** `Holdings.callOnSyncSnapshot` (L116-119) → `_callOnSync` (L261-266) returns unless `snapshot.isSnapshot` is set. Snapshot flag is set by the spoke via `setSnapshot` (nonce-checked, L100-110). So NAV is pushed only at snapshot points reported from spokes, not on every holding change `[UNVERIFIED]` for spoke timing.
- **Holding valuation.** `Hub.updateHoldingValue` (L352-357; enforced) → `holdings.update` → `_updateAccountingValue` → `holdings.callOnSyncSnapshot`. `Holdings.update` (L191-207) values the full amount via `valuation.getQuote` (L199).
- **Valuation source.** `OracleValuation` (feeder mapping per pool/network/feeder). `setPrice` (L71-73) feeder-only, local; `fromSpoke` (L79-93) envoy-only with staleness check on remote prices; `_setPrice` (L95-99) stores price then `hub.updateHoldingValue`; `getPrice` (L106-111) reverts `PriceNotSet`; `getQuote` (L114-122) has no staleness bound for local feeders.
- **Gas.** NAV read is O(1) per network; the per-holding work is paid at holding update time. No gas cap; no per-position loop in `netAssetValue`.
- **Revert behaviour.** A holding with no price reverts its `update` (`getQuote` → `PriceNotSet`) and the whole tx reverts (fail-closed for that holding). `Holdings.update` reverts `HoldingNotFound` if no valuation. Sync: a pool-network with any deficit skips the NAV push silently (`SkipSync`, `NAVManager.onSync` L172-183) rather than publishing a misstated NAV.
- **Uninitialized holdings.** `Holdings.increase` before initialization is tracked (amount) with value 0 (L154-157), and `hub.updateAccountingAmount` runs only if initialized (`HubHandler.sol` L70-99). Value is booked at `initializeHolding`. `[INFERENCE]` an uninitialized holding's amount is not in NAV until initialized.

### 2.3 Permissions
- Hub manager calls are gated by policy: `Hub.enforced` → `_enforce` (L598) → `hubRegistry.policy(poolId).enforce(poolId, msgSender(), msg.data)`. `_requireManager` (L606).
- `StdHubPolicy.enforce` (L131): caller must be Hub; with `onchainAccounting`, share-price updates require `caller == simplePriceManager` (L138); accounting selectors (`createAccount`, `setAccountMetadata`, `updateJournal`, `initializeHolding`, `updateHoldingValue`, `updateHoldingValuation`; L272-279) require `caller == navManager` (L197) with delay 0; share-price selectors → `_checkSharePrice` (L357-378); `setSnapshotHook` must be navManager (L204-206).
- Delayed (authorization, escalation-gated): `updateHubManager`, `setRequestManager`, `updateVault`, `updateCurrency`, `addShareClass`, `notifyShareClass`, `setAdapters`, `authorizeSpokeCall`, `updateManager` (L216-229). `managerCall` → `_checkManagerCall` (L299-315); BRM calls bounded by `maxBrmPriceDeviation` (`_checkRequestPrice` L319-349). Default deny → delay (L263). `cancelAuthorization` instant (L242).
- Granularity: per selector, per caller, plus a few argument checks (price bounds, share-price rate). Not per holding or per position.
- `updateRestriction` instant only for Freeze (L285-293).
- Per-caller allowlist (restricted/allowed; `CallerNotAllowed` L183-184).

### 2.4 Link and unvalued positions
- No single declaration drives permissions. Permissions are policy-level per selector; the holding declaration drives accounting. Holdings and NAV are not checked against manager permissions.
- A holding cannot be initialized without a valuation: `NAVManager._createHolding` (L148-162) requires `defaultValuation` (`ValuationNotSet`) then calls `hub.initializeHolding`.
- Unvalued amounts: amounts can be reported for uninitialized holdings (value 0, excluded from NAV) until NAVManager initializes them `[INFERENCE]`.
- `NAVManager.updateHoldingValue` is **permissionless** (L214-216; yAudit 2.7.1 confirms at their commit). It forwards to `hub.updateHoldingValue`, which passes the policy since the caller is navManager. Effect: any EOA can trigger a revaluation and a snapshot-driven NAV push (at snapshot points only). It cannot change the price itself; the price is whatever the oracle holds.
- Manager cannot open a non-valued holding through NAVManager; can through spoke-side reporting `[UNVERIFIED]` (spoke BalanceSheetManager implementation not in this tree; only `src/managers/spoke/interfaces/IBalanceSheetManager.sol`).

### 2.5 Debt and multi-leg; readability
- Debt: liability holdings and accounts (`initializeLiability`, NAVManager `fromHub`); NAV subtracts liability (L262-292). Same valuation path as assets.
- Multi-leg: per holding per network; accounts per asset and per network.
- Readability: holdings, accounts, snapshots, deficit counts are public views; NAV per (pool, network) computed on-chain; no single pooled number published except the share price.

### 2.6 Governance, upgradeability, deployment
- Hub, Holdings, Accounting, Gateway are singletons keyed by poolId (not per-pool deploys). Per pool: NAVManager, SimplePriceManager, OracleValuation, StdHubPolicy instance (CREATE2 factory `StdHubPolicyFactory` L383-417), Supervisor.
- `SimplePriceManager.navUpdater` is immutable (set in constructor).
- Supervisor: sentinels can veto pending authorizations (`cancelAuthorization`, L77-82) during delay; no positive power (L48-70, self-removal guard L86-99; LastSentinel guard).
- Policy constructor: delay > 0, escalation > delay, expiry > 0.
- Root/guardian governance of Hub upgrades: not read `[UNVERIFIED]`.

### 2.7 Audits and incidents (read in this pass)

| Report | Date | Result | Notes |
|---|---|---|---|
| Recon (`2025-04-Recon.pdf`) | Apr 2025 | H-01 int128→uint128 cast overflow in `updateHolding`; M-01 AsyncRequests._withdraw sendUpdateHoldingAmount; M-02 | Earlier protocol-v3 commit 95b10b5 (pre-NAVManager). Current code uses `uint128 diff` + `isPositive` (`Hub.sol` L558-564): `[INFERENCE]` the cast path is absent; fix not checked. |
| Cantina (`2025-02-Cantina.pdf`) | Feb 2025 | 0 Crit / 0 High | Summary only read. |
| Cantina (`2025-05-Cantina`) | May 2025 | 0 Crit / 0 High; 3 Medium (AxelarAdapter/CastLib string length); Low 3.2.4 (queued holding amounts priced at latest price; Acknowledged; Hub manager can adjust via `updateHoldingValue`) | Fix commits 7eae90a0, ee717dd2, 3f632296 cited. |
| yAudit (`2025-07-yAudit.pdf`) | Jul 2025 | 0 Crit / 1 High (2.6.1 shares transferred twice during requestRedeem for legacy vaults; Fixed PR#478); 1 Medium (2.7.1 zero deposits into balanceSheet block future snapshots; Fixed 168b35f) | Relevant: snapshot blocking. Legacy adapter removed in V3 migration. |
| Cantina (`2025-08-Cantina`) | Aug 2025 | 0 Crit / 0 High | Low/Gas/Info only. |
| BurraSec LayerZero | Aug 2025 | L-01, L-02 (Ack), Info | Adapter scope. |
| BurraSec Gateway | Sep 2025 | H-1 multicall drains subsidized gas (Resolved); H-2 cross-chain messages fail automatic delivery (Resolved); M-1, M-2 (Resolved) | Gateway, not NAV. |
| BurraSec | Oct 2025 | H-1 single pool manager can manipulate adapter payloads to bypass pool-ID checks in MultiAdapter (Resolved); M-1 return-bomb in Gateway catch (Resolved) | Cross-pool isolation finding. |
| yAudit v3.3 (`2026-06-yAudit-v3.3.pdf`) | Jun 2026 | 0 Crit / 0 High / 1 Medium / 3 Low / 4 Info | 2.6.1 (M): with StdManifest + onchainAccounting, OracleValuation price updates revert `OnchainAccountingOnly` (feeder price path blocked; stale holding values). 2.7.1 (L): permissionless `NAVManager.updateHoldingValue` → no-op NAV recomputes refresh the manifest rate-limit baseline, delaying guarded price commits. Audited StdManifest code, see section 0.4. |
| BurraSec v3.3 Part 1 (`2026-07-burraSec-v3.3.pdf`) | Jul 2026 | 0 Crit / 0 High / 13 Medium / 39 issues | M-03 (Resolved): large NAV swing (≥ maxAbsolutePriceDelta) → StdManifest demands exact-calldata authorization; price update reverts, unwinding the holding update and `setSnapshot` nonce; later messages fail `InvalidNonce`; recovery needs privileged intervention (Impact High, Likelihood Low). M-05 (Resolved): nonzero-delay StdManifest blocks OracleValuation feeder updates. M-12 (Resolved): ceil-rounded deviation band permits zero BRM price. M-10 (Ack): circuit breaker replacement resets rate-limit budget. |
| BurraSec v3.3 Part 2 (`2026-08-burraSec-v3.3.pdf`) | Aug 2026 | 0 Crit / 0 High / 2 Medium / 14 issues | Share-price guard L-1 unarmed on equal-price first commit (Resolved). |
| Sherlock v3.3 (`2026-08-Sherlock.pdf`) | Aug 2026 | 0 High / 2 Medium / 8 Low-Info | Vault math and CastLib. |
| BurraSec share manager (`2026-08-burraSec-ShareManager.pdf`) | Aug 2026 | `[UNVERIFIED]` not read | |
| BurraSec bridge (`2026-07-burraSec-bridge.pdf`) | Jul 2026 | `[UNVERIFIED]` not read | |
| Sherlock (`2026-09-Sherlock.pdf`) | Sep 2026 | 0 High / 0 Medium / 2 Low-Info | |
| BurraSec (`2026-09-burraSec.pdf`) | Sep 2026 | 0 Crit / 0 High / 2 issues | |
| AlexZoid FV (`2026-08-FV.pdf` on main) | Aug-Sep 2026 | `[UNVERIFIED]` not read | Docs: FV covers core contracts only. |

- Docs marketing claims ("38 reviews by 14 firms", "zero exploits since 2019"): `[UNVERIFIED]` as evidence.
- No Centrifuge V3 NAV-manipulation exploit found in search `[UNVERIFIED]`. Certora FV (1,589 properties): secondary press only `[UNVERIFIED]`.

### 2.8 Proposed grades (Centrifuge)

| dim | current | proposed | basis | source |
|---|---|---|---|---|
| declared | 2 | 2 | Holding (pool, sc, asset) declared with valuation and accounts; initialization required before NAV counts it. | Hub.sol L329-349; NAVManager.sol L148-162 |
| nav | null | **1** [CHANGE] | NAV computed on-chain from ledger (O(1) per network), but per-holding prices are feeder-pushed and share price is pushed by hook at snapshot points. | NAVManager.sol L262-292, L169-192; OracleValuation.sol L114-122 |
| granularity | 1 | 1 | Per selector + caller allowlist + few arg bounds; not per holding. | StdHubPolicy.sol L176-263 |
| single | null | **0** [CHANGE] | Holding declaration drives accounting; policy permissions are per selector and not derived from holdings. | StdHubPolicy.sol L131-263 |
| complete | null | null | Spoke-reported amounts via gateway; spoke BalanceSheetManager not in tree; uninitialized holdings excluded from NAV. | HubHandler.sol L70-99 |
| debt | null | **1** [CHANGE] | Liability accounts and holdings subtracted in NAV; same valuation path. | NAVManager.sol L262-292; `initializeLiability` |
| isolation | null | **1** [CHANGE, low confidence] | Per-pool NAVManager, SimplePriceManager, policy, Supervisor; Hub, Holdings and Gateway are shared singletons (H-1 Oct 2025 cross-pool finding, resolved). | Hub.sol; Supervisor.sol; burraSec Oct 2025 |
| trust | 2 | **1** [CHANGE, low confidence] | Oracle feeder set has quorum 1 with no price bounds in OracleValuation; share-price rate bounds and sentinel veto constrain effect; navUpdater immutable; feeder changes go through delayed managerCall `[INFERENCE]`; Root/guardian governance not read `[UNVERIFIED]`. |  OracleValuation.sol L71-99; StdHubPolicy.sol L263 |
| readable | 1 | 1 | Per-holding and per-network views; no single pooled NAV except share price. | Holdings/Accounting views |

Notes on grades:
- Centrifuge `trust` lowering is judgment: the code bounds share price (policy) but not per-holding price, and feeder quorum is one. Keep at 2 if the rubric counts policy delays and sentinel veto as trust mitigations.
- Centrifuge `nav` 1 vs Lagoon 0: Centrifuge NAV is a function of on-chain ledger state; Lagoon NAV is one operator-proposed number.

---

## 3. Side-by-side

| question | Lagoon | Centrifuge V3 |
|---|---|---|
| NAV source | one operator-pushed number, guardrail-bounded | ledger sums (on-chain) × feeder prices; hook pushes share price at snapshot points |
| NAV timing | valuation proposal; settles at settle tx | on holding update; pushed at snapshot sync |
| read gas | O(1) | O(1) per network |
| one reverting position | n/a | that holding's update reverts; deficit networks skip NAV push |
| permission granularity | Roles v2 (contract/function/args), off-repo | policy per selector and caller |
| link permissions ↔ NAV | none | none (accounting selectors gated to navManager) |
| debt | not declared | liability accounts |
| upgrades | delayed (24h–30d) transparent proxy, renounceable | singleton hubs; governance not read `[UNVERIFIED]` |

## 4. Open items (`[UNVERIFIED]`)
- Lagoon: Trail of Bits v0.5.0 and v0.6.0 reports; Roles config on a live Safe; DelayProxyAdmin deployed parameters.
- Lagoon: Sigma Prime governance note (secondary).
- Centrifuge: spoke BalanceSheetManager implementation (completeness); Root/guardian governance and upgrade delay; BurraSec share manager and bridge (Aug/Jul 2026); AlexZoid FV; StdManifest vs StdHubPolicy mapping; Recon H-01 fix status; Spearbit 2024-08 and xmxanuel reports (not read).
- Both: rubric anchors for `isolation` and `complete` are undefined in the survey; grades above for those are judgment.
