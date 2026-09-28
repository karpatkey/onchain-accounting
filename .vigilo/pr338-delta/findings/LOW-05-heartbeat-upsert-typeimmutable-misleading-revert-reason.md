# LOW-05: Heartbeat-upsert path can reject a `priceType` change with the wrong named error, masking the real reason from operators

## Summary
`PriceFeedLib.addFeed` (and its `addMonitorFeed` mirror) correctly **rejects every attempt to change a
previously-registered feed's `priceType` while upserting its heartbeat** — confirmed fail-safe, no silent identity
change is possible. However, depending on which two `priceType`s are involved, the rejection surfaces as either the
intended `PriceFeedTypeImmutable` error **or** an unrelated `InvalidPriceOracle` / `PriceFeedDecimalsMismatch`,
because the identity guard sits *after* a decimals-resolution call that can itself revert or produce a spurious
match first. This is not an exploitable bug (the type change is rejected either way), but it is a genuine
observability gap in a privileged, incident-response-sensitive code path — the audit brief's item 1(b) asked this to
be confirmed explicitly.

## Vulnerability Detail

### Root Cause
`addFeed` resolves the resubmitted feed's decimals via `_resolveFeedDecimals` **before** the upsert loop reaches the
`priceType` equality check, so a decimals-resolution failure (or a same-decimals coincidence across two different
"AggregatorV3-shaped" `priceType`s) is what the caller sees first, not the identity violation the comments say is
being enforced.

### Code Location
- File: `src/prices/PriceFeedLib.sol`
- Function: `addFeed` (lines 1653-1740), helper `_resolveFeedDecimals` (lines 1625-1634)

```solidity
// src/prices/PriceFeedLib.sol:1625-1634
function _resolveFeedDecimals(address priceFeed, IPrices.PriceType priceType) private view returns (uint8 dec) {
    if (priceType == IPrices.PriceType.Custom) {
        dec = ICustomPriceFeed(priceFeed).decimals();
    } else if (priceType == IPrices.PriceType.API3) {
        // @audit reverts InvalidPriceOracle here if a NON-18-decimal feed (e.g. an incumbent Chainlink/Redstone
        // feed being resubmitted as API3) is probed — this fires BEFORE the priceType-identity check below ever
        // runs, so the caller never sees PriceFeedTypeImmutable for this particular type-change attempt.
        if (AggregatorV3Interface(priceFeed).decimals() != 18) revert IPrices.InvalidPriceOracle();
        dec = 8;
    } else {
        dec = AggregatorV3Interface(priceFeed).decimals();
    }
}
```

```solidity
// src/prices/PriceFeedLib.sol:1684-1687
uint8 dec = _resolveFeedDecimals(priceFeed, priceType);
if (len > 0 && configs[0].decimals != dec) {
    // @audit if a resubmission's *coincidental* resolved decimals differ from configs[0]'s stored decimals
    // (e.g. legitimate decimals drift on an unrelated array slot, or a Custom feed whose decimals() happens to
    // differ), this fires PriceFeedDecimalsMismatch before the loop ever inspects priceType equality for the
    // targeted index.
    revert IPrices.PriceFeedDecimalsMismatch(asset, configs[0].decimals, dec);
}

for (uint256 i; i < len; ++i) {
    if (configs[i].priceFeed != priceFeed) continue;
    // @audit this is the ONLY place PriceFeedTypeImmutable is thrown — reachable only when
    // _resolveFeedDecimals(priceFeed, priceType) succeeded AND its result equals configs[0].decimals.
    if (configs[i].priceType != priceType) revert IPrices.PriceFeedTypeImmutable(asset, priceFeed);
    uint256 oldHeartbeat = configs[i].chainlinkHeartbeat;
    if (oldHeartbeat == heartbeat) revert IPrices.PriceFeedAlreadyRegistered(asset, priceFeed);
    configs[i].chainlinkHeartbeat = heartbeat;
    emit IPrices.PriceFeedHeartbeatUpdated(asset, priceFeed, oldHeartbeat, heartbeat);
    return;
}
```

Traced both sub-cases the brief asks about:

1. **Chainlink → Redstone on the same incumbent feed address** (the "dangerous, same validation branch" case): both
   `priceType`s fall into the `else` branch of `_resolveFeedDecimals` (identical `AggregatorV3Interface(priceFeed)
   .decimals()` call), so `dec` resolves to the same value the feed was originally registered with, the
   decimals-mismatch guard at line 1685 passes, execution reaches the loop, and the identity check at line 1709
   **correctly fires `PriceFeedTypeImmutable`**. Confirmed caught by name, exactly as intended.
2. **Chainlink → API3 on the same incumbent feed address**: `_resolveFeedDecimals` for `API3` demands
   `decimals() == 18`. An incumbent Chainlink/Redstone feed is essentially always 8-decimal, so this reverts
   `InvalidPriceOracle` **before line 1709 is ever reached** — the type change is still rejected (fail-safe holds),
   but the caller is told "invalid oracle", not "you cannot change this feed's type". The same can happen via the
   decimals-mismatch branch for a Custom↔Chainlink swap whose resolved decimals happen to differ from
   `configs[0].decimals`, surfacing `PriceFeedDecimalsMismatch` instead of `PriceFeedTypeImmutable`.

**In every traced sub-case the state-changing outcome is identical and safe: the transaction reverts and no
identity change is ever applied.** The only defect is *which* named error the MANAGER sees.

## Impact
- **Likelihood**: Low — only reachable via a MANAGER-privileged call (`NAVCalculator.addOrModifyPriceFeed` /
  `addMonitorFeed`, both `_requireManager()`-gated), and only when the operator is *already* attempting an
  unsupported operation (changing a feed's type through the heartbeat-upsert entrypoint) rather than the documented
  remove-then-re-add flow.
- **Impact**: Low — purely an operational/observability gap. No state corruption, no price manipulation, no
  unintended identity change is possible; the guard's *effect* (rejection) is confirmed correct in every case
  checked.
- **Severity**: LOW.

## Attack Scenario
Not an attacker-exploitable scenario (privileged, and always ends in a revert with no state change). Operational
scenario instead:

### Preconditions
- Asset `wstETH` is registered with a single primary feed `F` at `priceType = Chainlink`.
- A MANAGER, believing `F` should now be validated as an `API3` dAPI (e.g. after misreading deployment config),
  calls `addOrModifyPriceFeed(wstETH, F, PriceType.API3, newHeartbeat)`.

### Attack Steps (operational mis-trace, not an exploit)
1. `NAVCalculator.addOrModifyPriceFeed` → `_addPriceFeed` → `PriceFeedLib.addFeed(priceOracles, wstETH, F,
   newHeartbeat, PriceType.API3)`.
2. `_resolveFeedDecimals(F, PriceType.API3)` calls `AggregatorV3Interface(F).decimals()`, gets `8` (a real Chainlink
   feed), `8 != 18` → reverts `InvalidPriceOracle()`.
3. The MANAGER's tooling / block explorer surfaces `InvalidPriceOracle`, which reads as "the oracle contract itself
   is broken" rather than "you tried to change this feed's registered type" — the actual, and correct, rejection
   reason is `PriceFeedTypeImmutable`, which this call path never reaches.
4. Time is lost chasing the wrong root cause (e.g. checking `F`'s health on Etherscan) instead of recognizing the
   type-change attempt needs a remove-then-re-add, exactly as the code comments at lines 1704-1708 document as the
   intended (but here mis-surfaced) UX.

### Expected Impact
- No fund-safety impact. Confirmed fail-safe: the feed's `priceType`, address, decimals and array position are
  never altered by this call regardless of which error fires.
- Operational cost only: a misleading error name during a privileged registration/incident-response action.

## Recommended Mitigation
Run the `priceType` identity check **before** calling `_resolveFeedDecimals`, using the stored `configs[i].priceType`
for any index whose `priceFeed` address matches, so the reject-reason is always `PriceFeedTypeImmutable` when the
address matches and only the caller's *new* type differs from what's on record — independent of whether the new
type's decimals-resolution branch happens to revert or coincide with `configs[0].decimals`:

```solidity
for (uint256 i; i < len; ++i) {
    if (configs[i].priceFeed != priceFeed) continue;
    if (configs[i].priceType != priceType) revert IPrices.PriceFeedTypeImmutable(asset, priceFeed);
    // ... resolve decimals / update heartbeat only after identity is confirmed unchanged
}
```
(Decimals still need to be re-resolved and compared for the genuine drift-detection purpose documented at lines
1674-1683, but that check should run only once the loop has confirmed `priceType` is unchanged for a matched
address, so a type-mismatch attempt always surfaces as `PriceFeedTypeImmutable` and never as an unrelated
`InvalidPriceOracle`/`PriceFeedDecimalsMismatch`.)
