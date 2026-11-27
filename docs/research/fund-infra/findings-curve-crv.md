# Findings from the Curve 3pool + gauge fork test

Two surprises in `test/poc/fundconfig/FundConfigLpGauge.fork.t.sol`, checked with `cast` against mainnet at block 26,500,000 and by reading `src/`.

## 1. Legacy Curve pools report no wallet LP (latent, not live)

**Verdict:** latent gap in `src/`. Production NAV is not affected today, because no legacy pool is registered.

- `CurvePoolLib.getLpToken` (`src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol:85-93`) falls back to "the pool is its own LP". `balanceOf` on the pool fails open to 0, so `CurvePoolsMetaBalanceAdapter._instancePositions` (`src/balances/MetaBalanceAdapters/curve/CurvePoolsMetaBalanceAdapter.sol:60`) returns `[]`. A Safe holding 3Crv shows nothing.
- `getPool` (lines 146-165) already resolves legacy LPs through the registry with a round-trip check; `getLpToken` has no reverse lookup. The comment at lines 66-84 says this was cut from an earlier PR and deferred.
- `script/config/nav-config/meta-balance-adapters/1.json` registers four `CurvePoolsMeta` instances (`0xDB74…`, `0x4DEc…`, `0x390f…`, `0xD001…`). All four are self-LP (they answer `totalSupply()`/`symbol()`: `crvUSDUSDC-f`, `weeth-ng`, `RLUSD/USDC`, …), so they resolve correctly.

**Risk:** registering any legacy pool (3pool, and others whose LP is a separate token without `lp_token()`) silently under-reports its wallet LP. The FundConfig removal guard inherits the blind spot: it lets the 3pool position be removed while 3Crv is held.

**Proposed fix (separate PR):** a reverse registry fallback in `getLpToken` reusing `getPool`'s `_lpTokenFromRegistry` + `_hasCoinMethod` round-trip, skipped when the registry answer equals the pool; review all three `getLpToken` consumers together. Until then, a preflight check that rejects `CurvePoolsMeta` instances whose resolved LP has zero `totalSupply`.

**Doc drift:** `CurvePoolLib.sol:16-20` and `CurvePoolsMetaBalanceAdapter.sol:17-18` say StableSwap-NG pools reach a separate LP through `lp_token()`. The registered NG pools are self-LP and revert on `lp_token()`. Behaviour is right; the comments mislead.

## 2. CRV priced stale in `fundNav` (likely a test artifact)

**Verdict:** cause not confirmed by a direct check; very likely the test's time warp. A control run (CRV in the Safe, no `vm.warp`, assert `stale == false`) has not been run.

- CRV's primary feed is Chainlink CRV/USD `0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f`, heartbeat 86,400 s. At the fork block `updatedAt = 1795703003`, block time `1795703639`: 636 s old, fresh.
- `test_CRV_claimViaMinter` runs `vm.warp(block.timestamp + 1 days)` (line 444) to accrue CRV. That moves the feed's age to 86,400 + 636 s, past the heartbeat, with no new round on the fork. `calculateValue` then correctly reports the price stale.
- If confirmed, no pricing defect. A test that needs a fresh CRV price after warping must mock a new round (`vm.mockCall` on `latestRoundData`) or roll the fork forward instead of warping.
