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
   | `_verifyPayload(epoch, account, data)` | Refuse if VAPP's newest batch is more than 30 minutes old. Verify the blob's share 0 at index 0 and read the share count from it. For each subaccount in `data`: verify its shares against `epoch` at their stated blob indices (the subtree layout comes from the share count, never from the submitter), require consecutive indices, decode the record; require `owner == account`, zero perps; require `programVKey()` and `verifier()` equal the immutable values passed to the constructor (the reviewed pair at deployment). Have the pricer value every option and the spot of every non-cash collateral asset of the subaccounts that hold options or debt from the signed feeds in `data` (decision 5), require each such subaccount's own equity to be at least 0, and book its credit-only legs; sum per token, map each Derive asset id to its Ethereum token through an immutable table, scale 12 decimals to the token's, and return every covered token, zero included. |
   | `_isLive` | Live iff the stored epoch equals the live commitment, the batch is at most 30 minutes old by VAPP's proven `lastOpTimestamp` (the batch's `maxOpTimestamp`, an SP1 public input; the same bound refuses submits), and the program pins still hold. Measuring from the batch, not from the write, means a late first submit or a replay cannot make a stalled batch count again. |
   | `_liveValue`, `_assetLegs` | The attested amount; one `Collateral` credit leg per asset, net of options and debt. |

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

5. **Options and USDC debt at Derive's mark and spot, from Derive's signed feeds; perps refused.** The record lists
   each option as (option asset, series, amount); the series packs expiry, strike (8-decimal USD) and a call flag.
   Derive's option asset ids come from `public/get_instrument` (`base_asset_address`: `0xd071…3623` BTC, `0x4bb4…1eb4`
   ETH, `0x7344…64d9` HYPE; quote USDC). Options are cash-settled in Derive's USDC cash asset, taken at $1, so
   every option is worth its value in cash: long rounded down, short rounded up.
   - **Equity per subaccount.** On Derive, buying an option without enough USDC borrows the USDC, so the balance
     goes negative (subaccount 122119: 0.12 HYPE, −3.89049674163 USDC, 10 × HYPE-20261127-75-C), and a covered call
     is collateralised by the underlying, not by cash. A subaccount that holds options or a negative balance is
     therefore valued as equity in USD, 12 decimals: cash at 1; every other collateral asset at Derive's signed
     spot (a positive balance rounded down, a debt rounded up); options as above. **The equity must be at least 0
     on its own.** Equity is never netted across subaccounts. The contract cannot prove the submitter showed every
     subaccount of the wallet, so this keeps omission safe: every submitted subaccount is worth at least 0, and
     leaving one out can only lower the figure. This assumes Derive has no recourse from one subaccount to another
     (see Before acceptance). A subaccount with only non-negative collateral and no options needs no price and is
     booked as is.
   - **Credit-only legs, in the fund's units.** The family refuses debt legs (0022, `DebtLegRejected`), so debt is
     netted before it reaches the book, per subaccount, and the legs are worth at most the equity at the signed
     spot: (1) every non-cash asset with a positive balance stays in its own units (a HYPE-denominated fund needs
     HYPE legs to stay in HYPE units); (2) cash, options and every debt, a non-cash debt at spot rounded up, net
     into the cash token; (3) if that net is negative, the subaccount's non-cash legs shrink by the shortfall, in
     record order, each by the units worth it at spot, rounded up (against the fund). A subaccount's shortfall is
     taken from its own non-cash legs, never covered by another subaccount's cash. Example (subaccount 122119): net
     cash = −3.89 + 10 × 0.2139 = −1.75 USD, so the 0.12 HYPE leg becomes 0.12 − 1.75 / 62.37 = 0.0919 HYPE and the
     cash leg 0. The NAV Calculator prices each leg at its own feed, so the USD total differs from the equity by that
     feed's spread to Derive's spot.
   - **Zeros are written.** Every token the submitted records cover is attested, zero included, and the cash token
     whenever a subaccount was priced. Within one batch only prices can move (new feeds), and a value that fell to
     zero must replace the earlier positive one instead of leaving it cached.
   - **Prices.** A submit carries Derive's signed spot, forward, rate and SVI vol items, as served by
     `public/get_latest_signed_feeds`. A separate immutable contract, `DeriveOptionPricer`, verifies them, prices the
     options and returns the signed spot of each non-cash collateral asset the adapter asks for (a constructor
     table `CollateralSpot[]` maps a Derive collateral asset id to the option market whose spot feed prices it:
     Derive marks HYPE collateral and HYPE options at one HYPE spot). A pure USDC borrow against HYPE needs the
     spot item alone. It is split out so the adapter stays under the EIP-170 size limit. The signing scheme is not
     documented by Derive; it is Lyra v2's `BaseLyraFeed` scheme, recovered from live data: EIP-712
     `FeedData(bytes data,uint256 deadline,uint64 timestamp)`, domain name `Lyra{Spot,Forward,Rate,Vol}Feed`,
     version "1", chain 957, verifying contract = that feed's Derive-chain address (12 addresses for ETH, BTC, HYPE,
     each checked against both signers). Every item must carry one signature from each of the pricer's fixed signers
     (today `0xe920…4f18`, `0xee68…e763`), be within its deadline, not be from the future, and be used; items that
     price a live option or a collateral asset must be at most 5 minutes old. Without a pricer the adapter keeps the
     earlier behaviour: a negative balance ({NegativeBalance}) or an option is refused.
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
   - **A real borrow, checked against Derive.** Subaccount 122119 (0.12 HYPE, −3.89049674163 USDC, 10 ×
     HYPE-20261127-75-C) read through the adapter from its record in the batch at Ethereum block 26,456,460
     (2026-11-20 12:59 UTC) and Derive's signed feeds of 2026-11-22 20:03 UTC: the legs are 0.091641218458 HYPE and
     0 USDC, worth 5.714964376689 USD at the signed HYPE spot (62.36237877291293). `public/margin_watch` read
     5.715103424349 in the same minute: the gap is −0.0024%, inside the 0.1% the test allows. The account had not
     changed between the batch and the capture (`margin_watch` balances equal the record's). Fixture:
     `test/integration/derive-celestia/hype_split_122119_cdp.json`.
   - **Licensing.** Lyra's open-source `SVI.sol` and `Black76.sol` are GPL-3.0/AGPL; nothing was copied. The math
     (`derive/DeriveOptionMath.sol`) is written from the published formulas.
   - Perps are refused: the record's per-perp fields beyond the amount are not decoded.

6. **In-flight value: skip the settlement window, do not value it.** Value between the fund Safe and Derive is in
   neither leg: a deposit queued in the `OnchainActionManager` (`0xE366…AD3`) until a batch applies it; a withdrawal
   the `WithdrawalOutbox` (`0x7c74…FA63`) rate-limits into its queue, paid later by permissionless `processQueue`;
   a withdrawal deferred after a failed transfer, paid by the owner's `deferredProcess`. A normal withdrawal is paid
   inside `submitBatch` itself. A withdrawal's debit is in a committed batch before any payout, and a new batch
   zeroes older entries, so in-flight value is only ever missing, never counted twice; and it matters only at
   settlement (decision 3).
   - **Check.** The settlement guard runs `script/test/derive-celestia-proof.py --preflight SAFE` immediately before
     it signs and settles only on exit 0 (1: something in flight, 2: a read failed). At one block, Ethereum only:
     no deposit, deposit-to-new-subaccount or withdrawal request from the Safe with an action id at or above
     `VAPP.consumedPublicAccIndex()`; no unpaid queued withdrawal, each read in the bucket it was enqueued in (a later
     `setBucketLimit` moves the Safe's bucket, not its old entries); no deferred one with
     `deferredWithdrawals(id) != 0`. The log scans start at deployment and need an archive RPC (about 2 s on Alchemy).
   - **Observed.** From the outbox's deployment to block 26,507,752 (2026-11-27): 187 of about 6,081 payouts were
     queued, all in the shared global bucket, each paid in full within 1,882 blocks (median 225, about 45 minutes);
     5 were deferred, all since paid. The check, run for one of those recipients (`0x1e1f…124b`) at its enqueue
     block 26,354,952, exits 1 on its 682,753.36 USDC queue entry, and 0 today.

7. **Shares on HyperEVM: the operator combines both chains at pinned blocks; the bridge legs join the check.** The
   fund subscribes and redeems on HyperEVM and reaches Derive from Ethereum, the same Safe address on both
   (`0x8c79…7476`). HYPE crosses over LayerZero V2: the HyperEVM native OFT adapter `0x1e04…9670` (eid 30367) locks
   native HYPE, the Ethereum HYPE OFT `0x0762…13e2` (eid 30101) mints and burns; `OFTSent` and `OFTReceived` share a
   guid. NAV is not computed on HyperEVM from this member (it reads VAPP on Ethereum): the operator adds the HyperEVM
   holdings (native HYPE + WHYPE), the Ethereum HYPE and this member's legs, each chain read at its own pinned block.
   - **Counting rule.** A transfer is counted on its source iff sent after the source pin, and on its destination iff
     received at or before the destination pin. Exactly once is right; both is a double count, which non-simultaneous
     reads make possible and which is the one way this setup can over-report; neither is in flight. `--preflight
     SAFE --hyperevm-rpc URL --since-eth N --since-hyperevm M` classifies every transfer of the Safe since the
     previous settlement's pins and fails on anything not counted exactly once. A send whose receipt went to another
     address is a payout: counted at the source until sent.
   - **Checked on the real path.** hype-split's 0.12 HYPE (sent at HyperEVM 51,693,622, received at Ethereum
     26,450,116, deposited as action 8651 at 26,450,176, applied at 26,450,225), replayed at pinned blocks: settle
     before the send, skip mid-bridge, settle on arrival, skip while the deposit is queued, settle once applied, and
     skip (double count) with the HyperEVM pin before the send and the Ethereum pin after the arrival.
   - **Rejected for now:** relaying the attested value to HyperEVM over LayerZero (adds trust in its verifiers and a
     contract on each side) and proving Ethereum state there (no Ethereum light client on HyperEVM is known to us).

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
- **Value queued withdrawals with an outbox adapter** (`derive-spike` spec §3), so a settlement can go ahead while
  one waits. The queue is shared (the global `(0,0)` bucket): an unbounded walk lets any Derive user push it past the
  gas stipend, and `AdapterGasExhausted` then reverts every `getAccountNav`; a bounded walk returns a partial sum
  that the NAV Calculator accepts silently (it reads any other adapter revert as "nothing to report"). Entries also
  stay in the bucket chosen when they were enqueued. A per-fund bucket from Derive removes most of the delay instead.

## Consequences

- No NAV Calculator change; the member follows the Merkl pattern.
- The fund's Derive account may hold options, a USDC borrow against its collateral, and calls or puts covered by
  non-cash collateral; perps must be closed at settlement. The legs are the account's equity by Derive's model,
  before closing costs (taker fees, about 0.7% of the option value on 108093, and the bid/ask spread). A fund that
  wants those reflected applies a haircut at fund level.
- **Debt shrinks the non-cash legs.** A subaccount that owes more cash than its options and cash cover has the rest
  taken from its own non-cash legs (decision 5), so its HYPE leg reads less than the HYPE it holds. That is the
  right quantity for a HYPE-denominated NAV: the debt is carried in HYPE.
- **Residuals of the equity rule.** (a) Cash is taken at $1, as Derive's `margin_watch` does, while the NAV
  Calculator prices the USDC leg at its own feed: a USDC depeg moves the two apart. (b) The record's USDC balance
  excludes interest accrued since the subaccount last changed (`margin_watch` `pending_interest`, −0.0013 USD on
  122119 after two days), so a debt is understated by its accrued interest until the next posting; `margin_watch`'s
  `subaccount_value` excludes it too. (c) The submitter may pick any signed spot item from the last 5 minutes, as
  with the option feeds: the figure moves by the collateral's 5-minute price move on the covered part only.
  (d) Equity at least 0 is not Derive's margin rule: a subaccount can be liquidatable and still read its equity.
- **More trust:** the option values and the collateral spot rest on Derive's two feed signers, the same keys Derive's
  margin engine uses. They are not on Ethereum; rotating them means deploying a new pricer and adapter. A submit with
  options, debt or covered collateral needs feeds fetched within 5 minutes.
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
- Ethereum only, where VAPP is. A fund whose shares live on another chain combines the chains offchain (decision 7);
  the Derive leg itself is still read on Ethereum.
- Collateral assets need an Ethereum price feed, unless the fund is denominated in the same asset. Options need none:
  they are valued in USDC by the pricer. The pricer's `CollateralSpot[]` table (append-only at deployment) names the
  collateral assets it can price at Derive's spot; a debt or an option in an asset outside it is refused
  (`UnmappedSpotAsset`).
- Celestia retention is unknown; the keeper archives the blobs it proves against.
- **A settlement can wait for in-flight value** (decision 6): while the fund's own deposit is unapplied or its
  withdrawal is queued or deferred, no NAV is struck; the longest queue wait so far was about 6.3 hours. The check
  runs before the settlement transaction, not inside it, so the guard runs it immediately before signing. A
  deposit's `fallbackRecipient` receives the funds if Derive cannot apply it, and the check clears once the action
  is consumed: the fund names its own wallet as fallback.

## Implementation

`src/balances/AttestedBalanceAdapters/DeriveCelestiaAttestedBalanceAdapter.sol` with `derive/CelestiaShareProof.sol`,
`derive/DeriveRecord.sol`, `derive/DeriveOptionPricer.sol` (+ `IDeriveOptionPricer.sol`) and
`derive/DeriveOptionMath.sol`. The pricer's constructor is `(OptionMarket[] markets, address[] signers, CollateralSpot[]
collateralSpots)`; `values(feeds, options, spotAssets)` returns the option values and the verified spots. Payload: `abi.encode(ShareProof, SubaccountProof[], bytes feeds)` with
`feeds = abi.encode(IDeriveOptionPricer.Feeds)` (a nested `bytes`: decoding the feeds in the same tuple overflows the
stack under via-IR). Proof builder: `script/test/derive-celestia-proof.py` (about 1 s for the newest batch: one
Ethereum call, one Celestia block, and one signed-feeds call per priced currency). For records valued as equity (options
or a negative balance) it also writes the signed feed items they need, collateral spots included, and an `expected`
amount that mirrors the adapter's equity booking with a float reference of the pricer. Caps: 8
subaccounts per submit, 32 shares per subaccount (about 330 options), 8 tokens per account, 8 option markets, 32
feed items of each kind. Gas: a submit for subaccount 117522 (8 options, 4 expiries, 2 markets) costs about 1.02M.
Tests: the family conformance kit (`DeriveConformance.t.sol`), unit tests on synthetic blobs and signed feeds (long
and short options on credit, covered calls and puts, a pure USDC borrow, deficits, rounding), real batches (including
two option books priced from Derive's real signed feeds, an expired ETH series at Derive's published settlement,
subaccount 122119 with its USDC borrow against `margin_watch`, and a fixture the proof builder wrote unedited, matched
to its reference), math vectors (`derive/DeriveOptionMath.t.sol`), the proof builder's own suite
(`script/test/test_derive_celestia_proof.py`: decoder, feed selection, its reference on the same real books, and the
in-flight preflight against a stubbed chain), and a fork test against the real VAPP at a pinned block. In-flight
preflight: `--preflight SAFE` in the same script (decision 6). Plan: `docs/plans/2026-11-27-derive-in-flight-value.md`.

## Before acceptance

1. One real `transfer_spot` confirms that it re-emits both records; record Derive's fee and minimum.
2. Roles change to let the fund Safe register a scope-12 session key (refused today, checked by simulation).
3. Ask Derive whether the SP1 program binds the blob to the state transition, and to route owner functions
   through the timelock. Also ask for a share-proof endpoint for the newest batch: it adds no trust (the
   adapter checks every proof against Ethereum) and removes the dependency on public Celestia nodes.
4. Ask Derive to confirm in writing that a subaccount's losses never reach another subaccount of the same owner
   (the per-subaccount equity rule rests on it), and that `margin_watch` `subaccount_value` (cash at 1, collateral at
   the spot index, options at the mark) is the account's equity, with borrow interest accruing outside the record.
   If recourse exists, the adapter must require the full set of the fund's subaccounts in every submit, which needs
   an onchain list of them.
5. Audit pass, deployment config and the settlement-guard integration.
6. One deposit and one withdrawal of the fund's dust: record the queue-to-batch time, confirm the payout in a
   `submitBatch` transaction, and see the preflight exit 1 while each is pending, then 0. Ask Derive for a per-fund
   withdrawal bucket (`setBucketLimit`) sized to the fund's flows.
