# Settlement accounting, proof-based NAV, and compromised-bot threats

Scope: research only. Repo references are to `/Users/ismael/karpatkey/code/onchain-accounting`. Unverified claims are marked `[UNVERIFIED]`. Vendor numbers are vendor-reported unless noted.

---

## 0. Repo baseline (ground truth used below)

- `NAVCalculator.getAccountNav` is a single on-chain view. It reads every registered adapter and every asset price. Measured in `docs/howto/read-nav-in-slices.md`: about 30.0M gas for 41 assets and 21 adapters. `AaveV3InstancesMeta` alone is about 12.3M. Against the 50M `eth_call` cap that leaves about 1.7x headroom.
- Slicing (`getAccountNavForAdapters`, returns `PartialNAV`) helps only off-chain readers. It does not help on-chain consumers. Callers must pin one block and union the health flags. Swap-and-pop on `getAllAdapters()` causes silent skips when paging by index, so slices must name adapters, not indexes.
- Errors that matter for settlement (`src/nav/INAVCalculator.sol`): `AdapterGasExhausted(adapter, stipend, consumed)`, `InstanceGasExhausted`, `EmptyAdapterSlice`, `AdapterNotRegistered`, `DuplicateAdapterInSlice`. `GasStipendLib.exhausted` triggers at `consumed >= stipend - stipend/8`.
- Two-halves guarantee (ADR 0015, CLAUDE.md): contract level gives "cannot over-report"; the Safe roles allow-list (outside this repo) gives "cannot under-report", because direct protocol entrypoints are not allow-listed. Residual risk: a roles-permission change that adds a non-assistant path. No tripwire in this repo.
- Keeper path (ADR 0030): `submitFor`/`submitForBatch` need `SUBMITTER_ROLE` (admin = Security Council Safe). `removeFor` is permissionless only on proven death. `previewPositions` is stateless. `OWNER_RESERVE = 32` of a 256-position cap.
- Attested family (ADR 0022): proof-verified amounts, under-report only. Campaign split is not proof-bound and can be amplified up to 8x by third parties. Leg bound 512. Read gas: 4.18M at 256 legs, 10.34M at 512, 30.0M at 1024. Stale root forces value to 0. Debt legs rejected (`DebtLegRejected`). Revoked keeper means under-count.

Implication for settlement: NAV here is a pure read of current state at the block the caller chooses. This repo does not own a share price, subscription, or redemption. Any settlement layer must choose and record the snapshot block itself.

---

## 1. Proof-based NAV verification

### 1.1 What a proof buys us

Three different properties get confused in this space. Keep them apart:

| Property | Question | Who must be trusted without a proof |
|---|---|---|
| Integrity of a read | Was the value really in state at block B? | The NAV poster, unless proven |
| Completeness | Are all positions of the account in the NAV? | The adapter registry and the Safe roles allow-list |
| Valuation | Is the price right? | Price feeds and custom feeds |

Storage and ZK proofs address integrity only. For this repo that is the weakest of the three risks, because `getAccountNav` is already a live on-chain read. A proof helps only when a consumer cannot run the read itself: another chain, a contract that cannot afford 30M gas, or an L2 that cannot read L1 state live.

Completeness is not addressed by any proof. A ZK proof that "this NAV was computed by `getAccountNav` at block B" is still wrong if the adapter list is missing a position type. The roles allow-list (ADR 0015) is the completeness control, and it lives outside the repo.

### 1.2 Options

**RISC Zero Steel (view-call proofs).** Closest fit to our shape.
- Mechanism: the host runs the view call with a preflight (untrusted). A guest re-executes the call via revm with Merkle-verified state, outputs a commitment, and the result is wrapped in a Groth16 proof. The verifier calls `Steel.validateCommitment`.
- Maturity: audited by Veridise, September 2024 (https://veridise.com/wp-content/uploads/2024/11/VAR_RISCZero_240917_risc0_steel_V2_new.pdf). Advisory GHSA-gjv3-89hh-9xq2 / CVE-2025-52884: `validateCommitment` returned true for a crafted zero-digest commitment before 2.1.1 / 2.2.0. Low severity. Pin to a patched release.
- Docs: https://docs.boundless.network/developers/steel/how-it-works; Rust API https://risc0.github.io/risc0-ethereum/risc0_steel/; repo https://github.com/risc0/risc0-ethereum.
- Cost: vendor claims 100K SLOADs per view call and a 1.2B-gas partner saving (vendor-reported). Proof-to-tx window about 50 min (vendor-reported). Per-proof cost for a 30M-gas re-execution is `[UNVERIFIED]`; zkVM cycles scale roughly with executed instructions, so it will be large. Benchmark before committing.
- Fit: the whole `getAccountNav` is one view call, so Steel re-executes exactly the function we already trust. No new NAV logic on the proof side.

**Brevis ZK Data Coprocessor.**
- Storage proofs with `StorageData` (BlockNum, Address, Slot, Value) and a Pico zkVM backend (https://github.com/brevis-network/pico; docs https://coprocessor-docs.brevis.network/).
- Pico 3.1 claims 128-bit security on 4 GPUs and proofs ≤300 KB (vendor-reported, `[UNVERIFIED]`).
- Public-alpha limits (may be stale): storage value max 32 bytes; 69 s for 64 slots, 350 s for 4096 slots `[UNVERIFIED]`.
- Optimistic "coChain" propose-challenge mode exists. Not an indexer.
- Fit: good for specific slots (e.g., a single adapter's stored cache). Poor for a 30M-gas view call unless you re-implement the logic in a guest.

**Herodotus.**
- Storage Proof API (https://docs.herodotus.cloud/storage-proofs-api/introduction), Historical Block Hash Accumulator back to genesis, Satellite contracts for on-chain reads, HDP in Cairo, proving through Atlantic (managed SHARP prover, Ethereum SHARP verifier).
- Caveat: Herodotus does not host SHARP itself. Atlantic availability is a dependency. No published pricing or rate limits found `[UNVERIFIED]`.
- Docs at docs.herodotus.dev are about two years old. Treat as stale.
- Fit: good for cross-chain storage reads (historical block-hash accumulator). Not a general view-call prover.

**Axiom.** Not viable as a dependency.
- Trail of Bits (2025-05-30, https://blog.trailofbits.com/2025/05/30/a-deep-dive-into-axioms-halo2-circuits/) reports Axiom shut down its ZK coprocessor product after the audit. Circuits were repurposed into OpenVM. Axiom V1 was deprecated 2024-01-22 (https://docs-v1.axiom.xyz/).
- Third-party 2026 guides still describe Axiom as live at "$0.01/block, 6–12 s". That conflicts with the shutdown and is `[UNVERIFIED]`.
- Do not design around Axiom.

**UMA optimistic oracle (OOV3) for assertions.** Not a proof; a bonded dispute.
- Used for "assert a value, dispute window, escalation to DVM". Useful for off-chain claims (e.g., a Merkl-style campaign split, real-world RWA marks), not for on-chain state.
- Minimum bond = 2 × final fee when `burnedBondPercentage = 50%` (https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/implementation/OptimisticOracleV3.sol).
- Default liveness 2 h (https://docs.uma.xyz/developers/setting-custom-bond-and-liveness-parameters). `settleAssertion` only after liveness and no dispute.
- Final fee about $250 per UMIP-188 (https://discourse.uma.xyz/t/umip-188-increase-final-fee/2194); a proposal to double to $500 exists. Current value `[UNVERIFIED]`.
- Fit: could bound the Merkl campaign-split gap (ADR 0022 amplification) without trusting the submitter. Adds a 2 h+ latency to any value that depends on it.

### 1.3 Multi-chain aggregation

Two patterns:
1. Each chain runs its own `NAVCalculator`; a coordinator sums `PartialNAV`s. Requires a common block-timestamp convention and matching `quoteAsset` (`read-nav-in-slices.md` already requires these to match within one chain). Cross-chain sums need a documented snapshot-time tolerance, because each chain's block times differ.
2. One chain reads another chain's balances via storage proofs (Herodotus satellite, Brevis, Steel). Proof-verified reads become balances in the home-chain NAV only if the adapter that consumes them is attested (ADR 0022 family). Without that, a cross-chain storage read has no adapter to plug into, and the repo's "adapters report balances" convention does not fit it.

Recommendation: pattern 1 for now. Pattern 2 only through an attested adapter, with its own ADR.

### 1.4 Recommendations (proof-based NAV)

1. Do not put ZK proofs in the settlement critical path. The on-chain read is already trustworthy for the chain it runs on.
2. If an off-chain or cross-chain consumer needs NAV, prototype Steel over `getAccountNav` at a pinned block. Measure proving time and cost for 1× and 2× today's gas (30M, 60M) before committing. Mark as `[UNVERIFIED]` until measured.
3. Pin the Steel release to ≥2.1.1 / 2.2.0 (GHSA-gjv3-89hh-9xq2).
4. Any proof-verified value must still pass the completeness check the roles allow-list gives. A proof does not replace that.
5. Do not depend on Axiom.
6. Keep UMA as a candidate for the Merkl campaign-split gap only. Needs an ADR before use.

---

## 2. Strict on-chain settlement accounting

### 2.1 Reference designs

**ERC-7540 (async deposit and redeem vaults).**
- Final (created 2023-10-18). Requires EIP-20, EIP-165, EIP-4626, EIP-7575 (https://eips.ethereum.org/EIPS/eip-7540).
- `requestDeposit(assets, controller, owner)` and `requestRedeem`; claim via ERC-4626 `deposit`/`redeem`.
- Preview functions MUST revert on the async side. Cancelation is ERC-7887 (`[UNVERIFIED]` link: https://eips.ethereum.org/EIPS/eip-7887).
- The standard does not define epochs or NAV authority. Pricing happens at NAV update, not at request. OpenZeppelin ships an epoch-based strategy (`ERC7540EpochDeposit` / `ERC7540EpochRedeem`, PR #230).

**Lagoon (valuation manager + curator).**
- Valuation manager proposes with `updateNewTotalAssets(_newTotalAssets)`. Curator calls `settleDeposit(uint256 _newTotalAssets)` / `settleRedeem`, and the value must match the posted one.
- Settlement mints fee shares to `feeReceiver`. Management fee: `((assets × rate)/BPS) × timeElapsed / 1 year`. High-water mark: no performance fee below HWM.
- Haircut: exit at a stale valuation is instant; the price change is deferred to the next settlement. This is an arbitrage opening (see 2.2).
- Pending NAV is not readable on-chain. Redemptions settle only if the curator holds enough assets.
- Sync mode via `updateTotalAssetsLifespan` (Safe-only).
- Refs: https://docs.lagoon.finance/vault/vault-valuation, https://docs.lagoon.finance/developer-hub/smart-contract-reference, https://docs.lagoon.finance/vault/fees. Several pages are stale; v0.4.0 through v0.6.0 coexist.

**Centrifuge V3 (hub epochs).**
- Hub flow: `approveDeposits` / `approveRedeems` at a chosen price, then `issueShares` / `revokeShares` at NAV-per-share. NAV-per-share is pushed off-chain (`NAVManager`, `SimplePriceManager` in v3.1.0).
- Hub address for V3.1+ `0xA4A7Bb3831958463b3FE3E27A6a160F764341953` `[UNVERIFIED]`, from a Yearn report.
- `vault.pricePerShare()` may lag settlement. Redemptions process at epoch end, typically daily.
- Indexer bug: api-v3 #488 (phantom RedeemOrder rows after cancel). `forceCancelRedeemRequest` is admin-only.
- Refs: https://docs.centrifuge.io/developer/protocol/guides/invest-into-a-vault/, https://github.com/centrifuge/protocol-v3, https://newreleases.io/project/github/centrifuge/protocol/release/v3.1.0.

**Morpho Vaults V2.**
- Allocator reallocates with no timelock. Curator risk-increasing changes are timelocked. Sentinel can only decrease caps.
- `forceDeallocate(adapter, data, assets, onBehalf)` is permissionless, with a penalty ≤2% (WAD), and the penalty can be 0.
- `totalAssets()` = idle + adapter positions, with `maxRate` yield cap and loss realization.
- Audit flag: allocator can set a non-whitelisted liquidity adapter with no timelock (ChainSecurity, about 14 months old: https://cdn.prod.website-files.com/65d35b01a4034b72499019e8/68caac67e497b913915ad865_ChainSecurity_Morpho_Labs_Morpho_Vault_V2_audit.pdf).
- Docs: https://docs.morpho.org/learn/concepts/vault-v2/, https://docs.morpho.org/curate/tutorials-v2/emergency/, https://docs.morpho.org/developers/earn/tutorials/force-deallocate/.

**Enzyme (V3 / Onyx / V4 "Sulu").**
- NAV-per-share = GAV / total supply.
- V3 crystallizes performance fees on a fixed period (e.g., 90 days) against an HWM. Example from Enzyme's own write-up: a 20% fee with a 90-day period checks once per 90 days. V4 accrues continuously.
- Onyx is non-continuous. The manager reports GAV. Fees settle during the share value update: management fee first, then performance fee. Owed fees are converted to the fee asset at the asset rate from the valuation provider.
- `sharesActionTimelock`: seconds between a user's deposit and their next transfer or redemption. Per the 2021 PwC ISAE 3000 report, the timelock is not applied while a migration is pending, and it can be set to an arbitrary value with no minimum (https://www.pwc.ch/en/publications/2021/avantgarde-finance-isae-3000-report-enzyme-protocol.pdf).
- Refs: https://specs.enzyme.finance/fee-formulas/performance-fee, https://docs.enzyme.finance/onyx-protocol/architecture/fees, https://specs.enzyme.finance/topics/known-risks-and-mitigations.

**Ondo (OUSG / USDY).** Reference for NAV-authority and timing, not a vault standard.
- OUSG: NAV updated once per Business Day by Ondo, then pushed to the on-chain oracle. Subscription and redemption use that NAV via `OUSG_InstantManager` (0x93358db73B6cd4b98D89c8F5f230E81a95c2643a, Ethereum). Non-instant requests above limits go through support. Source: https://docs.ondo.finance/qualified-access-products/ousg/overview, https://docs.ondo.finance/addresses.
- USDY: accumulating, price rises at a rate Ondo fixes monthly in an on-chain oracle. Not derived from NAV (per a third-party report). Since 2026-11-03 the price updates continuously. `ContinuousPriceOracle` 0xbAEC2b9fE27cD054e1c0C2B720aF117d9D7eC871 from 2026-11-01 per the docs page. Legacy oracle live through end of 2026. Source: https://ondo.finance/blog/usdy-continuous-pricing, https://docs.ondo.finance/developer-guides/usdy-instant-manager-integration.
- Limits: the figures come from third-party reviews that conflict with each other (`[UNVERIFIED]`). Use live docs.
- Relevance: the daily NAV plus instant-manager pattern is the clearest real example of NAV-timing arbitrage being managed by pricing-at-oracle and per-user daily limits.

### 2.2 Attack surface, by mechanism

| # | Mechanism | Attack | Seen in | Mitigation |
|---|---|---|---|---|
| S-A | Stale NAV at exit (haircut) | Buy or redeem at a stale price before a known write-down lands | Lagoon haircut; OUSG daily NAV | Settle at the same epoch's NAV; redemption fee or swing pricing; no instant exit at a stale mark |
| S-B | Sandwich on NAV update | Front-run the posted NAV with deposits or redemptions | Any push oracle | Settle only at a committed, pre-cutoff NAV; no same-block deposit and settle; `sharesActionTimelock`-style lock |
| S-C | Pending flows counted in NAV | Requests after snapshot leak into the NAV or the share count | ERC-7540 general | Snapshot block ≤ cutoff; pending flows excluded from NAV, handled as a liability at the settlement price |
| S-D | Fee crystallization timing | Manager or user times flows around fee settlement | Enzyme V3 90-day; Lagoon HWM | Crystallize before pricing; fee shares minted at settlement, not at request; HWM tracked on-chain |
| S-E | Unpaid dividend liabilities | Accrued but unclaimed yield or fees not deducted | Centrifuge epoch; Ondo USDY accrual | Liability ledger in NAV-to-share conversion |
| S-F | NAV reversal / stale root | Settlement accepts a NAV from a stale or reverted read | ADR 0022 stale-root rule; ADR 0030 S6 | Revert, never count as dead or zero; stale → 0 (ADR 0022) |
| S-G | Indexer or accounting drift | Off-chain share ledger diverges from on-chain | Centrifuge api-v3 #488 | Single source of truth for share supply; on-chain event reconciliation |
| S-H | Admin force-cancel or force-deallocate | Operator moves value outside the NAV window | Centrifuge `forceCancelRedeemRequest`; Morpho `forceDeallocate` | Timelock or Security Council gate; log every force action; penalty ≥0 |

### 2.3 Settlement invariants (what the layer must guarantee)

1. **Single pinned snapshot.** Settlement reads `getAccountNav` at a block B. B must be ≤ the cutoff for the epoch's requests. Record B and the NAV in the epoch record. Use the repo's `timestamp` only as a cross-check (`read-nav-in-slices.md`).
2. **Pending flows excluded from NAV.** Requests not yet settled are a liability at the epoch price, not part of the NAV used to price them. Otherwise a request can change its own price.
3. **Fees crystallized before pricing.** Management fee, then performance fee (Enzyme order), then the share price is computed. Fee shares minted at settlement.
4. **Dividend liabilities deducted.** Accrued, unclaimed fees and yield are a liability in the NAV-to-share conversion. Not counted as NAV owed to the holder twice.
5. **No instant exit at a stale mark.** Exit price is the settlement price for the next epoch. Stale NAV is never a valid exit price (Lagoon haircut is the anti-example).
6. **Valuation and settlement value match.** Lagoon's `settleDeposit` must match the posted `newTotalAssets`. Equivalent here: the settlement record stores the NAV hash or the block, and settlement must reference it.
7. **Revert, never zero.** A failed or stale read blocks settlement; it does not set NAV to zero or skip an adapter (ADR 0030 S6, ADR 0022 stale→0 applies only to the attested value, not to a failed NAV read).

### 2.4 Recommendations (settlement)

1. The repo should not own subscription logic. It should expose a pinned-block NAV read that the settlement layer records. Confirm the snapshot block is an argument, not `block.number`, so the caller pins it.
2. Settlement layer: take the NAV at a block at or before the request cutoff. Reject any settlement whose NAV block is after cutoff.
3. Exit at settlement price only. No instant redeem at a stale mark. If an instant path is needed, use an OUSG-style daily per-user limit as the rate limit (see §3.2).
4. Record the epoch's fee crystallization in the same transaction as the share price update. Use Enzyme Onyx's ordering as the reference.
5. Use `sharesActionTimelock` (Enzyme) or a block-based lock between subscribe and redeem to kill same-block sandwich. Size it against the NAV update frequency. A 1-second lock stops flash sandwiches but not multi-block arbitrage (Enzyme known risks).
6. Do not adopt Morpho V2 `forceDeallocate` semantics without a timelock. Its penalty can be 0.
7. Treat `[UNVERIFIED]` items (Centrifuge hub address, Lagoon version drift, ERC-7887 link) as unconfirmed until read from the live source.

---

## 3. Compromised-bot threat model

### 3.1 Assumptions

- The bot holds a Roles v2 role on the portfolio Safe (permission to call specific functions on specific targets, subject to conditions).
- The bot holds `SUBMITTER_ROLE` on the assisted and attested adapters (ADR 0030, ADR 0022).
- The bot's EOA can sign arbitrary transactions. Conditions in Roles are the only off-chain-independent limit.
- The Safe owners and the Security Council are not compromised.

### 3.2 Roles v2 mitigations (what exists)

Source: Zodiac docs (https://docs.zodiac.eco/developers/roles/allowances, https://docs.zodiac.eco/developers/roles/conditions, https://docs.zodiac.eco/developers/roles/reference) and the Gnosis Guild docs (https://docs.roles.gnosisguild.org/general/allowances, https://docs.roles.gnosisguild.org/general/conditions). The ZodiacRolesResearch peer is downloading the v2 (2.1.1) sources to /tmp; `/tmp/roles` was empty when checked. Confirm every item below against that source before relying on it.

- **Allowances.** `setAllowance(bytes32 key, uint128 balance, uint128 maxRefill, uint128 refill, uint64 period, uint64 timestamp)`. `period` is seconds. `period = 0` is a one-time budget that never refills. `refill` is added per period, capped by `maxRefill`. Keys ≤31 bytes.
- **Allowance accounting.** Failed calls do not consume allowance. Allowances update only after a successful call (Gnosis conditions doc). Useful: a reverting attack attempt costs no budget.
- **`WithinAllowance`.** Checks an integer field against an allowance and consumes it. Limits amounts only. It does not limit recipients: "combine WithinAllowance with a condition on the recipient, or the member can send the full budget to any address" (Zodiac allowances doc).
- **`CallWithinAllowance`.** Counts calls (decrements by 1). Rate limit on function invocations, e.g., `submitFor` ≤ N per period.
- **`EtherWithinAllowance`, `Encoding.EtherValue`.** Native-value limit.
- **`EqualTo` / `EqualToAvatar`.** Pins a field to a value, or to the Safe address. Use for recipient and approval-spender fields. `EqualToAvatar` is equivalent to `EqualTo` with the avatar as `compValue`, without storing the address (Gnosis conditions doc).
- **`maxRefill = 0`.** Zodiac reference says no ceiling; the older Gnosis page does not say. `[UNVERIFIED]`. Set an explicit ceiling anyway.
- **Roles v3 (preview).** Session keys, expiring roles, forfeitable roles (Zodiac docs preview). Not v2. Do not assume they exist for us.
- **Custom conditions.** Roles supports custom condition contracts for logic beyond operators. `[UNVERIFIED]` for v2.1.1; confirm in source. This is the only route to an on-chain price or NAV-delta check inside a Roles call.

Limits of Roles alone:
- Conditions check calldata and call context. They do not see prices, NAV, or other chains.
- A permitted target that does arbitrary things (e.g., a generic swap router) is only as safe as its calldata conditions.
- Allowances are per role-key, not per Safe-wide. Multiple roles can compound the budget.

### 3.3 Enumerated attacks

Ranked by severity (impact × plausibility given the stated assumptions). Each row names the control in the current design and the gap.

| Rank | ID | Attack | Impact | Current control | Gap / recommended control |
|---|---|---|---|---|---|
| 1 (Critical) | A1 | Bot transfers assets to attacker recipient via an allowed function | Direct loss of portfolio assets | Roles conditions (if any) | Require `EqualToAvatar` or an allow-listed recipient on every transfer, and `WithinAllowance` per token. No "any recipient" permission. |
| 2 (Critical) | A2 | Bot grants unlimited ERC-20 approval to an attacker spender, then drains | Direct loss | None in repo | `approve` only to an allow-listed spender, with `WithinAllowance` on amount, or `EqualTo` 0 for revocations. Deny `increaseAllowance`-style unbounded paths. |
| 3 (Critical) | A3 | Roles-permission change adds a non-assistant path to assisted protocols; bot exploits it to make the cache miss positions | Silent under-report; completeness loss (ADR 0015 residual) | None in repo (no tripwire) | Out-of-repo. Add a monitor or alarm on any `scopeTarget`/`allowFunction` change touching assisted protocols. Require Security Council approval. |
| 4 (High) | A4 | Bot submits crafted attested values (Merkl) to reduce NAV or misstate campaign split | Under-report (ADR 0022 says under-report only); campaign split up to 8x amplification | Merkle proof, stale-root → 0, leg bound 512 | Bound per-submit delta. Add a campaign-split cap that the proof does not set. Treat repeated upserts as a rate-limit target: `CallWithinAllowance` on `submitFor`. |
| 5 (High) | A5 | Bot sets NAV low via under-report to create cheap subscribe at settlement | Subscriber dilution / arbitrage at the expense of existing holders | Under-report only (contract level); settlement pins block (repo none) | On-chain NAV-delta circuit breaker in the settlement layer: reject settlement if |ΔNAV| exceeds a bound since the last epoch without Security Council override. |
| 6 (High) | A6 | Bot uses an allowed DeFi call (swap, deposit) at a manipulated price, sandwiches itself | Loss through slippage and oracle manipulation | Roles conditions on target and function | Custom condition: oracle-deviation check (price vs. Chainlink) before the call; `WithinAllowance` on amount per period. |
| 7 (High) | A7 | Bot removes live positions via `removeFor` or equivalent | Under-report; NAV drops | ADR 0030: permissionless `removeFor` only on proven death; S6 reverting read never counts as dead | Keep the proof-of-death gate. Add a rate limit on removals per period. |
| 8 (Medium) | A8 | Bot fills `OWNER_RESERVE` / creates dust positions to grief the 256 cap (S13) | Denial of service on new positions | `OWNER_RESERVE = 32` of 256 | Keep the reserve. Rate-limit `submitFor` with `CallWithinAllowance`. |
| 9 (Medium) | A9 | Bot submits oversized batches to push `getAccountNav` past gas (DoS settlement) | Settlement blocked | Leg bound 512; `AdapterGasExhausted`; 1.7x headroom | Cap batch size in Roles (`WithinAllowance` on array length, if expressible) and keep the leg bound. Monitor gas headroom. |
| 10 (Medium) | A10 | Bot spams `submitFor` or `removeFor` to burn gas or trigger cache churn | Operational noise; gas cost | None | `CallWithinAllowance` on each function. |
| 11 (Low) | A11 | Key theft of the keeper EOA | Limited by role scope | Roles scope; S5: keeper compromise can only add dust | Keep the keeper's role narrow (`submitFor` only, per ADR 0030). Rotate keys. |
| 12 (Low) | A12 | Bot front-runs settlement with its own deposits (if it holds a deposit role) | Pricing manipulation | Depends on settlement layer | §2.3 invariants: pending flows excluded; settlement at a pinned block. |

Ranking rationale: A1–A3 are direct loss or silent completeness loss and need only a single Roles permission to exist. A4–A6 move the NAV and so move prices for every holder. A7–A12 are availability or griefing.

### 3.4 On-chain circuit breakers (recommended, not in repo)

1. **NAV-delta bound.** Settlement rejects a NAV change beyond X% per epoch without a Security Council override. Blocks A5 and partly A4.
2. **Per-function rate limits in Roles.** `CallWithinAllowance` on `submitFor`, `removeFor`, `approve`, and every transfer. Blocks A2, A7, A8, A10.
3. **Recipient allow-list.** `EqualToAvatar` on transfers; allow-listed spenders only. Blocks A1, A2.
4. **Oracle-deviation guard** as a custom Roles condition for DeFi calls. Blocks A6.
5. **Pause** via Safe-owner multisig on the settlement layer. Not automatic. Needs a documented trigger.
6. **Proof-of-death and stale gates** already in the repo (ADR 0022, ADR 0030). Keep them.
7. **Timelock** on any change to Roles permissions touching assisted protocols (A3). Use the NAV timelock (3-day delay, ADR 0030 rollout).

### 3.5 Recommendations (threat model)

1. Enforce recipient and spender pinning in Roles before anything else (A1, A2). These are the highest-impact and cheapest to fix.
2. Add `CallWithinAllowance` on every bot-callable function (A7, A8, A10).
3. Add the NAV-delta circuit breaker in the settlement layer (A5). Requires a settlement contract that does not yet exist in this repo.
4. Write a Roles-permission-change alarm for assisted and attested protocols (A3). This is the only tripwire for the ADR 0015 residual.
5. Confirm all Roles v2 mechanics from the ZodiacRolesResearch sources before writing conditions. Items marked `[UNVERIFIED]` in §3.2 are not confirmed.
6. Keep ADR 0030 S5 and S6 as the reference for keeper-compromise scope.

---

## 4. Cross-cutting recommendations (ranked)

1. **A1, A2: Roles recipient and spender pinning.** Highest impact, lowest cost, no code in this repo.
2. **A3: roles-permission change alarm.** Closes the only completeness gap the repo cannot see.
3. **Settlement pinned-block and NAV-delta breaker.** Needs a new settlement contract; defines the epoch invariants in §2.3.
4. **Rate limits on every bot function.** Roles `CallWithinAllowance`.
5. **Proofs (Steel) only if an off-chain or cross-chain consumer appears.** Not needed for the on-chain path.
6. **Do not use Axiom.** Shut down (Trail of Bits).

---

## 5. Open items and [UNVERIFIED] list

- Roles v2 (2.1.1) mechanics: custom conditions, `maxRefill = 0` semantics, `scopeTarget`/`allowFunction` names. Pending ZodiacRolesResearch sources in /tmp (not yet present at time of writing).
- Steel proving cost for a 30M-gas view call. Needs a benchmark.
- Herodotus and Brevis pricing and rate limits.
- UMA final-fee current value ($250 vs $500).
- Centrifuge V3.1 hub address.
- Lagoon version drift (v0.4.0–v0.6.0).
- ERC-7887 canonical link.
- Ondo OUSG/USDY instant limits (conflicting third-party sources).
- Morpho V2 `forceDeallocate` penalty semantics with a zero penalty.

Verification not run: this file is research only. No builds, tests, or on-chain reads were executed.
