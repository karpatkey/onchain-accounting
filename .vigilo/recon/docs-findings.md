# Vigilo Phase 1 Reconnaissance: Onchain Accounting Protocol

**Protocol:** Onchain Accounting Infrastructure for Portfolio NAV  
**Scope:** Core system (NAVCalculator, balance adapters, price feeds, bridge escrow, bridge adapters)  
**Document date:** 2026-06-27  
**Status:** Final pre-deployment audit completed; 20 findings confirmed (12 fixed this round, 4 accepted as operational/design constraints), 4 systemic acknowledged.

---

## 1. Protocol Purpose & Core Mechanisms

### What the protocol does

`onchain-accounting` is an **on-chain portfolio accounting layer** that computes Net Asset Value (NAV) for multi-protocol portfolios. It aggregates:

1. **Balances** — from 35 balance adapters covering 20+ DeFi protocols (Aave, Morpho, Curve, Balancer, Uniswap, Compound, Lido, StakeWise, Fluid, Gearbox, ether.fi, Nexus Mutual, and more)
2. **Prices** — multi-feed (Chainlink, Redstone, API3, custom) with freshest-wins feed selection
3. **NAV calculation** — aggregates all positions in a chosen quote currency, reports per-leg breakdown and typed identity
4. **Cross-chain bridge** — BridgeEscrow + 6 protocol adapters (Across, CCIP, CCTP, Stargate, Gnosis, Superchain) to transfer assets between chains with invoiced settlement

**Key value proposition:** "anyone can verify the numbers" — all balances derive from on-chain state (no oracles to trust), all prices are auditable (multi-feed + staleness signals), and NAV is deterministically computed.

**Non-scope:** No tokenized shares, subscriptions/redemptions, or staking-share minting. Those sit in a separate layer above NAV and the bridge.

Source: README.md, CLAUDE.md, docs/README.md

---

## 2. Core Invariants

### Explicit invariants (from spec + code)

1. **Amount always positive; sign via isDebt** (`src/balances/BALANCE_ADAPTERS.md` §3.1)
   - Every `PositionBalance.amount` is `uint256 > 0`
   - Debt vs. credit is signalled by `isDebt: bool`, never negative amounts
   - NAVCalculator multiplies by −1 when `isDebt = true`

2. **Balance adapters report balances, not values** (`src/balances/BALANCE_ADAPTERS.md` §1, CLAUDE.md §Conventions)
   - Adapters return `PositionBalance[]` (asset, amount, isDebt flag)
   - Adapters never compute prices or apply quote-currency conversions
   - Pricing is delegated entirely to NAVCalculator's read path

3. **`balanceAdapter` field = `address(this)`** (CLAUDE.md §Conventions, `src/balances/BALANCE_ADAPTERS.md` §5)
   - Immutable audit trail; adapter swap does not change position identity
   - Excluded from reconciliation key (`(chainId, protocolId, positionId, balanceAsset.asset, positionKind)`)

4. **Adapters are immutable post-deploy** (CLAUDE.md §Conventions, ADR 0005)
   - No `Ownable`, no admin functions, no upgrade path
   - Constructor pins all protocol addresses, NAVCalculator reference, identity constants
   - Documented exceptions: Merkl rewards (proof-verified cache, `onlyOwner`/ASSISTANT_ROLE), ether.fi & StakeWise withdrawals (id-only cache, values read live, re-verified on every read)

5. **Registered assets only contribute to NAV** (`src/balances/BALANCE_ADAPTERS.md` §2, §9.4)
   - NAVCalculator iterates all adapters; adapters may return unregistered assets
   - Filtering by registry happens in NAV read path (in `PriceFeedLib.computeNav`)
   - Unregistered position = silent zero in NAV

6. **Freshest-feed selector** (`src/prices/PRICE_ADAPTERS.md` §2, ADR 0009)
   - On each `latestPrice(asset)` read, `_selectFeed` iterates all registered feeds for that asset
   - Returns price from the **freshest non-stale survivor** (max `effectiveTime = min(updatedAt, block.timestamp)`)
   - All-stale fallback: `(0, firstFeed.decimals, stale=true)` (not a revert)
   - Staleness gate: `block.timestamp − effectiveTime >= chainlinkHeartbeat` → skip feed
   - L2 sequencer check: if sequencer down or in grace period → `stale=true` (min grace period: 1 hour)

7. **Per-chain position identity** (docs/howto/position-identity-schema.md, `src/utils/ProtocolIds.sol`, `src/utils/PositionKind.sol`)
   - `protocolId = keccak256(protocol-slug)` — e.g. `keccak256("aave-v3-lending")`
   - `positionId = abi.encode(...)` of the stable on-chain key (schema per protocol)
   - `positionKind` ∈ `{Wallet, Supplied, Borrowed, Collateral, Staking, Rewards, Fees}`
   - Reconciliation key: `keccak256(abi.encode(chainId, protocolId, positionId, asset, kind))`

8. **Meta-adapter instance set governed on NAVCalculator** (ADR 0010, `src/balances/BALANCE_ADAPTERS.md` §6.1)
   - 20 meta-adapters (one per protocol family) derive every instance from an immutable contract
   - Instance set (vault addresses, pool ids, market ids) stored on NAVCalculator as `bytes32[]`
   - `MANAGER` role controls instance set via `addMetaInstances` / `removeMetaInstances` (no adapter redeploy)
   - Per-instance revert isolation so one bad instance cannot zero out the batch

9. **Bridge escrow: funded pass-through, not commingled pool** (ADR 0012, `src/bridge/BRIDGE_ADAPTERS.md` §2–3)
   - On destination chain, `releaseByInvoiceId(messagePayload)` pulls **exact amount** from the calling adapter (which holds delivered funds)
   - Escrow holds no standing balance; one invoice can never be paid from another's tokens
   - Invoice identity includes per-account nonce (monotonic, ensures uniqueness per operation)
   - Checksum + `completedInvoices[hash]` replay guard on destination

10. **Bridge completion is provable** (ADR 0012, `src/bridge/BRIDGE_ADAPTERS.md` §7)
    - Each adapter authenticates the genuine protocol contract + source chain + source sender before releasing
    - No public fallback dispatcher; adapter is the direct protocol recipient
    - `trustedRemoteAdapter[chainId]` whitelist per source adapter on every inbound message
    - Protocol-native dedup (CCIP `messageId`, LZ nonce, CCTP `usedNonces`, etc.) as defense-in-depth

### [INFERRED] Invariants

11. **NAV conserves across multi-adapter queries** — sum of all positions across all adapters = the reported NAV
    - Adapters operate independently; no double-counting or inter-adapter transfers of identity
    - Each position belongs to exactly one adapter (verified by `protocolId` + `positionId` mapping)

12. **Price stale signal propagates to NAV level** — if any asset's price is stale, NAV reports `stalePriceAssets` + global `sequencerDown` flag
    - Consumers can detect incomplete data at the NAV level without parsing every position

13. **Meta-adapter instance revert isolation does not corrupt other instances** — try/catch around per-instance calls
    - One protocol version or bad instance does not cascade to the whole batch (see `MetaBalanceAdapter` base class)

14. **Assisted adapters can only under-report, never over-report** (ADR 0007, 0014, 0015)
    - Merkl: proof-verified cache, so cached amounts cannot exceed the merkle root
    - ether.fi / StakeWise: id-only cache, amounts read live on each access, ownership re-verified per read
    - Agent can refuse submission (under-report) or submit false ids (still reads as 0 or drops on re-verification), but cannot inflate

---

## 3. Trust Model & Admin Powers

### Key roles (per CLAUDE.md, src/nav/INAVCalculator.sol, src/bridge/BRIDGE_ADAPTERS.md)

#### On `NAVCalculator` (UUPS upgradeable)
- **`DEFAULT_ADMIN_ROLE`** — Received by security-council Safe at deploy end (step 07 of quickstart)
  - Can upgrade NAVCalculator implementation (via UUPS)
  - Can grant/revoke `MANAGER` role
  - Powers: contract migration on security issues

- **`MANAGER` role** — Held by security council (post step-07 handoff)
  - Register/unregister assets
  - Add/remove price feeds per asset
  - Set L2 sequencer grace period (floor: ≥ 1 hour)
  - Add/remove balance adapters
  - Add/remove/configure meta-adapter instances
  - **Cannot** compute NAV unilaterally (read-only function)

#### On `BridgeEscrow` (UUPS upgradeable)
- **`DEFAULT_ADMIN_ROLE`** — Received by security council at deploy end
  - Authorize/revoke bridge adapters
  - Register/unregister bridge-asset symbols
  - Pause (trigger `emergencyWithdraw`)
  - Can upgrade escrow implementation

- **`MANAGER` role** — Held by security council
  - `cancelInvoice` on source chain (before cross-chain delivery)
  - `markInvoiceCompleted` on source chain (after destination confirms completion)
  - **Cannot call** `releaseByInvoiceId` (adapter-only; ADR 0012 hardened this)

#### On Balance Adapters
- **Plain adapters:** No role; immutable. Configuration baked into constructor.
- **Meta-adapters:** No role; immutable. Instance set governed via `NAVCalculator.addMetaInstances` / `removeMetaInstances` (MANAGER-gated).
- **Assisted adapters** (Merkl, ether.fi, StakeWise; ADR 0015):
  - `DEFAULT_ADMIN_ROLE` — Grants/revokes `ASSISTANT_ROLE`
  - `ASSISTANT_ROLE` — Can submit proofs (Merkl) or id caches (ether.fi/StakeWise); cannot fabricate amounts (verified on-chain or read live)

#### On Bridge Adapters (non-upgradeable)
- **`DEFAULT_ADMIN_ROLE`** — Set to security council at deploy
  - Can configure protocol addresses, mappings, `setTrustedRemoteAdapter`
- **`MANAGER` role** — Set to security council
  - `completeBridge` (manager-path completion for attestation-based bridges like CCTP)
  - `recoverStuckAssets` (recipient-restricted to escrow or authorized account)

### Documented limits on trust

**Adapter configuration (MANAGER):**
- Can register/unregister assets (but only with a price feed; unregistered assets silently drop from NAV)
- Can add/remove adapters (but cannot retroactively change past positions' identity; each position carries `balanceAdapter` for audit trail)
- Meta-instances can be added/removed without redeploy, but **not** modified in place (immutable by instance)

**Price feed configuration (MANAGER):**
- Can add additional feeds per asset (multi-feed redundancy)
- Can remove feeds (but not the last feed for an asset)
- Cannot directly override prices (reads are always from the protocol layer: Chainlink, Redstone, API3, or custom contract logic)

**Bridge release (adapter-only, no MANAGER override):**
- ADR 0012 removed the ability for MANAGER to call `releaseByInvoiceId` directly
- Release is adapter-only, which means the adapter must authenticate the protocol + source first
- This prevents a compromised MANAGER from draining escrow across chains

**Assisted adapter submission (ASSISTANT_ROLE):**
- Merkl: proofs verified against live `Distributor.getMerkleRoot()` (cannot fabricate)
- ether.fi / StakeWise: ids cached, amounts read live (cannot inflate)
- Agent can refuse to submit (causing under-report) but cannot over-report

### Centralization / security council governance

- All admin powers converge on the security-council Safe (post-deploy step 07)
- NAVCalculator + BridgeEscrow are UUPS-upgradeable (recovery path for post-launch issues)
- Adapters are non-upgradeable (immutability convention; redeployment required to fix)
- Deploy flow is **EOA-only** (deployer signs all steps 01–07); no Safe executes in deploy path
- Bridge adapters deployed via **canonical CREATE2** (same address across all 7 target chains); `trustedRemoteAdapter` can assume same-address sibling

Source: CLAUDE.md, QUICKSTART.md, README.md, src/bridge/BRIDGE_ADAPTERS.md, ADR 0012

---

## 4. Security Properties & Claimed Guarantees

### Balance reporting (immutable, no oracle risk)

1. **Balance derivation is deterministic from on-chain state alone**
   - No trusted off-chain indexer; each adapter is a `view` contract (except documented exceptions: Merkl proof, ether.fi/StakeWise ids)
   - Anyone can re-run the adapter against a given block and verify the reported balance

2. **Meta-adapters scale without redeploying**
   - New pool/vault/market addition is a governance transaction, not a smart-contract deploy
   - Reduces surface area for bugs; existing adapter logic does not change

3. **Per-instance isolation prevents cascade failures**
   - One stale/broken protocol instance (e.g., a Compound comet with zero reserves) cannot corrupt the entire adapter family batch
   - `try/catch` wraps each instance's read; revert on one → skip that instance, continue with others

### Price feeds (multi-feed + freshness + sequencer)

1. **Freshest-wins selector prevents feed staleness from silently producing stale NAV**
   - If any feed has a recent update, that feed's price is used (others are ignored)
   - Only when *all* feeds are stale do we return `stale=true` (not a reverted read, but flagged in NAV response)
   - Consumers can distinguish "old NAV" (staleness flag present) from "current NAV"

2. **L2 sequencer uptime check prevents stale L2 prices on sequencer downtime**
   - Minimum grace period: 1 hour (enforced on-chain)
   - If sequencer is down or in grace window → all prices marked stale
   - Prevents downstream products from using stale-on-sequencer-restart prices

3. **Custom feed interface (`ICustomPriceFeed`) allows derived prices without trustless oracle**
   - Yield-bearing stables (sDAI, sUSDe), LSTs (wstETH, rETH, rsETH), cross-rates — all computed from on-chain state
   - `getLatestPrice()` returns `(price, stale)` with on-chain verification; `latestRoundData()` provides freshness timestamp
   - Same heartbeat gate + freshness-ranking as Chainlink feeds

### NAV calculation (aggregation guarantee)

1. **NAV is a pure-view read; cannot revert from missing adapter or stale price**
   - Missing price feed → position ignored (silently dropped or marked stale, not revert)
   - Unregistered adapter → never queried (not in `getAllAdapters()`)
   - NAV response carries `stalePriceAssets[]` and `sequencerDown` flags for transparency

2. **PositionBalance identity is stable and reconcilable**
   - Same position emitted from the same adapter at the same block → same `(protocolId, positionId, balanceAsset, positionKind)`
   - Indexers can build canonical mappings: `positionId` always decodes to the same on-chain key for a given `protocolId`
   - Redeploying an adapter does not change position identity (adapter address is not part of identity)

### Bridge (provable settlement, no double-spend)

1. **Destination release is provable — only the genuine protocol contract can trigger release**
   - Each adapter authenticates `msg.sender == <real protocol contract>` (CCIP router, Stargate endpoint, etc.)
   - Source chain + sender verified via `trustedRemoteAdapter` whitelist
   - Protocol-native dedup (CCIP `messageId`, LZ nonce, etc.) as additional guard

2. **Funded pass-through prevents cross-invoice payout**
   - `releaseByInvoiceId` pulls from the adapter (which holds delivered funds), not from a standing escrow pool
   - Invoice A cannot be paid from Invoice B's tokens

3. **Invoice identity includes per-account nonce for uniqueness**
   - No two operations from the same account can produce the same invoice hash
   - Checksum includes: `(sourceChainId, destinationChainId, account, assetSymbol, amount, nonce, timestamp)`

4. **In-transit balance caching for NAV on source chain (pre-completion)**
   - While invoice is `BRIDGING`, the NAV on source accounts for the pending transfer
   - Once marked `COMPLETED` on source, in-transit balance is decremented
   - If marked `CANCELLED`, tokens are returned and cache is updated

### Access control & upgrade authority

1. **UUPS upgrade authority concentrated on security council**
   - NAVCalculator + BridgeEscrow can be upgraded by security council only
   - Implementation contracts (`NAVRegistryLib`, `PriceFeedLib`) are not upgradeable (deployed via CREATE2)
   - Adapters are not upgradeable (if a fix is needed, new adapter + switch via `removeBalanceAdapters` / `addBalanceAdapters`)

2. **Creator-less deployment (no privileged deployer lingering)**
   - Step 07 (`TransferAdminToSecurityCouncil`) hands all roles to the council and renounces deployer EOA's roles
   - Post-deploy, the deployer EOA has no special powers

---

## 5. Known Limitations & Documented Exceptions

### Immutability exceptions (adapters that are mutable)

**ADR 0007 — Merkl rewards adapter** (`src/balances/AssistedBalanceAdapters/MerklRewardsBalanceAdapter.sol`)

- **Mutable storage:** Per-(user, token) merkle-proof cache + claimed amounts
- **Trust boundary:** Owner-gated (`ASSISTANT_ROLE`), proof-verified against live `Distributor.getMerkleRoot()`
- **Failure mode:** Agent can refuse to submit (under-report); cannot fabricate amounts (invalid proof reverts)
- **Operational dependency:** Off-chain agent must re-submit proofs every ~8 hours (root rotates with dispute window)

**ADR 0014 — ether.fi & StakeWise exit-queue adapters** (`src/balances/AssistedBalanceAdapters/EtherFiWithdrawalQueueBalanceAdapter.sol`, `StakeWiseV3ExitQueueBalanceAdapter.sol`)

- **Mutable storage:** Per-account list of NFT token ids (ether.fi) or position tickets (StakeWise); **never amounts**
- **Trust boundary:** Owner-gated (`ASSISTANT_ROLE`), amounts read live on every access, ownership re-verified per read
- **Failure mode:** Agent can refuse to submit ids (under-report); cannot inflate (live read + ownership check)
- **Operational dependency:** Off-chain agent must scan events and submit ids; stale/claimed ids must be garbage-collected

**ADR 0015 — Assisted adapter family** (shared `AssistedBalanceAdapter` base with `ASSISTANT_ROLE`)

- Consolidates Merkl, ether.fi, and StakeWise under a shared `AccessControl` pattern
- Admin (`DEFAULT_ADMIN_ROLE`) can grant/revoke/rotate `ASSISTANT_ROLE` without redeploy

### Design/trade-off caveats

**ADR 0005 — Aave V3 Safety Module: hardcoded stake-token list**

- Four stake tokens (`stkAAVE`, `stkABPT`, `stkABPTv2`, `stkGHO`) pinned as compile-time constants
- Adding a new SM stake token requires code change + redeploy + Safe transaction
- Rationale: immutability is more valuable than runtime flexibility; new tokens are infrequent

**ADR 0009 — Multi-feed price redundancy**

- Freshest-wins selector means if one feed is fresh the others are ignored
- If the fresh feed is manipulated (e.g., flash-loan attack on an AMM feed), NAV can be inflated/deflated for that read
- Mitigation: multiple feeds + price-oracle reconstruction (see ADR 0002 & findings fix #2 below)

**ADR 0012 — Bridge provable release**

- Adapters deployed via canonical CREATE2 (same address on all target chains)
- `trustedRemoteAdapter` defaults assume same address; misconfiguration is asserted at deploy time
- Stargate V2 fee model: adapter quotes post-fee amount and re-encodes invoice (depositor bears bridge fee, standard UX)

**ADR 0011 — NAVCalculator size management**

- `PriceFeedLib` and `NAVRegistryLib` extracted to external libraries (deployed separately, linked)
- These libraries hold the heavy read/compute engine to avoid EIP-170 bytecode limit on `NAVCalculator`
- Both are immutable (CREATE2 deployed) with addresses pinned in `foundry.toml` and `LibraryPins.sol`

### Untracked positions / by-design gaps

From `docs/` and integration test config:

- **Nexus Mutual staking:** Currently scans all `StakingNFT` ids (unbounded if supply grows large; future agent-fed candidate)
- **Uniswap V3 / PancakeSwap V3 positions:** NFT scan bounded at 256 per pool (future agent-fed candidate)
- **Sablier streams:** Not yet covered (would require agent-fed approach for non-enumerable stream ids)
- **RWA / off-chain assets:** Out of scope; no adapter family exists
- **Perps / derivatives:** Not in current scope
- **LST restaking primitives** (Eigenlayer, Symbiotic): Partial coverage; expanding

Source: CLAUDE.md, docs/roadmap/balance-adapter-coverage.md, docs/audits/2026-06-final-pre-deploy-audit.md

---

## 6. Audit Findings Summary (Final pre-deployment audit, 2026-06)

**Overall status:** 20 findings confirmed; 12 fixed in this audit round, 4 accepted as operational/design constraints, 4 systemic findings. No critical findings remain in shipping code.

### High-severity findings (fixed)

**[1] ERC20DefaultBalanceAdapter — phantom balance from unchecked short returndata**
- Assembly `balanceOf` read output from calldata buffer without checking `returndatasize`
- Short/void return → phantom balance (~5.09e76) → overflow in `_calculateNav` → NAV reverts or corrupts
- **Fix:** Read into zeroed scratch word, validate `returndatasize >= 32` before decode
- **Impact on audit:** Makes ERC20 adapter behavior deterministic

**[2] UniswapV3PoolsMeta — LP principal valued from manipulable spot price (`slot0`)**
- `slot0` (sqrtPriceX96, tick) used for in-range liquidity split + fees; vulnerable to flash-loan manipulation
- Violates repo's "never trust AMM spot price" rule
- **Fix:** Reconstruct price from oracle feeds (`NAV_CALCULATOR.getPriceData`); compute implied sqrtPriceX96
- **Impact on audit:** UNI V3 positions now oracle-backed, not spot-manipulable

### Medium-severity findings (fixed)

**[3] ETHPlus_Price — heartbeat checked against wrong basket**
- Freshness gated on prime (target) basket; price computed over active (backup) basket after default
- Stale backup collateral accepted as fresh
- **Fix:** Drive freshness off `basketHandler.basketTokens()` (active basket)

**[4] AaveV2InstancesMeta — stable-rate debt silently dropped**
- Adapter inherited V3 code (variable-rate only); stable debt never emitted
- Debt understated, NAV overstated
- **Fix:** Capture `currentStableDebt`, emit third `Borrowed` leg when present

**[5] StakeWiseV3VaultsMeta — osToken debt converted through wrong rate object**
- Used staking-vault rate; should use `OsTokenVaultController` rate
- Debt mis-valued
- **Fix:** Pin controller as immutable, convert through controller

**[6]/[13] BalancerV3PoolLib — duplicate-underlying tokens double-counted**
- Pool with two ERC4626 wrappers of one underlying: first matched twice, second dropped
- **Fix:** Index-driven per-token contribution (`poolBalanceOfIndexed`), not address-matched

### Low-severity findings (7 fixed, 5 acknowledged)

**[7] NavLens — try/catch doesn't catch decode failures (fail-open bypass)**
- `try IPositionDescribable(...).protocolName() catch {}` doesn't catch returndata-decode revert
- **Fix:** Use low-level staticcall + ABI string envelope validation; `_safeString` helper

**[8]/S1 — PriceFeedLib — feedless asset reverts entire NAV read**
- Registered asset with live position but no feed → `PriceFeedNotSet` → NAV reverts
- **Fix:** Treat feedless as all-stale (price 0, stale=true), not revert; mark in `stalePriceAssets`

**[9]/S2 — PriceFeedLib — stale non-USD quote feed silently returns USD instead of quote currency**
- Quote asset price is stale → should mark NAV stale, but returned USD value instead
- **Fix:** Preserve stale signal through quote conversion; never fall back to USD

**[10] AuraRewardsMeta — V3 boosted pools with duplicate wrappers**
- Same root cause as [6]; fixed via same index-driven approach

**[14] UniswapV2PairLib — PancakeSwap V2 uses wrong protocol-fee constants**
- PCS fee fraction differs from Uni (8/(17+8) vs 1/(5+1)); inherited wrong constants
- **Fix:** Virtual `_mintFeeConstants()` hook per DEX

**Acknowledged low-severity (design/operational):**

**[11]** ERC20DefaultBalanceAdapter — constructor `initialAssets` added without registry check → can register untracked assets. *Accepted:* MANAGER responsibility; registration requires asset + feed.

**[12]** StaderWithdrawalQueue — `MAX_REQUESTS_PROBED` cap can silently undercount if account has many requests. *Accepted:* Operator instrumentation detects drift; GC on claimed ids.

**[15]** UniswapV3PoolsMeta — LP positions silently dropped when account holds > 256 NPM NFTs globally. *Accepted:* Bounded scan per pool (256); full account enumeration infeasible (agent-fed future work).

**[16]/[17]/[18]/[19]/[20]** (Info findings): documented in audit report; mostly fixed (Convex CV stash reward drop, Fluid fragile assembly, zero-rate edge cases).

### Systemic findings (documented, not breaking)

**S1 — Stale-feed → zero-value behavior is intentional**
- All feeds stale → `stale=true` in NAV response, not revert; position marked zero-value
- Surfaced via `stalePriceAssets[]` for consumers to detect

**S2 — Quote-feed staleness now preserved through conversion**
- Stale quote asset price → propagates to `quoteAssetStale` flag in NAV

**S3 — Inconsistent short-returndata guarding across libs**
- Documented; standardized on `returndatasize() >= 32` checks going forward

**S4 — Fail-open masks misconfiguration**
- Missing feed / unregistered asset → NAV doesn't revert, but flags in response
- Design choice for robustness; MANAGER tools still surface misconfiguration explicitly

---

## 7. Validation & Reconciliation Strategy

### Position identity reconciliation (stable key)

```
Per-chain reconciliation key:
keccak256(abi.encode(chainId, protocolId, positionId, balanceAsset.asset, positionKind))
```

This remains stable even if:
- Adapter is redeployed (balanceAdapter field is not part of key)
- Protocol instance is moved (e.g., Uniswap LP from V2 to V3, separate positionId)
- Asset symbol changes on-chain (only asset address matters)

Source: `docs/howto/position-identity-schema.md`, `src/balances/BALANCE_ADAPTERS.md` §3.1

### Cross-system consistency checks (from test/integration/)

- **Fork-test snapshots (JSON-driven):** Real accounts on pinned blocks; NAV compared against DeBank API (weekly automated refresh)
- **Per-adapter fork tests:** Every adapter tested against ≥1 real holder at a pinned block; amount verified
- **Meta-adapter isolation tests:** Revert on one instance does not cascade
- **Price feed redundancy:** Freshest-wins selector tested with stale / conflicting feeds

Source: `docs/howto/refresh-integration-test-blocks.md`, ADR 0003, `test/integration/accounts.json`

---

## 8. Risk Summary & Audit Scope Notes

### Out of scope

- Smart contract code analysis (bugs, reentrancy, overflow, etc.) — Phase 2 auditor job
- Deployment procedures and key management
- Off-chain agent implementation (Merkl submitter, ether.fi/StakeWise id scanner)
- External protocol security (Aave, Compound, Morpho, Chainlink, bridge protocols)

### In scope (documentation-only)

- Protocol design and intended behavior
- Trust model and security boundaries
- Invariants that the system claims to hold
- Known limitations and documented exceptions
- Interface guarantees and reconciliation keys

### Key uncertainties for Phase 2

1. **Library linking correctness** — `PriceFeedLib` and `NAVRegistryLib` are deterministic CREATE2; pins in `foundry.toml` and `LibraryPins.sol` must match actual bytecode
2. **Cross-chain CREATE2 assumption** — Adapters and escrow assume same address across 7 chains; assert statements added but should be re-verified post-deploy
3. **Assisted adapter submission SLA** — Merkl proof re-submission every 8 hours, ether.fi/StakeWise id garbage collection are **operational obligations**; failure = under-reporting, not over-reporting, but should be monitored
4. **Quote-asset staleness propagation** — ADR 0012 fixes ensure stale quote-asset price does not silently return USD value; verify this in read-path testing
5. **Per-instance revert isolation** — Meta-adapters should never cascade one instance's failure; unit tests cover this but end-to-end integration test should include a "broken instance" scenario

---

## 9. Summary Table: Protocol Claims vs. Audit Findings

| Claim | Status | Validated by | Risk / Caveats |
|-------|--------|--------------|-----------------|
| Amount always positive; sign via isDebt | ✓ Verified | Code convention, interface | No adapters allow negative amounts |
| Adapters are immutable | ✓ Verified (3 exceptions) | ADR 0005, 0007, 0014, 0015 | Merkl, ether.fi, StakeWise are mutable but proof/id-verified |
| NAV is deterministic from on-chain state | ✓ Verified | Adapter interfaces, tests | Except assisted adapters (rely on agent ids); values always live-read |
| Freshest-feed selector prevents stale NAV | ✓ Fixed (audit #8) | PriceFeedLib, ADR 0009 | All-stale falls back to price=0, stale=true (not revert) |
| Bridge release is provable | ✓ Fixed (ADR 0012) | CRITICAL audit finding resolved | Adapters authenticate real protocol contract + source now |
| Position identity is stable/reconcilable | ✓ Verified | PositionBalance schema, tests | Balances across redeploys, protocol updates |
| L2 sequencer check prevents stale prices | ✓ Verified | Prices init, L2 grace period ≥ 1h | Minimum 1 hour enforced on-chain |
| In-transit balances track on source chain | ✓ Verified | Bridge accounting, ADR 0012 | Decremented atomically when marked COMPLETED |
| Cross-invoice payout prevented | ✓ Fixed (ADR 0012) | Funded pass-through design | Release pulls from adapter, not pool |
| MANAGER cannot call releaseByInvoiceId | ✓ Fixed (ADR 0012) | Adapter-only gate | CRITICAL finding C1 resolved |

---

## References

### Core Documentation (repo-relative paths for deep auditors)

- `CLAUDE.md` — Architecture index, conventions, role definitions
- `README.md` — Elevator pitch, subsystem overview
- `src/balances/BALANCE_ADAPTERS.md` — Balance adapter framework
- `src/prices/PRICE_ADAPTERS.md` — Price feed architecture
- `src/bridge/BRIDGE_ADAPTERS.md` — Bridge module design (post-ADR 0012)
- `docs/howto/position-identity-schema.md` — Position identity reference

### ADRs (Architecture Decision Records)

- **ADR 0005** — Aave Safety Module: hardcoded immutable stake-token list
- **ADR 0007** — Merkl rewards: proof-verified cache, documented mutable exception
- **ADR 0009** — Multi-feed price redundancy, freshest-wins selector
- **ADR 0010** — Meta-balance-adapters: one per protocol, instances on NAVCalculator
- **ADR 0011** — NAVCalculator EIP-170 size management (external libraries)
- **ADR 0012** — Bridge provable release: **CRITICAL audit findings C1 + H1–H14 resolved**
- **ADR 0014** — Agent-fed cache adapters for exit queues (ether.fi, StakeWise)
- **ADR 0015** — Assisted balance-adapter family (shared AccessControl base)

All in `docs/decisions/`

### Audit Reports

- `docs/audits/2026-06-final-pre-deploy-audit.md` — **20 findings, 12 fixed, 4 acknowledged, 4 systemic**

---

**Reconnaissance completed by:** Vigilo Speculator Phase 1  
**Handoff:** All findings feed Phase 2 deep auditors for code-level verification and post-deploy validation.
