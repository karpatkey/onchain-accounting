# Bug-class sweep — `src/balances/` + `src/prices/`

**Scope.** Take the five defect shapes proven by the ~20-PR hardening wave and sweep every file in
`src/balances/` and `src/prices/` for further instances. Mechanical: known signatures, not open-ended review.

**Base commit.** `53b2d2eb` (`Merge pull request #192 from karpatkey/deploy/preflight-step-gates`).
Worktree `/home/sgzerbo/github-projects/onchain-accounting-sweep`, detached HEAD, **no source edited**.
`git status --porcelain --untracked-files=all` clean apart from this file; no `out/`. No review gates were run.

**The five classes.**

| # | Shape |
|---|---|
| 1 | `try`/`catch` does not catch a return-data decode failure, nor the `extcodesize` precheck on a code-less address — both revert in the *calling* frame and propagate past `catch` |
| 2 | A fail-open read that discards its `ok` flag, so a failed read is indistinguishable from a genuine zero |
| 3 | Gas starvation misclassified as a genuine revert — a callee that absorbs its own OOG returns successfully with a leg missing; and a locally-capped read cannot be rescued by more caller gas |
| 4 | A lookup returning `address(0)` silently zeroing a value-bearing leg |
| 5 | Tests that look like checks and aren't |

**Ranking rule.** Over-reports above under-reports. An under-report is conservative and visible to a caller
comparing against expectations; an over-report is not.

**Deliberately not re-reported** (owned / in flight): `EulerVaultsMetaBalanceAdapter._safeDebt` starvation (PR #193);
`CurvePoolLib.getPool(3Crv)` and the two vacuous Curve *label* fork tests; StakeWise's `_getAssetInfo` fallback label
path; `MetaBalanceAdapter.positionIds` and `_assetsForInstances` absorbing a starved instance (accepted by decision);
the paginated NAV read's unpinned slice-invariance. Two further items sit adjacent to that list and are **not** counted
as new findings here, because they are already in the unowned register: the never-implemented caller-side
`registerAsset` codesize guard (reachable via the `(uint256, bool)` decode at `PriceFeedLib.sol:105`), and
`ERC20DefaultBalanceAdapter`'s unstipended per-asset read (already documented at `PriceFeedLib.sol:1112-1117`).

---

# O1 — `ERC4626RedeemLib.redeemValue` silently upgrades a fee-net valuation to a gross one

**Class 3** (with a class-2 flavour: the fallback cannot distinguish "the vault answered" from "the read failed").
**Direction: over-reports NAV.** **Reachable with the currently governed instance set.**
**This is the only over-report in the sweep reachable today, which is why it gets its own section.**

### The code

`src/balances/ERC4626RedeemLib.sol:24-30`

```solidity
function redeemValue(address vault, uint256 shares) internal view returns (uint256) {
    try IERC4626Redeemable(vault).previewRedeem(shares) returns (uint256 net) {
        return net;
    } catch {
        return IERC4626Redeemable(vault).convertToAssets(shares);
    }
}
```

The library's own NatSpec (`:13-17`) states the premise that makes this a defect:

> `{redeemValue}` prefers `previewRedeem` (which, per EIP-4626 §4.3, is net of any redemption fee that
> `convertToAssets` **MUST ignore**) so a fee-charging vault is not over-reported, and falls back to
> `convertToAssets` only when `previewRedeem` reverts (e.g. the vault is paused) so the position is still reported.

So by construction `convertToAssets(s) >= previewRedeem(s)`, with the gap being exactly the redemption fee. The
fallback is therefore **unconditionally upward**. The trade-off is stated — "so the position is still reported" — but
its *direction* is not, and it is the one direction every other adapter in this repo is written to avoid. Compare
`GearboxV3CreditAccountsMetaBalanceAdapter.sol:37-40`, `FluidVaultsMetaBalanceAdapter.sol:69-72`,
`MorphoMarketsMetaBalanceAdapter.sol:60-63` — each drops a whole position rather than let a read failure move a
number upward. This library moves it upward silently.

### Exact call path from a NAV read to the mis-valued leg

```
NAVCalculator.getAccountNav(account)                     src/nav/NAVCalculator.sol
  └─ NAVCalculator._computePositions                     NAVCalculator.sol:469-483
      └─ PriceFeedLib.computeNav               (DELEGATECALL)   PriceFeedLib.sol:628
          └─ _getPositionBalances(allAdapters, assetIndex, account, address(0))   PriceFeedLib.sol:666
              └─ _queryAllAdapters                                    PriceFeedLib.sol:1049-1057
                  └─ _getAdapterPositions(adapter, account, filter)   PriceFeedLib.sol:1126-1152
                      └─ IBalanceAdapter(adapter).getAdapterPositions{gas: stipend}(...)   :1135
                          └─ MetaBalanceAdapter.getAdapterPositions          MetaBalanceAdapter.sol:191-199
                              └─ _positionsForInstances                       MetaBalanceAdapter.sol:282-314
                                  └─ this.instancePositions{gas: stipend}(...)  :293
                                      └─ MorphoVaultsMetaBalanceAdapter._instancePositions
                                                          MorphoVaultsMetaBalanceAdapter.sol:25-56
                                          └─ ERC4626RedeemLib.redeemValue(vault, vault.balanceOf(account))   :47
                                              ├─ try previewRedeem  → fee-net   ← correct
                                              └─ catch → convertToAssets → GROSS ← the defect
                                          └─ amount becomes PositionBalance.amount   :53
          └─ totalValue += _priceConversion(pos.amount, pos.isDebt, ...)   PriceFeedLib.sol:688-697
          └─ nav.value = totalValue                                        PriceFeedLib.sol:699
```

Both call sites reach the NAV number the same way:

* `MorphoVaultsMetaBalanceAdapter.sol:47` — deployed on **mainnet** (`balanceAdapters.MorphoVaultsMeta`,
  `script/config/deployments/1.json`) and **arbitrum** (`42161.json`), with a MANAGER-governed instance set.
* `AaveUmbrellaBalanceAdapter.sol:348` (via `_sharesToUnderlying:335-351`) — deployed on **mainnet**.

### What an operator would see

**Nothing.** This is the part that has to survive a sceptical reader:

* The leg is present, well-formed, positive, with the correct `balanceAsset`, `positionId`, `protocolSubId` and
  `positionKind`. Only `amount` is larger.
* It is a **balance-side** failure, so none of the price-side signals fire: `nav.stalePriceAssets` and
  `nav.irregularPriceAssets` (`PriceFeedLib.sol:678-679`) are untouched, `pd.stale` / `pd.irregular` /
  `divergenceBps` are untouched.
* No `AdapterGasExhausted` and no `InstanceGasExhausted`: nothing reverted from where those guards stand — the
  adapter returned normally, and so did the instance.
* No event. These are `view` paths end to end.
* `getAccountNavVerbose` is not a cross-check: it goes through `computeNavAndPositions`, which
  `PriceFeedLib.sol:609-614` documents as an intentional duplicate of the same math, over the same
  `PositionBalance[]`. Both reads return the same wrong number.

There is no field anywhere in `INAVCalculator.NAV`, `INAVCalculator.Position` or `INAVCalculator.PositionBalance`
that separates a fee-net valuation from a gross one. The only way to detect it is to call `previewRedeem` and
`convertToAssets` off-chain and diff them.

### Does it need anything the governance process wouldn't already have approved?

**No — and that is the sharp edge.** The exposure requires no change inside the trust boundary:

* the vault is already an approved instance (MANAGER `addMetaInstances`);
* the adapter, the asset registry, the instance set and the price feeds are all unchanged;
* the adapter is immutable, so once a trigger appears there is no fix short of redeploy + re-register.

Both triggers sit **entirely outside** the governance boundary, on the vault side:

1. **The vault turns on a redemption / exit fee.** A vault-owner action. `AaveUmbrellaBalanceAdapter.sol:344-346`
   names this explicitly for the `waToken` wrapper — "a redemption fee on the wrapper (possible via Aave
   governance)". Nothing in this repo is consulted.
2. **`previewRedeem` reverts or starves.** A vault-internal condition: paused, a queue market reverting, or a
   withdraw queue grown past what the frame can pay for. MetaMorpho's `previewRedeem` walks the withdraw queue, so
   its cost is a function of vault configuration the fund does not control. All ordinary operation, not an attack.

### Honest bounds on the claim

* **Magnitude is exactly the fee.** For a zero-fee vault `previewRedeem == convertToAssets` (the library says so),
  so on every currently configured instance the over-report today is **0**. The exposure is latent: it turns on
  the day a fee does, on an adapter that cannot be changed. This is a "fix it while it is free" finding, not a
  "there is a wrong number on chain right now" finding, and it should be triaged as such.
* **The revert half is certain from the code.** Any `previewRedeem` revert ⇒ gross valuation. No measurement needed.
* **The gas half is unverified.** I did not measure a vault where a starved `previewRedeem` leaves enough for
  `convertToAssets`. It is plausible (the queue walk is the expensive part) but treat it as a hypothesis; the
  revert half alone justifies the fix.
* **Note the asymmetry with the fallback's own risk:** if `convertToAssets` also reverts, the whole instance is
  dropped by the per-instance `catch` — under-report, the safe direction. Only the *successful* fallback is the bug.

### Shape of a fix (for scoping only — not applied)

The conservative direction is available and cheap: on `previewRedeem` failure, drop the leg (return 0 / revert the
instance) rather than substituting a value known to be an upper bound. That trades a silent over-report for a
visible under-report, which is the trade every sibling adapter already makes. If the "still report something"
property is wanted, `convertToAssets` would need to be reported with a flag, and there is no field for one — which
is itself an argument for the drop.

---

# U1 — `AssistedCoordCache._collect` absorbs a starved coordinate

**Class 3.** **Direction: under-reports NAV.** **Reachable with the currently governed instance set.**
**This is a port of a fix that already merged one directory away — but it is *not* line-for-line.**

### The code

`src/balances/AssistedBalanceAdapters/AssistedCoordCache.sol:222-230`

```solidity
for (uint256 i; i < list.length; ++i) {
    try this.valueCoordSelf(account, list[i], underlying) returns (
        INAVCalculator.PositionBalance[] memory legs
    ) {
        for (uint256 j; j < legs.length; ++j) { temp[count++] = legs[j]; }
    } catch {}
}
```

A bare `catch {}`, no `{gas: …}` stipend, no gas classification. A coordinate whose live valuation runs out of gas
is dropped exactly like one that genuinely reverted; the ~1/64 the EVM hands back then starves every *subsequent*
coordinate the same way; and `_collect` — and therefore `getAdapterPositions` — **returns successfully** with a
near-empty list. `PriceFeedLib._getAdapterPositions` sees no failure and raises nothing
(`PriceFeedLib.sol:1110-1118` describes precisely this residual). The account's entire assisted position set can
vanish with a complete-looking answer.

Direction is under-report *only* because the assisted family emits no debt legs by design
(`StakeWiseV3ExitQueueAssistedBalanceAdapter.sol:208` — `isDebt: false`). That is a property of today's three
members, not of the base class.

Reachable: `NexusMutualStakingPoolsAssisted`, `EtherFiWithdrawalQueueAssisted` and `StakeWiseV3ExitQueueAssisted`
are all registered on mainnet (`script/config/deployments/1.json`).

### The merged fix to copy

**PR #182**, merged as `2077c82e` (`Merge pull request #182 from karpatkey/fix/meta-instance-gas-exhaustion`).
The substantive commit is **`47ced224`** — *"fix(balances): stop the per-instance fan-out from absorbing a starved
instance"*. It touched `src/balances/MetaBalanceAdapter.sol`, `src/errors.sol`, `src/prices/PriceFeedLib.sol`,
`src/utils/GasStipendLib.sol`, plus `test/balances/MetaBalanceAdapterGasExhaustion.t.sol` and
`test/nav/NAVCalculator.gasCaps.t.sol`. The adapter-side diff is small enough to quote in full:

```diff
   for (uint256 i = 0; i < instances.length; i++) {
-      try this.instancePositions(account, instances[i], assetFilter) returns (
+      // One sample, used both to derive the stipend and to measure against it — see GasStipendLib.exhausted.
+      uint256 available = gasleft();
+      uint256 stipend = GasStipendLib.stipendFrom(available);
+      try this.instancePositions{gas: stipend}(account, instances[i], assetFilter) returns (
           INAVCalculator.PositionBalance[] memory p
       ) {
           perInstance[i] = p;
           total += p.length;
       } catch {
+          uint256 consumed = available - gasleft();
+          if (GasStipendLib.exhausted(stipend, consumed)) {
+              revert InstanceGasExhausted(address(this), instances[i], stipend, consumed);
+          }
           perInstance[i] = new INAVCalculator.PositionBalance[](0);
       }
   }
```

Its commit message also measured the hole it closed: *"33% NAV over-report on a three-instance adapter with one
starved instance, at every budget."*

### Is the port line-for-line? **No.** Three differences, one of them load-bearing.

1. **The `{gas: stipend}` is not optional here — it is a prerequisite.** The assisted fan-out currently forwards
   nothing, so the child gets 63/64 implicitly and there is no `stipend` figure to feed `GasStipendLib.exhausted`.
   The explicit `stipendFrom(gasleft())` must be added first, exactly as in the diff above. Mechanical.

2. **`InstanceGasExhausted` would be *rejected* upstream.** This is the difference that matters, and re-deriving
   it costs an afternoon. `PriceFeedLib._reraiseIfInstanceExhausted` gates the re-raise on three checks
   (`PriceFeedLib.sol:1182-1198`), the last of which is:

   ```solidity
   if (!adapter.supportsInterface(type(IMetaBalanceAdapter).interfaceId)) return;
   ```

   `AssistedCoordCache.supportsInterface` answers `IBalanceAdapter`, `IAssistedBalanceAdapter` and `IERC165` — **not**
   `IMetaBalanceAdapter`. So an `InstanceGasExhausted` raised by an assisted adapter fails gate 3, falls through to
   the gas heuristic, and — because the adapter would have raised on its *first* starved coordinate having spent
   almost nothing — is scored a benign revert by `GasStipendLib.exhausted` and **failed open, dropping the whole
   adapter**. That is verbatim the failure mode `47ced224`'s message says the explicit selector exists to prevent:

   > a meta-adapter that stops on its first starved instance has barely spent anything by the time it raises, so
   > the gas test would score a deliberate exhaustion signal as a benign revert and fail open — dropping the WHOLE
   > meta-adapter instead of surfacing the one instance, which is worse than the hole being closed.

   So the implementer must pick one of: (a) widen gate 3 to accept `IAssistedBalanceAdapter` as well — cheapest,
   and the marker interface already exists for exactly this kind of typing; (b) add a distinct
   `CoordinateGasExhausted(address adapter, bytes32 coordId, uint256 stipend, uint256 consumed)` and a second
   selector gate; or (c) leave the error un-honoured upstream and accept whole-adapter drop, which is strictly
   worse than the current behaviour and should not be chosen. **Option (a) is the smallest correct change**, but it
   is a `PriceFeedLib` edit — which moves that library's CREATE2 pin, and so must be sequenced with the held
   pin-regen PR. Flagging that explicitly because it changes the cost of this fix from "one file" to "pin-relevant".

3. **The scope carve-out does not transfer.** `47ced224` deliberately limited itself to `_positionsForInstances`,
   on the stated grounds that `_assetsForInstances` and `positionIds` *"degrade by under-reporting to a caller that
   can see it, not by moving a number."* `AssistedCoordCache._collect` is **not** in that category: it is on the
   `getAdapterPositions` path and it moves the NAV number. It was missed because it lives in a different base
   class, not because it was excluded. `_owedAmount` (`:198-204`) shares the same `_collect` and inherits the same
   behaviour.

---

# Remaining over-reports

## O2 — `UniswapV2PairLib`'s `kLast` fail-open resolves upward on a discarded `ok`

**Class 2 + class 3.** **Direction: over-reports NAV.** **Hypothetical instance set only.**

`src/balances/MetaBalanceAdapters/uniswap/UniswapV2PairLib.sol:123-124`

```solidity
(bool kLastOk, uint256 kLast) = _safeCallUint(pair, abi.encodeCall(IUniswapV2Pair.kLast, ()));
if (!kLastOk || kLast == 0) return (0, false);   // → pendingMint 0 → effectiveSupply = totalSupply
```

`_safeCallUint` delegates to `StaticCallLib.safeUint`, whose `ok` is the **raw staticcall success flag**. The
library documents at `:35-42` that this is exactly the question `ok` cannot answer:

> Callers that must distinguish "call succeeded but gave no usable value" from "returned zero" cannot get that from
> `(ok, result)` at all — they should call `{probeWord}` and gate on its `hasWord`.

**Failure scenario.** A pair whose `kLast()` returns fewer than 32 bytes — a V2 fork that omits the getter behind a
permissive fallback, or a code-less/short-replying pair — yields `kLastOk == true, kLast == 0`, indistinguishable
from a genuine "no fee accrued since last mint". `_pendingProtocolMint` returns 0, `effectiveSupply` collapses from
`totalSupply + pendingMint` to plain `totalSupply` (`:62`), and the LP's reserve share at `:64-65` is reported
**larger than `burn` would actually pay**. A reverting or gas-starved `kLast()` (`!kLastOk`) takes the same branch.

**Why this is an un-swept sibling, not a new idea.** The `feeTo()` read one line above (`:116-120`) was moved to
`StaticCallLib.safeAddrStrict` with a `malformed` flag *precisely because this branch resolves upward*. The 30-line
NatSpec at `:75-102` says so:

> **This is the one fail-open branch in this file whose failure direction is UPWARD** … Returning 0 collapses
> `effectiveSupply` … making the caller's reserve share LARGER — an over-report, the direction adapters are
> required never to take.

The hardening was applied to the first half of the expression and not the second. `safeUint` is also bounded by a
fixed `PROBE_GAS = 100_000` (`StaticCallLib.sol:49`) — class 3's second blind spot, which
`GasStipendLib.sol:39-43` explicitly rejects: *"a ceiling makes exhaustion unrecoverable — the caller cannot escape
it by supplying more gas."*

**Reachability.** Requires `feeTo != address(0)`, else `:121` returns before `kLast` is read. No
`UniswapV2PoolsMeta` or `PancakeSwapV2PoolsMeta` adapter is deployed on any of the 24 chains (checked every
`script/config/deployments/*.json`). Mainnet Uniswap V2 has `feeTo == address(0)`. A PancakeSwap V2 deployment
would have it set, as would Uniswap V2 if the protocol fee were ever switched on.

## O3 — the `assetFilter` half of the unreportable-debt guard, in six adapters

**Class 2 (adjacent).** **Direction: over-reports NAV in a filtered view.** **Reachable with the currently governed
instance set.**

Six adapters close the unregistered-debt hole with near-identical reasoning:

| File | Line |
|---|---|
| `MorphoMarketsMetaBalanceAdapter.sol` | 60-63 |
| `FluidVaultsMetaBalanceAdapter.sol` | 69-72 |
| `AaveV3InstancesMetaBalanceAdapter.sol` | 72-76 |
| `CompoundV3CometsMetaBalanceAdapter.sol` | 57-60 |
| `SparkLendBalanceAdapter.sol` | 128-132 |
| `GearboxV3CreditAccountsMetaBalanceAdapter.sol` | 138-139 |

each saying some form of *"Checked on registration only, NOT the assetFilter — a filtered view showing collateral
while hiding an unreportable debt over-reports the same way."*

That closes the *unregistered* case and leaves the *filtered* case open in the same function.

**Failure scenario** (`MorphoMarketsMetaBalanceAdapter.sol:52-53, 77-89`): a market whose loan token **is**
registered, queried with `assetFilter == collateralToken`. `collateralEligible` is true, `loanEligible` is false, so
the `Collateral` leg is emitted and the `Borrowed` leg is suppressed — a position reported as pure credit. Reached
from the per-asset NAV read (`PriceFeedLib.sol:723-732`, `NAVCalculator.sol:894-896`).

**Judgement.** This may well be intended semantics for a per-asset view — you asked for one asset, you get one
asset. But it is verbatim the failure the surrounding comments forbid, it is not written down anywhere as a
deliberate exception, and it is systemic across every lending adapter. **Wants a ruling, not necessarily a fix.**

## O4 — `FluidVaultLib.aggregate` absorbs its own out-of-gas mid-loop

**Class 3.** **Direction: under-reports in general; over-reports for a net-negative-equity NFT in the dropped
tail.** **Reachable with the currently governed instance set.**

`src/balances/MetaBalanceAdapters/FluidVaultLib.sol:150-163`

```solidity
uint256[] memory nftIds = IFluidVaultResolver(resolver).positionsNftIdOfUser(account);
for (uint256 i = 0; i < nftIds.length; i++) {
    ...
    (bool ok, bytes memory ret) = resolver.staticcall(abi.encodeWithSelector(
        IFluidVaultResolver.positionByNftId.selector, nftId));
    if (!ok || ret.length < 384) continue;
    ...
    collateralTotal += supply;
    debtTotal += borrow;
}
```

**This was named as a class-2 sibling to check, and it is not one** — it *does* test `ok` at `:157`. What it is
instead is a class-3 instance: a fail-open staticcall inside an unbounded loop over an account-sized NFT list. A
frame that starves mid-loop fails every remaining `positionByNftId`, `continue`s past each, and **returns
successfully with a partial aggregate**. `MetaBalanceAdapter`'s per-instance `InstanceGasExhausted` classifier is
never reached, because nothing failed from where it stands — `GasStipendLib.sol:25-30` describes exactly this
residual.

Dropped NFTs lose their supply and borrow together, so the usual direction is under-report. An NFT whose borrow
exceeds its supply — an underwater/liquidatable position — raises NAV when dropped. `FluidVaultsMeta` is deployed
on mainnet with a governed vault set.

---

# Under-reports

## U2 — `AaveV3SafetyModuleBalanceAdapter._cooldownSplit`: a classification-only read that can zero real balances

**Class 1.** **Direction: under-reports NAV.** **Signature present; not currently triggered — reachable via a proxy
upgrade of any of the four pinned stake tokens.**

`src/balances/BalanceAdapters/AaveV3SafetyModuleBalanceAdapter.sol:335` (also `:346`, `:352`)

```solidity
try IStakeToken(stakeToken).stakersCooldowns(account) returns (uint40 t, uint216 a) {
    ts = t; amt = a;
} catch {
    return (balShares, 0, false);
}
```

`uint40` and `uint216` both get ABI range validators, and the reply must be a full 64 bytes. A short reply — the
pre-2.5 stkAAVE ABI returned a single `uint256` — or a first word with bits set above 40 reverts **in this frame,
past `catch`**. That propagates out of `getAdapterPositions`, `PriceFeedLib._getAdapterPositions` fails open on the
revert (`:1139-1150`), and the **entire** Safety Module adapter drops out of the NAV.

**Why it is a defect and not a trade-off.** `_cooldownSplit` is classification-only: `lockedShares +
unlockedShares == balShares` (`:220-221`) and both legs are valued identically via `previewRedeem`, so it can only
ever move a balance between `isLocked` buckets. Its `catch` was written to fail open to "all locked". This is
`EulerVaultsMetaBalanceAdapter._supplyKind` verbatim (PR #167) — a cosmetic read able to zero real balances — in a
file that fix did not sweep. `EulerVaultsMetaBalanceAdapter.sol:158-185` documents the reasoning and the remedy
(drop to a low-level staticcall, validate the head before decoding).

**Live-trigger check.** I measured `stakersCooldowns(address)` returndata width on all four pinned tokens
(`_records()`, `:51-55`) against mainnet:

```
0x4da27a545c0c5B758a6BA100e3a049001de870f5  (stkAAVE)     64 bytes
0xa1116930326D21fB917d5A27F1E9943A9595fb47  (stkABPT)     64 bytes
0x9eDA81C21C273a82BE9Bbc19B6A6182212068101  (stkABPT_V2)  64 bytes
0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d  (stkGHO)      64 bytes
```

So it is **not firing today**. All four are upgradeable proxies and the adapter is immutable, which is the whole
argument for fixing it now.

## U3 — `BalancerV3PoolLib.poolTokens`: raw `abi.decode(…, (address))` on an arbitrary pool token's reply

**Class 1.** **Direction: under-reports NAV.** **Reachable with the currently governed instance set.**

`src/balances/MetaBalanceAdapters/balancer/BalancerV3PoolLib.sol:23-24`

```solidity
(bool success, bytes memory data) = currentToken.staticcall(abi.encodeWithSelector(IERC4626.asset.selector));
tokens[i] = (success && data.length >= 32) ? abi.decode(data, (address)) : currentToken;
```

A length check is not a range check. A pool token whose `asset()` answers a full word with dirty upper 96 bits — a
`bytes32`-shaped return, a padding-careless implementation, a permissive fallback — reverts the decode in the
calling frame. The identical probe 47 lines down (`:71-74`) sidesteps the decode entirely, so the two halves of one
file disagree.

This is the **only** raw `abi.decode(…, (address))` left in `src/balances` outside the masking convention that
`CurvePoolLib.sol:210-229` (`_firstAddress`, "rejects rather than masks") and
`AaveV3InstancesMetaBalanceAdapter.sol:204-206` ("Mask rather than `abi.decode(ret, (address))`: that reverts on a
word with dirty upper bits") both document at length.

Caught by the per-instance boundary ⇒ the whole instance is dropped. `BalancerV3PoolsMeta` and
`BalancerV3GaugesMeta` are deployed on **mainnet, base and arbitrum**.

## U4 — `AaveUmbrellaBalanceAdapter`: two more raw `abi.decode(…, (address))` after a guarded staticcall

**Class 1.** **Direction: under-reports NAV.** **Reachable with the currently governed instance set.**

`src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol:449` and `:458`

```solidity
address bare = abi.decode(ret, (address));   // _resolveRewardBareReserve:445-451
return abi.decode(ret, (address));           // _safeAsset:455-459
```

Both sit behind a correct `if (!ok || ret.length < 32) return …` guard — the guard simply stops short of the decode.
A reward token answering `UNDERLYING_ASSET_ADDRESS()`, or a stake token answering `asset()`, with a non-address word
reverts `getAdapterPositions`; `PriceFeedLib` fails open on the revert; the entire Umbrella adapter leaves the NAV
with no signal. Deployed on **mainnet**.

## U5 — `AaveUmbrellaBalanceAdapter._resolveBareReserve` → `address(0)` → whole stake token dropped

**Class 4 + class 3.** **Direction: under-reports NAV.** **Reachable with the currently governed instance set.**

`src/balances/BalanceAdapters/AaveUmbrellaBalanceAdapter.sol:242` (also `:139`, `:192`), resolving via
`_resolveBareReserve:414-424`

```solidity
address bare = _resolveBareReserve(stk);
if (bare == address(0)) continue;
```

The `CurvePoolLib.getPool` shape: a two-hop `asset()` chain that fails to resolve silently drops that stake token's
**entire** set of legs — locked staking, unlocked staking, and rewards — and a caller cannot tell the difference
between "no position" and "could not resolve". Compounding it, `_safeAsset` reads through
`staticcall{gas: PROBE_GAS}` — a fixed local cap, class 3's second blind spot, unrescuable by supplying more gas.
Deployed on **mainnet**.

## U6 — `ezETH_CustomPriceFeed._rate`: `try`/`catch` over nested dynamic arrays

**Class 1.** **Direction: under-reports (a dropped price, not a wrong one).** **Reachable with the currently
governed instance set.**

`src/prices/protocols/ezETH_CustomPriceFeed.sol:34`

```solidity
try RESTAKE_MANAGER.calculateTVLs() returns (uint256[][] memory, uint256[] memory, uint256 totalTVL) {
    ...
} catch {
    return 0;
}
```

The **only** `try`/`catch` over a non-trivially-decodable return anywhere in `src/` — confirmed by dumping every
`_rate()` implementation across all 34 files in `src/prices/protocols/`. A malformed head, an absurd length, or
empty returndata reverts the decode in this frame, past the `catch { return 0; }` that was written to be the
fail-open. Renzo's RestakeManager is an ERC-1967 proxy, which is the empty-returndata trigger named in the brief:
an implementation slot pointing at a code-less address makes the `delegatecall` succeed and return nothing.

Impact is bounded one frame up — `PriceFeedLib.sol:105-110`'s `catch { continue; }` skips the feed, so the asset
degrades to stale rather than mispriced — but the intended `return 0` path is not the one taken, and the fallback
inside the feed never runs. Deployed on **mainnet** (`deployments/1.json` → `customPriceFeeds.ezETH`). The
arbitrum deployment uses `ezETH_L2_CustomPriceFeed`, whose `_rate()` is a plain `getRate()` and is unaffected.

## U7 — `CompoundV3CometLib._rewardConfig`: three range validators on one decode

**Class 1.** **Direction: under-reports NAV.** **Hypothetical only — needs a rewards-contract upgrade.**

`src/balances/MetaBalanceAdapters/CompoundV3CometLib.sol:233`

```solidity
(token, rescaleFactor, shouldUpscale) = abi.decode(data, (address, uint64, bool));
```

Guarded on `ok` and on `data.length == 96`, but `address`, `uint64` and `bool` each emit a range validator — and
`bool` reverts on any word that is not exactly 0 or 1. A `CometRewards` answering 96 bytes with a non-boolean third
word reverts the whole comet instance. `rewards` is constructor-pinned (`COMPOUND_REWARDS`), so this needs an
upgrade of Compound's rewards contract. Deployed on mainnet, base and arbitrum.

---

# Class 5 — tests that look like checks and aren't

All three verified against mainnet at the pinned fork block; none is inferred from reading assertions alone.

## T1 — the whole of `ConvexCurveLPStakingMetaBalanceAdapter.fork.t.sol` asserts nothing

`test/balances/MetaBalanceAdapters/fork/ConvexCurveLPStakingMetaBalanceAdapter.fork.t.sol`,
`FORK_BLOCK = 22_500_000`. Measured on mainnet at that block:

```
rewarder 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA  balanceOf(0x989AEb4d175e16225E39E87d0D97A3360524AD80) = 0
rewarder 0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA  earned  (0x989AEb4d175e16225E39E87d0D97A3360524AD80) = 0
```

So all five staked-gated tests take their early return and assert nothing:

| Test | Guard |
|---|---|
| `test_booster_resolvesLpToken` | `:94` `if (staked == 0) return;` |
| `test_crvUsdUsdc_stakedDecomposesProRata` | `:107` |
| `test_crvEarned_reportedExactly` | `:121` (and `:127` on `crvExpected == 0`) |
| `test_cvxDerived_fromCrv` | `:141` (and `:152` on `crvAmt == 0`) |
| `test_positionId_isRewarder` | `:177` |

The sixth and last, `test_allFour_rewarders_fanOut:170`, is:

```solidity
assertGe(pos.length, 0); // at least no revert
```

`pos.length` is a `uint256`, so this can never fail. The "no revert" property is supplied by the call itself; the
assertion line is decoration. **`ConvexCurveLPStakingMeta` is deployed on mainnet with a governed instance set and
has zero effective fork coverage.**

## T2 — seven more vacuous tests in `CurveMeta.fork.t.sol`, beyond the two already owned

`test/balances/MetaBalanceAdapters/fork/CurveMeta.fork.t.sol`, same `FORK_BLOCK = 22_500_000`. Every pinned holder
reads zero:

```
gauge 0x95f00391cB5EebCd190EB58728B4CE23DbFa6ac1  staked(0xc9332cbf6fee06A6b8cf87e56Bd2E77e08C0C13c) = 0
gauge 0x053df3e4D0CeD9a3Bf0494F97E83CE1f13BdC0E2  staked(0x6cF2A2Cb4F1D3A4aeb56DB52E9b5B69F8bDB83c5) = 0
pool  0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E  LP    (0xc9332cbf6fee06A6b8cf87e56Bd2E77e08C0C13c) = 0
pool  0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5  LP    (0x6cF2A2Cb4F1D3A4aeb56DB52E9b5B69F8bDB83c5) = 0
```

**Already owned:** `test_positionLabels_crvUsdUsdc_gauge` (`:198`) and `test_positionLabels_threepool` (`:214`).

**Not owned, equally vacuous:** `test_crvUsdUsdc_walletLp_decomposes` (`:101`), `test_weethWeth_walletLp_decomposes`
(`:114`), `test_threepool_walletLp_decomposes_int128` (`:126`), `test_crvUsdUsdc_gauge_stakedAndRewards` (`:148`),
`test_weethWeth_gauge_staked` (`:161`), `test_crvUsdUsdc_gauge_assetFilter` (`:173`), `test_gauge_identity` (`:186`).

Only `test_crvUsdUsdc_instanceAssets_match_coins` (`:136`) has no early return and genuinely asserts.

## T3 — `NAVCalculator.invariant.t.sol:250` is a tautology

```solidity
assertTrue(bytes(registeredAssets[i].symbol).length >= 0, "symbol queryable");
```

`length` is a `uint256`; `>= 0` always holds. Nothing is checked. Its two neighbours —
`NAVCalculator.t.sol:685` and `:1815` — use `> 0` correctly, so this reads as a typo that survived review.

## T4 — `AaveV3SafetyModuleBalanceAdapter.fork.t.sol:156` — the reward-freeze test is a no-op at its pinned block

`test/balances/BalanceAdapters/fork/AaveV3SafetyModuleBalanceAdapter.fork.t.sol:156-165`,
`FORK_BLOCK = 25_000_000`.

```solidity
function test_rewards_freezeAfterDistributionEnd() public {
    uint256 distributionEnd = STK_GHO.distributionEnd();
    if (distributionEnd <= block.timestamp) return; // distribution already concluded; nothing to test
    ...
    assertEq(afterEnd, atEnd, "no further reward accrual past distribution end");
}
```

Measured on mainnet:

```
stkGHO (0x1a88Df1c…).distributionEnd() @ block 25,000,000 = 1749123599   (2025-06-05)
block 25,000,000 timestamp                                = 1777637363   (2026-04-29)
```

`1749123599 <= 1777637363` ⇒ the guard fires ⇒ the single assertion is never reached. The reward-freeze
behaviour of `AaveV3SafetyModuleBalanceAdapter` — deployed on **mainnet** — has **zero** coverage.

The test's own comment concedes the shape (*"if it's already past … the test is a no-op"*), so this is a known
degradation rather than an oversight; the point is that it has now actually degraded, silently, and nothing
reports it. Fixing it means either re-pinning `FORK_BLOCK` to a block before June 2025 for this assertion, or
warping backwards, or moving the property to a unit test with a mock.

---

# The mechanical signal for class 5

The shape — *a test whose assertions all sit behind an early-return guard that fires at the pinned block* — is
invisible from reading assertions, and the gas-floor signal (a vacuous test measured at 9,333 gas) needs a full
`via_ir` build plus RPC. That was not runnable here: three `solc` processes were already live with ~8 GB
available, which is the known concurrent-worktree OOM signature, so I did not add a fourth build.

**A build-free equivalent exists and turned out to be more precise.** Two passes:

**Pass 1 — static, no build, no RPC.** For every function in `test/**/fork/*.sol`, record the line of the first
bare `return;` (or `if (…) return;`) and the lines of every `assert*` / `vm.expectRevert` / `vm.expectEmit`.
Classify:

* **`FULLY GATED`** — every assertion line is *after* the first guard line. If the guard fires, the test asserts
  nothing. **This is the signal.**
* `PARTIAL` — some assertions precede the guard; the test still checks something.
* `NO-ASSERTS` — no assertion in the function body at all. Mostly noise (see below).

**Pass 2 — resolve each `FULLY GATED` guard on-chain at that file's `FORK_BLOCK`** with `cast call … --block N`.
A guard that evaluates true is a confirmed-vacuous test.

**Result on this tree.** Pass 1 flagged **15** `FULLY GATED` tests. Pass 2 confirmed **15 of 15** vacuous —
**no false positives in that bucket**:

| File | Gated | Guard | Verified |
|---|---|---|---|
| `ConvexCurveLPStakingMetaBalanceAdapter.fork.t.sol` | 5 | `staked == 0` | `balanceOf = 0`, `earned = 0` |
| `CurveMeta.fork.t.sol` | 9 | `staked == 0` / `walletLp == 0` | all 4 holder/pool reads `= 0` |
| `AaveV3SafetyModuleBalanceAdapter.fork.t.sol` | 1 | `distributionEnd <= block.timestamp` | `1749123599 <= 1777637363` |

Two calibration notes, so the next person can trust and reuse it:

* **`NO-ASSERTS` is mostly noise — do not act on it without a second look.** 24 of 25 hits are one-line tests
  delegating to a shared helper (`_assertMetaHasPositions`, `_assertHolderBalanceMatches`, `_assertHappyPath`,
  `_assertEnter`, the integration `test_accountNavs`). I read every one of those helpers: all contain real,
  *unguarded* assertions, so the tests are sound. The single genuine member is
  `FluidVaultsMetaBalanceAdapter.fork.t.sol:60` `test_metaBalance_doesNotRevert`, which asserts nothing by design
  and says so — a deliberate smoke test, and the file's other six tests do assert.
* **The tautology detector produced one false positive, and it is instructive.**
  `StakeWiseV3ExitQueueAssistedBalanceAdapter.fork.t.sol:89`
  `assertGe(IStakeWiseExitVault(GENESIS_VAULT).getExitQueueIndex(TICKET), 0, "should be checkpointed")` looks like
  the always-true `assertGe(x, 0)` pattern, **but `getExitQueueIndex` returns `int256`** and `-1` means "not
  checkpointed" (`StakeWiseV3ExitQueueAssistedBalanceAdapter.sol:269`). It is a real check. Any `assertGe(x, 0)`
  rule must resolve the return type before firing; only the two confirmed cases (`pos.length`,
  `bytes(...).length`) are genuinely unsigned.

The scanner is ~70 lines of Python (kept in this session's scratchpad as `vacuous_scan.py`, deliberately not
added to the repo). It is worth folding into CI as a lint: a new `FULLY GATED` fork test is a defect at the moment
it is written, and this catches it without a fork, an RPC key, or a build.

**Coverage caveat, stated plainly.** This sweeps the *guard-gated* shape across all fork tests. It does **not**
catch the other three class-5 shapes the wave found — a test byte-identical to the happy path, and a guard test
that never enters the production call path. Those need mutation testing (delete the guard's call site, see if the
suite stays green), which is a separate exercise and is not covered here. Of the ~1,500 tests in the suite, this
pass examined every function in the 40 fork-test files; the ~1,300 non-fork tests were scanned only for
tautological assertions (yielding T3).

---

# Coverage — what was swept and found clean

This is the part that makes it a sweep rather than a sample. All 108 files under `src/balances/` and
`src/prices/`, plus `src/utils/StaticCallLib.sol` and `src/utils/GasStipendLib.sol` as the shared primitives every
finding routes through.

### Read in full, or across the whole relevant surface — no finding

* `src/balances/LabelLib.sol` — the most thoroughly hardened reader in the repo: codesize short-circuit (`:131`),
  capped output window (`:141`), bound on bytes *copied* rather than `returndatasize()` (`:152`), ABI-head
  validation before decode (`:159-167`). All four code classes covered.
* `src/utils/StaticCallLib.sol` — correct as written; the defects are in callers that use `ok` where the library
  says to use `hasWord` (O2).
* `src/utils/GasStipendLib.sol` — including its own honest statement of what it cannot see (`:25-30`), which is
  what U1 and O4 are instances of.
* `src/balances/MetaBalanceAdapter.sol` — post-`47ced224`.
* `src/balances/MetaBalanceAdapters/curve/CurvePoolLib.sol` — `_firstAddress` rejects rather than masks, applied
  uniformly to every address read in the file.
* `src/balances/MetaBalanceAdapters/uniswap/UniswapV2PairLib.sol` — apart from O2.
* `src/balances/MetaBalanceAdapters/uniswap/UniswapV3PoolLib.sol`.
* `src/balances/BalanceAdapters/SparkLendBalanceAdapter.sol` and
  `src/balances/MetaBalanceAdapters/AaveV3InstancesMetaBalanceAdapter.sol` — both bitmap paths correctly avoid
  `try` for the non-contract and decode classes and mask instead of decoding; both close the unregistered-debt hole.
* `src/balances/MetaBalanceAdapters/GearboxV3CreditAccountsMetaBalanceAdapter.sol` — the `_debtReportable` gate at
  `:78` is sound; `_debtOf` failure drops the whole account.
* `src/balances/MetaBalanceAdapters/FluidVaultsMetaBalanceAdapter.sol` — the `||` at `:59` and the `debtRegistered`
  gate at `:73-76` are both correct.
* `src/balances/MetaBalanceAdapters/StakeWiseV3VaultsMetaBalanceAdapter.sol` — both legs share one asset and one
  filter, so the filter is symmetric and O3 does not apply.
* `src/balances/MetaBalanceAdapters/MorphoMarketsMetaBalanceAdapter.sol` — the realised-borrow gate at `:64-70`
  and the two-separate-`try` reasoning at `:140-149` are both correct.
* `src/balances/BalanceAdapters/ERC20DefaultBalanceAdapter.sol` — the assembly `balanceOf` read is correct and
  well-commented; its unstipended gas behaviour is the already-documented open item, not a new find.
* `src/balances/MetaBalanceAdapters/balancer/BalancerGaugeLib.sol`.
* `src/balances/MetaBalanceAdapters/curve/CurveGaugesMetaBalanceAdapter.sol` and
  `src/balances/MetaBalanceAdapters/ConvexCurveLPStakingMetaBalanceAdapter.sol` — every `ok`-discard site resolves
  downward; `pid()` already routes through `probeWord`/`hasWord` (`:294-305`), which is the correct pattern O2 is
  missing.
* `src/prices/BaseCustomPriceFeed.sol`, `src/prices/NavBaseUsdLib.sol`,
  `src/prices/TwoFeedChainlinkPriceFeed.sol`.
* `src/prices/PriceFeedLib.sol` — feed selection (`_selectFeedCore`, `_readFeedPrice`), divergence, sequencer,
  `buildPriceData`, `computeNav`, `_getAdapterPositions` and `_reraiseIfInstanceExhausted`.
* All 34 files in `src/prices/protocols/` — every `_rate()` implementation dumped and inspected; U6 is the only
  one with a `try`/`catch` over a non-trivially-decodable return.

### Signature-grepped for all four code classes — no match

`try` / `catch` / `staticcall` / `abi.decode` / `!= address(0)` / `== address(0)`:

* `src/balances/MetaBalanceAdapters/DedupeLib.sol`
* `src/balances/RegisteredAssetLib.sol`
* `src/balances/Balances.sol`
* `src/balances/BalanceAdapterBase.sol`
* `src/balances/SingleAssetBalanceAdapterBase.sol`
* `src/prices/Prices.sol`
* The five assistants — `BalanceAdapterAssistant.sol`, `IBalanceAdapterAssistant.sol`,
  `EtherFiWithdrawalQueueAssistant.sol`, `NexusMutualStakingPoolsAssistant.sol`,
  `StakeWiseV3ExitQueueAssistant.sol` (their `try … catch (bytes memory reason)` sites are write-path `remove()`
  calls with a `void` return — no decode surface)
* The interface-only files — `IBalanceAdapter`, `IBalances`, `IMetaBalanceAdapter`, `IAssistedBalanceAdapter`,
  `IPositionDescribable`, `IPositionEnumerable`, `IConvex`, `IUniswapV2`, `IBalancerV3`, `ICustomPriceFeed`,
  `IPrices`
* The three GPL Uniswap math libraries — `lib/TickMath.sol`, `lib/LiquidityAmounts.sol`, `lib/FixedPoint128.sol`
  (pure math, no external calls)
* `src/balances/BalanceAdapters/CapBalanceAdapter.sol`, `EthenaCooldownBalanceAdapter.sol`,
  `KelpWithdrawalQueueBalanceAdapter.sol`, `LidoWithdrawalQueueBalanceAdapter.sol`,
  `StaderWithdrawalQueueBalanceAdapter.sol` — single-asset, credit-only. Their `try` sites return `uint256` or
  `address` against constructor-pinned targets, and every failure path drops a credit leg. Two carry a weak
  class-1 signature not worth a finding on its own: `LidoWithdrawalQueueBalanceAdapter.sol:254`
  (`try WITHDRAWAL_QUEUE.STETH() returns (address s)` — dirty-word decode, target pinned via `requireContract`)
  and `EthenaCooldownBalanceAdapter.sol:139` (`try STAKED_USDE.cooldownDuration() returns (uint24 duration)` —
  a `uint24` range validator; sUSDe's protocol maximum is 90 days, well inside 2²⁴ seconds).
* `src/balances/MetaBalanceAdapters/GearboxV3MarketsMetaBalanceAdapter.sol`,
  `curve/CurvePoolsMetaBalanceAdapter.sol` (its `abi.decode` at `:143` is a `uint256`, correctly guarded),
  `balancer/BalancerV2PoolLib.sol`, `uniswap/UniswapV3PoolsMetaBalanceAdapter.sol` (already on
  `probeWord`/`safeAddrStrict`), `MorphoVaultsMetaBalanceAdapter.sol`, `FluidFTokensMetaBalanceAdapter.sol`.
* `src/balances/AssistedBalanceAdapters/NexusMutualStakingPoolsAssistedBalanceAdapter.sol` and
  `EtherFiWithdrawalQueueAssistedBalanceAdapter.sol` — both contain class-1 signatures
  (`try … returns (Token[] memory)` at Nexus `:175`; `try nft.getRequest() returns (WithdrawRequest memory)` at
  ether.fi `:203`) that are **defanged** by the `try this.valueCoordSelf(...)` frame boundary in
  `AssistedCoordCache._collect`: the decode revert happens in the child frame and is caught. Recorded here so the
  next reader does not re-derive them; the isolation that saves them is the same one U1 is about.

---

*Report-only. No source file was modified. Nothing is committed; this file is untracked, and the worktree is on a
detached HEAD (`git switch -c <branch>` would be required before committing anything, which is deliberately not
done — the tree must stop moving before the held CREATE2 pin-regen can be computed against it).*
