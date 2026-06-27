# Assisted Adapter Coverage Summary

Audit branch: audit/vigilo-fixes
Scope: per-contract, access control + under-report invariant

---

## MerklRewardsBalanceAdapter
**Data-feeding model:** Off-chain assistant submits `(user, token, cumulativeAmount, merkleProof[])` via `submitProof`; proof is verified on-chain against live `Distributor.getMerkleRoot()` before caching. Reads compute `cumulativeAmount - claimed[user][token].amount`, returning 0 when the cached root no longer matches the live root.

**Under-report invariant: HOLDS.**
- `_unclaimed` always reads `claimed` from live Distributor. Stale-cache (root rotated) → returns 0. Fully-claimed → returns 0.
- `AmountRegression` guard prevents the assistant from feeding a lower cumulative amount to suppress a previously-verified value.
- Leaf encoding `keccak256(abi.encode(user, token, cumulativeAmount))` matches the Merkl Distributor source (ADR 0007 verified).
- **L-02 filed**: ASSISTANT_ROLE can `clearAllocation` on any live entry (targeted under-report). Documented design trade-off; no over-report path.
- No over-report path found.

---

## EtherFiWithdrawalQueueBalanceAdapter
**Data-feeding model:** ASSISTANT_ROLE submits tokenId arrays per account. Reads re-verify `ownerOf(tokenId) == account`, `isValid`, `isFinalized`, and value each from live `getClaimableAmount` (finalized) or `min(amountOfEEth, amountForShare(shareOfEEth)) - feeGwei` (pending).

**Under-report invariant: HOLDS.**
- Cache stores tokenIds only. Values are live on-chain reads on every NAV query.
- Ownership re-verified on every read (`ownerOf` try/catch → 0 if burned/transferred).
- `isValid` and `isFinalized` checks prevent counting invalidated or miscategorized requests.
- Pending valuation: `min(amountOfEEth, amountForShare(shareOfEEth)) - feeGwei` — takes the lower of locked eETH or share-implied ETH, protecting against negative rebase.
- MAX_TOKEN_IDS = 256 cap prevents OOG at read time.
- Light write-time hygiene (`ownerOf` check at submit) does not affect read-time correctness.
- No over-report path found.

---

## StakeWiseV3ExitQueueBalanceAdapter
**Data-feeding model:** ASSISTANT_ROLE submits `(vault, positionTicket, timestamp)` tuples per account. Reads value each position from `vault.calculateExitedAssets(receiver=account, positionTicket, timestamp, exitQueueIndex)` + `convertToAssets(leftShares)`. The `receiver=account` parameter is the on-chain ownership verification.

**Under-report invariant: HOLDS.**
- Cache stores coordinates only. `calculateExitedAssets(receiver=account, ...)` returns (0,0,0) for any tuple not genuinely belonging to `account`.
- Wrong/stale timestamp fed by the agent: `calculateExitedAssets` returns 0 → under-report, not over-report.
- `idx < 0` (fully pending): `queryIdx = type(uint256).max` causes `calculateExitedAssets` to return `(leftShares=full, 0, 0)` per StakeWise's early-return behavior; valued via `convertToAssets(leftShares)`.
- `getExitQueueIndex` try/catch → 0; `calculateExitedAssets` try/catch → 0; `convertToAssets` try/catch → 0. All failure modes degrade to under-report.
- MAX_POSITIONS = 256 cap prevents OOG.
- No over-report path found.

---

## NexusMutualStakingPoolsBalanceAdapter
**Data-feeding model:** Fully immutable; no assistant. Scans StakingNFT `tokenInfo(1..totalSupply)` descending to discover an account's tokenIds, then values via `StakingViewer.getTokens(ids)`. Early-exit via `balanceOf` count avoids scanning the full supply for non-stakers or small holders.

**Under-report invariant: HOLDS (no assistant to compromise).**
- Scan is bounded by `MAX_POSITIONS_PER_ACCOUNT = 64` at collection time.
- `balanceOf == 0` short-circuits to no scan. Reverts degrade to fewer ids (under-report).
- Ownership verified by `tokenInfo(id).owner == account` (live on-chain read).
- `StakingViewer.getAggregatedTokens` / `getTokens` try/catch → 0.
- **L-01 filed**: `getAdapterBalances` uses `getAggregatedTokens` while `getAdapterPositions` uses `getTokens` — two separate calls on the same external viewer. Any inconsistency between these two viewer methods causes the two interface paths to diverge. Not an over-report risk; a consistency risk.
- Known documented risk: if StakingNFT `totalSupply` grows very large, the scan can OOG inside NAV (not caught by try/catch). Out of scope here per SCOPE.md directive to focus on new issues.
- No over-report path found.

---

## UniswapV3PoolsMetaBalanceAdapter
**Data-feeding model:** Immutable meta-adapter (no assistant role despite directory placement). Instance set is pool addresses governed on NAVCalculator. For each pool, scans the account's NPM-held NFTs (`tokenOfOwnerByIndex`), computes liquidity amounts from oracle-derived `sqrtPriceX96`, and computes unclaimed fees from pool tick-level fee growth state.

**Under-report invariant: CONDITIONALLY HOLDS — see M-01.**
- Principal liquidity split uses oracle-derived `sqrtPriceX96` (manipulation resistant). Clean.
- Both tokens must be registered and non-stale to report any legs. Defensive.
- NFT ownership verified via `tokenOfOwnerByIndex` (NPM is ERC721Enumerable). Clean.
- Pool filter `t0 != token0 || t1 != token1 || f != fee` prevents cross-pool contamination. Clean.
- **M-01 filed**: `_computeFees` uses the oracle-derived `sqrtPriceX96` for the feeGrowthInside branch selection, while the pool's `feeGrowthOutside` tick state is anchored to the actual pool tick. When oracle price diverges enough to cross a position tick boundary (wrong branch selected), the unchecked subtraction `fgInside - fgInside0Last` can wrap to a near-max value, producing a massively over-reported fee leg. This violates the under-report invariant.

---

## PancakeSwapV3PoolsMetaBalanceAdapter
**Data-feeding model:** Identical to UniswapV3 (inherits all logic), only `_protocolId()` is overridden to return `PANCAKESWAP_V3`.

**Under-report invariant: CONDITIONALLY HOLDS — inherits M-01 from parent.**
- Historical `slot0.feeProtocol` uint32 vs uint8 ABI divergence is now moot (slot0 not read). Verified clean.
- All principal, fee, ownership, and registration logic is inherited unchanged from `UniswapV3PoolsMetaBalanceAdapter`.
- M-01 applies identically to PancakeSwap V3 pools.

---

## Finding Index

| ID | Severity | Adapter | Title |
|----|----------|---------|-------|
| M-01 | Medium | UniswapV3 / PancakeSwapV3 | Fee-growth branch selected via oracle tick, not pool tick — over-report on divergence |
| L-01 | Low | NexusMutual | `getAdapterBalances` vs `getAdapterPositions` use different viewer calls — consistency gap |
| L-02 | Low | Merkl | ASSISTANT_ROLE can `clearAllocation` on live entries — targeted under-report |
