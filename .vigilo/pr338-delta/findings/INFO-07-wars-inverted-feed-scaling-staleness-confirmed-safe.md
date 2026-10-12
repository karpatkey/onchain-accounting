# INFO-07: Arc (5042) wARS inverted-ARS custom feed — scaling, inversion, staleness and divide-by-zero/overflow all confirmed correct and fail-closed

## Summary
Per audit brief item 2: reviewed `InvertedChainlinkCustomPriceFeed` (`src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol`),
the contract backing the Arc (chain 5042) wARS entry in
`script/config/contracts-deployment-config/custom-price-feeds/5042.json`, in full, plus its NAV-side registration in
`script/config/nav-config/assets-and-price-feeds/5042.json`. No bug found; every risk in the brief is either
structurally impossible or explicitly and correctly guarded.

## Verification

### Inversion math and NAV_DECIMALS scaling
- File: `src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol:194-195`
```solidity
// X/USD = 1 / (X per USD), in NAV_DECIMALS. Division LAST — the answer is the denominator.
price = _navUnit.mulDiv(_feedUnit, uint256(answer), Math.Rounding.Floor);
```
`_navUnit = 10**NAV_DECIMALS` (8) and `_feedUnit = 10**feedDecimals` (8, for the live ARS feed), so
`price = 1e8 * 1e8 / answer`, matching the worked example in the docstring (`1e8*1e8/158309760000 = 63167` ≈
$0.00063167). `Math.mulDiv` is OpenZeppelin's 512-bit-intermediate implementation, so the `_navUnit * _feedUnit`
multiplication (max `1e8 * 1e8 = 1e16`, far under any realistic overflow bound for either the intermediate or the
final result at these decimal magnitudes) cannot overflow. Division is confirmed LAST, exactly as the docstring
states, avoiding the premature-floor error a "pre-invert into an 18-dec rate" shape would introduce.

### Divide-by-zero
- File: `src/prices/protocols/InvertedChainlinkCustomPriceFeed.sol:177-179`
```solidity
// A non-positive answer makes the inversion undefined — and a zero denominator would REVERT inside
// mulDiv, which on the read path is a worse failure than reporting staleness. Gate it here.
if (answer <= 0) return (0, true, roundId, startedAt, updatedAt, answeredInRound);
```
`answer <= 0` (which subsumes `answer == 0`) is checked and short-circuits to `stale = true` **before** the
`mulDiv` division at line 195 — a zero-answer feed can never reach the division. Confirmed: `mulDiv`'s division
input is provably nonzero at the point of use.

### Overflow
- The multiplication (`_navUnit * _feedUnit`) is bounded by two 8-decimal constants (`1e8 * 1e8 = 1e16`), nowhere
  near `type(uint256).max`; `Math.mulDiv` additionally handles arbitrary-width intermediates safely regardless.
  `answer` is read as `int256` from Chainlink and cast to `uint256` only after the `answer <= 0` gate, so no
  underflow/sign issue either.

### Staleness handling — three independent layers, all fail-closed
1. **Live decimals re-assertion per read** (lines 163-175): the cached `_feedUnit`/`_feedDecimals` are re-checked
   against the feed's *live* `decimals()` via `StaticCallLib.probeWord` on every call to `_compute()`. A mismatch,
   an unreadable `decimals()`, or a dirty/short returndata word all report `stale = true` rather than silently
   rescaling — verified this is the correct direction for this feed specifically, since (per the docstring at
   lines 49-59) the cached unit here is a *numerator*, so a `decimals()` migration would otherwise **over-report**,
   unlike every sibling "multiplied rate" feed in the repo where a cached-unit mismatch under-reports. The
   `probeWord`-based check (not `try`/`catch`) correctly also catches a decode failure, not just a revert (see
   `src/utils/StaticCallLib.sol:143-156`; `hasWord` is false on both `!ok` and `size < 32`).
2. **Plausibility band** (`MIN_ANSWER`/`MAX_ANSWER`, lines 106-119, 181-186): configured as `[1e10, 1e13]` raw
   units (`[100, 100000]` ARS/USD) in `script/config/contracts-deployment-config/custom-price-feeds/5042.json`,
   comfortably bracketing the live ~1596 ARS/USD rate with wide headroom in both directions (documented rationale:
   ceiling allows ~63x further ARS depreciation; floor catches a redenomination event or an inverted/mis-quoted
   feed, since an `ARS/USD`-direction feed masquerading at the same address would answer ~5 orders of magnitude
   below the floor). This is the runtime backstop for an aggregator migration that swaps quote direction at the
   same proxy address with the same `decimals()` — a case live-decimals re-assertion alone cannot catch, which the
   contract's own docstring (lines 106-117) explicitly calls out as the scenario this guards against.
3. **Heartbeat staleness** (lines 188-192), using the upstream-clock-ahead guard (`eff = min(updatedAt,
   block.timestamp)`) before comparing age against `FEED_HEARTBEAT` (86400s, matching both the constructor arg in
   `custom-price-feeds/5042.json` and the NAV-side registration heartbeat in `assets-and-price-feeds/5042.json:31`
   — no drift between the two configured values).

### Registration-time checks (constructor)
- `minAnswer_ == 0 || maxAnswer_ <= minAnswer_` reverts `InvalidArguments` (lines 133-135) — the band cannot be
  configured degenerately.
- `OracleArgumentChecks.assertChainlinkOracle` / `assertERC20Address` / `assertNotZeroNumber` gate the feed/asset/
  heartbeat constructor args.

### `BASE_ASSET == address(0)` — no NAV circularity
The feed derives its price from a single direct Chainlink leg with no NAV read, so `NavBaseUsdLib`'s
base/USD-must-be-direct circularity invariant does not apply; `PriceFeedLib._validateFeedNotCircular`
(`src/prices/PriceFeedLib.sol:2017-2030`) still runs at registration (fails closed, `CustomFeedBaseUnreadable`, on
any feed whose `BASE_ASSET()` cannot be read) and correctly resolves `address(0) != token`, so registration
succeeds without flagging a false circularity.

## Impact
- **Severity**: Informational — confirms the brief's checklist (scaling/inversion math, staleness, divide-by-zero,
  overflow) against NAV_DECIMALS with no defect found. This feed is unusually well-hardened relative to a typical
  inverted-oracle adapter (three independent staleness/sanity layers plus an explicit fail-closed decode guard).

## Recommended Mitigation
None required.
