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

4. **`isLocked` is part of the reconciliation key.** Because both legs share one positionId,
   `isLocked` must enter the identity key to keep the two legs distinct:
   `keccak256(abi.encode(chainId, protocolId, positionId, balanceAsset.asset, positionKind, isLocked))`.

5. **Rule:** `isLocked = false` only when the leg is **fully liquid / withdrawable now**. The
   claimable leg holds the withdrawable portion; the locked leg holds the pending / cooling
   portion ("partial = locked" — any not-yet-withdrawable amount lands on the locked leg).

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

| protocolId | static `positionId` | legs |
|---|---|---|
| `lido-withdrawal` | `abi.encode(address withdrawalQueue)` | claimable + locked |
| `stader-withdrawal` | `abi.encode(address userWithdrawalManager)` | claimable + locked |
| `kelp-withdrawal` | `abi.encode(address asset)` (per payout asset) | claimable + locked, per asset |
| `stakewise-exit` | `abi.encode(address vault)` (per vault) | claimable (exited) + locked (queued), per vault |
| `etherfi-withdrawal` | `abi.encode(address withdrawRequestNFT)` | claimable + locked |
| `ethena-cooldown` | `abi.encode(address sUSDe)` | single leg, `isLocked` while cooling |
| `aave-v3-safety-module` | live `abi.encode(address stakeToken)`; unstaking `abi.encode(address stakeToken, uint8 1)` | live (`isLocked=false`) + unstaking (`isLocked` unless in window) |
| `aave-v3-umbrella` | live `abi.encode(address stakeToken)`; unstaking `abi.encode(address stakeToken, uint8 1)` | live (`isLocked=false`) + unstaking (`isLocked` unless in window) |

## Per-protocol claimable/locked predicate

The locked portion is the amount for which the predicate below is true.

| Adapter | claimable vs locked split |
|---|---|
| Lido | per request: locked while `!status.isFinalized` (claimed requests skipped) |
| Stader | per request: locked while `ethFinalized == 0` |
| Kelp | per request, per asset: locked while `!(userNonce < nextLockedNonce(asset) && block.number >= withdrawalStartBlock + withdrawalDelayBlocks())` |
| StakeWise V3 | per vault: claimable = `exitedAssets`; locked = `convertToAssets(leftShares)` (partial = locked) |
| ether.fi | per request: locked while `!isFinalized(tokenId)` |
| Ethena | single cooldown: locked until `block.timestamp >= cooldownEnd` (or `cooldownDuration == 0`) |
| Aave SM | live stake `isLocked=false`; unstaking leg locked unless inside the unstake window |
| Umbrella | live stake `isLocked=false`; unstaking leg locked unless inside the withdrawal window |

For the staking-with-cooldown adapters (Aave SM, Umbrella) the live stake stays one
`Staking` leg (`isLocked=false`); a separate unstaking `Staking` leg appears only while a
cooldown is active, distinguished from the live leg by `uint8 1` in its `positionId` (this is
the one case where the two legs use *distinct* static positionIds rather than relying on
`isLocked` alone). Stake tokens that do not expose the expected cooldown ABI degrade gracefully
to a single live-stake leg (the cooldown reads are wrapped in try/catch).

## Per-request ids live in the app, not in identity

Per-request coordinates (NFT id, ticket, nonce) are deliberately **not** in `positionId` or in
`positionLabels`. A per-request positionId was considered and rejected: those ids are
ephemeral (minted and burned as requests are created and claimed), so keying NAV identity on
them would churn the reconciliation key on every request lifecycle event and defeat caching.
`positionLabels` is therefore **unchanged** — a static breadcrumb keyed on the static
positionId (e.g. `["Lido","stETH Withdrawal Queue"]`).

Per-request detail still belongs somewhere — it lives in the **app**, which reads the queue
contracts directly and the adapters' coordinate getters (`tokenIdsOf` on the ether.fi adapter,
`positionsOf` on the StakeWise V3 adapter) to render an individual breakdown. NAV exposes the
claimable/locked split; the app drills down to the request level.

## Notes / known limitations

- **StakeWise claim delay.** StakeWise also enforces a ~24h `claimExitedAssets` delay after a
  position's `timestamp` that is *not* gated on here, because no public getter for the vault's
  claim delay is confirmed. Omitting it can only mark a fully-exited leg claimable slightly
  early; the leg's still-queued shares remain on the locked leg. Revisit if a getter is confirmed.
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
- Consumers that key on the reconciliation tuple must include `isLocked` (it is now part of the
  key). The aggregate balance getters are unchanged, so total-NAV consumers need no change.
- The app reads `isLocked` straight from `getAccountPositions` and renders a Claimable/Pending
  badge per leg; the per-protocol `use-*-withdrawals` re-derivation hooks become redundant for
  the split, and use the adapters' coordinate getters for per-request drill-down.
- The decode tables in `docs/howto/position-identity-schema.md` and
  `docs/reference/position-identity-matrix.md` reflect the static positionId + two-leg schema.
