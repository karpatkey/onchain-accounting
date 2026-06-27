# M-02: `ankrETH_CustomPriceFeed` Applies No Staleness Check on `ratio()` — Frozen Rate Passes as Fresh

## Summary

`ankrETH_CustomPriceFeed._compute()` multiplies a fresh Chainlink ETH/USD price by `IankrETH(ANKR_ETH).ratio()`. No freshness check is applied to `ratio()`. If the Ankr oracle pauses updates or is compromised, the price feed continues returning `stale = false` with an arbitrarily stale rate. This corroborates and extends wave-1 finding H-02, which catalogued the same pattern for rETH, wstETH, cbETH, rsETH, and ETHx but did not include ankrETH.

## Vulnerability Detail

### Root Cause

- File: `src/prices/protocols/ankrETH_CustomPriceFeed.sol`
- Function: `_compute()`
- Lines: 64–68

```solidity
// ankrETH_CustomPriceFeed.sol:64-68
uint256 ratio = IankrETH(ANKR_ETH).ratio();
if (ratio == 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
// @audit No staleness check on ratio(). A frozen non-zero ratio passes as fresh
//        as long as the Chainlink ETH/USD feed remains live.
price = uint256(ethToUsdPrice).mulDiv(1e18, ratio, Math.Rounding.Floor);
```

The Chainlink ETH/USD heartbeat is enforced (lines 61–63), but the only gate on `ratio` is `ratio == 0`. A stale, frozen, or manipulated non-zero `ratio` passes silently.

### ankrETH Rate Update Mechanism

The Ankr `ratio()` function reflects the relationship between ankrETH supply and the total ETH staked by Ankr validators. It is updated by an off-chain relayer that submits transactions to the Ankr contract. If the relayer pauses, the contracts are put into an emergency state, or governance manipulates the rate provider, `ratio()` can remain frozen at an old value while the real exchange rate moves.

Because `ratio` decreases over time (more ETH accrues per ankrETH as staking rewards accumulate), a frozen `ratio` from days ago means the price is denominated by an OLD lower ratio, resulting in a HIGHER computed ankrETH price than reality. Concretely: a frozen `ratio` = 0.85e18 (older snapshot) vs a true `ratio` = 0.82e18 (current, after more rewards accrued) would produce a price 3.7% higher than the true value.

### Comparison to H-02

Wave-1 H-02 covers: rETH (`getExchangeRate()`), wstETH (`stEthPerToken()`), cbETH (`exchangeRate()`), rsETH (`getLatestRate()`), ETHx (`getExchangeRate()`). ankrETH (`ratio()`) is the same vulnerability class, omitted from H-02.

## Impact

- **Likelihood**: Low-Medium — Requires Ankr's rate-update mechanism to pause or be compromised, while Chainlink ETH/USD remains fresh.
- **Impact**: Medium — ankrETH is priced above its real value. All portfolio positions holding ankrETH contribute an overstated NAV. If downstream systems use NAV for risk checks or limits, the overstated price could hide a solvency shortfall.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- Ankr's off-chain relayer stops submitting `ratio()` updates.
- Chainlink ETH/USD continues to update normally.

### Attack Steps
1. Ankr rate-update relayer pauses for an extended period (days/hours).
2. `ratio()` remains at the stale snapshot value while real staking rewards continue to accrue.
3. `ankrETH_CustomPriceFeed._compute()` fetches the fresh ETH/USD Chainlink price and the stale `ratio`.
4. The staleness gate checks only the Chainlink `updatedAt`; that check passes.
5. The feed returns `stale = false`, `price = ethUsdPrice * 1e18 / staleBigRatio`.
6. NAVCalculator uses this inflated price for all accounts holding ankrETH.
7. Reported NAV overstates the true ankrETH-denominated value.

### Expected Impact
- Portfolio NAV is overstated by the stale rate error for all ankrETH positions.
- No in-protocol loss occurs directly, but downstream risk systems and NAV-consumers receive misleading data.

## Recommended Mitigation

The Ankr protocol does not expose a `lastUpdated` timestamp alongside `ratio()`. Apply the same mitigation recommended in H-02: add a plausible-range sanity bound. ankrETH is a reward-bearing ETH LST; its ratio (ankrETH per ETH) should remain within a narrow band of its current value (e.g. no more than 5–10% change over the staleness window). Concretely:

```solidity
// Constructor: add immutable bounds
uint256 public immutable MIN_RATIO;   // e.g. 5e17 (0.5 ankrETH per ETH, sanity floor)
uint256 public immutable MAX_RATIO;   // e.g. 1e18 (1:1, freshly-deployed pool scenario)

// _compute(): sanity check after fetching ratio
uint256 ratio = IankrETH(ANKR_ETH).ratio();
if (ratio == 0 || ratio < MIN_RATIO || ratio > MAX_RATIO) {
    // @audit-fix: reject implausible ratio; mark stale
    return (0, true, roundId, startedAt, updatedAt, answeredInRound);
}
```

Bounds should be set conservatively around the protocol's realistic operating range and reviewed periodically.
