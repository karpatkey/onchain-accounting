# 0016 — `isLocked` position status (claimable vs locked) + per-request de-aggregation

- Status: Accepted
- Supersedes (partially): the account-global anchor `positionId` of the withdrawal-queue / cooldown adapters

## Context

Withdrawal-queue and unstaking-cooldown adapters previously **aggregated** all of an
account's in-flight requests into a single `PositionBalance` leg and exposed no
claimable-vs-pending signal. NAV could report "you are owed 12.4 ETH" but not "8 is
claimable now, 4.4 is still locked." That distinction is real (per-request finalization,
per-request cooldown windows) and was previously only re-derived, in duplicated form, in
the app.

## Decision

1. Add `bool isLocked` to `INAVCalculator.PositionBalance` and `INAVCalculator.Position`
   (copied through unchanged in `PriceFeedLib`). It is an **attribute, not identity** — it
   is *not* part of the reconciliation key
   `keccak256(abi.encode(chainId, protocolId, positionId, balanceAsset.asset, positionKind))`.

2. **Rule:** `isLocked = false` only when the leg is **fully liquid / withdrawable now**.
   Any pending / cooling / partial portion ⇒ `isLocked = true` ("partial = locked").

3. **De-aggregate to one leg per request.** Each withdrawal request / NFT / ticket / cooldown
   becomes its own `PositionBalance`, addressable by a per-request `positionId`, carrying its
   own `isLocked`. Because each leg's `positionId` is unique, `isLocked` never needs to enter
   the key. NAV totals are unchanged (sum of legs = old aggregate).

4. **All other adapters report `isLocked = false`.**

The status is always computed **on-chain** from live reads. Enumerable / single-record
protocols (Lido, Stader, Kelp, Aave SM, Umbrella, Ethena) discover their legs on-chain. The
two assisted adapters (StakeWise V3, ether.fi) receive only the *coordinate* from the agent
(ticket / tokenId — not enumerable on-chain); amount and `isLocked` are still derived live, so
the assistant can only under-report.

## Per-protocol `isLocked` predicate

| Adapter | positionId | granularity | `isLocked` |
|---|---|---|---|
| Lido | `abi.encode(uint256 requestId)` | per NFT | `!status.isFinalized` (claimed skipped) |
| Stader | `abi.encode(uint256 requestId)` | per request | `ethFinalized == 0` |
| Kelp | `abi.encode(address asset, uint256 userNonce)` | per request | `!(userNonce < nextLockedNonce(asset) && block.number >= withdrawalStartBlock + withdrawalDelayBlocks())` |
| StakeWise V3 | `abi.encode(address vault, uint256 ticket, uint256 ts)` | per ticket | `leftShares > 0 \|\| exitedAssets == 0` (partial = locked) |
| ether.fi | `abi.encode(uint256 tokenId)` | per NFT | `!isFinalized(tokenId)` |
| Ethena | `abi.encode(address sUSDe)` | single cooldown | `!(block.timestamp >= cooldownEnd \|\| cooldownDuration == 0)` |
| Aave SM | stake `abi.encode(stk)`; unstaking `abi.encode(stk, uint8 1)` | live + unstaking legs | live `false`; unstaking `!(inUnstakeWindow)` |
| Umbrella | stake `abi.encode(stk)`; unstaking `abi.encode(stk, uint8 1)` | live + unstaking legs | live `false`; unstaking `!(inWithdrawalWindow)` |

For the staking-with-cooldown adapters (Aave SM, Umbrella) the live stake stays one
`Staking` leg (`isLocked=false`); a separate unstaking `Staking` leg appears only while a
cooldown is active, distinguished from the live leg by `uint8 1` in its `positionId`. Stake
tokens that do not expose the expected cooldown ABI degrade gracefully to a single live-stake
leg (the cooldown reads are wrapped in try/catch).

## Notes / known limitations

- **StakeWise claim delay.** StakeWise also enforces a ~24h `claimExitedAssets` delay after a
  position's `timestamp` that is *not* gated on here, because no public getter for the vault's
  claim delay is confirmed. Omitting it can only mark a fully-exited leg claimable slightly
  early; the leg is still locked while any shares remain queued. Revisit if a getter is confirmed.
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
- The app reads `isLocked` straight from `getAccountPositions` and renders a Claimable/Pending
  badge per leg; the per-protocol `use-*-withdrawals` re-derivation hooks become redundant.
- This supersedes the account-global anchor `positionId` introduced for these adapters; the
  decode tables in `docs/howto/position-identity-schema.md` and
  `docs/reference/position-identity-matrix.md` are updated to the per-request schema above.
