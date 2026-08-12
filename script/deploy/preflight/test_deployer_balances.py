#!/usr/bin/env python3
"""Verdict truth table for deployer_balances.py. Run with `python3 -m unittest`.

The TESTS use only the standard library, but the module under test does not: importing
`deployer_balances` imports `chainlib`, which imports third-party `requests` (chainlib.py:21). So this
suite needs `requests` installed even though it never makes a network call, and the CI job installs it
explicitly. An earlier version of this docstring said "stdlib only", which was false and left the CI
job passing only because the runner image happens to ship `requests` — green for a reason nobody had
established.

WHY THIS EXISTS. Until this file landed, this deploy gate had NO automated coverage: CI ran forge, lint
and the lockfile check, and nothing that executed any Python here. (That is now historical — the
`preflight` job in .github/workflows/foundry.yml runs this suite. What remains uncovered is every live
value: RPC readings, oracle prices and the 16 measured baselines are all faked here, so this suite
cannot detect a stale baseline or a chain that changed its fee mode.) Every guard was verified once, by
hand, against live RPC, and three of them were then re-broken by later edits: the regime probe was
gated on a collection it did not need, which let a chain skip the probe entirely; widening that
predicate routed a config error into the transient-error handler; and both probes were briefly
allowed to land on different blocks. Each of those is a fail-open that a table like this one catches
for free.

EXPECTATIONS COME FROM THE RUNBOOK'S INVARIANTS, NOT FROM THIS MODULE'S CODE. Reading the expected
verdict off the implementation would make the suite agree with whatever the code does, including its
bugs. The invariants asserted here, in the project's own terms:

  I1  FAIL CLOSED. Anything the gate cannot verify is not a pass. A checker that returns success
      without having checked is the defect the UNPRICEABLE third state exists to prevent.
  I2  A LOWER BOUND IS NEVER PRESENTED AS AN ESTIMATE. `need` omits the L1 data-availability fee on
      any chain that charges one, so a shortfall for such a chain must be labelled, not printed bare.
  I3  A CONFIG ERROR MUST NOT READ AS TRANSIENT. Telling an operator to retry a bad edit forever is
      its own failure; the two must be distinguishable in the note.
  I4  GUARDS ARE STRUCTURAL, NOT DOCUMENTARY, and survive `python -O` (so `raise`, never `assert`).

A cell where this file and the runbook disagree is a FINDING, not a broken test.
"""
import io
import sys
import unittest
import unittest.mock as mock
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import chainlib as c  # noqa: E402
import deployer_balances as db  # noqa: E402

# Representatives, chosen so each sits in exactly one bucket of the membership axis.
PRICED = 8453          # in L1_FEE_OMITTED_PRICED — charges an L1 fee, allowed to price
ZERO_FEE = 42220       # in L1_FEE_OMITTED_PRICED with baselines of 0 (charges nothing)
UNMODELLED = 534352    # in L1_FEE_UNMODELLED — must fail closed unconditionally
NEITHER = 1            # in neither set
OVERRIDDEN = 100       # in GAS_PRICE_OVERRIDE_WEI — priced from the pin, not the node

GOOD_PRICE = 1_000_000_000
GAS = 1_000_000


def _n_of(data: str) -> int:
    """Recover the payload length from an encoded getL1Fee call, so a fake can answer per size.

    Parsed in named steps rather than by a counted offset. The first version of this used a hardcoded
    slice and was silently 2 characters out, because OP_GET_L1_FEE carries the `0x` prefix — so it
    decoded a misaligned word, never matched the BIG size, and answered every probe with the SMALL
    value. Two trip tests then failed for a reason that had nothing to do with the code under test.
    """
    h = data[2:] if data.startswith("0x") else data
    words = h[8:]                       # drop the 4-byte selector
    return int(words[64:128], 16)       # word 0 is the bytes offset; word 1 is the length


def _payload_of(data: str) -> bytes:
    """The actual bytes the probe put on the wire, so a test can assert their character."""
    h = data[2:] if data.startswith("0x") else data
    words = h[8:]
    n = int(words[64:128], 16)
    return bytes.fromhex(words[128:128 + 2 * n])


class Fake:
    """Minimal RPC stand-in. Records calls so ordering claims can be asserted, not assumed."""

    def __init__(self, balance, quoted=GOOD_PRICE, big=None, small=None,
                 eth_call_raises=None, block="0x2f8b950", raw_eth_call=None):
        self.balance, self.quoted, self.block = balance, quoted, block
        self.big, self.small, self.eth_call_raises = big, small, eth_call_raises
        # Returned VERBATIM from eth_call when set, so a test can exercise the returndata itself
        # ("0x" vs garbage) rather than only the exception paths. The distinction is load-bearing:
        # `0x` is evidence of an absent predeploy, garbage is a node answering badly.
        self.raw_eth_call = raw_eth_call
        self.calls = []
        self.payloads = []

    def rpc(self, url, method, params, *a, **k):
        self.calls.append((method, params))
        if method == "eth_getBalance":
            return hex(self.balance)
        if method == "eth_gasPrice":
            return hex(self.quoted)
        if method == "eth_blockNumber":
            return self.block
        if method == "eth_call":
            if self.eth_call_raises:
                raise self.eth_call_raises
            if self.raw_eth_call is not None:
                return self.raw_eth_call
            self.payloads.append(_payload_of(params[0]["data"]))
            n = _n_of(params[0]["data"])
            v = self.big if n == db.L1_REGIME_PROBE_BYTES_BIG else self.small
            return hex(v if v is not None else 0)
        raise AssertionError(f"unexpected RPC method {method}")

    @property
    def probe_blocks(self):
        return [p[1] for m, p in self.calls if m == "eth_call"]


def run_one(cid, *, balance, quoted=GOOD_PRICE, gas=GAS, big=None, small=None,
            eth_call_raises=None, drop_baseline=False, raw_eth_call=None):
    """Drive db.one() against a fake chain. Returns (row, fake)."""
    base_big = db.L1_REGIME_BASELINE_WEI.get(cid, 0)
    base_small = db.L1_REGIME_BASELINE_SMALL_WEI.get(cid, 0)
    fake = Fake(balance, quoted,
                big=base_big if big is None else big,
                small=base_small if small is None else small,
                eth_call_raises=eth_call_raises, raw_eth_call=raw_eth_call)
    patched_big = {k: v for k, v in db.L1_REGIME_BASELINE_WEI.items() if not (drop_baseline and k == cid)}
    with mock.patch.object(db, "scope", lambda _cid: {
            "metaAdapters": 0, "plainAdapters": 0, "assistants": 0,
            "feeds": 0, "assets": 0, "metaInstances": 0}), \
            mock.patch.object(db, "L1_REGIME_BASELINE_WEI", patched_big), \
            mock.patch.object(c, "chain_config", lambda _cid: {
                "name": f"chain{_cid}", "nativeTokenSymbol": "TOK",
                "addresses": {"admin": "0x" + "11" * 20}}), \
            mock.patch.object(c, "probe_rpc", lambda _cid: ("http://fake", "fake", [])), \
            mock.patch.object(c, "rpc", fake.rpc):
        row = db.one(cid, {str(cid): {"total": gas}})
    return row, fake


def need_for(price=GOOD_PRICE, gas=GAS):
    return gas * price * db.FEE_VOLATILITY_HEADROOM


class TestFailClosed(unittest.TestCase):
    """I1 — anything unverifiable is not a pass. `sufficient is None` is the only correct verdict."""

    def test_implausible_node_quote_is_not_a_pass(self):
        # A quote below the floor makes `need` collapse toward 0, so `bal >= need` becomes a tautology.
        row, _ = run_one(NEITHER, balance=10**21, quoted=db.GAS_PRICE_IMPLAUSIBLE_WEI - 1)
        self.assertIsNone(row["sufficient"])
        self.assertFalse(row["priceable"])

    def test_quote_exactly_at_floor_is_priceable(self):
        # Boundary: the floor is inclusive. Stated so a later edit cannot quietly flip the comparison.
        row, _ = run_one(NEITHER, balance=10**24, quoted=db.GAS_PRICE_IMPLAUSIBLE_WEI)
        self.assertIsNotNone(row["sufficient"])

    def test_unmodelled_chain_never_passes_however_rich(self):
        row, _ = run_one(UNMODELLED, balance=10**24)
        self.assertIsNone(row["sufficient"], "an execution-only figure is a lower bound, not an estimate")
        self.assertIn("LOWER BOUND", row["l1Note"].upper())

    def test_probe_trip_on_big_payload_fails_closed(self):
        base = db.L1_REGIME_BASELINE_WEI[PRICED]
        row, _ = run_one(PRICED, balance=10**24, big=base * (db.L1_REGIME_MAX_RISE + 1))
        self.assertIsNone(row["sufficient"])
        self.assertIn("big-payload", row["l1Note"])

    def test_probe_trip_on_small_payload_fails_closed(self):
        # BIG passes, SMALL trips: the second probe must be reached, not short-circuited by the first.
        base = db.L1_REGIME_BASELINE_SMALL_WEI[PRICED]
        row, _ = run_one(PRICED, balance=10**24, small=base * (db.L1_REGIME_MAX_RISE + 1))
        self.assertIsNone(row["sufficient"])
        self.assertIn("small-payload", row["l1Note"])
        # The label must not assert a CAUSE. This scenario is big-passes/small-trips, i.e. the two
        # readings moved apart — a curve move — so the old "base-fee" label named the opposite cause.
        self.assertNotIn("base-fee", row["l1Note"])

    def test_zero_baseline_chain_trips_on_any_nonzero_reading(self):
        # celo charges nothing today; a baseline of 0 must mean "any charge at all is a regime change",
        # not "0 * limit == 0, so nothing can ever trip".
        row, _ = run_one(ZERO_FEE, balance=10**24, big=1)
        self.assertIsNone(row["sufficient"])

    def test_rpc_failure_during_probe_fails_closed_and_invites_retry(self):
        row, _ = run_one(PRICED, balance=10**24, eth_call_raises=RuntimeError("boom"))
        self.assertIsNone(row["sufficient"], "an unverifiable regime is not a pass")
        self.assertIn("retry", row["l1Note"].lower())

    def test_headroom_below_floor_fails_closed_even_when_funded(self):
        need = need_for()
        row, _ = run_one(PRICED, balance=need + db.L1_OMITTED_MIN_HEADROOM_WEI - 1)
        self.assertIsNone(row["sufficient"])
        self.assertIn("headroom", row["l1Note"].lower())

    def test_headroom_at_floor_passes(self):
        need = need_for()
        row, _ = run_one(PRICED, balance=need + db.L1_OMITTED_MIN_HEADROOM_WEI)
        self.assertIs(row["sufficient"], True)
        self.assertIsNone(row["l1Note"])

    def test_top_up_is_unreachable_for_l1_charging_chains(self):
        # Documented consequence of the headroom guard: bal < need implies negative headroom, which is
        # under the floor, so these rows go UNPRICEABLE before any TOP UP verdict can be printed. This
        # is asserted because "unreachable" is load-bearing for the shortfall fix, not because it is
        # the desired end state — #287 owns pricing the term properly.
        row, _ = run_one(PRICED, balance=need_for() - 1)
        self.assertIsNone(row["sufficient"])

    def test_ordinary_chain_short_is_a_top_up_not_unpriceable(self):
        row, _ = run_one(NEITHER, balance=need_for() - 1)
        self.assertIs(row["sufficient"], False)


class TestConfigErrorIsNotTransient(unittest.TestCase):
    """I3 — a hand-maintained collection divergence must not present as a retryable blip."""

    def test_missing_baseline_names_itself_a_config_error(self):
        row, _ = run_one(PRICED, balance=10**24, drop_baseline=True)
        self.assertIsNone(row["sufficient"])
        self.assertIn("CONFIG ERROR", row["l1Note"])
        self.assertIn("retrying will not help", row["l1Note"].lower())

    def test_missing_baseline_does_not_silently_skip_the_probe(self):
        # The original defect: the probe was gated on membership in the baseline dict, so a chain added
        # without one skipped this check entirely and passed on the balance guard alone.
        row, _ = run_one(PRICED, balance=10**24, drop_baseline=True)
        self.assertIsNotNone(row["l1Note"], "a missing baseline is an unverifiable regime, not a pass")


class TestProbeIsPinnedToOneBlock(unittest.TestCase):
    """Both readings must land on ONE block, or an upgrade between them yields a hybrid snapshot."""

    def test_both_probes_use_the_same_pinned_block(self):
        _, fake = run_one(PRICED, balance=10**24)
        self.assertEqual(len(fake.probe_blocks), 2, "both axes must actually be probed")
        self.assertEqual(len(set(fake.probe_blocks)), 1, "the two probes landed on different blocks")
        self.assertNotIn("latest", fake.probe_blocks, "'latest' is not a pinned block")


class TestProbePayloadIsIncompressible(unittest.TestCase):
    """Post-Fjord, getL1Fee prices the FASTLZ-COMPRESSED size, so a homogeneous payload measures almost
    nothing. The probe shipped `"ff" * n` for a while and understated real deploy calldata ~59x; the
    baselines below it were measured with those bytes. These tests exist because a mutation run proved the
    rest of this suite could not tell the two payloads apart — every RPC value is faked, so nothing else
    here notices the difference. zlib stands in for FastLZ: it is not the same estimator, but "a single
    repeated byte compresses to nothing" is true of both, which is all that has to be caught.
    """

    THRESHOLD = 0.9

    def _ratio(self, b: bytes) -> float:
        import zlib
        return len(zlib.compress(b, 6)) / len(b)

    def test_payload_is_incompressible(self):
        for n in (db.L1_REGIME_PROBE_BYTES_SMALL, db.L1_REGIME_PROBE_BYTES_BIG):
            with self.subTest(n=n):
                raw = bytes.fromhex(db._probe_payload(n))[:n]
                self.assertGreater(self._ratio(raw), self.THRESHOLD)

    def test_a_homogeneous_payload_would_fail_this_check(self):
        # Pins the threshold to something meaningful: the payload this replaced scores ~0.001.
        self.assertLess(self._ratio(b"\xff" * db.L1_REGIME_PROBE_BYTES_BIG), 0.01)

    def test_payload_is_deterministic_across_calls(self):
        # A baseline is only meaningful against the exact bytes it was measured with.
        n = db.L1_REGIME_PROBE_BYTES_SMALL
        self.assertEqual(db._probe_payload(n), db._probe_payload(n))

    def test_payload_length_and_abi_padding(self):
        for n in (db.L1_REGIME_PROBE_BYTES_SMALL, db.L1_REGIME_PROBE_BYTES_BIG):
            with self.subTest(n=n):
                h = db._probe_payload(n)
                self.assertEqual(len(h) % 64, 0, "not padded to a 32-byte boundary")
                self.assertEqual(len(h) // 2, n + (-n % 32))

    def test_bytes_actually_sent_on_the_wire_are_incompressible(self):
        # The one that catches a regression at the CALL SITE rather than in the helper: a future edit that
        # inlines a homogeneous payload again fails here even though every faked fee value is unchanged.
        _, fake = run_one(PRICED, balance=10**24)
        self.assertEqual(len(fake.payloads), 2)
        for p in fake.payloads:
            self.assertGreater(self._ratio(p), self.THRESHOLD)


class TestLowerBoundLabelling(unittest.TestCase):
    """I2 — a shortfall computed from an L1-omitting `need` must carry the flag and the warning."""

    def test_flag_set_for_both_l1_collections(self):
        for cid in (PRICED, UNMODELLED):
            with self.subTest(cid=cid):
                row, _ = run_one(cid, balance=10**24)
                self.assertTrue(row["shortfallExcludesL1"])

    def test_flag_clear_for_a_chain_in_neither_collection(self):
        # NOTE, and it is a real residual gap rather than a property worth celebrating: the flag is set
        # by MEMBERSHIP, not by whether the chain actually charges an L1 fee. A chain that charges one
        # and is in neither collection is short-reportable today with an understated figure and no
        # label. #287 owns closing that; this assertion pins current scope so the gap stays visible.
        row, _ = run_one(NEITHER, balance=10**24)
        self.assertFalse(row["shortfallExcludesL1"])

    def test_top_up_line_says_lower_bound_and_send_more(self):
        rows = [{"chainId": PRICED, "name": "base", "error": None, "sufficient": False,
                 "shortfallExcludesL1": True, "deployer": "0x" + "11" * 20, "priceSource": "node",
                 "l1Note": None, "balanceEth": 1.0, "needEth": 2.0, "shortfallEth": 1.0,
                 "gasPriceWei": GOOD_PRICE, "quotedGasPriceWei": GOOD_PRICE}]
        out, code = run_main(rows)
        self.assertEqual(code, 1)
        self.assertIn("LOWER BOUND", out)
        self.assertIn("SEND MORE", out)


def run_main(rows, chains=None):
    """Drive main()'s aggregation and exit code over canned rows."""
    ids = chains or [r["chainId"] for r in rows]
    by_id = {r["chainId"]: r for r in rows}
    buf = io.StringIO()
    with mock.patch.object(sys, "argv", ["deployer_balances.py"]), \
            mock.patch.object(c, "load_env", lambda *a, **k: None), \
            mock.patch.object(c, "resolve_chains", lambda _x: (ids, "test")), \
            mock.patch.object(c, "chain_config", lambda cid: {
                "name": f"chain{cid}", "nativeTokenSymbol": "TOK"}), \
            mock.patch.object(db, "one", lambda cid, _g: by_id[cid]), \
            redirect_stdout(buf):
        code = db.main()
    return buf.getvalue(), code


class TestExitCode(unittest.TestCase):
    """I1 at the process boundary: the gate's exit code is the only thing a runbook step reads."""

    OK = {"chainId": NEITHER, "name": "ok", "error": None, "sufficient": True,
          "shortfallExcludesL1": False, "deployer": "0x" + "11" * 20, "priceSource": "node",
          "l1Note": None, "balanceEth": 9.0, "needEth": 1.0, "shortfallEth": 0.0,
          "gasPriceWei": GOOD_PRICE, "quotedGasPriceWei": GOOD_PRICE}

    def test_all_funded_exits_zero(self):
        out, code = run_main([dict(self.OK)])
        self.assertEqual(code, 0)
        self.assertIn("priced and funded", out)

    def test_unpriceable_exits_nonzero_and_is_not_reported_as_ok(self):
        row = dict(self.OK, chainId=PRICED, sufficient=None, l1Note="regime moved")
        out, code = run_main([row])
        self.assertEqual(code, 1, "a chain the gate could not price must not exit 0")
        self.assertIn("UNPRICEABLE", out)
        self.assertIn("NOT a pass", out)
        self.assertNotIn("priced and funded", out)

    def test_rpc_error_exits_nonzero(self):
        row = dict(self.OK, error="connection refused")
        out, code = run_main([row])
        self.assertEqual(code, 1)
        self.assertIn("RPC ERROR", out)

    def test_override_priced_row_discloses_the_pin(self):
        # Drives the real selection through one() first: the earlier version fed a pre-labelled canned row,
        # so it checked only the print format and would still have passed if one() stopped consulting
        # GAS_PRICE_OVERRIDE_WEI entirely — a vacuous test of the mechanism it was named for.
        pinned = db.GAS_PRICE_OVERRIDE_WEI[OVERRIDDEN]
        row, _ = run_one(OVERRIDDEN, balance=10**24, quoted=31)
        self.assertEqual(row["priceSource"], "override")
        self.assertEqual(row["gasPriceWei"], pinned, "priced from the node quote, not the pin")
        self.assertEqual(row["quotedGasPriceWei"], 31)
        self.assertEqual(row["needWei"], GAS * pinned * db.FEE_VOLATILITY_HEADROOM)
        out, _ = run_main([row])
        self.assertIn("PINNED", out)

    def test_pin_below_a_plausible_quote_fails_closed(self):
        # The pin replaces the quote unconditionally, so a pin that has gone stale in the UNSAFE
        # direction (real price now above it) would size from the stale constant and print an
        # authoritative OK off an under-estimate. It must go UNPRICEABLE instead.
        pinned = db.GAS_PRICE_OVERRIDE_WEI[OVERRIDDEN]
        row, _ = run_one(OVERRIDDEN, balance=10**24, quoted=pinned + 1)
        self.assertIsNone(row["sufficient"], "a pin that no longer bounds the price is not a pass")
        self.assertFalse(row["priceable"])
        self.assertIn("remeasure", row["priceNote"])
        out, code = run_main([row])
        self.assertEqual(code, 1, "a stale pin must not exit 0")
        self.assertIn("UNPRICEABLE", out)
        # Must name the pin as the cause, not send the reader to the node like the generic message does.
        self.assertIn("GAS_PRICE_OVERRIDE_WEI", out)
        # The NOT PRICED summary is a SECOND rendering of the reason, and its default tail claims the
        # quote was too LOW — the opposite of this cause. Asserting on the summary line specifically,
        # because the status line above passed while this one was still wrong.
        summary = out.split("--- NOT PRICED")[1]
        self.assertNotIn("quote too low to size from", summary)
        self.assertIn("no longer bounds the price", summary)

    def test_pin_at_or_above_the_quote_still_prices(self):
        # The boundary is `quoted > override`, not `>=`: a quote that merely reaches the pin is still
        # bounded by it. Guards the guard against failing every override row closed.
        pinned = db.GAS_PRICE_OVERRIDE_WEI[OVERRIDDEN]
        for quoted in (pinned - 1, pinned):
            with self.subTest(quoted=quoted):
                row, _ = run_one(OVERRIDDEN, balance=10**24, quoted=quoted)
                self.assertTrue(row["priceable"])
                self.assertIsNone(row["priceNote"])
                self.assertEqual(row["gasPriceWei"], pinned)

    def test_unclassified_chain_charging_an_l1_fee_fails_closed(self):
        # The structural end of the missed-chain class. Every review round of this branch found another
        # chain that belonged in an L1 collection and was not in one — hemi worst, at 1.96x its whole
        # `need`. A hand-maintained list is a documentary guard; this makes it self-checking. OVERRIDDEN
        # (100) is in NEITHER collection, so a non-zero oracle reading must condemn it.
        row, _ = run_one(OVERRIDDEN, balance=10**24, big=12_345)
        self.assertIsNone(row["sufficient"], "an unmodelled L1 fee must not be priced past")
        self.assertIn("UNCLASSIFIED L1 FEE", row["l1Note"])
        self.assertIn("12345", row["l1Note"], "the reading itself is the evidence; print it")

    def test_unclassified_chain_with_no_l1_fee_still_prices(self):
        # Guards the guard against failing every unclassified chain closed. A zero reading is the real
        # case for xlayer (196), which HAS the predeploy and returns 0, exactly like celo.
        row, _ = run_one(OVERRIDDEN, balance=10**24, big=0)
        self.assertIsNotNone(row["sufficient"])
        self.assertIsNone(row["l1Note"])

    def test_probe_failure_on_an_unverified_chain_fails_closed(self):
        # ABSENCE OF EVIDENCE IS NOT EVIDENCE OF ABSENCE. An L1_FEE_UNVERIFIED chain has no prior
        # measurement by definition; if the probe also cannot complete, the row is backed by nothing
        # at all — and the first version of this guard printed OK anyway, because it swallowed a
        # transport failure and an absent predeploy through the same `except Exception: pass`.
        unverified = sorted(db.L1_FEE_UNVERIFIED)[0]
        row, _ = run_one(unverified, balance=10**24,
                         eth_call_raises=c.RpcError("eth_call failed after 4 attempts"))
        self.assertIsNone(row["sufficient"], "unknown fee status must not render as a pass")
        self.assertIn("UNKNOWN", row["l1Note"])
        self.assertIn("not a fee-free chain", row["l1Note"])

    def test_probe_failure_on_a_measured_chain_does_not_block(self):
        # The other side of the same distinction, and why the two sets were worth separating: a chain
        # in L1_FEE_NONE_VERIFIED was already MEASURED fee-free, so the probe is drift-detection there,
        # not the only evidence. A blip must not fail it closed and stall a 24-chain deploy.
        measured = sorted(db.L1_FEE_NONE_VERIFIED)[0]
        row, _ = run_one(measured, balance=10**24,
                         eth_call_raises=c.RpcError("eth_call failed after 4 attempts"))
        self.assertIsNotNone(row["sufficient"], "a measured-fee-free chain has prior evidence")

    def test_empty_returndata_is_read_as_absence_but_garbage_is_not(self):
        # `0x` means the node ANSWERED and there is no predeploy — evidence. Garbage means the node
        # answered badly — ambiguous. Both used to raise ValueError from `int(x, 16)` and be swallowed
        # identically, which is why this checks the RETURNDATA rather than narrowing the exception.
        unverified = sorted(db.L1_FEE_UNVERIFIED)[0]
        row, _ = run_one(unverified, balance=10**24, raw_eth_call="0x")
        self.assertIsNotNone(row["sufficient"], "an answered `0x` is evidence of no predeploy")
        row, _ = run_one(unverified, balance=10**24, raw_eth_call="0xZZnothex")
        self.assertIsNone(row["sufficient"], "unparseable returndata is not evidence of absence")

    def test_zero_gas_units_is_not_a_pass(self):
        # The other multiplicand. `need = gas * price * headroom`, so gas=0 collapses `need` to 0 and
        # `bal >= need` holds for ANY balance — the same tautology GAS_PRICE_IMPLAUSIBLE_WEI prevents on
        # the price side, reached from the side that had no floor. Realistic input: a --gas-units file
        # keyed `{"gas": ...}` instead of `{"total": ...}` reads as 0.
        row, _ = run_one(PRICED, balance=0, gas=0)
        self.assertIsNone(row["sufficient"], "a zero-gas estimate must never certify a balance")
        self.assertFalse(row["priceable"])
        self.assertIn("total", row["gasNote"], "the note must name the key that was mis-transcribed")
        out, code = run_main([row])
        self.assertEqual(code, 1)
        self.assertIn("UNPRICEABLE", out)

    def test_gas_units_just_under_the_floor_is_not_a_pass(self):
        row, _ = run_one(PRICED, balance=10**24, gas=db.GAS_UNITS_IMPLAUSIBLE - 1)
        self.assertIsNone(row["sufficient"])

    def test_plausible_gas_units_still_price(self):
        # Guards the guard: the floor must not fail every row closed.
        row, _ = run_one(PRICED, balance=10**24, gas=db.GAS_UNITS_IMPLAUSIBLE)
        self.assertIsNotNone(row["sufficient"])
        self.assertIsNone(row["gasNote"])

    def test_stale_pin_guard_needs_no_plausibility_term(self):
        # Replaces a test that asserted an explicit `quoted >= GAS_PRICE_IMPLAUSIBLE_WEI` conjunct by
        # mock-patching in a pin BELOW the floor — a configuration the module raises ValueError on at
        # import, so it certified a state that cannot exist and the conjunct it defended was dead code.
        #
        # What is actually true is a COUPLING between two guards, and that is what this asserts: the
        # import-time invariant forces every pin >= the floor, so `quoted > override` already implies
        # `quoted >= GAS_PRICE_IMPLAUSIBLE_WEI`. If someone relaxes the import invariant, this fails
        # and the stale-pin guard needs its plausibility term back.
        for cid, pin in db.GAS_PRICE_OVERRIDE_WEI.items():
            with self.subTest(chain=cid):
                self.assertGreaterEqual(
                    pin, db.GAS_PRICE_IMPLAUSIBLE_WEI,
                    "the stale-pin guard omits a plausibility term because this holds")


class TestImportTimeInvariants(unittest.TestCase):
    """I4 — structural, and not stripped by `python -O`."""

    SRC = (HERE / "deployer_balances.py").read_text()

    def _exec_with(self, old, new):
        self.assertIn(old, self.SRC, "substitution target vanished — update this test, not the code")
        ns = {"__name__": "not_main", "__file__": str(HERE / "deployer_balances.py")}
        exec(compile(self.SRC.replace(old, new, 1), "patched", "exec"), ns)  # noqa: S102
        return ns

    def test_override_below_the_implausible_floor_is_rejected_at_import(self):
        with self.assertRaises(ValueError):
            self._exec_with("GAS_PRICE_OVERRIDE_WEI = {", "GAS_PRICE_OVERRIDE_WEI = {1: 1, ")

    def test_priced_chain_without_a_baseline_is_rejected_at_import(self):
        with self.assertRaises(ValueError):
            self._exec_with("L1_FEE_OMITTED_PRICED = {", "L1_FEE_OMITTED_PRICED = {777, ")

    def test_chain_in_both_l1_collections_is_rejected_at_import(self):
        with self.assertRaises(ValueError):
            self._exec_with("L1_FEE_UNMODELLED = {534352, 43111}",
                            "L1_FEE_UNMODELLED = {534352, 43111, 8453}")

    def test_unpatched_source_imports_cleanly(self):
        # Guards the three tests above: if the module raised for an unrelated reason they would pass
        # for the wrong reason.
        self._exec_with("GAS_PRICE_OVERRIDE_WEI = {", "GAS_PRICE_OVERRIDE_WEI = {")

    def test_no_input_combination_can_certify_a_collapsed_estimate(self):
        # THE GOVERNING INVARIANT, STATED ONCE AND EXECUTABLY. Every previous guard here was written
        # per-axis after a specific fail-open was found: a floor on the price (pass 0), then a floor on
        # the gas units (pass 2, after a mis-keyed --gas-units file printed "all 24 chains priced and
        # funded" on an empty deployer). Per-axis guards are why this kept recurring — each one closes
        # the hole that was just found and says nothing about the next one.
        #
        # This asserts the property those guards exist to produce, over a grid spanning every
        # degenerate combination: an OK verdict REQUIRES a `need` at least as large as the smallest
        # estimate the floors are supposed to permit. It therefore fails for ANY future collapse route
        # — a third multiplicand, a headroom of 0, a new pricing branch — not just the two known ones.
        floor = db.GAS_UNITS_IMPLAUSIBLE * db.GAS_PRICE_IMPLAUSIBLE_WEI * db.FEE_VOLATILITY_HEADROOM
        checked = 0
        for gas in (0, 1, db.GAS_UNITS_IMPLAUSIBLE - 1, db.GAS_UNITS_IMPLAUSIBLE, GAS):
            for quoted in (0, 1, db.GAS_PRICE_IMPLAUSIBLE_WEI - 1, db.GAS_PRICE_IMPLAUSIBLE_WEI,
                           GOOD_PRICE):
                for bal in (0, 1, 10**24):
                    for cid in (PRICED, OVERRIDDEN, NEITHER, UNMODELLED, ZERO_FEE):
                        row, _ = run_one(cid, balance=bal, quoted=quoted, gas=gas)
                        checked += 1
                        if row.get("sufficient") is True:
                            self.assertGreaterEqual(
                                row["needWei"], floor,
                                f"chain {cid} certified OK on need={row['needWei']} from "
                                f"gas={gas} quoted={quoted} bal={bal} — below the {floor} floor the "
                                f"guards are supposed to enforce, i.e. a tautological pass")
        self.assertGreater(checked, 200, "the grid collapsed; this test would pass vacuously")

    def test_oracle_returning_unreadable_data_is_permanent_not_transient(self):
        # Branch coverage found this arm untested — it was added in pass 2 and never exercised, which
        # is the dead-code-reading-as-coverage class the guard itself was written to fix. `int(x, 16)`
        # raises ValueError on empty `0x` returndata, i.e. a chain with no OP GasPriceOracle predeploy,
        # which is PERMANENT. It must not tell an operator to retry, and it must not advise the fix
        # that drops the chain into neither collection (the hemi state).
        row, _ = run_one(PRICED, balance=10**24,
                         eth_call_raises=ValueError("invalid literal for int() with base 16: '0x'"))
        self.assertIsNone(row["sufficient"])
        self.assertIn("RETRYING WILL NOT HELP", row["l1Note"])
        self.assertNotIn("may be transient", row["l1Note"])
        self.assertIn("NEITHER", row["l1Note"], "must warn against the fix that re-creates the hemi gap")

    def test_transient_rpc_failure_on_the_probe_is_still_reported_as_retryable(self):
        # The other side of the same fork: a genuine network blip must NOT be relabelled permanent.
        # Asserting both arms so a future edit cannot collapse them into one message.
        row, _ = run_one(PRICED, balance=10**24, eth_call_raises=TimeoutError("read timed out"))
        self.assertIsNone(row["sufficient"])
        self.assertIn("may be transient", row["l1Note"])

    def test_rpc_failure_reading_balance_is_an_error_row_not_a_verdict(self):
        # :577-584 were uncovered. An unreachable chain must produce an error row, never OK.
        fake = Fake(0)
        def boom(url, method, params, *a, **k):
            if method == "eth_getBalance":
                raise ConnectionError("connection refused")
            return fake.rpc(url, method, params)
        with mock.patch.object(db, "scope", lambda _cid: {
                "metaAdapters": 0, "plainAdapters": 0, "assistants": 0,
                "feeds": 0, "assets": 0, "metaInstances": 0}), \
                mock.patch.object(c, "chain_config", lambda _cid: {
                    "name": "x", "nativeTokenSymbol": "TOK", "addresses": {"admin": "0x" + "11" * 20}}), \
                mock.patch.object(c, "probe_rpc", lambda _cid: ("http://fake", "fake", [])), \
                mock.patch.object(c, "rpc", boom):
            row = db.one(PRICED, {str(PRICED): {"total": GAS}})
        self.assertIn("error", row)
        self.assertNotIn("sufficient", row, "an unreachable chain must not carry a verdict at all")

    def test_builtin_gas_estimate_is_used_when_no_override_is_supplied(self):
        # :558 was uncovered — every test passed --gas-units, so the built-in per-step estimate that
        # runs on a real deploy day had NO coverage. It must clear the implausibility floor by
        # construction, since GAS_SHELL alone is 14x it.
        s = {"metaAdapters": 2, "plainAdapters": 3, "assistants": 1,
             "feeds": 4, "assets": 10, "metaInstances": 5}
        est = db.gas_estimate(s, None)
        self.assertGreaterEqual(est, db.GAS_SHELL)
        self.assertGreater(est, db.GAS_UNITS_IMPLAUSIBLE)
        self.assertEqual(db.gas_estimate({k: 0 for k in s}, None), db.GAS_SHELL,
                         "an empty scope should still cost the shell deploy")

    def test_l1_classification_covers_the_whole_deploy_scope(self):
        # SILENCE IS NOT AN ANSWER. Before this, a chain absent from both L1 sets was implicitly "no
        # fee", and that implicit default is precisely what let hemi print a clean OK at ~1/3 of its
        # real cost. The four sets must now COVER the deploy scope, so adding a chain to
        # redeploy_scope.json without classifying it fails here instead of on deploy day.
        #
        # Deliberately asserted against the scope file rather than a hard-coded list: the scope is the
        # thing that grows, and a check that does not read it would go stale the first time it does.
        ids, _src, _ = c.redeploy_scope()
        scope = set(ids)
        classified = (db.L1_FEE_OMITTED_PRICED | db.L1_FEE_UNMODELLED
                      | db.L1_FEE_NONE_VERIFIED | db.L1_FEE_UNVERIFIED)
        self.assertEqual(
            sorted(scope - classified), [],
            "chains in the deploy scope with no L1-fee classification — decide: priced with a "
            "measured baseline, failed closed, verified fee-free, or explicitly unverified")

    def test_l1_classification_has_no_phantom_chains(self):
        # The other direction: a classification for a chain that is not deployed is dead config, and
        # dead config is how a stale entry outlives the reason it was added.
        ids, _src, _ = c.redeploy_scope()
        classified = (db.L1_FEE_OMITTED_PRICED | db.L1_FEE_UNMODELLED
                      | db.L1_FEE_NONE_VERIFIED | db.L1_FEE_UNVERIFIED)
        self.assertEqual(sorted(classified - set(ids)), [],
                         "chains classified for the L1-fee axis but not in the deploy scope")

    def test_unverified_chains_are_not_claimed_as_fee_free(self):
        # The distinction the two new sets exist to preserve. An unverified chain must never be
        # silently folded into the verified-fee-free set — that collapse is the hemi inference
        # ("it doesn't look like a rollup") wearing a set name.
        self.assertEqual(db.L1_FEE_NONE_VERIFIED & db.L1_FEE_UNVERIFIED, set())
        self.assertTrue(db.L1_FEE_UNVERIFIED, "an empty unverified set means someone guessed")

    def test_hemi_is_failed_closed(self):
        # Regression pin. hemi (43111) was in NEITHER L1 collection, so it received no regime probe, no
        # headroom floor and shortfallExcludesL1=False, and printed a clean OK while ~3x under-funded:
        # measured 2026-08-12, its omitted L1 fee is 5.485e-5 ETH against a whole `need` of 2.801e-5 ETH
        # (1.96x the entire estimate). Asserting membership rather than behaviour because the fee is a
        # live on-chain reading — this only has to stop a silent removal.
        self.assertIn(43111, db.L1_FEE_UNMODELLED,
                      "hemi's omitted L1 fee exceeds its whole `need`; it must fail closed like scroll")
        self.assertNotIn(43111, db.L1_FEE_OMITTED_PRICED,
                         "hemi must not be in the priced set — its omitted term is not immaterial")

    # Workaround chains whose special handling is deliberately NOT about fees, each with the reason it
    # needs no L1-fee or gas-price classification. Kept next to the assertion so adding a workaround
    # forces the decision here rather than defaulting to "unclassified".
    NON_FEE_WORKAROUNDS = {
        # Block GAS LIMIT, not price: the ~12.5M-gas impl deploy does not fit HyperEVM's ~3M small
        # blocks, so the workaround toggles big blocks. L1-fee status UNMEASURED — endpoint not
        # reachable from where this suite runs, and HyperEVM is Hyperliquid's own execution layer
        # rather than a rollup posting data to Ethereum.
        999,
        # gnosis — a standalone L1, not a rollup. MEASURED 2026-08-12: no OP GasPriceOracle at
        # 0x420...0F (codesize 0). Its workaround is purely gas-PRICE (tip-driven inclusion).
        100,
        # plasma — workaround is purely gas-PRICE (the node pads eth_gasPrice with a tip nobody pays).
        # L1-fee status UNMEASURED: endpoint not reachable from where this suite runs.
        9745,
    }
    # NOTE none of these three is CERTIFIED fee-free; two are unmeasured. That is tolerable only because
    # the runtime guard in `one()` probes every unclassified chain's OP GasPriceOracle on-chain and fails
    # the row closed on a non-zero reading. This static check is the second line: it forces a written
    # decision per workaround chain so a missing entry is visible without a network round-trip.

    def test_every_workaround_chain_is_classified(self):
        # hemi hid in plain sight: it had a WORKAROUNDS entry for its fee floor, which made it look
        # handled while it sat outside both L1 collections, and it printed a clean OK while ~3x
        # under-funded. A chain singled out as needing special treatment is exactly the kind a
        # hand-maintained set misses, so every such chain must be deliberately classified — priced with
        # omission, failed closed, pinned, or explicitly recorded above as not a fee case.
        # GAS_PRICE_OVERRIDE_WEI is deliberately NOT accepted as classification. It is the gas-PRICE
        # axis; this check polices the L1-FEE axis, and the two are independent — hemi proved it by
        # having a price-side workaround while its fee side was the thing that was wrong. Counting a pin
        # as "classified" would let exactly that combination through the check written to catch it.
        classified = (db.L1_FEE_OMITTED_PRICED | db.L1_FEE_UNMODELLED | self.NON_FEE_WORKAROUNDS)
        for cid in db.WORKAROUNDS:
            with self.subTest(chain=cid):
                self.assertIn(cid, classified,
                              f"chain {cid} has a WORKAROUNDS entry but no L1-fee or gas-price "
                              f"classification — decide which it is, or add it to "
                              f"NON_FEE_WORKAROUNDS with the reason")

    def test_invariants_use_raise_not_assert(self):
        # `python -O` strips assert, which would silently delete both gates.
        for line in self.SRC.splitlines():
            stripped = line.strip()
            self.assertFalse(stripped.startswith("assert "),
                             f"bare assert in a gate invariant is stripped under -O: {stripped}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
