# 0016 — `isLocked` position status (claimable vs locked) via a static positionId + two-leg split

- Status: Accepted
- Supersedes (partially): the single aggregated leg of the withdrawal-queue / cooldown adapters

## Context

Withdrawal-queue and unstaking-cooldown adapters previously **aggregated** all of an
account's in-flight requests into a single `PositionBalance` leg and exposed no
claimable-vs-pending signal. NAV could report "you are owed 12.4 ETH" but not "8 is
claimable now, 4.4 is still locked." That distinction is real (per-request finalization,
per-request cooldown windows) and was previously only re-derived, in duplicated form, in
the app.

## Decision

1. Add `bool isLocked` to `INAVCalculator.PositionBalance` and `INAVCalculator.Position`
   (copied through unchanged in `PriceFeedLib`).

2. **Keep a static, timeless `positionId`.** Each withdrawal-queue / cooldown adapter keeps a
   **static positionId** — a contract / asset / vault coordinate, never a per-request id (see
   the table below). It does not change as requests come and go.

3. **Split into up to two legs that share the static positionId.** An account's holding is
   split into a **claimable leg** (`isLocked = false`) and a **locked / pending leg**
   (`isLocked = true`). Both legs carry the **same** static positionId; they are told apart by
   `isLocked`. An account with nothing claimable (or nothing pending) emits only the one
   relevant leg. NAV totals are unchanged (sum of the two legs = the old aggregate).

4. **`isLocked` is NOT part of the reconciliation key (it is a mutable per-leg attribute).** Both
   legs share one positionId AND one stable key
   `keccak256(abi.encode(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind))`.
   `isLocked` is deliberately excluded: a leg flips `true→false` as its portion finalizes/unlocks,
   so keying on it would split one economic position into two keys over its lifetime. The claimable
   and locked legs therefore share one key and are **summed** in reconciliation (the sum is the full
   holding); `isLocked` is read per leg for the claimable-vs-locked breakdown, not as an identity
   discriminator.

5. **Uniform rule:** `isLocked = non-withdrawable`. `isLocked = false` only when the leg is
   **fully liquid / withdrawable now**. The claimable leg holds the withdrawable portion; the
   locked leg holds the pending / cooling portion ("partial = locked" — any not-yet-withdrawable
   amount lands on the locked leg). For the staking-with-cooldown adapters (Aave SM, Umbrella) the
   same rule applies: active stake is non-withdrawable (it needs a cooldown first) so it is
   **locked**, and only a cooldown that has elapsed and is still in its window is unlocked.

6. **All other adapters report `isLocked = false`** (single leg, unchanged).

The status is always computed **on-chain** from live reads. Enumerable / single-record
protocols (Lido, Stader, Kelp, Aave SM, Umbrella, Ethena) discover their legs on-chain. The
two assisted adapters (StakeWise V3, ether.fi) receive only the *coordinate* from the agent
(ticket / tokenId — not enumerable on-chain); amounts and `isLocked` are still derived live, so
the assistant can only under-report.

### Aggregate getters are unchanged

`getAdapterBalances` / `getAdapterBalanceForAsset` still return the **aggregate total** per
asset (claimable + locked summed) — the balance API is untouched. Only `getAdapterPositions`
performs the claimable/locked split.

## Static `positionId` and legs per adapter

| protocolSubId | static `positionId` | legs |
|---|---|---|
| `lido-withdrawal` | `abi.encode(address withdrawalQueue)` | claimable + locked |
| `stader-withdrawal` | `abi.encode(address userWithdrawalManager)` | claimable + locked |
| `kelp-withdrawal` | `abi.encode(address withdrawalManager)` (payout asset in `balanceAsset`) | claimable + locked |
| `stakewise-v3-exit` | `abi.encode(address vault)` (per vault) | claimable (exited) + locked (queued), per vault |
| `etherfi-withdrawal` | `abi.encode(address withdrawRequestNFT)` | claimable + locked |
| `ethena-cooldown` | `abi.encode(address sUSDe)` | single leg, `isLocked` while cooling |
| `aave-v3-safety-module` | `abi.encode(address stakeToken)` (both staking legs; reward leg too) | locked stake (`isLocked=true`) + unlocked stake (`isLocked=false`, cooldown elapsed-and-in-window) |
| `aave-v3-umbrella` | `abi.encode(address stakeToken)` (both staking legs; reward leg too) | locked stake (`isLocked=true`) + unlocked stake (`isLocked=false`, cooldown elapsed-and-in-window) |

## Per-protocol claimable/locked predicate

The locked portion is the amount for which the predicate below is true.

| Adapter | claimable vs locked split |
|---|---|
| Lido | per request: locked while `!status.isFinalized` (claimed requests skipped) |
| Stader | per request: locked while `ethFinalized == 0` |
| Kelp | per request: locked while `!(userNonce < nextLockedNonce(asset) && block.number >= withdrawalStartBlock + withdrawalDelayBlocks())` |
| StakeWise V3 | per position: `exitedAssets` is claimable only once `block.timestamp >= timestamp + EXIT_CLAIM_DELAY` (else locked); `convertToAssets(leftShares)` (still-queued remainder) is always locked (partial = locked) |
| ether.fi | per request: locked while `!isFinalized(tokenId)` |
| Ethena | single cooldown: locked until `block.timestamp >= cooldownEnd` (or `cooldownDuration == 0`) |
| Aave SM | active stake is non-withdrawable (needs cooldown) ⇒ locked; only a cooldown elapsed-and-in-window is the unlocked leg |
| Umbrella | active stake is non-withdrawable (needs cooldown) ⇒ locked; only a cooldown elapsed-and-in-window is the unlocked leg |

For the staking-with-cooldown adapters (Aave SM, Umbrella) the uniform rule `isLocked =
non-withdrawable` applies just as it does to the queues: active stake cannot be withdrawn without
first sitting out a cooldown, so it is **locked** (`isLocked=true`) — merged with any cooling or
expired-but-out-of-window cooldown into a single locked `Staking` leg. Only a cooldown that has
elapsed *and* is still inside its withdrawal window is withdrawable now, and forms the unlocked
`Staking` leg (`isLocked=false`). Both staking legs share `positionId = abi.encode(stakeToken)`
(no `uint8` discriminator); the `Rewards` leg shares it too and is told apart by
`positionKind=Rewards`. This is exactly the same identity model as the queues — one static
positionId, locked vs unlocked told apart by `isLocked` alone. Stake tokens that do not expose the
expected cooldown ABI degrade gracefully to a single locked-stake leg (the cooldown reads are
wrapped in try/catch).

## Per-request ids live in `positionInstanceId`, not in the stable identity key

Per-request coordinates (NFT id, ticket, nonce) are deliberately **not** in `positionId` or in
`positionLabels`. A per-request positionId was considered and rejected: those ids are
ephemeral (minted and burned as requests are created and claimed), so keying NAV identity on
them would churn the reconciliation key on every request lifecycle event and defeat caching.
`positionLabels` is therefore **unchanged** — a static breadcrumb keyed on the static
positionId (e.g. `["Withdrawal Queue", "stETH"]` for Lido, below the `protocolName()` of `"Lido"`).

Instead, each per-request coordinate rides in the typed, optional `positionInstanceId` field
(`bytes32`) on every leg — the NFT id / exit ticket / nonce widened to `bytes32`. It is the sole
ephemeral identity field: the stable reconciliation key
`(chainId, protocolSubId, positionId, balanceAsset.asset, positionKind)` deliberately
**excludes** it, so the legs of one anchor sum and identity survives request churn. A consumer
that wants per-request granularity may append `positionInstanceId` to the key. The adapters also
expose coordinate getters (`tokenIdsOf` on the ether.fi adapter, `positionsOf` on the StakeWise V3
adapter) so the app can read the queue contracts directly and render an individual breakdown. NAV
exposes the claimable/locked split; the app drills down to the request level.

## Notes / known limitations

- **StakeWise claim delay.** StakeWise also enforces a post-checkpoint `claimExitedAssets` delay
  (a fixed protocol constant, ~24h on V3 mainnet) after a position's `timestamp`. There is no
  public getter for it, so it is pinned on the adapter at construction as the immutable
  `EXIT_CLAIM_DELAY` and gated on directly: the exited portion is reported as **locked** until
  `block.timestamp >= timestamp + EXIT_CLAIM_DELAY`, which avoids marking a fully-exited leg
  claimable up to ~24h early. The leg's still-queued shares are always on the locked leg. The
  owed *total* (claimable + locked) is unaffected by the gate.
- **Kelp delay-gate fix.** The previous Kelp logic (and the app hook) treated a request as
  claimable on the nonce cursor alone, omitting the block-delay gate — a false-positive class
  matching a Sherlock-audited finding. The two-gate predicate above corrects it.
- **Rounding.** For Aave SM / Umbrella the split values each leg via `previewRedeem` /
  `convertToAssets` independently, so the per-leg sum can differ from the single-leg total by a
  few wei; the balance methods still report the exact total.

## Consequences

- The withdrawal-queue / cooldown adapters and `NAVCalculator` must be **redeployed** (the
  struct field changes all bytecode; adapters are immutable). The library pin shifts and must be
  regenerated against CI.
- Consumers that key on the reconciliation tuple must **not** include `isLocked` — it is a mutable
  per-leg attribute, so the claimable and locked legs share one key and must be **summed**. The
  aggregate balance getters are unchanged, so total-NAV consumers need no change.
- The app reads `isLocked` straight from `getAccountPositions` and renders a Claimable/Pending
  badge per leg; the per-protocol `use-*-withdrawals` re-derivation hooks become redundant for
  the split, and use the adapters' coordinate getters for per-request drill-down.
- The decode tables in `docs/howto/position-identity-schema.md` and
  `docs/reference/position-identity-matrix.md` reflect the static positionId + two-leg schema.
