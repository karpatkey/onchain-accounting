# State of the art: deriving NAV coverage and manager permissions from declared positions

Scope: how DeFi vault/fund systems declare positions, derive accounting (NAV), and gate manager permissions. Input to kpk's proposed per-fund FundConfig, where one declaration drives both NAV coverage and Zodiac-Roles-style permissions through shared immutable protocol adapters.

Source legend: primary = GitHub source/README/spec read this session (paths given). `[UNVERIFIED]` = search summary, unread PDF, or rate-limited path. `[INFERENCE]` = my conclusion from read code.

## 0. Bottom line

- No surveyed system derives BOTH accounting coverage AND manager permissions from one declaration. Closest: Enzyme (per-type library + parser) and Sommelier (per-protocol adaptor that holds both `balanceOf` and callable functions). Both still gate calls per adapter, not per function, and Enzyme's parser declares assets moved, not a full call surface.
- Most systems split the two: permissions via merkle roots (Veda, Aera), role/allowlist (Yearn, Euler, Sommelier registry), or call-scoped policies (Enzyme); accounting via off-chain pushed NAV (Lagoon, Mellow, Veda Accountant, Aera anchor/drift), or live reads per declared position (Sommelier, Morpho V2, Enzyme).
- The only systems where accounting coverage is structurally complete by construction are those where every allocation must route through an adapter whose valuation the adapter itself provides: Morpho V2 (adapter caps + `realAssets`), Enzyme (external position + `getManagedAssets`), Mellow/Centrifuge hub-side holdings (push/hook). Mellow and Lagoon accept off-chain pushed values, so coverage is an operator claim bounded by guardrails.
- kpk's current Safe + Zodiac Roles v2 setup (permissions) plus NAVCalculator (valuation) has exactly the split the surveyed systems use. The FundConfig design would narrow the gap none of them addresses: a single declaration that generates both the NAV adapter set and the Roles allow-list (Safe-owner paths around Roles stay outside it).

## 1. Per-system findings

Each entry: declaration / accounting / permissions / shared registry / governance & deployment / incidents.

### 1.1 Enzyme (`enzymefinance/protocol`, dev branch, GPL-3.0)
- Declaration: external positions. `ExternalPositionManager` (pragma 0.6.12) creates per-fund position instances via `IExternalPositionFactory.deploy(vaultProxy, typeId, lib, initData)`. Position type → (lib, parser) registered in the manager's type info.
- Accounting: `IExternalPosition.getManagedAssets()` and `getDebtAssets()` (non-view, return `(address[], uint256[])`). Position lib computes value per instance.
- Permissions: every `CallOnExternalPosition` requires `IVault(vaultProxy).canManageAssets(_caller)`. Per action: `parseAssetsForAction(externalPosition, actionId, actionArgs)` returns `assetsToTransfer`, `amountsToTransfer`, `assetsToReceive`; then the lib call; then `PostCallOnExternalPosition` policy hook. The parser is the permission-side declaration of asset movement; the lib is accounting. Same type contract family, separate functions.
- Shared registry: yes. `updateExternalPositionTypesInfo` is `onlyFundDeployerOwner` (type → lib + parser). Instances are per-fund (`vaultProxy`).
- Governance: immutables `EXTERNAL_POSITION_FACTORY`, `POLICY_MANAGER`. Types added by fund-deployer owner; policies per fund via PolicyManager.
- Incidents: audit list in README: 2025-02 gmx-v2 "disallowed-adapter-incoming-assets-policy" (finding content unread `[UNVERIFIED]`), 2025-03 single-asset-deposit-queue, 2025-04 myso-v3, 2025-05 stakewise-v3. "Onyx"/"Sulu" naming not found in README `[UNVERIFIED]`.
- Assessment [INFERENCE]: closest structural analog to FundConfig. Parser = permission-side declaration; lib = accounting-side declaration; one registry per type. Gap: the call surface is the parser's arg decoding, not an enumerated function allowlist; the `canManageAssets` gate is per-vault, not per-position.

### 1.2 Sommelier (`PeggyJV/cellar-contracts`, Apache-2.0, pragma 0.8.21)
- Declaration: positions (credit/debt arrays, `MAX_POSITIONS = 32`) and adaptors. `getPositionData` maps id → `Registry.PositionData` (adaptor + asset). Positions and adaptors need governance catalogue entries (`positionCatalogue`, `adaptorCatalogue`).
- Accounting: `totalAssets` loops `creditPositions`/`debtPositions` calling `_balanceOf(position)` (`Cellar.sol` L1013, L1019). Per-position live read.
- Permissions: `callOnAdaptor` gated by `_isAuthorized()` (solmate Auth → Authority; strategist or Automation contract). `_makeAdaptorCalls` (L1284-1294) checks only `adaptorCatalogue[adaptor]`, then `adaptor.functionDelegateCall(callData)` for each `callData`. Permission granularity = whole adaptor, not per function. Post-check: `totalAssets` within `allowedRebalanceDeviation` band and `totalSupply` unchanged; `blockExternalReceiver` set during call.
- Position removal: `removePosition` requires `_balanceOf == 0`; `forcePositionOut` is governance-only, bypasses that check.
- Shared registry: Registry holds trusted adaptors/positions; adding one needs Registry multisig AND Sommelier governance (`docs/permissions.md`, primary). PriceRouter multisig, 7-day timelock (docs).
- Governance/deploy: per-cellar contracts; governance-controlled catalogues.
- Incidents: 0xMacro report items A-4 (minHealthFactor) and A-16a (Morpho `balanceOf` ignores accrued interest) `[UNVERIFIED]` (search summary; A-16a would be a direct accounting-coverage bug). Audits: Macro Sommelier-3/-4; A-8 to A-14 (`[UNVERIFIED]` contents).
- Assessment [INFERENCE]: the adaptor is the one-declaration-per-protocol pattern (same contract holds `balanceOf` and strategist-callable functions). But the permission surface is "any function on a catalogued adaptor", so the declaration does not bound the call surface. Accounting uses the same position id that permissions use, so coverage and catalogue share a key.

### 1.3 Veda BoringVault / Arctic (`Veda-Labs/boring-vault`, pragma 0.8.21)
- Declaration: Merkle leaves per strategist: `keccak256(abi.encodePacked(decoder, target, valueNonZero, selector, packedArgs))`. Decoder/sanitizer (`DecodersAndSanitizers`) decodes args and checks them (e.g., recipient = vault).
- Accounting: separate contract `AccountantWithRateProviders`. Exchange rate pushed off-chain, rate-limited, bounded. Bounds: min upper 1e4, max lower 1e4, max update delay 14 days, max platform fee 20%, max performance fee 50%. Out-of-bound update pauses Accountant and Teller (`AccountantWithRateProviders.sol`, read to L300; L300-628 `[UNVERIFIED]` unread). Note 6-decimal truncation in fee conversion (read).
- Permissions: `ManagerWithMerkleVerification.manageVaultWithMerkleVerification(bytes32[][], address[] decodersAndSanitizers, address[] targets, bytes[] targetData, uint256[] values)`. `manageRoot` per strategist, owner-set. Post-batch `totalSupply` must be unchanged (`TotalSupplyMustRemainConstantDuringPlatform`).
- Shared registry: no. Permission tree and rate are independent. Decoders are shared per protocol but the tree is per strategist.
- Governance: owner-set roots and bounds; pause MULTISIG role. Per-vault deployment.
- Incidents/audits: 0xmacro, Certora, Sigma Prime, Spearbit arctic-0 (README, contents `[UNVERIFIED]`).
- Assessment [INFERENCE]: the tightest permission model in the survey (per-call leaves with arg sanitization), with zero link to accounting; valuation is an off-chain rate. The totalSupply check guards shares, not assets.

### 1.4 Morpho Vault V2 (`morpho-org/vault-v2`, GPL-2.0-or-later core; MIT elsewhere)
- Declaration: adapters (`MorphoMarketV1AdapterV2`, `MorphoVaultV1Adapter`, Midnight fixed-rate). Each adapter has `adapterId`, collateral-token ids, and market-param ids. Caps keyed by id (`VaultV2.sol` L89-97: optional adapter registry).
- Accounting: `realAssets()` loops the adapter's market set calling `expectedSupplyAssets`. If that reverts, `realAssets` reverts and `accrueInterest` is blocked (DoS, read in source).
- Permissions: `allocate`/`deallocate` are parentVault-only. Allocator moves capital; curator sets absolute and relative caps. Relative caps constrain allocations only, not withdrawals. `forceDeallocate` penalty up to 2%. Sentinel role. Timelocks on curator changes except `decreaseAbsoluteCap`/`decreaseRelativeCap`; `abdicate`.
- Shared registry: optional adapter registry; factory `VaultV2Factory`. Contracts immutable; per-vault deployment.
- Governance: Owner, Curator, Allocator(s), Sentinel. Fees: perf ≤50%, mgmt ≤5%/yr. Certora-verified (README `[UNVERIFIED]` for report contents).
- Doc conflict: mintlify mirror says increases are timelocked; GitHub README authoritative (only decrease-cap skips timelock).
- Assessment [INFERENCE]: the only surveyed design where coverage is complete by construction: every allocation goes through an adapter, and the adapter values what it holds. Permission (caps, allocator) and accounting are keyed on the same ids. Risk: the valuation view is on the critical path of accrual.

### 1.5 Lagoon v0 (`hopperlabsxyz/lagoon-v0`, BUSL-1.1)
- Declaration: none. Assets are not declared; NAV is a number.
- Accounting: `updateNewTotalAssets` (`onlyValuationManager`, `Vault-v0.6.0.sol` L462-491). Blocked while sync ops are valid (must `expireTotalAssets` first). Price per share proposed off-chain, checked against guardrails `isCompliant(currentPps, nextPps, timePastSinceLastValuationUpdate)`. First update (lastFeeTime == 0) unchecked. Security council `securityCouncilUpdateTotalAssets` (`onlySecurityCouncil`, L496) bypasses guardrails. `updateTotalAssetsLifespan` (`onlySafe`, L453): totalAssets expires.
- Permissions: Safe-operated; `onlySafe` gates Safe-only functions. Roles module not read (`src/v0.6.0/vault/Roles.sol` 404 on raw `main`/`master`) `[UNVERIFIED]`.
- Shared registry: `protocol-v2` ProtocolRegistry, LogicRegistry, FeeRegistry; `protocol-v3` OptinProxyFactory. Per-fund proxies (BeaconProxy in v1, Optin in v2/v3) `[UNVERIFIED]` for upgrade authority.
- Incidents: Nethermind v0.5.0 (critical mint-without-assets, fixed; high pending-assets-moved) `[UNVERIFIED]`.
- Assessment [INFERENCE]: NAV is an operator claim bounded by per-update rate guardrails. No declaration, so no coverage guarantee. Guardrail is the only control; first update and security-council path are explicit exceptions.

### 1.6 Aera v3 (`aera-finance/aera-contracts-public/v3`)
- Declaration: none on-chain; operations are guardian-submitted, validated by per-guardian merkle roots (`guardianRoots`).
- Accounting: `PriceAndFeeCalculatorV2` (`ORACLE_REGISTRY` immutable): per-vault anchor/drift price. `setAnchorPrice` is accountant-only; bad anchor auto-pauses if `pauseOnBadAnchorUpdate`. `setDriftPrice` only inside anchor band. Fees accrue on anchor updates.
- Permissions: `BaseVault.submit(bytes)` callable by guardians only; `_beforeSubmitHooks`/`_afterSubmitHooks`; `_noPendingApprovalsInvariant`. `setGuardianRoot`, `removeGuardian`, `setSubmitHooks`, `unpause`: owner/authority. `checkGuardianWhitelist` permissionless, removes non-whitelisted guardians. Pause by auth or guardian. Immutable `WHITELIST`.
- Periphery: `Executor.execute(OperationPayable[])` nonReentrant, raw calls, `_checkOperation` hook.
- Shared registry: `OracleRegistry`; permission roots per guardian; no shared permission/valuation declaration.
- Incidents: Cantina race in guardian removal (`BaseVault.sol#L140-L149`) `[UNVERIFIED]` (search summary; not re-read this session).
- Assessment [INFERENCE]: permission side is merkle-per-guardian; accounting side is accountant-pushed price. Two independent trust roots.

### 1.7 Mellow Flexible Vaults (`mellow-finance/flexible-vaults`, BUSL-1.1, pragma 0.8.25)
- Declaration: none unified. Permissions are declared in `src/permissions/Verifier.sol` by verification type: `ONCHAIN_COMPACT` (EnumerableSet of (who, where, selector)), `MERKLE_EXTENDED` (who, where, value, data hash), `MERKLE_COMPACT` (who, where, selector), `CUSTOM_VERIFIER` (external contract). Leaf = double keccak of `(verificationType, keccak(verificationData))`. `verifyCall` reverts `VerificationFailed`.
- Accounting: `src/managers/RiskManager.sol`: balances pushed via `modifyVaultBalance` / `modifySubvaultBalance` (role or queue). `convertToShares` uses oracle `getReport` with `isSuspicious` check. Limits: `setVaultLimit`, `setSubvaultLimit`, `allowSubvaultAssets`, `disallowSubvaultAssets`.
- Permissions roles: `SET_MERKLE_ROOT_ROLE`, `CALLER_ROLE`, `ALLOW_CALL_ROLE`, `DISALLOW_CALL_ROLE` (via `vault().hasRole`).
- Shared registry: no. Permission verifier and risk manager are separate contracts; balances are not derived from declared positions.
- Governance: Notion docs for Factories/Hooks/Modules/Oracles/Permissions/Queues/Vaults (README; unread `[UNVERIFIED]`). Factories and hooks are per-vault.
- Incidents/audits: Nethermind 2025-08 to 2026-06; Sherlock 2025-08/09; MixBytes 2026-07 (SyncRedeemQueue). Sherlock 2025-07-28: `ShareManager.sol:L139` `updateChecks` inverted, fix status `[UNVERIFIED]`.
- Subvault source (`src/accounts/Subvault.sol`) returned 404 on raw; not read `[UNVERIFIED]` for subvault execution model.
- Assessment [INFERENCE]: permission model is the most explicit verifier-type catalogue in the survey (ONCHAIN_COMPACT is closest to an allowlist per position). Balance is push-updated; coverage is a risk-manager claim, not derived.

### 1.8 Euler Earn (`euler-xyz/euler-earn`, GPL-2.0-or-later)
- Declaration: strategies = accepted ERC-4626 (EVK) vaults, max 30, one underlying per vault. Supply cap per strategy (default 0). Idle supply via escrow vault.
- Accounting: MetaMorpho v1.1 model: strategy value via ERC-4626 `convertToAssets` `[UNVERIFIED]` exact function; no position-level declaration beyond strategy address.
- Permissions: Owner (curator, allocators, guardian, fee ≤50%, fee recipient; timelock controls); Curator (caps, timelocked increases, forced removal submit); Allocator (supplyQueue, withdrawQueue, reallocate); Guardian (revoke pending timelock/cap/removal/guardian). Timelock 24h–2w, zero at setup.
- Shared registry: `EulerEarnFactory` (immutable instances). Public allocator `[UNVERIFIED]`.
- Governance: timelocked owner/curator; runbooks in README for unsafe strategy, reverting strategy, curator takeover, allocator takeover.
- Audits: Certora, Enigma Dark, Pashov, Sigma Prime (README; contents `[UNVERIFIED]`).
- Assessment [INFERENCE]: strategy caps are the permission surface; accounting is the ERC-4626 surface of each strategy. Coverage = strategy set; no per-position adapter.

### 1.9 Yearn V3 (`yearn/yearn-vaults-v3/TECH_SPEC.md`)
- Declaration: strategies added by ADD_STRATEGY_MANAGER; debt allocated per strategy (`current_debt`).
- Accounting: `process_report` per strategy compares `totalAssets` vs `current_debt`; profit locked and unlocked linearly; losses offset by locked profit. Accountant periphery returns fee shares.
- Permissions: roles only: ADD_STRATEGY_MANAGER, REVOKE_STRATEGY_MANAGER, FORCE_REVOKE_MANAGER, ACCOUNTANT_MANAGER, QUEUE_MANAGER, REPORTING_MANAGER, DEBT_MANAGER, MAX_DEBT_MANAGER, DEPOSIT_LIMIT_MANAGER, WITHDRAW_LIMIT_MANAGER (also controls transfer hook), MINIMUM_IDLE_MANAGER, PROFIT_UNLOCK_MANAGER, DEBT_PURCHASER, EMERGENCY_MANAGER. `role_manager` assigns roles. Shutdown irreversible.
- Shared registry: none. Permission and accounting share the strategy address only.
- Incidents: documented gotcha: WITHDRAW_LIMIT_MANAGER can brick transfers (spec). `set_open_role` permissionless claim `[UNVERIFIED]`.
- Assessment [INFERENCE]: a coverage model without per-position declaration; relies on strategy `totalAssets` report.

### 1.10 Centrifuge (`centrifuge/protocol`, BUSL-1.1 with GPL exceptions)
- Declaration: hub-and-spoke. `Holdings` (per pool/asset, snapshot hook `ISnapshotHook`) registers holdings; hub does NAV/pricing.
- Accounting: `NAVManager` (`INAVHook`) abstracts holding management and NAV; `SimplePriceManager` computes share price for single-class pools (`docs/architecture/managers/hub-managers.puml`, primary).
- Permissions: `Supervisor` per-pool sentinel registry; sentinels can veto pending authorizations within a delay window. `IManagerCallFromHub`/`IManagerCallFromSpoke`; `Envoy` routes calls. Optional per-pool policy bounds managers; outside policy needs timelocked authorization (README).
- Shared registry: core immutable with opt-in extensions (hook, spoke manager, hub manager, valuation, adapter). Per-pool deployment.
- Audits: Spearbit 2024-08, Cantina, Sherlock, burraSec, FV, yAudit 2025–2026 (`docs/audits/` PDFs, unread `[UNVERIFIED]`).
- Assessment [INFERENCE]: the holdings registry is the one declared-position list that feeds NAV (snapshot hook). Permission is manager/policy-scoped, not holding-scoped `[UNVERIFIED]` whether permission ever references holdings.

### 1.11 Superform v2-periphery (`superform-xyz/v2-periphery`, Apache-2.0)
- Declaration: strategy hook bundles executed by `SuperVaultStrategy`; hooks are per-protocol contracts.
- Accounting: ECDSA validator-signed PPS oracle (`ECDSAPPSOracle` → `SuperVaultAggregator`). Single PPS source; PPS HWM in strategy.
- Permissions: manager authorization and pause in `SuperVaultAggregator` (registry/factory). SuperGovernor roles SUPER_GOVERNOR, GOVERNOR, GUARDIAN, BANK_MANAGER; timelocked.
- Shared registry: Aggregator (factory + registry).
- Audits: Cantina 2025-06, GetRecon 2025-11, 0xMacro 2025-11, octane 2025-11 (PDFs unread `[UNVERIFIED]`). Known issues #987/#1015 (bridge best-effort) `[UNVERIFIED]`.
- Assessment [INFERENCE]: hooks are shared per-protocol adapters but accounting is validator-signed, not derived from hooks.

### 1.12 Gauntlet / Steakhouse (`Steakhouse-Financial/box`)
- `[UNVERIFIED]` allocator source and exact composition; not read. Operates MetaMorpho/Morpho V1 vaults; coverage = vault list with per-market caps (Morpho V1 model).

## 2. Comparison table

| System | Where positions declared | NAV derived from declaration? | Permissions derived from declaration? | Shared registry for both? | Per-fund deploy | Registry governance |
|---|---|---|---|---|---|---|
| Enzyme | Per-fund external position instance + global type (lib, parser) | Yes (`getManagedAssets`/`getDebtAssets` in lib) | Partly: parser declares assets moved per action; gate = `canManageAssets` + policies | Yes (type registry shared, instances per-fund) | Yes | Fund deployer owner |
| Sommelier | Cellar position arrays + adaptor (catalogued) | Yes (`balanceOf` per position) | No: whole adaptor callable (`_makeAdaptorCalls`) | Partly (Registry; same position ids) | Yes | Registry multisig + Sommelier governance |
| Veda | Merkle leaves per strategist | No (off-chain rate) | Yes (decoder + target + selector + args) | No | Yes | Owner |
| Morpho V2 | Adapter ids (caps, market ids) | Yes (`realAssets` over adapter markets) | Partly (caps, allocator; not per-call) | Yes (ids shared) | Yes (factory) | Owner, Curator, Timelock |
| Lagoon v0 | None | No (pushed NAV + guardrail) | Safe/Roles `[UNVERIFIED]` | No | Yes (proxies) | Protocol registries |
| Aera v3 | None (guardian merkle) | No (anchor/drift pushed) | Yes (merkle per guardian) | No | Yes | Owner/authority |
| Mellow | Verifier types (ONCHAIN_COMPACT, MERKLE_*) | No (push-updated balances) | Yes (verifier) | No | Yes | Role-based |
| Euler Earn | Strategy set (EVK vaults) | Partly (ERC-4626 `convertToAssets`) | Partly (caps, queues) | No | Yes (factory) | Owner/curator timelock |
| Yearn V3 | Strategy set | Partly (`process_report`) | Roles only | No | Yes | Role manager |
| Centrifuge | Holdings (per pool) | Yes (NAVManager + Holdings hook) | Manager/policy-scoped | Partly (hub) | Per pool | Timelocked authorization, Supervisor |
| Superform | Strategy hook bundle | No (validator-signed PPS) | Aggregator authorization | Yes (Aggregator) | Yes | SuperGovernor |

## 3. Closest system to FundConfig

- Enzyme: one shared (type-level) registration per protocol with two functions (lib for accounting, parser for asset movement), and per-fund instances. Matches the FundConfig shape most directly.
- Sommelier: matches the adaptor-as-unit idea but does not bound the call surface.
- Morpho V2: matches the "coverage complete because all routes go through the adapter" argument, with caps keyed by the same ids.
- Centrifuge: the holdings registry is the single declared-position list feeding NAV.

No system matches FundConfig fully: none emits a complete call allowlist from the same declaration that feeds NAV.

## 4. Patterns to steal

- Per-protocol immutable adapter exposing both `balances(fund)` (accounting) and a call-scope descriptor (permissions) (Enzyme parser + lib; Sommelier adaptor).
- Permissions bound to (target, selector, argument constraints), not whole contracts (Veda leaf with decoder/sanitizer; Mellow `MERKLE_EXTENDED`).
- Post-batch invariant checks: totalSupply unchanged (Veda), totalAssets within deviation band and shares unchanged (Sommelier `callOnAdaptor`).
- Timelock exceptions only for risk-reducing actions (Morpho V2 decrease-cap; Euler Earn; Superform GOVERNOR).
- Registry of trusted adapters with two-party approval (Sommelier Registry multisig + governance).
- Separate guardian/sentinel role that can only pause or revoke (Euler Earn guardian; Morpho Sentinel; Centrifuge Supervisor veto).
- Stale-gated clears, permissionless (Aera guardian whitelist check; Mellow stale-gated clears in this repo's attested family).

## 5. Pitfalls

- Parser/lib drift: the asset-movement declaration (permissions) and the valuation (accounting) are two code paths. Enzyme's parser and lib can disagree; add a test that asserts the set equality.
- Whole-adaptor allowlists (Sommelier): any function on a catalogued adaptor is callable.
- Valuation on the critical path: Morpho V2 `realAssets` reverts if one market view reverts, blocking accrual.
- Under-reported `balanceOf` (Sommelier A-16a, `[UNVERIFIED]`): accrued interest omitted.
- Push-based NAV with a first-update exception and a security-council bypass (Lagoon): guardrail is only as tight as the first update.
- Guardian removal race (Aera, `[UNVERIFIED]`).
- Transfer hooks as brick vector (Yearn WITHDRAW_LIMIT_MANAGER).
- Mutable registries: type registries (Enzyme) and protocol registries (Lagoon) change trust for all funds at once.
- Fee rounding truncation (Veda 6-decimal fee conversion).
- Bridge best-effort (Superform #987/#1015, `[UNVERIFIED]`).

## 6. Recommendation for kpk

Build FundConfig as a single declaration that generates both outputs, and enforce the equality in CI rather than trusting it at runtime.

1. Shared immutable adapter per protocol, one per position type (Enzyme shape). Each adapter exposes:
   - `positions(fund) -> PositionBalance[]` for NAVCalculator (existing `IBalanceAdapter` interface; amounts positive; `isDebt`).
   - `permissions(params) -> (target, selector, argConstraints)[]` for Roles scoping (DeFi Kit output). Constrain args (recipient = fund Safe, asset = declared asset), as Veda leaves do.
2. FundConfig lists position instances with adapter ids. Two generators run from it:
   - NAV adapter set and `addBalanceAdapters` / `addMetaInstances` (`06_Configure`).
   - Roles allow-list (per-fund Zodiac Roles role).
3. Completeness check in CI: the Roles allow-list must reference only targets that some adapter in the config declares; each NAV adapter's declared asset set must match the permission-side asset movement set. This closes the assisted-family residual risk in CLAUDE.md (roles-permission change adding an unlisted path) because the allow-list is generated, not hand-maintained.
4. Keep the assisted/attested families (ADR 0015/0018/0022/0030) as the exception path. Their completeness rests on the roles allow-list; generated allow-lists make that rest on a test.
5. Governance: the shared adapter set is immutable (repo convention). Adding an adapter type is a new adapter contract plus a governance-gated registry entry (two-party, Sommelier-style). Per-fund configs are upgradeable only via a new config version, not by mutating adapters.
6. Avoid Morpho V2's `realAssets` DoS shape: adapters should isolate per-position valuation failures (fail-open per position, then the health flag, as the repo's `getAccountNavForAdapters` union-of-health flags already does).
7. Do not copy Sommelier's whole-adaptor allowlist: the generated Roles set must be per (target, selector).
8. Do not copy Lagoon/Mellow/Veda off-chain NAV as the only accounting path; keep on-chain coverage (adapter-derived) and treat off-chain push as a bounded cross-check.

Open items to verify before design freeze: Lagoon `Roles.sol`/`GuardRailsManager.sol` (404); Enzyme gmx-v2 finding content; Sommelier A-4/A-16a text; Aera Cantina race; Mellow subvault execution model (`src/accounts/Subvault.sol` 404); Veda accountant L300-628 and decoder folder; Centrifuge Holdings ↔ permission linkage.

## 7. [UNVERIFIED] register

- Enzyme "Onyx"/"Sulu" naming; gmx-v2 audit content; parser set-equality tests.
- Sommelier 0xMacro A-4, A-16a, A-8 to A-14 content.
- Veda Accountant L300-628; decoders folder; audit reports.
- Lagoon `Roles.sol`, `GuardRailsManager.sol` (404); Nethermind v0.5.0 findings; Safe/Roles execution path.
- Aera Cantina guardian-removal race (`BaseVault.sol#L140-L149`); Aera 20/80 fee split; v3 repo location.
- Mellow `src/accounts/Subvault.sol` (404); Lazy Mellow naming; Sherlock 2025-07-28 ShareManager L139 fix status.
- Euler public allocator; exact `totalAssets` function.
- Yearn `set_open_role` permissionless claim.
- Centrifuge Holdings ↔ permission linkage; hub addresses; `src/managers` tree (rate-limited).
- Superform #987/#1015 bridge issues; audit PDF contents.
- Steakhouse/Gauntlet allocator source.
- Morpho V2 doc conflict resolved in favor of GitHub README; mintlify mirror unread.
