# 0018 — Wrapper-fed assisted balance adapters (on-chain feeder, `WRAPPER_ROLE`)

Status: accepted

## Context

The assisted balance-adapter family (ADR [0015](0015-assisted-balance-adapter-family.md)) covers adapters that cannot derive a position from on-chain state alone and need a trusted party to submit position *coordinates* (never amounts), which the adapter then values live and re-verifies per read — so the feeder can only under-report. Every existing member is fed by an **off-chain** `ASSISTANT_ROLE` agent (kpk-agents automation) that watches chain state and submits the account's coordinates via periodic transactions.

For Nexus Mutual staking, the coordinates are `StakingNFT` token ids that are created/destroyed at a very specific, observable moment: when the position is opened or closed. An off-chain agent submitting a full-set `submitTokenIds` on a polling cadence is one way to keep the cache current, but it leaves a window between the on-chain deposit/withdraw and the agent's next submission during which NAV is stale, and it depends on an off-chain process staying live.

If deposits and withdrawals are routed through a **wrapper contract**, that wrapper already knows the token id the pool returned at exactly the moment it changes — it can push/pop the id into the adapter **atomically, in the same transaction**, with no off-chain component and no staleness window.

## Decision

Add a **wrapper-fed variant** to the assisted family: same trust model and family invariant as ADR 0015 (cache coordinates only, value live, re-verify ownership per read → the feeder can only under-report), but the feeder is an **on-chain contract holding `WRAPPER_ROLE`** instead of an off-chain agent holding `ASSISTANT_ROLE`, and the submit surface is **incremental** (single add / single remove) rather than a full-set replace.

- **`IWrapperFedBalanceAdapter`** (`is IAccessControl, IBalanceAdapter`) — marker interface exposing `WRAPPER_ROLE()`, the wrapper-fed peer of `IAssistedBalanceAdapter`. `IAccessControl` first so the C3 linearization matches `AccessControl` (OZ v5 `IAccessControl` is not `IERC165`).
- **`WrapperFedBalanceAdapter`** — abstract `AccessControl` base: `DEFAULT_ADMIN_ROLE` administers `WRAPPER_ROLE`; the constructor takes `(admin, wrapper)` and the wrapper is optional (granted after the wrapper is deployed, since the wrapper needs the adapter's address at construction). Mirrors `AssistedBalanceAdapter`.
- The generic NFT-id machinery is **shared** by both variants via role-agnostic cores factored out of the old assistant-only bases: `NftIdCache` (the `EnumerableSet.UintSet`-per-account store + ownership-checked/capped add, remove, clear) and `NftIdValuation` (the per-id fail-open `_collectLegs` self-call fan-out). The assistant-fed `AssistedNftCacheAdapter` / `AssistedNftValuationAdapter` and the wrapper-fed `WrapperFedNftValuationAdapter` all build on these — so Uniswap V3 / PancakeSwap V3 / ether.fi / the assistant-fed Nexus adapter keep their exact public API and behavior, and the wrapper-fed adapter reuses the identical cache + valuation code with only a different role and submit surface.
- **`WrapperFedNftValuationAdapter`** exposes `submit(account, tokenId)` (→ ownership-checked, capped, fail-loud add) and `remove(account, tokenId)` (idempotent), both `onlyRole(WRAPPER_ROLE)`, plus an admin `clearAccount` rescue.

**First member.** `NexusMutualStakingPoolsBalanceAdapter` — wrapper-fed peer of `NexusMutualStakingPoolsAssistedBalanceAdapter`. Both share the entire Nexus valuation via the feeder-agnostic `NexusMutualStakingValuationBase` mixin (per-NFT NXM `Staking` + `Rewards` legs, live ownership re-verification, positionId = staking-pool address, `positionInstanceId` = tokenId, labels), so the two adapters differ only in feeder and submit surface. It is fed by **`NexusMutualStakingPoolsWrapper`** — a thin, `DEPOSITOR_ROLE`-gated forwarder around Nexus staking pools: `depositTo` forwards to the pool and `submit`s the returned tokenId for the caller in the same tx; `withdraw` forwards and `remove`s it. On deposit the wrapper **pulls the exact NXM `amount` from the DEPOSITOR** (`transferFrom`) and then sets the exact-amount allowance to the Nexus `TokenController` before the pool call — so the DEPOSITOR must approve the wrapper to spend its NXM, and the wrapper custodies no NXM between calls. To withdraw, the wrapper must be a `StakingNFT` operator (arranged off-chain).

The tracked account is the **wrapper caller** (`msg.sender`), matching the adapter's live ownership re-verification. Nexus's `depositTo` mints/tops-up to a `destination` param, which stays in the wrapper's signature (ABI parity), but the adapter's fail-loud `submit` reverts `NotTokenOwner` — rolling the deposit back — if `destination != msg.sender`, so a caller must set `destination` to itself.

## Consequences

- Nexus staking gains an on-chain, atomically-maintained tracking path; the assistant-fed adapter (ADR 0015) is **kept** alongside it — both coexist, and the choice of which to register on `NAVCalculator` is a config decision.
- The wrapper-fed adapter remains a documented immutability exception (assisted family), now expressed through `WRAPPER_ROLE` rather than `ASSISTANT_ROLE`. The family invariant is unchanged, so the safety argument (feeder can only under-report) carries over verbatim.
- Because `withdraw` pops the id unconditionally and Nexus does not burn the `StakingNFT` on withdraw, a **partial** withdrawal stops tracking any remaining stake until the next deposit re-adds the id — a safe under-report, consistent with the invariant.
- New wrapper-fed members extend `WrapperFedNftValuationAdapter` (or `WrapperFedBalanceAdapter` directly for non-NFT coordinate shapes). Supersedes nothing in ADR 0015; extends it with a second feeder mechanism.
