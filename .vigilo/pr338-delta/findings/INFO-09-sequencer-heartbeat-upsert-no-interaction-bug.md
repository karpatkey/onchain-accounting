# INFO-09: L2 sequencer-uptime gate and the heartbeat-upsert feature are fully independent — no interaction bug found

## Summary
Per audit brief item 4: verified the L2-sequencer-uptime check and per-feed heartbeat staleness are two
independently-computed, OR-combined flags with no shared mutable state, so changing a feed's `chainlinkHeartbeat`
via the new upsert path cannot affect, bypass, or be affected by the sequencer grace-period check.

## Verification

### The two checks never share state
- File: `src/prices/Prices.sol:60-77`
```solidity
bool sequencerDown = checkL2SequencerUptime();
bool feedStale;
(price, decimals, feedStale,,) = _selectFeed(token);
stale = sequencerDown || feedStale;
```
`sequencerDown` comes from `chainlinkL2SequencerUptimeFeed`/`chainlinkL2SequencerGracePeriod` (both set only via
`__Prices_init` at initialization — not touched anywhere in this PR's diff). `feedStale` comes from
`_selectFeedCore`'s per-feed `block.timestamp - effectiveTime >= cfg.chainlinkHeartbeat` comparison
(`src/prices/PriceFeedLib.sol:169`), which is exactly the field `addFeed`'s upsert path mutates
(`configs[i].chainlinkHeartbeat = heartbeat;`, line 1713). The two booleans are computed from disjoint storage
(`chainlinkL2SequencerUptimeFeed`/`chainlinkL2SequencerGracePeriod` vs. `_priceOracles[asset][i].chainlinkHeartbeat`)
and combined only by a plain `||` — there is no code path where writing one influences the other's inputs.

### `checkSequencerUptime` fails closed independently of any heartbeat value
- File: `src/prices/PriceFeedLib.sol:468-488`
```solidity
function checkSequencerUptime(address uptimeFeed, uint256 gracePeriod) external view returns (bool stale) {
    if (uptimeFeed == address(0)) return false; // L1 bypass only
    ...
    try AggregatorV3Interface(uptimeFeed).latestRoundData() returns (...) { ... } catch { return true; }
    if (answer != 0) { stale = true; }
    else if (startedAt == 0) { stale = true; }
    else {
        uint256 effectiveStartedAt = startedAt > block.timestamp ? block.timestamp : startedAt;
        if (block.timestamp - effectiveStartedAt <= gracePeriod) stale = true;
    }
}
```
The only non-L2 bypass is `uptimeFeed == address(0)`, a deploy-time constant unrelated to any asset's heartbeat
configuration. A reverting uptime feed fails closed (`stale = true`), a nonzero `answer` fails closed, and an
unelapsed grace period fails closed. `gracePeriod` is a single chain-wide value (`chainlinkL2SequencerGracePeriod`)
with no per-asset or per-feed override, so a MANAGER upserting one asset's `chainlinkHeartbeat` has zero surface
to influence it.

### Both checks apply symmetrically to a feed regardless of its (possibly just-upserted) heartbeat
`Prices.latestPrice`'s `stale = sequencerDown || feedStale` means: tightening a heartbeat (making `feedStale` more
likely to fire) only ever makes the combined `stale` flag MORE conservative (harder to report a fresh price), and
loosening a heartbeat only affects the `feedStale` term in the safe direction the PR documents — it never
interacts with, weakens, or is weakened by the sequencer term. No shared clock, no shared config, no code path
found where one gate's outcome depends on the other's threshold.

## Impact
- **Severity**: Informational — confirms no interaction bug between the new heartbeat-upsert feature and the
  existing L2-sequencer-uptime gate. The two remain architecturally independent, OR-combined safety checks.

## Recommended Mitigation
None required.
