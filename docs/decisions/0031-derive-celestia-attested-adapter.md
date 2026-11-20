# 0031 — Derive v3 balances: an attested member verified against Derive's Celestia blob commitment

**Status:** proposed (2026-11-20)
**Extends:** [0022](0022-attested-balance-adapter-family.md) (attested family). No change to `NAVCalculator` or to
the Merkl member ([0007](0007-merkl-trust-minimized-cache.md)).

## Context

A fund Safe that trades on Derive v3 keeps its collateral and positions on Derive's sequencer. Ethereum holds the
`VerifiableApp` (VAPP, `0xd330…58BB`): the current state root, an SP1 proof per batch (about every 10 minutes,
measured), and `celestiaLastCommitment()`, the Celestia share commitment of the newest batch's data blob. Derive
publishes no state layout and no per-account proof, so the root cannot be used directly.

Each batch's blob is public on Celestia. Its subaccount section was decoded (Rust bincode varints; evidence in
`derive-spike/docs/research/derive-v3-l1-verification.md`, addenda of 2026-11-19 and 2026-11-20). Every record holds
id, manager, owner, collateral balances and positions, and only subaccounts that changed in the batch appear. A
prototype (`derive-spike/onchain`) verifies a record's shares against `celestiaLastCommitment()` and decodes it,
tested on real batches and on a fork of mainnet.

## Decision

1. **A new attested member, `DeriveCelestiaAttestedBalanceAdapter`**, on `AttestedValueCache`:

   | Hook | Implementation |
   |---|---|
   | `_liveEpoch()` | `VAPP.celestiaLastCommitment()` |
   | `_verifyPayload(epoch, account, data)` | Verify the blob's share 0 at index 0 and read the share count from it. For each subaccount in `data`: verify its shares against `epoch` at their stated blob indices (the subtree layout comes from the share count, never from the submitter), require consecutive indices, decode the record; require `owner == account`, zero perps, zero options, every balance ≥ 0; require `programVKey()` and `verifier()` equal the immutable values passed to the constructor (the reviewed pair at deployment). Sum balances per asset across the subaccounts, map each Derive asset id to its Ethereum token through an immutable table, scale 12 decimals to the token's. |
   | `_isLive` | Live iff the stored epoch equals the live commitment, the entry is at most 30 minutes old, and the program pins still hold. |
   | `_liveValue`, `_assetLegs` | The attested amount; one `Collateral` credit leg per asset. |

2. **What the proof binds, stated as 0022 requires.** The proof binds the decoded amounts to the bytes Derive
   posted to Celestia for the newest batch. It does **not** bind them to `stateRoot()`: whether Derive's SP1 program
   proves that blob equals the state transition is not public. The owner wallet and subaccount id come from the
   same bytes. The asset table and decimals are adapter constants, not attested.

3. **Written at settlement, not per batch.** The settlement guard holds `SUBMITTER_ROLE` and, in one transaction,
   calls `submit(safe, proof)`, then `getAccountNav`, then `processRequests`. No keeper resubmits each batch.
   Between settlements the Derive leg reads 0 (stale epoch); `attestations(safe, asset)` still returns the last
   proven value, epoch and time for dashboards.

4. **Freshness by touching the account.** A record is readable only while it is in the newest batch. Before
   settling, a keeper moves a dust amount between two subaccounts the fund owns (`private/transfer_spot`, session
   key with scope 12 only, which Derive limits to same-owner subaccounts). No Ethereum transaction is needed.

## Alternatives considered

- **Derive-signed wallet value.** Needs Derive to build and operate a signer; the trust moves to its keys.
  Kept as a fallback.
- **Proof on every read** (`getAccountNavWithProofs`). Every consumer must build proofs, the NAV Calculator needs
  an upgrade, and NAV fails when proof sources are down. The family's `previewPositions(account, data)` already
  serves live UI checks without it.
- **Time-to-live liveness alone.** A trade inside the window spends collateral while NAV still shows it:
  over-report. The epoch stays the primary rule; the 30-minute cap only adds a bound for when Derive stops posting
  batches while its sequencer keeps trading, which the epoch alone cannot see.
- **Per-batch keeper or absence proofs.** Absence proofs average 2.8 shares per newer batch, and cannot use
  neighbours when the fund's id is the highest in the section (38 of 84 batches checked).

## Consequences

- No NAV Calculator change; the member follows the Merkl pattern.
- The fund's Derive account must hold collateral only at settlement: settle after expiry.
- **Trust that remains:** Derive's sequencer authors the blob; VAPP's owner (Safe `0x62c0…90F7`, a 4 h timelock
  or a 6-of-8 Safe) can call `setRoot`, `setVKey`, `setVerifier` without a proof. The vkey has rotated three
  times (blocks 26,101,785 and 26,110,967 directly, 26,364,645 through the timelock, installing `0x00bc954f…`).
  The pins turn a later rotation into a refusal to read, not a wrong read. Rotation procedure: review the new
  program with Derive, deploy a new member with the new pair, swap it on `NAVCalculator`; the Derive leg reads
  0 in between.
- **The format is reverse-engineered.** A format change makes proofs fail to decode: under-report, fail loud.
- **Share positions are proven; framing is a consistency check.** Celestia's commitment fixes a share's index only
  under the true tree shape, so the member reads the share count from share 0 and checks each share at its stated
  index: the decoded bytes are exactly the posted ones, in order. Where the record starts within them comes from
  the prover; the member requires the next record's head after it, or the previous record ending at it. Framing
  by the previous record needs that record's shares, and it may belong to anyone; the fund holds two adjacent
  subaccount ids and touches both, so each frames the other.
- Clears stay permissionless and stale-gated (0022): anyone can zero the leg after a batch. Under-report only.
- Ethereum only, where VAPP is. A fund whose shares live on another chain needs a relay or offchain aggregation.
- Assets need an Ethereum price feed, unless the fund is denominated in the same asset.
- Celestia retention is unknown; the keeper archives the blobs it proves against.

## Implementation

`src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol` with
`derive/CelestiaShareProof.sol` and `derive/DeriveRecord.sol`. Proof builder: `script/test/derive-celestia-proof.py`
(about 1 s for the newest batch: one Ethereum call, one Celestia block). Caps: 8 subaccounts per submit, 32 shares
per subaccount, 8 tokens per account. Tests: the family conformance kit (`DeriveConformance.t.sol`), unit tests
on synthetic blobs and two real batches, and a fork test against the real VAPP at a pinned block.

## Before acceptance

1. One real `transfer_spot` confirms that it re-emits both records; record Derive's fee and minimum.
2. Roles change to let the fund Safe register a scope-12 session key (refused today, checked by simulation).
3. Ask Derive whether the SP1 program binds the blob to the state transition, and to route owner functions
   through the timelock. Also ask for a share-proof endpoint for the newest batch: it adds no trust (the
   adapter checks every proof against Ethereum) and removes the dependency on public Celestia nodes.
4. Audit pass, deployment config and the settlement-guard integration.
