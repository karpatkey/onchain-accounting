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
   | `_verifyPayload(epoch, account, data)` | Refuse if VAPP's newest batch is more than 30 minutes old. Verify the blob's share 0 at index 0 and read the share count from it. For each subaccount in `data`: verify its shares against `epoch` at their stated blob indices (the subtree layout comes from the share count, never from the submitter), require consecutive indices, decode the record; require `owner == account`, zero perps, every collateral balance ≥ 0; require `programVKey()` and `verifier()` equal the immutable values passed to the constructor (the reviewed pair at deployment). Have the option pricer value every option of the submit from the signed feeds in `data` (decision 5) and require each subaccount's own cash to cover its own shorts; sum per token, map each Derive asset id to its Ethereum token through an immutable table, scale 12 decimals to the token's, and return every covered token, zero included. |
   | `_isLive` | Live iff the stored epoch equals the live commitment, the batch is at most 30 minutes old by VAPP's proven `lastOpTimestamp` (the batch's `maxOpTimestamp`, an SP1 public input; the same bound refuses submits), and the program pins still hold. Measuring from the batch, not from the write, means a late first submit or a replay cannot make a stalled batch count again. |
   | `_liveValue`, `_assetLegs` | The attested amount; one `Collateral` credit leg per asset, net of options. |

2. **What the proof binds, stated as 0022 requires.** The proof binds the decoded amounts to the bytes Derive
   posted to Celestia for the newest batch. It does **not** bind them to `stateRoot()`: whether Derive's SP1 program
   proves that blob equals the state transition is not public. The owner wallet and subaccount id come from the
   same bytes. The asset table, the option-market table, the feed signer set and decimals are constants, not
   attested. Option values come from Derive's signed oracle feeds, not from the proof (decision 5).

3. **Written at settlement, not per batch.** The settlement guard holds `SUBMITTER_ROLE` and, in one transaction,
   calls `submit(safe, proof)`, then `getAccountNav`, then `processRequests`. No keeper resubmits each batch.
   Between settlements the Derive leg reads 0 (stale epoch); `attestations(safe, asset)` still returns the last
   proven value, epoch and time for dashboards.

4. **Freshness by touching the account.** A record is readable only while it is in the newest batch. Before
   settling, a keeper moves a dust amount between two subaccounts the fund owns (`private/transfer_spot`, session
   key with scope 12 only, which Derive limits to same-owner subaccounts). No Ethereum transaction is needed.

5. **Options at Derive's mark, from Derive's signed feeds; perps refused.** The record lists each option as
   (option asset, series, amount); the series packs expiry, strike (8-decimal USD) and a call flag. Derive's
   option asset ids come from `public/get_instrument` (`base_asset_address`: `0xd071…3623` BTC, `0x4bb4…1eb4` ETH,
   `0x7344…64d9` HYPE; quote USDC). Options are cash-settled in Derive's USDC cash asset, taken at $1, so every
   option is credited (long, rounded down) or debited (short, rounded up) to the cash token.
   - **Each subaccount on its own.** A subaccount's short options must be covered by its own cash plus its own
     long options; shorts are never netted against another subaccount. The contract cannot prove the submitter
     showed every subaccount of the wallet, so this keeps omission safe: every submitted subaccount is worth at
     least 0, and leaving one out can only lower the figure. This assumes Derive has no recourse from one
     subaccount to another (see Before acceptance).
   - **Zeros are written.** Every token the submitted records cover is attested, zero included, and the cash token
     whenever options were valued. Within one batch only option prices can move (new feeds), and a value that fell
     to zero must replace the earlier positive one instead of leaving it cached.
   - **Prices.** A submit carries Derive's signed spot, forward, rate and SVI vol items, as served by
     `public/get_latest_signed_feeds`. A separate immutable contract, `DeriveOptionPricer`, verifies them and prices
     the options; it is split out so the adapter stays under the EIP-170 size limit (adapter 21,569 bytes, pricer
     10,091). The signing scheme is not documented by Derive; it is Lyra v2's `BaseLyraFeed` scheme, recovered from
     live data: EIP-712 `FeedData(bytes data,uint256 deadline,uint64 timestamp)`, domain name
     `Lyra{Spot,Forward,Rate,Vol}Feed`, version "1", chain 957, verifying contract = that feed's Derive-chain
     address (12 addresses for ETH, BTC, HYPE, each checked against both signers). Every item must carry one
     signature from each of the pricer's fixed signers (today `0xe920…4f18`, `0xee68…e763`), be within its
     deadline, not be from the future, and be used; items that price a live option must be at most 5 minutes old.
   - **Live option:** Black-76 on Derive's SVI slice. SVI as Derive publishes it: k = ln(K / SVI_fwd), clamped to
     ±4·sqrt(a + b·σ); w = a + b·(ρ(k − m) + sqrt((k − m)² + σ²)), capped at 144; vol = sqrt(w / SVI_refTau). Black-76
     with F = spot + fwd_diff, the rate clamped at 0, τ in 365-day years, a total-vol cap of 24.
   - **Expired option:** intrinsic value at Derive's settlement price, (currentSpotAggregate −
     settlementStartAggregate) / 1800 from the forward item stamped at the expiry. Checked against Derive's
     published settlement of ETH-20261116: 1819.511710943306, all digits.
   - **How close to Derive's mark.** On subaccount 108093 (177 options), from a snapshot where the feeds were
     identical before and after `public/margin_watch`, the same formula in Python matched Derive's marks with a
     median gap of 0.00008%, worst 0.10%, $0.08 on $46,629. Not bit-exact: Derive's pricing code is not public. The
     onchain library matches 50-digit references (N(x) to 1e-12, Black-76 to 1e-12 relative) and the Python
     reference to the micro-USDC on two real subaccounts.
   - **Licensing.** Lyra's open-source `SVI.sol` and `Black76.sol` are GPL-3.0/AGPL; nothing was copied. The math
     (`derive/DeriveOptionMath.sol`) is written from the published formulas.
   - Perps are refused: the record's per-perp fields beyond the amount are not decoded.

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
- The fund's Derive account may hold options; perps must be closed at settlement. The leg is the options' fair
  value by Derive's model, before closing costs (taker fees, about 0.7% of the option value on 108093, and the
  bid/ask spread). A fund that wants those reflected applies a haircut at fund level.
- **More trust:** the option value rests on Derive's two feed signers, the same keys Derive's margin engine uses.
  They are not on Ethereum; rotating them means deploying a new pricer and adapter. A submit with options needs
  feeds fetched within 5 minutes.
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
- Collateral assets need an Ethereum price feed, unless the fund is denominated in the same asset. Options need none:
  they are valued in USDC by the pricer.
- Celestia retention is unknown; the keeper archives the blobs it proves against.

## Implementation

`src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol` with `derive/CelestiaShareProof.sol`,
`derive/DeriveRecord.sol`, `derive/DeriveOptionPricer.sol` (+ `IDeriveOptionPricer.sol`) and
`derive/DeriveOptionMath.sol`. Payload: `abi.encode(ShareProof, SubaccountProof[], bytes feeds)` with
`feeds = abi.encode(IDeriveOptionPricer.Feeds)` (a nested `bytes`: decoding the feeds in the same tuple overflows the
stack under via-IR). Proof builder: `script/test/derive-celestia-proof.py` (about 1 s for the newest batch: one
Ethereum call, one Celestia block). Caps: 8 subaccounts per submit, 32 shares per subaccount (about 330 options), 8
tokens per account, 8 option markets, 32 feed items of each kind. Gas: a submit for subaccount 117522 (8 options, 4
expiries, 2 markets) costs about 1.02M. Tests: the family conformance kit (`DeriveConformance.t.sol`), unit tests on
synthetic blobs and signed feeds, real batches (including two option books priced from Derive's real signed feeds
and an expired ETH series at Derive's published settlement), math vectors (`derive/DeriveOptionMath.t.sol`), and a
fork test against the real VAPP at a pinned block.

## Before acceptance

1. One real `transfer_spot` confirms that it re-emits both records; record Derive's fee and minimum.
2. Roles change to let the fund Safe register a scope-12 session key (refused today, checked by simulation).
3. Ask Derive whether the SP1 program binds the blob to the state transition, and to route owner functions
   through the timelock. Also ask for a share-proof endpoint for the newest batch: it adds no trust (the
   adapter checks every proof against Ethereum) and removes the dependency on public Celestia nodes.
4. Ask Derive to confirm in writing that a subaccount's losses never reach another subaccount of the same owner
   (the per-subaccount coverage rule rests on it). If recourse exists, the adapter must require the full set of
   the fund's subaccounts in every submit, which needs an onchain list of them.
5. Audit pass, deployment config and the settlement-guard integration.
