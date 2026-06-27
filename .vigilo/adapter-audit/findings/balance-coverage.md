# Balance Adapter Coverage — Per-Adapter Verdict

| Adapter | Valuation method (one line) | Verdict |
|---------|----------------------------|---------|
| AaveUmbrellaBalanceAdapter | `stakeToken.convertToAssets(balanceOf)` chained through up to one ERC4626 wrapper hop to the bare reserve; rewards via `calculateCurrentUserRewards` resolved to the same bare reserve | L-01 |
| AaveV3SafetyModuleBalanceAdapter | `previewRedeem(balanceOf)` for each hardcoded stake token; `getTotalRewardsBalance` for AAVE rewards | Clean |
| CapBalanceAdapter | `CUSD.getBurnAmount(USDC, cUsdBalance)` per leg (cUSD) and `getBurnAmount(USDC, stcUSD→convertToAssets→cUSD)` per leg (stcUSD) in NAV path; combined one-call `getBurnAmount` in aggregate path | L-03 |
| ERC20DefaultBalanceAdapter | `balanceOf(account)` via guarded assembly (zeroed scratch word, `returndatasize >= 32`); native via `account.balance` | Clean |
| ERC4626WrapBalanceAdapter | `WRAPPER.convertToAssets(WRAPPER.balanceOf(account))` denominated in `WRAPPER.asset()` | L-02 |
| EthenaCooldownBalanceAdapter | `StakedUSDeV2.cooldowns(account).underlyingAmount` — reads the locked USDe directly from the silo slot | Clean |
| KelpWithdrawalQueueBalanceAdapter | Sums `expectedAssetAmount` across open deque entries (`userAssociatedNonces` → `getUserWithdrawalRequest`) per payout asset; capped at 256 entries | Clean |
| LidoWithdrawalQueueBalanceAdapter | Finalized requests: `getClaimableEther` (exact); non-finalized: `amountOfStETH` (locked at request time) | L-04 |
| SparkLendBalanceAdapter | `getUserReserveData` aToken balance (supply) and variable debt per reserve; Collateral vs Supplied via `usageAsCollateralEnabled` | Clean |
| StaderWithdrawalQueueBalanceAdapter | `userWithdrawRequests(id).ethFinalized` (if > 0) else `ethExpected`; enumerated via OOB-catching `requestIdsByUserAddress` loop | Clean |

---

## Prior-finding disposition

| Prior finding | Status in this review |
|---|---|
| M-4 (ERC4626 `convertToAssets` ignores redeem fee) | **Confirmed** — L-02. Present and unchanged. Low because current wrapped vaults carry no exit fee. |
| M-5 (ERC4626 double-count wrapper + direct feed) | **Configuration-level risk, not an adapter bug.** The adapter itself is correct; double-counting requires a misconfigured NAVCalculator registration. Refuted as an adapter finding. |
| M-6 (Lido non-finalized requests overstated after negative rebase) | **Confirmed** — L-04. Present and unchanged. Low because negative rebases are rare and temporary. |
| M-15 (Cap leg-vs-combined burn-quote inconsistency) | **Confirmed** — L-03. Present and unchanged. Low because the divergence requires a non-proportional fee from Cap's `getBurnAmount`. |

---

## Notes on clean adapters

**AaveV3SafetyModuleBalanceAdapter**: uses `previewRedeem` (not `convertToAssets`), which correctly handles any redemption discount. The stkAAVE case where `stakedToken == rewardToken == AAVE` emits two distinct PositionBalances with different `positionKind` (Staking vs Rewards) — correct, not double-counting.

**EthenaCooldownBalanceAdapter**: reads the single `underlyingAmount` slot which Ethena zeroes on `unstake()`. No post-claim overstatement possible. The `PositionKind.Supplied` assignment is slightly debatable (the position is more accurately `Staking` since it is mid-exit), but consistent with the other withdrawal-queue adapters.

**KelpWithdrawalQueueBalanceAdapter**: `_owedForAsset` clamps the scan to 256 entries when `count > MAX_REQUESTS_PROBED` — this is a silent undercount (not a DoS), acknowledged by the existing comment. `positionId: ""` for multiple-payout-asset positions is fine because the identity key includes `balanceAsset`.

**StaderWithdrawalQueueBalanceAdapter**: `ethFinalized > 0 ? ethFinalized : ethExpected` correctly uses the exact finalised value when available. Stader does not apply a rebase-based finalization cap (unlike Lido), so `ethExpected` is a safe estimate for pending requests. Claimed-request detection via `owner == address(0)` relies on Stader's storage layout — acknowledged Low in prior audit (#12).

**SparkLendBalanceAdapter**: `aTokenBalance` from `getUserReserveData` is already in underlying token units (Aave/Spark aTokens maintain a 1:1 balance with the underlying inclusive of accrued interest). Variable debt only — stable debt dropped as explicitly documented (deprecated by Aave/Spark). Multi-leg split with correct `isDebt: true` on the Borrowed leg. Clean.
