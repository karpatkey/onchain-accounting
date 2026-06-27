# L-01: AaveUmbrella — Multiple reward tokens collapsing to the same bare reserve are summed without deduplication, doubling reward leg NAV

## Summary

`_claimableRewardInBareReserve` sums every reward token from `calculateCurrentUserRewards` whose resolved bare reserve equals the requested `wantedBareReserve`. If a single stake token has two configured reward tokens that both resolve to the same bare reserve (e.g. two aToken variants of USDC), their raw amounts are summed and reported as one reward figure in that reserve's units. Because the two reward tokens are denominated in different aToken contracts (not 1:1 unit-equivalent), the addition is incoherent, and the aggregate is over- or under-stated relative to the real claimable amount.

## Vulnerability Detail

### Root Cause

In `_claimableRewardInBareReserve`, all reward tokens that resolve to the same bare reserve are summed unconditionally:

```solidity
// @audit sums raw reward amounts across *different* reward tokens that share the same bare reserve
for (uint256 i; i < tokens.length; ++i) {
    address bare = _resolveRewardBareReserve(tokens[i]);
    if (bare == wantedBareReserve) {
        total += amounts[i];   // units of tokens[i], not of bare
    }
}
```

Each `amounts[i]` is in units of `tokens[i]` — the raw reward token. `_resolveRewardBareReserve` maps aTokens to their underlying via `UNDERLYING_ASSET_ADDRESS()`, but does **not** convert `amounts[i]` through the aToken's exchange rate before adding. If `tokens[i]` is a waToken (ERC4626-wrapped aToken) rather than a plain aToken, `amounts[i]` is in waToken-share units, not in bare-reserve units. Adding share amounts to asset amounts inflates or deflates the reported reward balance.

### Code Location
- File: `src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol`
- Function: `_claimableRewardInBareReserve`
- Lines: 292–305

```solidity
// @audit amounts[i] is in reward-token units (possibly waToken shares), not bare-reserve units
function _claimableRewardInBareReserve(address stakeToken, address user, address wantedBareReserve)
    internal
    view
    returns (uint256 total)
{
    (address[] memory tokens, uint256[] memory amounts) =
        REWARDS_CONTROLLER.calculateCurrentUserRewards(stakeToken, user);
    for (uint256 i; i < tokens.length; ++i) {
        address bare = _resolveRewardBareReserve(tokens[i]);
        if (bare == wantedBareReserve) {
            total += amounts[i];  // @audit no rate conversion applied
        }
    }
}
```

### Secondary concern

`_resolveRewardBareReserve` resolves only **one** hop via `UNDERLYING_ASSET_ADDRESS()`. If the reward token is a waToken (one ERC4626 hop above a plain aToken), it will return the aToken address, not the actual bare reserve. The staking-principal path (`_stakedUnderlying`) handles up to two wrapper hops explicitly, but the reward path does not mirror that depth, so a waToken reward will be mapped to the aToken address instead of the bare reserve, causing it to be skipped (aToken not registered in NAV) rather than reported.

## Impact

- **Likelihood**: Low — requires a governance-configured stake token to have multiple reward tokens with overlapping bare reserves, or a waToken as a reward token. Umbrella governance is responsible for reward configuration; today's deployments likely use distinct reward tokens. Not a current-state issue, but is a latent risk activated by future governance actions.
- **Impact**: Low — over-reports reward NAV if two distinct reward tokens for the same bare reserve are summed in incompatible units; under-reports if a waToken reward is skipped due to the single-hop resolution. Does not affect staked-principal valuation or isDebt flags.
- **Severity**: LOW

## Attack Scenario

### Preconditions
- Aave Umbrella governance configures a new stake token with two reward tokens both backed by the same bare reserve (e.g. a plain aUSDC reward plus a waUSDC reward).
- Both tokens' `UNDERLYING_ASSET_ADDRESS()` (for aUSDC) and bare address (for waUSDC, which has no `UNDERLYING_ASSET_ADDRESS()`) resolve or fall back to the same USDC address.

### Attack Steps
1. Aave governance action: add a second reward token (waUSDC, an ERC4626 wrapper) to an existing Umbrella stake token.
2. Adapter queries `calculateCurrentUserRewards` for the affected stake token; receives `[aUSDC, waUSDC]` with amounts `[A_atokens, B_shares]`.
3. `_resolveRewardBareReserve(aUSDC)` → USDC; `_resolveRewardBareReserve(waUSDC)` → USDC (because waUSDC has no `UNDERLYING_ASSET_ADDRESS()`, so it falls back to returning the waUSDC address itself — which is NOT USDC; this branch is the under-report path, not over-report). If `aUSDC.UNDERLYING_ASSET_ADDRESS() == USDC` and waUSDC also exposes `UNDERLYING_ASSET_ADDRESS() == USDC`, then `B_shares` (waToken shares) are added as if they were USDC units.
4. Reported reward NAV is `A + B` where B is in waToken-share units, inflating the position by `B_shares × (1 − 1/exchangeRate)`.

### Expected Impact
- Reward leg for that stake token is reported in mixed units, causing a NAV inaccuracy proportional to the waToken-to-bare-reserve exchange-rate deviation from 1:1.

## Recommended Mitigation

After resolving the bare reserve for a reward token, apply any intervening exchange rate before accumulating. Use the same multi-hop `_stakedUnderlying` conversion pattern for the reward path: if `_isErc4626Wrapper(rewardToken)`, convert `amounts[i]` through `IERC4626Like(rewardToken).convertToAssets(amounts[i])` before summing.
