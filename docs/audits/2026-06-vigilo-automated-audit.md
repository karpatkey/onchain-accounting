# Vigilo Automated Security Audit — onchain-accounting

**Date:** 2026-06-27
**Scope:** All contracts under `src/**` (124 files: balances adapters, prices, NAV, bridge, proxy, deployment, utils) and deployment scripts under `script/deploy/*` (01–07 + atomic deployers + `DeploySalts`).
**Method:** Vigilo multi-agent pipeline — recon (explorator + speculator) → 6 specialist auditors (oracle, access-control, cross-chain, logic, reentrancy, defi) → **independent adversarial verification of every High finding** → severity-corrected consolidation.
**Out of scope:** `test/**`, `lib/**` (dependencies), mocks.

> ⚠️ **Read this first.** The raw per-auditor output produced **9 "High" findings**. Independent adversarial re-verification against the code **refuted or downgraded 8 of them** (3 were already-fixed or factually wrong; the rest are trust-model- or config-gated Mediums/Lows). The raw findings live under `.vigilo/findings/`; verdicts under `.vigilo/verification-verdicts.md`. **This report is the authoritative, verified view** — prefer it over the raw files.

---

## Result at a glance

| Severity | Count | Notes |
|---|---|---|
| **High** | 1 | Superchain dual-L2 address confusion (design; no code guard) — matches a known open issue |
| **Medium** | 15 | Mostly valuation-accuracy and bridge-lifecycle correctness; several trust-model-bounded |
| **Low** | ~11 | Defense-in-depth, griefing, footguns |
| **Refuted / Invalid / Already-fixed** | 3 (all originally "High") | SafeCast DoS, proxy front-run, sUSDe share-unit |

**Positive result (verified):** The headline security invariant of the assisted balance-adapter family — *the assistant can only under-report, never over-report* — **holds** for all three adapters (Merkl, ether.fi, StakeWise V3). Proofs are bound to the live Merkl Distributor root; exit-queue adapters re-verify on-chain ownership and read amounts live on every call. See "Assisted-adapter invariant" below.

---

## Refuted / already-fixed (do not action)

These were emitted as High by individual auditors but did not survive verification:

1. **SafeCast `toInt256` DoS in price selection — ALREADY FIXED.** `PriceFeedLib.sol:102` bounds-checks `customPrice > type(int256).max` and `continue`s before the cast (commit `887ac32`). The cast is also per-feed inside the selection loop, so a bad feed is skipped, not fatal. (Raw: `findings/high/access-control/H-01`, `findings/low/access-control/L-01`.)
2. **Proxy `initialize()` front-run — NOT POSSIBLE.** `script/deploy/AtomicProxyDeployer.sol` / `AtomicNAVProxyDeployer.sol` deploy the proxy **and** call `initialize` inside a single constructor (one transaction); the `initializer` modifier blocks re-init. A prior v1 front-run incident was already remediated by a salt bump (`02_DeployProxies.s.sol` history comment). (Raw: `findings/high/access-control/H-02` proxy portion, `findings/medium/access-control/M-07`.)
3. **sUSDe / sUSDS wrong share-unit — FACTUALLY WRONG.** Both feeds call `convertToAssets(10 ** _vaultDecimals)` and divide by `10 ** _vaultDecimals`; the unit is correct. The authoring agent itself flagged it as misread. (Raw: `findings/high/oracle/H-03`.)

---

## High

### H-1 — Single Superchain L1 adapter cannot disambiguate Optimism vs Base
**Location:** `src/bridge/adapters/SuperchainBridgeAdapter.sol` (`_authenticateMessengerSource`, `initialize`), `src/bridge/BridgeAdapter.sol` (`trustedRemoteAdapter` mapping).
**Status:** CONFIRMED (design). Matches the project's own known-open "Superchain L1-hub" issue.

Adapters deploy via canonical CREATE2, so the L2 sibling has the **same address** on Optimism (10) and Base (8453). On L1 a single `SuperchainBridgeAdapter` is initialized with exactly one `l2Messenger` / `optimismPortal`, but `setTrustedRemoteAdapter` can register both chain ids — and because the sibling address is identical, `trustedRemoteAdapter[10] == trustedRemoteAdapter[8453]`. Authentication checks `msg.sender == l2Messenger` and `xDomainMessageSender() == trustedRemoteAdapter[srcChainId]`; neither binds the *claimed* source chain id to a chain-specific messenger when one adapter is wired for two L2s. A withdrawal proven via the configured portal/messenger can be accepted while *claiming* the other L2's chain id.

**Impact:** Cross-L2 impersonation / wrong-chain delivery if a single L1 adapter is ever configured for both L2s. There is **no code-level guard** preventing the misconfiguration.
**Recommendation:** Deploy **separate** L1 `SuperchainBridgeAdapter` instances per L2 (distinct salts), each wired to exactly one portal/messenger; and add a runtime guard so `setTrustedRemoteAdapter` reverts on a second distinct chain id for an instance already bound to one L2. Encode the bound chain id into authentication.

---

## Medium

> Severity rationale: items marked *(trust-bounded)* require a compromised/malicious privileged role (MANAGER / security council) and are bounded by the funded-pass-through escrow design (escrow pulls from the adapter, never a standing balance) and the authorized-account allowlist. They are real residual risks but not externally exploitable by an arbitrary attacker.

### M-1 — Across source authentication is weak; MANAGER completion path trusts caller-supplied source chain *(trust-bounded)*
**Consolidates:** cross-chain H-01 (tautological `_authenticateSource`), cross-chain H-04, access-control M-06.
**Location:** `src/bridge/adapters/AcrossBridgeAdapter.sol` (`_authenticateSource`, `_completeBridge` ~L157–167, `handleV3AcrossMessage` ~L216).
`_authenticateSource(uint64 sourceKey, uint24 claimed)` compares two values that are the same variable, so the only real gate is `trustedRemoteAdapter[sourceKey] == address(this)`. The Across V3 callback does not surface the source depositor, so the sibling-sender cannot be cryptographically verified — defense rests on the escrow checksum + funded pass-through. In the MANAGER `_completeBridge` path, `sourceChainId` is decoded from caller-supplied `protocolData`, so a compromised MANAGER can satisfy the check and redirect **already-delivered** funds to any **authorized** account. Not arbitrary-amount, not arbitrary-recipient, not reachable by a non-privileged attacker.
**Recommendation:** Land the planned adapter-provenance work (per-invoice source-sender record); remove the tautological parameter; constrain the MANAGER recovery path to invoices with a recorded provenance entry.

### M-2 — LST/restaking custom feeds lack rate-reasonableness / protocol-health bounds
**Consolidates:** oracle H-02 (downgraded), defi M-02 (ankrETH), oracle M-01 (ezETH `calculateTVLs`), logic M-01 (ezETH_L2 keeper rate).
**Location:** `src/prices/BaseCustomPriceFeed.sol:75`, `src/prices/protocols/{rETH,wstETH,cbETH,ETHx,rsETH,ankrETH,ezETH,ezETH_L2}_CustomPriceFeed.sol`.
These feeds read a protocol exchange rate (`getExchangeRate`/`stEthPerToken`/`ratio`/keeper rate) and gate only on `rate == 0`. For the live-computed ratios (Lido, Rocket Pool, Coinbase, Stader, Kelp, Ankr) "staleness" is not push-timestamped, so the real exposure is a **paused/compromised protocol or a bridged/keeper rate freezing** (ezETH_L2, ankrETH `ratio()`) and the absence of sanity bounds. A frozen or manipulated rate is multiplied by a fresh Chainlink anchor and passes silently.
**Recommendation:** Add deviation/bounds checks (min/max plausible rate, max deviation vs. previous) and, for keeper/bridged rates (ezETH_L2, ankrETH), an explicit freshness gate. Document which feeds rely on protocol-liveness assumptions.

### M-3 — Rate-only custom-feed timestamp sentinel can dominate freshest-wins selection (latent / config-gated)
**Location:** `src/prices/PriceFeedLib.sol:110` (`updatedAt = lrdUpdatedAt == 0 ? block.timestamp - 1 : lrdUpdatedAt`), selection at `:137`.
A custom feed returning `updatedAt == 0` is assigned `block.timestamp - 1`, which beats any real Chainlink feed updated ≥1s ago in the "freshest non-stale wins" race — defeating a Chainlink cross-check if both were ever registered for one asset. **Currently latent:** no registered asset pairs a rate-only custom feed with a Chainlink feed (verified against `script/config/nav-config/assets-and-price-feeds/1.json`; only ETH/WETH have dual feeds and neither is rate-only). Also see access-control M-01 (future-timestamp clamping) — same selection surface.
**Recommendation:** Don't synthesize a near-now timestamp for rate feeds; either carry the real underlying `updatedAt` or treat custom feeds as a tie-broken fallback rather than a freshness winner. Add a config-time assertion preventing a rate-only feed from being co-registered with a market feed.

### M-4 — ERC4626-based valuation: donation/inflation sensitivity and `convertToAssets` ignores redeem fees
**Consolidates:** oracle M-05 (donation), defi M-01 (`convertToAssets` vs `previewRedeem`), logic M-03 / defi M-05 (Aave Umbrella double-hop wrapper).
**Location:** `src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol:190`, `src/balances/MetaBalanceAdapters/MorphoVaultsMetaBalanceAdapter.sol:49`, `src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol:282`, ERC4626-backed price feeds (sGHO/sUSDe/syrupUSDC/RWIV/sXDAI/sUSDS).
Valuation via `convertToAssets`/`totalAssets` is donation/inflation-influenceable for low-liquidity vaults and, per EIP-4626, omits redemption fees that `previewRedeem` would include — overstating NAV for any fee-on-redeem vault. The Aave Umbrella `_isErc4626Wrapper` heuristic (`convertToAssets(0) == 0`) is also fragile for vaults using a decimals offset.
**Recommendation:** Prefer `previewRedeem` for redeemable positions; add donation-resistance assumptions to the price-feed docs; replace the `convertToAssets(0)` heuristic with an explicit wrapper allowlist/typecheck.

### M-5 — NAV double-count when an ERC4626 wrapper is tracked by both the wrap adapter and a custom feed / ERC20Default
**Location:** `src/balances/BalanceAdapters/ERC4626WrapBalanceAdapter.sol`, config `script/config/nav-config/balance-adapters/1.json`.
If a wrapper token is valued both as wrapper-shares (custom feed) and as the converted underlying (wrap adapter), the same value is counted twice. Caught manually for RWIV (disabled in config) but no on-chain guard prevents recurrence for sGHO/sUSDS/syrupUSDC or future wrappers.
**Recommendation:** Add a registration-time invariant on `NAVCalculator` that rejects registering the same asset under both a wrap adapter and a direct price feed.

### M-6 — Lido withdrawal queue overstates non-finalized requests after a negative rebase
**Location:** `src/balances/BalanceAdapters/LidoWithdrawalQueueBalanceAdapter.sol:126`.
Non-finalized requests are valued at `amountOfStETH` (frozen at request time); after validator slashing the finalized payout is capped lower. The adapter's own NatSpec acknowledges this with no code mitigation. Window: request → finalization.
**Recommendation:** Cap non-finalized value using the current share rate (mirror Lido's finalization cap), or document as accepted with monitoring.

### M-7 — Convex CVX rewards overstated by time-of-check cliff
**Location:** `src/balances/MetaBalanceAdapters/ConvexRewardsMetaBalanceAdapter.sol:329`.
`_cvxMintAmount` computes the emission cliff from the *current* `totalSupply`; actual mint happens at claim, by which point the supply may have crossed a cliff, lowering the multiplier. Over-reports pending CVX for large long-held CRV balances.
**Recommendation:** Document as an upper-bound estimate, or apply a conservative cliff margin.

### M-8 — `answeredInRound` not checked; an incomplete Chainlink round passes the staleness gate
**Location:** `src/prices/PriceFeedLib.sol` (Chainlink path, ~L120–133).
Staleness uses `updatedAt`/heartbeat and `answer > 0` but not round completeness (`answeredInRound`/`updatedAt != 0` on the returned round). A carried-over incomplete round can slip through.
**Recommendation:** Reject rounds where `updatedAt == 0`; consider `answeredInRound >= roundId` where the feed exposes it.

### M-9 — Stale asset price is silently zeroed in valuation with no per-asset stale flag surfaced
**Consolidates:** oracle M-04 (`calculateValue`), access-control M-02 (quote-asset stale not flagged in positions).
**Location:** `src/prices/PriceFeedLib.sol` (`calculateValue`), `src/nav/NAVCalculator.sol` positions/verbose path.
When all feeds for an asset are stale the value contributes 0 but the per-asset/per-position response carries no stale indicator, so a silently-dropped position is indistinguishable from a zero balance to consumers. (By design NAV does not revert on staleness — this is about *observability*, not a revert bug.)
**Recommendation:** Propagate a per-asset/per-position `stale` flag into the verbose NAV response so downstream consumers can detect dropped legs.

### M-10 — Bridge invoice-lifecycle correctness gaps
**Consolidates:** cross-chain M-02, M-03, M-04, M-05; access-control M-04.
**Location:** `src/bridge/BridgeEscrow.sol`, `src/bridge/adapters/{Cctp,Ccip,Stargate}BridgeAdapter.sol`.
- **`cancelInvoice` cannot refund ERC20** — it checks `balanceOf(escrow) >= amount`, but the funded pass-through already forwarded tokens to the adapter, so ERC20 cancellation always reverts (`BridgeEscrow.sol:262`). Stuck-funds path.
- **`revokeAdapter` has no active-invoice guard** (`BridgeEscrow.sol:511`) — revoking an adapter with in-flight invoices makes their destination release fail (`releaseByInvoiceId` requires the caller be an authorized adapter). Contrast `revokeAccount`, which does guard.
- **CCIP over-delivery** strands surplus — `>= data.amount` check releases only `data.amount`, leaving the remainder in the adapter (`CcipBridgeAdapter.sol:245`).
- **Stargate post-fee re-encode** changes the destination `checksum24`/hash vs. the source gross hash, so source `markInvoiceCompleted` and destination replay key diverge — a fee change between two delivery attempts could double-pay (`StargateBridgeAdapter.sol:182`).
- **CCTP nonce marked before `receiveMessage`** — if `receiveMessage` succeeds but `_fundAndRelease` reverts, Circle's nonce is consumed while the adapter state rolls back, permanently bricking the invoice on retry (`CctpBridgeAdapter.sol:212`).
**Recommendation:** Refund from the adapter (or via an adapter pull-back) in `cancelInvoice`; add an active-invoice guard to `revokeAdapter`; handle CCIP surplus; key the destination replay guard on the **source** invoice hash for fee-taking bridges; reorder CCTP so `receiveMessage` precedes irreversible state and balance checks precede nonce marking.

### M-11 — Gnosis MANAGER completion path reads live AMB context and bricks the fallback
**Location:** `src/bridge/adapters/GnosisBridgeAdapter.sol` (`_authenticateSource`, ~L209).
`amb.messageSender()` / `messageSourceChainId()` are only valid inside an active AMB callback. The MANAGER recovery path (outside a callback) reads stale/zero data or reverts, defeating the intended fallback for failed AMB deliveries.
**Recommendation:** In the MANAGER path, authenticate via stored/passed provenance rather than live AMB context.

### M-12 — `completeBridge` lacks `nonReentrant`; `depositAndBridge` leaves an open approval
**Consolidates:** reentrancy M-01, M-03.
**Location:** `src/bridge/BridgeAdapter.sol` (`completeBridge`), `src/bridge/BridgeEscrow.sol` (`depositAndBridge`).
`completeBridge` is the only completion entry point without `nonReentrant` (all auto-path callbacks have it). `depositAndBridge` `forceApprove`s the adapter and does not reset to 0 after `bridge()` returns, leaving a lingering allowance. The escrow's `releaseByInvoiceId` guard blocks the primary re-entry, so this is hardening rather than a proven drain.
**Recommendation:** Add `nonReentrant` to `completeBridge`; reset the approval to 0 after `bridge()`.

### M-13 — Balancer V2/V3 read-only reentrancy via stale `getPoolTokens`
**Location:** `src/balances/MetaBalanceAdapters/balancer/BalancerV2PoolLib.sol` (`shares` → `getPoolTokens`), `BalancerV3PoolLib.sol` (`getStablePoolDynamicData`).
Valuation reads Vault pool balances that can be mid-update during a join/exit/flash-loan, the classic Balancer read-only reentrancy vector — a consumer reading `getAccountNav` inside such a callback can observe a manipulated pool valuation.
**Recommendation:** Use Balancer's reentrancy-guard `ensureNotInVaultContext` (V2) / equivalent before reading pool balances, or read via a manipulation-resistant rate.

### M-14 — Deploy script 07 does not strip the deployer from the three assisted adapters
**Location:** `script/deploy/07_TransferAdminToSecurityCouncil.s.sol:57`.
07 hands off NAVCalculator, BridgeEscrow, and the 6 bridge adapters, but **not** `MerklRewardsBalanceAdapter`, `EtherFiWithdrawalQueueBalanceAdapter`, `StakeWiseV3ExitQueueBalanceAdapter`. The deployer EOA retains `DEFAULT_ADMIN_ROLE` on all three post-deploy and can grant/revoke `ASSISTANT_ROLE`. (Note: even a hostile assistant can only under-report per the verified invariant, so blast radius is bounded — but a lingering deployer admin role contradicts the intended handoff.)
**Recommendation:** Extend 07 to transfer `DEFAULT_ADMIN_ROLE` of the assisted adapters to the security council and renounce the deployer's.

### M-15 — Cap adapter: per-leg vs combined burn-quote inconsistency
**Location:** `src/balances/BalanceAdapters/CapBalanceAdapter.sol` (`getAdapterPositions` vs `getAdapterBalances`).
Positions path quotes `getBurnAmount` per leg (cUSD, stcUSD); balances path quotes once on the combined total. Under any non-proportional (fixed/tiered) fee the two diverge, and small legs can round to 0 individually while the combined clears the threshold.
**Recommendation:** Quote consistently (combined, then split pro-rata) or document the proportional-fee assumption.

---

## Low (defense-in-depth / footguns)

- **Bridge adapter `initialize` front-run (griefing only).** Adapters CREATE2-deploy then `initialize` in separate txs (`05`); a front-runner can seize adapter admin, but escrow authorization (`06`) + council handoff (`07`) + salt-bump redeploy keep funds safe. Mitigate by atomic deploy+init (constructor or `Create2Deployer` wrapper) or a deployer-bound init guard.
- **192-bit checksum replay key — widen to 256-bit for defense-in-depth.** Real forge cost is 2^192 (second-preimage), not 2^96; monotonic nonce already in the preimage. `InvoiceDataLib.calculateChecksum` / `BridgeEscrow` could store the full 32-byte hash.
- **No two-step admin transfer** on non-upgradeable bridge adapters and assisted adapters — a wrong/renounced admin is unrecoverable. Adopt `AccessControlDefaultAdminRules` or a 2-step pattern.
- **Feed registration does no price-sanity / liveness validation** (accepts a feed whose first read is 0/negative/stale); **ERC165 check is insufficient** to guarantee `AggregatorV3` semantics.
- **Stale return carries a real non-zero `updatedAt`** (custom feeds return `answer=0, updatedAt=<real>` when stale), misleading raw external callers; `CrossRate` returns mismatched round metadata.
- **Compound V3 `uint64` tracking-accrued overflow** can revert and silently drop a whole comet position (under-report direction; caught by per-instance try/catch).
- **CCTP completion has no ERC20 balance preflight** before consuming the nonce; **`registerAsset` TOCTOU** allows re-pointing an active symbol; **selectFeed custom path** makes an extra `latestRoundData` call (minor gas/grief).

---

## Assisted-adapter invariant — verified holding ✅

The user's primary concern (focus #3). For all three assisted adapters the *under-report-only* invariant **holds**:

- **Merkl** (`MerklRewardsBalanceAdapter.sol`): cached leaf `keccak256(abi.encode(user, token, cumulativeAmount))` is proof-verified against the **live** Distributor root at submit; reads subtract live `claimed()`; a root-staleness guard returns 0 when the cached root ≠ live root; `submitProof` rejects amount regressions. The assistant cannot fabricate or inflate an amount.
- **ether.fi** (`EtherFiWithdrawalQueueBalanceAdapter.sol`): cache holds request ids only; `ownerOf`/`isValid` re-checked every read; finalized requests valued via live `getClaimableAmount`, pending via the conservative `min(...)` of two live estimates minus fee. An NFT the account no longer owns contributes nothing.
- **StakeWise V3** (`StakeWiseV3ExitQueueBalanceAdapter.sol`): `calculateExitedAssets(receiver=account, …)` returns zero for a tuple the account doesn't own; ownership is enforced by the vault, not the cache.

The only residual is governance hygiene (M-14): the deployer keeps `DEFAULT_ADMIN_ROLE` on these adapters after handoff.

---

## Phase notes & limitations

- **No executable PoCs were generated.** After verification, the surviving findings are design-, trust-model-, or config-gated (Superchain misconfiguration, compromised-MANAGER paths, valuation-accuracy bounds, deploy-script hygiene). None is an arbitrary-attacker fund-drain with a single-tx Foundry repro, so PoC effort was deprioritized in favor of verification depth. The Superchain (H-1) and bridge-lifecycle (M-10) items are the strongest candidates if a repro is later wanted.
- Raw per-auditor findings: `.vigilo/findings/{high,medium,low}/<auditor>/`. Recon: `.vigilo/recon/`. Verification verdicts: `.vigilo/verification-verdicts.md`. Permission matrix: `.vigilo/findings/access-control-permission-matrix.md`.
- This is an automated audit and does not replace a manual review by a human auditor; treat the Mediums as a prioritized review queue, not a closed list.
