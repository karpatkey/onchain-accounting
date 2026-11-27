# ERC landscape for kpk tokenized funds (research, no repo changes)

Scope: standards and prior art for a tokenized fund built on top of onchain-accounting. NAVCalculator covers balances + prices. Share/subscription logic is a separate layer. Method: primary sources first (eips.ethereum.org, GitHub raw/API, Discourse JSON, vendor docs fetched directly). Search-synthesis claims are marked `[UNVERIFIED]`.

---

## 1. Verified status table

| Item | Status (verified) | Primary source | Notes |
|---|---|---|---|
| ERC-8318 "Tokenized fund lifecycle metadata" (formerly uFund) | **Not merged.** Raw `ERCS/erc-8318.md` on master: 404. eips.ethereum.org/EIPS/eip-8318: 404. PR open, s-draft, e-review | https://github.com/ethereum/ERCs/pull/1845 ; spec mirror https://eip.tools/eip/8318 | Last PR update 2026-11-27. Editors @g11tech, @jochem-brouwer, @samwilsn, @xinbenlv. Author Praveen Kumar (@praveensparkout, BlockchainX). "uFund" removed from text 2026-11-11 |
| ERC-8330 Subject-Linked NAV Snapshot Oracle | **Last Call** on master, `last-call-deadline: 2026-11-30`, requires 165 | https://eips.ethereum.org/EIPS/eip-8330 ; raw master `ERCS/erc-8330.md` ; PR https://github.com/ethereum/ERCs/pull/1858 | Forum post 11 says it was returned to Review after the 2026-10-29 aggregation change. Conflict: master is treated as authoritative for the status field; re-check before relying on it |
| ERC-7575 Multi-Asset ERC-4626 Vaults | **Final**, created 2023-12-11, requires 20/165/2771/4626 | https://eips.ethereum.org/EIPS/eip-7575 | `share()`; `vault(asset)` on share (SHOULD); `VaultUpdate(asset, vault)` (vault=0 = removal). No enumeration on-chain |
| ERC-7540 Async ERC-4626 | **Final**, created 2023-10-18, requires 20/165/4626/7575 | https://eips.ethereum.org/EIPS/eip-7540 | Core has no min-out parameter on request/claim. Previews MUST revert on async sides |
| ERC-7535 ETH-native ERC-4626 | **Final** | https://eips.ethereum.org/EIPS/eip-7535 | Not relevant to NAV binding; listed for completeness |
| ERC-7887 Cancelation for ERC-7540 | **Draft**, created 2025-02-18, requires 165/7540 | https://eips.ethereum.org/EIPS/eip-7887 | cancel/claimCancel for deposit and redeem; new requests blocked while cancel pending |
| ERC-7726 Common Quote Oracle | **Draft**, created 2024-06-20, requires 7528 | https://eips.ethereum.org/EIPS/eip-7726 | `getQuote(baseAmount, base, quote)`. No freshness/validity signal (rounds down) |
| ERC-7621 Basket Token | **Draft**, created 2024-02-11, requires 20/165/173 | https://eips.ethereum.org/EIPS/eip-7621 | Verified: `contribute(amounts, receiver, minShares)`, `withdraw(lpAmount, receiver, minAmounts)`: min-out is in base. `rebalance` owner-only (ERC-173). IERC7621 id `0xc9c80f73`. Authors Alvara (Ryder, Mitchell-Clark) |
| ERC-8113 Series Accounting for Incentivized Vaults | **Draft**, created 2025-12-25, requires 4626/7540 | https://eips.ethereum.org/EIPS/eip-8113 ; forum https://ethereum-magicians.org/t/erc-8113-series-accounting-for-incentivized-vaults/27306 | Per-series `totalAssets/totalShares/sharesOf/highwaterMark`. Redeem by `assets`, not `shares`. Not backward compatible with 4626/7540 (its own statement) |
| ERC-1726 Dividend-Paying Token | **Never merged.** Issue closed, stale | https://github.com/ethereum/EIPs/issues/1726 | Roger Wu, 2021-07-28: "No" when asked if it became a Draft. Ref impl https://github.com/Roger-Wu/DividendPayingToken (ETH only) |
| ERC-2222 Funds Distribution Token | **Never merged.** Issue closed, stale (2021-12-04) | https://github.com/ethereum/EIPs/issues/2222 | Supersedes 1726 + 1843 by its own text. Ref impl https://github.com/atpar/funds-distribution-token, unaudited |
| Lagoon async flow (v0.6.0) | Primary doc fetched | https://docs.lagoon.finance/developer-hub/integration/async-deposit-flow.md | See section 4.3 |
| Morpho Vault V2 liquidity | Primary doc fetched (partial) | https://docs.morpho.org/curate/concepts/liquidity/ | See section 4.5. Penalty figure and "fully 4626 compliant" conflict remain `[UNVERIFIED]` |

Claims from the earlier summary that are **false or wrong**:
- "ERC-8318 is a draft standard in the EIPs repo": false. It is an open PR, not merged; eips.ethereum.org returns 404.
- "uFund" as a standard name: removed from the ERC text on 2026-11-11. Use "tokenized fund lifecycle metadata".
- "ERC-8330 is Last Call and returned to Review": both are reported. Master says Last Call; forum says Review. Unresolved.

---

## 2. What each candidate standard covers (for kpk)

### 2.1 ERC-8318 (fund lifecycle metadata, events-first)
Source: spec mirror https://eip.tools/eip/8318 (fetched).
- Core `IFundMetadata is IERC165`, id `0x9539c458` (per spec table; `[UNVERIFIED]` against compiled ABI, see section 6).
- Reads: `navPerShare()` (uint256 nav, uint8 decimals; MUST NOT revert, returns last value even when stale), `navAsOf(ts)` (MAY revert), `navUpdatedAt()`, `navStale()`, `navStalenessThreshold()`, `valuationCurrency()` (bytes3 ISO 4217), `lifecycleState()` enum {Pending, SubscriptionOpen, SubscriptionClosed, Operating, RedemptionOnly, WindingDown, Closed, Paused}, `distributionCount()`, `distributionById(id)`, `pendingDistributionIds()`, `lastDistributionId()`, `nextDistributionDate()`, fee bps getters (management, performance, subscription, redemption), `minInvestment()`, `subscriptionWindow()`, `redemptionWindow()`, `maturityDate()`.
- Events (indexed fields normative): `NavUpdated(previousNav, newNav, navDecimals, effectiveAt)`, `LifecycleStateChanged(prev, new, timestamp)`, `DistributionDeclared(id, distributionType, exDate, recordDate, paymentDate, amountPerShare, amountDecimals, currency)`, `DistributionPaid(id, totalAmount, amountDecimals, currency, paidAt)`, `DistributionCancelled(id, reason)`.
- `DistributionInfo` = {id, declaredAt, exDate, recordDate, paymentDate, amountPerShare, amountDecimals, currency, type {Dividend, Coupon, ReturnOfCapital, Other}, status {Declared, ExDate, Paid, Cancelled}}.
- Write side: events only. Rationale in spec: a single `setNav` would be "too prescriptive or too loose". Write functions SHOULD be restricted to authorized accounts, not one EOA.
- Optional extensions (each has an ID; ref impl does not implement them): `IFundMetadataAUM` (0x081529b6), `IFundMetadataLockup` (0xb6e90569; `lockupExpires(address)`; privacy caveat), `IFundMetadataYield` (0xc744ad19; `accruedYield(address)`), `IFundMetadataMultiClass` (0xe872a87f; bytes32 shareClassId on every function), `IFundMetadataProofOfReserves` (0x9655511c; "publishing an attestation is not proof of solvency").
- Security section: a large holder may trade on a pending NAV update. Mitigations listed: ex-NAV pricing, cooldowns, lockups, `navStale` guard, commit-reveal or timelocked oracle.
- Reference impl https://github.com/Blockchainxtech/ufund (1 star, unaudited, MIT). `UFundBase.sol` + `IFundMetadata.sol`. Roles FUND_ADMIN_ROLE, NAV_PUBLISHER_ROLE, DISTRIBUTION_AGENT_ROLE. `markDistributionPaid` does not move funds (trusted). Extensions unimplemented.
- Forum https://ethereum-magicians.org/t/erc-8318-ufund-standardized-fund-metadata-lifecycle-interface/28660: 2 posts only. Post 2 (Yokesh Sankar, @yokesh-sparkout, 2026-07-01) supports events-only write side. Asks for NAV precision/decimals, timestamp, and attestation reference in events. Asks how lifecycle and redemption-window events relate to ERC-7540 request IDs, to avoid divergent state. No third-party "too broad" pushback found.

### 2.2 ERC-8330 (NAV snapshot oracle, Last Call per master)
Source: https://eips.ethereum.org/EIPS/eip-8330 ; ref impl https://github.com/KulaDao/titled-asset-standards/tree/main/packages/erc-nav-oracle (audited commit caa9b05, Verichains, per authors).
- `NAVSnapshot` = {subjectId, currency, navBasis, nav (int256), decimals, valuationTimestamp, publishedAt, provider, methodologyHash, methodologyURI, correctsIndex, correctedByIndex}. Sentinels: NO_CORRECTION = max uint, NO_CORRECTED_BY = 0.
- Core `INAVSnapshotOracle`: `publishNAV`, `setNAVBasis`, `invalidateSnapshot`, `isSnapshotInvalidated`, `setStalenessConfig`, `streamNAVBasis`, `latestNAV`, `latestNAVStatus` (adds `isPublishStale`, `isValuationStale`), `getSnapshot`, `currentSnapshotIndex`, `isSnapshotCurrent`, `snapshotCount`, `latestNAVByProvider`, `providerSnapshotCount`, `providerSnapshotAt`, `heartbeat`, `maxValuationAge`.
- Optional `INAVAggregation`: `aggregatedNAV(subjectId, currency)` returns (nav, decimals, navBasis, valuationTimestamp, freshProviderCount, isValuationStale). Reverts without fresh quorum; lower median. The selector is unchanged from the earlier draft, but the decoded tuple is ABI-incompatible, so ERC-165 id changed.
- Scope excludes: NAV calculation, provider credentialing, methodology verification, backing, executable-price guarantees. **No settlement/finality states.** Authors declined proposed/disputed/final for core (redcoat, forum post 7) and suggested an optional extension.
- Forum https://ethereum-magicians.org/t/erc-8330-subject-linked-nav-snapshot-oracle/28939:
  - Post 9 (Dmitry Sergeev, 2026-10-09): aggregate freshness issue. Post 12 (2026-10-30): confirmed addressed.
  - Posts 6 and 8 (PREDGE): asked for proposed/disputed/final. Post 7 (redcoat): declined for core.
  - Post 13 (Charles Buck, 2026-11-18): rollback of bad reports; historical reads.
  - Post 14 (@AOTrust, 2026-11-25): reference `NAVSnapshotOracle.sol` grants `PROVIDER_ROLE` globally, with no subjectId scope. A provider trusted by one issuer can publish into another issuer's stream. Suggests an optional `isAuthorizedProvider(subjectId, currency, provider)` view, or stating global authorization explicitly. `hasRole` leaves no record of the grant in force at publish time. **Direct relevance to kpk:** our keeper would be a provider; scope it per fund.
- Authors: Chris Turner (c.turner@kula.com), David Hay (@david-hay; forum "redcoat"), Reagan Simpson (@krumg111), Collins Musyimi (@Musyimi97).

### 2.3 Share-token binding and discovery
- ERC-7575 `share()` on vault, `vault(asset)` on share: lookup by asset, no enumeration. Forum https://ethereum-magicians.org/t/erc-7575-partial-and-extended-erc-4626-vaults/17274 post 9 (Jeroen, Centrifuge, 2024-05-10): enumeration would "add significant gas overhead"; proposed events instead; "a user would want to look up a vault by a specific asset, rather than get the full list." Indexers (posts 6, 10, Kevin) want enumeration.
- ERC-8318 and ERC-8330 are token-neutral. Neither binds to a share-token address. ERC-8330 binds by `subjectId` (bytes32), so the mapping `share token -> subjectId` must be defined by us or in an extension.
- ERC-7621 makes the basket contract itself the share token: no separate binding needed (single-contract model).

### 2.4 Settlement and min-out
- ERC-7540: no min-out in core. Joey Santoro (forum post 7, 2023-10-25): "Any mechanism which requires asynchronicity by definition cannot quote the user a min amount out and any kind of slippage protection would add too many edge cases and implementation complexity. The core design assumption is that depositors trust the vault..." Source: https://ethereum-magicians.org/t/eip-7540-asynchronous-erc-4626-tokenized-vaults/16153.json. Yakitori (post 5) argued for static-call quotes and a mandatory lock; rejected by Joey ("locked shares... must either be locked in the vault or burned").
- ERC-7621 (sync) puts min-out in base: `minShares` on contribute, `minAmounts` on withdraw. Precedent for min-out in a sync basket.
- ERC-7887: cancel is the only pre-settlement escape. Verified in spec text.
- Lagoon: settlement NAV is set by curator at one valuation point; user has no slippage parameter. See 4.3.
- Conclusion for (b): async min-out is structurally unavailable in the 7540 model. The NAV-bound alternative is: the settlement price is a published NAV snapshot (ERC-8330 `navBasis`/`valuationTimestamp`, or ERC-8318 `navPerShare`), and the request records a maximum deviation or a snapshot index. Threat analysis belongs to `SettlementAndThreats`; this document only specifies the interface shape.

### 2.5 Portfolio accounting vs NAVCalculator (gap c)
Repo facts (read in `src/nav/INAVCalculator.sol`):
- `struct PositionBalance` (line 150): `Asset balanceAsset; address balanceAdapter; uint256 amount; bool isDebt; bytes32 protocolBrand; bytes32 protocolId; bytes32 protocolSubId; bytes positionId; PositionKind positionKind; bool isLocked; bytes32 positionInstanceId`. `amount` positive; `isDebt` signs it.
- `struct Position` (line 183): adds `quoteAsset`, `value` (negative for debt), `price`, `priceDecimals`, `stale`, plus copied identity fields.
- `getAccountNav(account, quoteAsset) -> NAV` (line 741). `NAV` fields per doc comment: `value, quoteAsset, timestamp, stalePriceAssets, sequencerDown, quoteAssetStale`. `[UNVERIFIED]` signedness of `NAV.value` (struct not read).
- `getAccountNavForAdapters(account, quoteAsset, adapters[]) -> PartialNAV` (line 860): slice read; caller must pass the SAME quoteAsset to every slice; `value` sums, nothing else does; adapter set must be registered; non-empty; no duplicates.
- `getAccountNavVerbose(account, quoteAsset) -> VerboseNAV` (line 930): NAV + labelled positions. The slice path has no verbose counterpart (line 850).
- `getAccountPositions` (line 869): enriched `Position[]`.

Mapping to ERC-8330 / ERC-8318:

| NAVCalculator | ERC-8330 | ERC-8318 | Gap |
|---|---|---|---|
| `NAV.value` (quote asset) | `NAVSnapshot.nav` (int256), `currency`, `decimals` | `navPerShare()` is per share, not total | Ours is total NAV. Per-share needs share supply at the same block. **Gap:** define `nav / totalSupply` at snapshot block |
| `NAV.timestamp` | `valuationTimestamp` | `navAsOf`, `navUpdatedAt` | Align: use the same block for valuation and snapshot |
| `NAV.stalePriceAssets`, `sequencerDown`, `quoteAssetStale` | `latestNAVStatus.isValuationStale` | `navStale()` | Map to a single boolean? Keep the three flags: ERC-8330 has one bit only, so 8330 loses information. Use methodologyURI or an extension for the detail |
| `PositionBalance[]` breakdown | none | none | **Gap:** neither standard carries a per-position breakdown. Options: (i) commit a Merkle root of PositionBalance leaves in `methodologyHash`; (ii) extension view returning `PositionBalance[]` for the snapshot block |
| `getAccountNavForAdapters` slices | one `publishNAV` call | none | Slices must be read in one block, else the sum is not a snapshot (CLAUDE.md read-nav-in-slices rule) |
| `isLocked` | none | `IFundMetadataLockup` (privacy caveat) | Locks inside NAV are visible in PositionBalance; exposing per-holder lockups is the 8318 privacy issue |
| `PositionKind` Rewards, Fees | none | none | Accrued rewards/fees are not distributions; 8318 `Other` type covers only declared distributions |
| `balanceAdapter = address(this)` audit trail | `provider` | none | Map `provider` to the NAVCalculator keeper address |

Gaps summary for (c):
1. No per-position breakdown in any standard. Needs our own extension or a Merkle commitment.
2. Single-block consistency for slice reads: enforce in our publisher, not in the standard.
3. Per-subject provider authorization: ERC-8330 authorizes globally (AOTrust post 14).

---

## 3. Gap analysis vs the three proposed interfaces

### (a) Fund discovery on the share token
- Need: `shareToken -> fund metadata + NAV oracle + lifecycle`.
- Existing: ERC-7575 `share()`/`vault(asset)` (lookup by asset only). ERC-8318 and ERC-8330 are token-neutral.
- Gap: no standard binds share token to `subjectId` (8330) or to metadata contract (8318).
- Option: ERC-165-gated view on share token: `fundMetadata() -> address`, `navOracle() -> (address, bytes32 subjectId)`. One staticcall each. Put it as an extension to 8318 (`IFundMetadataShareToken`) or as a standalone 3-function interface in our repo.

### (b) NAV-bound settlement with min-out
- Existing: ERC-7540 (no min-out, deliberate); ERC-7621 (sync min-out in base); ERC-7887 (cancel).
- Gap: no standard binds an async request to a NAV snapshot index or to a max deviation.
- Option: keep (b) as interface spec only: `requestDeposit` records `navSnapshotIndex` or `maxNavDeviationBps`; settlement reverts if the snapshot used is older than `maxValuationAge` (exists in 8330 config). Threat model: `SettlementAndThreats`.

### (c) Portfolio accounting vs INAVCalculator
- See 2.5. Gaps: per-position breakdown, slice consistency, per-subject provider scoping, sign convention of isDebt vs nav (negative total NAV possible when debt dominates; 8330 `nav` is int256, so OK, but `[UNVERIFIED]` for `NAV.value`).

---

## 4. Prior art

### 4.1 Basket and fund-like token standards
- **ERC-7621 Basket Token** (Draft, Alvara). Verified: weighted constituents, owner rebalance via ERC-173, `minShares`/`minAmounts` min-out in base, `totalBasketValue()` deterministic and implementation-defined ("MUST NOT be assumed comparable across implementations"). Closest to a "fund token" in the ERC corpus. Production use by Alvara (BSKT) `[UNVERIFIED]`. Alvara's "EF recognition" claim `[UNVERIFIED]`.
- **ERC-8113 Series Accounting** (Draft, Yash Saraswat). Verified: per-batch series with own highwater mark; consolidation to a lead series; redeem by assets. Relevant for fee fairness, not for NAV standardization. Not backward compatible with 4626/7540.
- **ERC-7425 Tokenized Reserve** (Draft, Jimmy Debe, 2023-06-30) `[UNVERIFIED]` details. https://eips.ethereum.org/EIPS/eip-7425 ; forum https://ethereum-magicians.org/t/eip-7425-tokenized-reserve/15297
- **ERC-8192 Mandated Execution** (Tabilabs; forum draft only) `[UNVERIFIED]`. Mandate = authorization envelope with bounded delegated execution on 4626 vaults; allowlist binds adapter code hash. Companion ERC-8240. Forum https://ethereum-magicians.org/t/erc-8240-trust-infrastructure-for-agents-and-assets/28322 (8192 only in search results).
- **ERC-7621, ERC-8113, ERC-7425, ERC-8192** all originate from search synthesis (Pigi article https://app.pigi.finance/learn/next-gen-tokenized-vault-standards-part-2 ) apart from the 7621 and 8113 primary pages above. The 7425 and 8192 details are `[UNVERIFIED]`.
- ERC-5115, ERC-29991, ERC-7943 (uRWA): mentioned in search results only. `[UNVERIFIED]`, not checked.

### 4.2 Oracle and quote standards
- ERC-7726 Common Quote Oracle (Draft): verified; no freshness or validity. Use ERC-8330 `latestNAVStatus` as the freshness source for fund NAV; use 7726 only for asset-to-quote conversion, if at all.

### 4.3 Lagoon (ERC-7540 curated vault): verified from primary doc
Source: https://docs.lagoon.finance/developer-hub/integration/async-deposit-flow.md (fetched; describes v0.6.0, v0.5.x differences noted).
- Request IDs are epoch-based; `pendingDepositRequest(0, user)` wildcard.
- `pendingSilo` (owned by vault) escrows deposit assets and redeem shares until settlement. Not called by users.
- Curator settles one epoch at a single valuation point. Settlement is a curator action with **no time guarantee**.
- Shares are minted to the vault at settlement; the user's `balanceOf` excludes claimable shares until claim.
- A second deposit request in the same epoch merges. A new request while a valuation is pending reverts `OnlyOneRequestAllowed`.
- Claim reverts `RequestIdNotClaimable` before settlement.
- Cancel is blocked once `updateNewTotalAssets` runs for the epoch (`RequestNotCancelable`). Redeem cancel exists in v0.6.0 only.
- v0.6.0: entry and exit fees applied at the rate in force at the settled epoch. Curator can `claimSharesOnBehalf` / `claimAssetsOnBehalf` (v0.6.0 only).
- Closed vault: synchronous redeem at final price, no epochs.
- Useful for kpk: the epoch model is the same shape as (b). Their min-out is absent; the NAV is set at settlement by the curator, which is the trust point to replace with ERC-8330 snapshots.

### 4.4 Centrifuge
- Modes: sync, async, hybrid (sync deposit + ERC-7540 redeem queue). Source: https://docs.centrifuge.io/developer/protocol/architecture/vaults/ `[UNVERIFIED]` (not fetched). 24h epoch detail is third-party only `[UNVERIFIED]`.
- Centrifuge's ERC-7575 post (Jeroen) is the main source for the "no enumeration" design argument (section 2.3).

### 4.5 Morpho Vault V2: partially verified
Source: https://docs.morpho.org/curate/concepts/liquidity/ (fetched).
- Adapters + ID/Cap system. Caps are checked on `allocate` and on `deposit`/`mint` routed to the liquidity adapter. Caps are **not** checked on withdrawals or interest accrual, so exposure can exceed a cap without new allocation (verified doc text).
- Liquidity adapter serves deposits and fills withdrawals. If idle and adapter liquidity are both empty, the vault is illiquid until allocator reallocates.
- In-kind redemption: `forceDeallocate` is permissionless, moves liquidity from adapter to vault idle, net of a per-adapter penalty; goes through `sendSharesGate`/`receiveAssetsGate`, which can block it. Penalty size (up to 2% per GitHub README snippet) `[UNVERIFIED]`, not on the fetched page.
- ERC-4626 compliance: ChainSecurity audit (https://cdn.prod.website-files.com/65d35b01a4034b72499019e8/68caac67e497b913915ad865_ChainSecurity_Morpho_Labs_Morpho_Vault_V2_audit.pdf) says "fully ERC4626 compliant"; SDK docs say `maxWithdraw`/`maxDeposit` return 0 in some states. Conflict `[UNVERIFIED]`.
- Relevance to kpk: adapters + caps is the same risk-framework idea as our balance-adapter registry. Their "exposure can exceed cap without allocation" note is a NAV-side point: our NAV must not assume caps bind.

### 4.6 Positions ERCs
Not checked in depth; no standard in the corpus maps to `PositionBalance` (per-position, multi-leg, with PositionKind). Our PositionBalance is the closest precedent in this repo. `[INFERENCE]`: no standard to adopt; keep it internal.

---

## 5. Dividends: accumulating vs distributing

- **Accumulating** (NAV per share rises): the fund reports `navPerShare` (8318) or `NAV` (8330). Yield appears as NAV growth. ERC-8318 `IFundMetadataYield` is optional (not implemented by the ref impl). ERC-8113 handles fee fairness across batches.
- **Distributing** (cash paid per share on a date): ERC-8318 `DistributionInfo` (declared, exDate, recordDate, paymentDate, amount, type, status) + events. Payment is recorded via `DistributionPaid`, and per spec MUST be emitted when paid "by any mechanism (on-chain or off-chain)". The ref impl's `markDistributionPaid` does not move funds.
- Legacy pull-payment standards: ERC-1726 and ERC-2222 are never merged; their dividend accounting is a useful reference (magnified dividend per share, corrections on transfer) but not a standard to build on.
- **Ex-dividend vs pending redemption (ERC-7540):** `[INFERENCE]` if shares are escrowed in a pending silo (Lagoon model), the holder of record on `recordDate` may be the silo, not the redeemer. The redeemer would lose the distribution unless entitlement is fixed at `recordDate` for the controller. Need an explicit rule in our spec: (1) entitlement is by holder at recordDate, with pending-redeem shares attributed to the controller; or (2) a distribution declared after `requestRedeem` but before exDate is excluded. Neither 8318 nor 7540 specifies this. Flag for `SettlementAndThreats`.
- ERC-8318 `DistributionInfo.exDate` / `recordDate` are timestamps only; no rule ties them to pending redemptions.

---

## 6. Recommendation

Options:
- **A. Extend ERC-8318** with an optional `IFundMetadataShareToken` (share binding + `navOracle` pointer) and optional settlement-status extension.
- **B. New ERC** for NAV-bound async settlement (request records snapshot index / max deviation; settlement reverts on stale snapshot).
- **C. Extension ERC** on top of 8318 + 8330 + 7540: share binding, per-position breakdown commitment, and NAV-bound settlement as one optional interface.

Recommendation: **A now, C later; do not start B.**
1. Use ERC-8330 as the NAV source. It is in Last Call on master; subjectId binding is the right hook. Ask the authors (David Hay, Chris Turner) whether a per-subject provider authorization view is planned (AOTrust post 14).
2. Do not depend on ERC-8318 being merged. The PR is open with editor approval pending, and the spec is Draft. Implement the 8318 core ID check in our repo as an optional adapter, and propose the share-binding extension as a PR comment to PR #1845 (author Praveen Kumar; forum post 2 author Yokesh Sankar).
3. Min-out / NAV-bound settlement: keep as our own interface in the repo, shaped like ERC-7621 (explicit min or max bound on the call). Precedent exists in ERC-7621 for sync; async is structurally excluded from 7540 by design (Joey Santoro). Do not claim standard compliance for it.
4. Per-position breakdown: use a Merkle commitment of PositionBalance leaves in `methodologyHash`, or an extension view. Decide with `RepoAccountingMap`'s findings on the meta-adapter interface.
5. Dividends: write an explicit recordDate rule for pending redemptions before wiring 8318 `DistributionInfo` to settlement.

Do not create a new ERC until 8330 and 8318 settle. The fund-metadata space already has three open drafts (8318, 8330, 8113); a fourth would add to the fragmentation.

---

## 7. Contacts (for standard feedback)

- ERC-8318: Praveen Kumar (@praveensparkout, BlockchainX, PR #1845 author); Yokesh Sankar (@yokesh-sparkout, forum post 2); editors @g11tech, @jochem-brouwer, @samwilsn, @xinbenlv.
- ERC-8330: David Hay (@david-hay; forum "redcoat"), Chris Turner (c.turner@kula.com), Reagan Simpson (@krumg111), Collins Musyimi (@Musyimi97). Forum: Dmitry Sergeev (@SergeevDmitry, posts 9/12), AOTrust (post 14), Charles Buck (post 13).
- ERC-7575: Jeroen (Centrifuge), Joey Santoro (@joeysantoro), Kevin (@beringela).
- ERC-7540: Joey Santoro (@joeysantoro), Yakitori (@Yakitori), Farhaan (@0xfarhaan, Maple), sogipec (@sogipec).
- ERC-7621: Dominic Ryder (dom@alvara.xyz), Michael Ryder (mike@alvara.xyz), Callum Mitchell-Clark (@AlvaraProtocol).
- ERC-8113: Yash Saraswat (@0xpanicError).
- ERC-1726: Roger Wu (@Roger-Wu). ERC-2222: Johannes Pfeffer (@jo-tud), Johannes Escherich (@jo-es), Tom Lam (@erinata).

---

## 8. Unverified / open items

- `[UNVERIFIED]` ERC-8318 core ID `0x9539c458` vs compiled ABI (spec table only). PR #1845 comment says six IDs are asserted in bundled tests; not checked.
- `[UNVERIFIED]` `NAV.value` sign convention (struct not read; `Position.value` is negative for debt per doc comment).
- `[UNVERIFIED]` ERC-8330 status conflict (Last Call on master vs "returned to Review" in forum post 11).
- `[UNVERIFIED]` Centrifuge epoch and vault mode details (docs not fetched).
- `[UNVERIFIED]` Morpho V2 forceDeallocate penalty (2%) and ERC-4626 `maxWithdraw` conflict.
- `[UNVERIFIED]` ERC-7425, ERC-8192, ERC-5115, ERC-29991, ERC-7943: search synthesis only.
- `[UNVERIFIED]` Alvara "EF recognition" and BSKT production use.
- `[INFERENCE]` ex-dividend rule for pending redemptions (section 5).
- Not checked: `docs/howto/position-identity-schema.md` (positionId decode tables), `RepoAccountingMap` findings on meta-adapter interface, `SettlementAndThreats` findings. Cross-reference before finalizing.

## 9. Links (primary)

- https://github.com/ethereum/ERCs/pull/1845 (ERC-8318 PR)
- https://eip.tools/eip/8318 (ERC-8318 spec mirror)
- https://github.com/Blockchainxtech/ufund (ERC-8318 ref impl)
- https://ethereum-magicians.org/t/erc-8318-ufund-standardized-fund-metadata-lifecycle-interface/28660
- https://eips.ethereum.org/EIPS/eip-8330 ; https://github.com/ethereum/ERCs/pull/1858 ; https://ethereum-magicians.org/t/erc-8330-subject-linked-nav-snapshot-oracle/28939
- https://github.com/KulaDao/titled-asset-standards/tree/main/packages/erc-nav-oracle
- https://eips.ethereum.org/EIPS/eip-7575 ; https://ethereum-magicians.org/t/erc-7575-partial-and-extended-erc-4626-vaults/17274
- https://eips.ethereum.org/EIPS/eip-7540 ; https://ethereum-magicians.org/t/eip-7540-asynchronous-erc-4626-tokenized-vaults/16153
- https://eips.ethereum.org/EIPS/eip-7887 ; https://eips.ethereum.org/EIPS/eip-7535 ; https://eips.ethereum.org/EIPS/eip-7726
- https://eips.ethereum.org/EIPS/eip-7621 ; https://eips.ethereum.org/EIPS/eip-8113 ; https://ethereum-magicians.org/t/erc-8113-series-accounting-for-incentivized-vaults/27306
- https://github.com/ethereum/EIPs/issues/1726 ; https://github.com/ethereum/EIPs/issues/2222
- https://docs.lagoon.finance/developer-hub/integration/async-deposit-flow.md
- https://docs.morpho.org/curate/concepts/liquidity/
- Repo: `src/nav/INAVCalculator.sol` lines 150 (PositionBalance), 183 (Position), 741, 860, 930.
