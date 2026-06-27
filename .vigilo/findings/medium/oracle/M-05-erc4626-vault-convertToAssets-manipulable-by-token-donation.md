# M-05: ERC-4626 Vault Price Feeds Use `convertToAssets` Which Is Manipulable by Direct Token Donation

## Summary

Six custom price feeds compute a vault-share price by calling `IERC4626(vault).convertToAssets(10 ** _vaultDecimals)`. Standard ERC-4626 implementations derive `convertToAssets` from `totalAssets / totalSupply`. An attacker who transfers underlying tokens directly to the vault contract (bypassing the `deposit` function) increases `totalAssets` without minting new shares, inflating the reported exchange rate. For a read-only NAV system this directly inflates the reported NAV of every account holding the affected vault shares.

## Vulnerability Detail

### Root Cause

- File: `src/prices/protocols/sGHO_CustomPriceFeed.sol`, lines 94–95
- File: `src/prices/protocols/sUSDe_CustomPriceFeed.sol`, lines 95–96
- File: `src/prices/protocols/syrupUSDC_CustomPriceFeed.sol`, lines 95–96
- File: `src/prices/protocols/RWIV_CustomPriceFeed.sol`, lines 95–96
- File: `src/prices/protocols/sXDAI_CustomPriceFeed.sol`, lines 95–96
- File: `src/prices/protocols/sUSDS_CustomPriceFeed.sol`, lines 97–98

All six follow the same pattern (example from `sGHO_CustomPriceFeed.sol`):

```solidity
// @audit convertToAssets reads totalAssets/totalSupply, which is inflatable by donation
uint256 sghoToGhoPrice = IERC4626(SGHO).convertToAssets(10 ** _vaultDecimals);
price = sghoToGhoPrice.mulDiv(ghoToUsdPrice.toUint256(), 10 ** _vaultDecimals, Math.Rounding.Floor);
```

`IERC4626.convertToAssets(shares)` is defined by OpenZeppelin as:
```
assets = shares.mulDiv(totalAssets() + 1, totalSupply() + 10**_decimalsOffset(), Math.Rounding.Floor)
```

`totalAssets()` for a standard ERC-4626 vault returns the vault's balance of the underlying token:
```solidity
function totalAssets() public view virtual returns (uint256) {
    return IERC20(asset()).balanceOf(address(this));
}
```

An attacker can call `IERC20(underlyingToken).transfer(vaultAddress, donationAmount)` to increase `balanceOf(vault)` without minting any shares. This inflates the price returned by `convertToAssets`.

### Affected Vaults and Estimated Inflation Sensitivity

| Feed | Vault | Underlying |
|---|---|---|
| `sGHO_CustomPriceFeed` | sGHO (Aave GHO savings) | GHO |
| `sUSDe_CustomPriceFeed` | sUSDe (Ethena staked USDe) | USDe |
| `syrupUSDC_CustomPriceFeed` | syrupUSDC (Maple Finance) | USDC |
| `RWIV_CustomPriceFeed` | RWIV (Nexus Mutual RWI) | USDC |
| `sXDAI_CustomPriceFeed` | sDAI/sxDAI (Gnosis savings) | xDAI |
| `sUSDS_CustomPriceFeed` | sUSDS (Sky/MakerDAO savings) | USDS |

The degree of inflation is:
```
priceInflation = donationAmount / totalAssets_before
```

A $1M donation to sUSDe (total TVL ~$3B) inflates the rate by approximately 0.03%, which is negligible. A $100K donation to RWIV (smaller TVL) could cause a proportionally larger distortion.

### Important caveat for sGHO

Aave's sGHO (StakedTokenV3) is not a standard ERC-4626 vault — it uses a custom accounting mechanism. Its `totalAssets()` may not track the raw `balanceOf(vault)` directly. The vulnerability applies with full force to any vault whose `totalAssets` is derived from `balanceOf`, which is true for the Maple Finance syrupUSDC and Nexus RWIV vault implementations.

## Impact

- **Likelihood**: Low — An attacker must spend real tokens with no direct on-chain gain from the NAVCalculator.
- **Impact**: Medium — Inflated vault price inflates the reported NAV for all accounts holding affected vault shares. Downstream off-chain systems that consume NAV for risk management, rebalancing, or withdrawal gating may be deceived.
- **Severity**: MEDIUM

## Attack Scenario

### Preconditions
- A portfolio account holds a significant position in syrupUSDC or RWIV.
- The attacker has capital to donate to the vault.
- An off-chain system (e.g. a risk model or a withdrawal gating mechanism) reads NAV from this system.

### Attack Steps
1. Attacker identifies that the NAV-based system gates an action at a threshold (e.g. "execute rebalance when NAV falls below X").
2. Portfolio NAV is approaching the threshold from above (asset values are declining).
3. Attacker donates a material amount of USDC directly to the syrupUSDC vault contract address: `USDC.transfer(syrupUSDC_vault, donationAmount)`.
4. `syrupUSDC.convertToAssets(1 share)` now returns a higher value.
5. `syrupUSDC_CustomPriceFeed.getLatestPrice()` returns an inflated price.
6. NAVCalculator reports the portfolio NAV as above the threshold.
7. The rebalancing or risk-management action is not triggered, even though the true portfolio value warrants it.

### Expected Impact
- Reported NAV for accounts holding syrupUSDC or RWIV is overstated relative to true value.
- Off-chain systems relying on this NAV may fail to trigger protective actions (rebalancing, risk alerts, or position limits).

## Recommended Mitigation

For each affected feed, either:

1. **Use a point-in-time snapshotted rate instead of live `convertToAssets`**: Some vaults expose a `pricePerShare()` or equivalent function that is computed from internal accounting rather than live `balanceOf`. Use that if available.

2. **Add a price sanity bound**: After computing the vault exchange rate, verify it falls within a plausible range relative to the expected baseline (e.g. rate must be within ±10% of 1.0 for yield-bearing stablecoins). Mark the feed stale if the rate exceeds the bound:

```solidity
uint256 rate = IERC4626(SGHO).convertToAssets(10 ** _vaultDecimals);
// @audit-fix: sanity bound to reject donation-inflated rates
if (rate > MAX_EXPECTED_RATE) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
```

3. **Document the limitation**: If the bound approach is not feasible, document in the NatSpec that the price is susceptible to donation manipulation and that callers should corroborate against an independent price source for large positions.
