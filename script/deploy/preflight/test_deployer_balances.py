#!/usr/bin/env python3
"""Verdict truth table for deployer_balances.py. Stdlib only: `python3 -m unittest`.

WHY THIS EXISTS. This file is a deploy gate with no automated coverage — CI runs forge, lint and the
lockfile check, and nothing that executes any Python here. Every guard in it was verified once, by
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
                 eth_call_raises=None, block="0x2f8b950"):
        self.balance, self.quoted, self.block = balance, quoted, block
        self.big, self.small, self.eth_call_raises = big, small, eth_call_raises
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
            self.payloads.append(_payload_of(params[0]["data"]))
            n = _n_of(params[0]["data"])
            v = self.big if n == db.L1_REGIME_PROBE_BYTES_BIG else self.small
            return hex(v if v is not None else 0)
        raise AssertionError(f"unexpected RPC method {method}")

    @property
    def probe_blocks(self):
        return [p[1] for m, p in self.calls if m == "eth_call"]


def run_one(cid, *, balance, quoted=GOOD_PRICE, gas=GAS, big=None, small=None,
            eth_call_raises=None, drop_baseline=False):
    """Drive db.one() against a fake chain. Returns (row, fake)."""
    base_big = db.L1_REGIME_BASELINE_WEI.get(cid, 0)
    base_small = db.L1_REGIME_BASELINE_SMALL_WEI.get(cid, 0)
    fake = Fake(balance, quoted,
                big=base_big if big is None else big,
                small=base_small if small is None else small,
                eth_call_raises=eth_call_raises)
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

    def test_probe_trip_on_payload_size_axis_fails_closed(self):
        base = db.L1_REGIME_BASELINE_WEI[PRICED]
        row, _ = run_one(PRICED, balance=10**24, big=base * (db.L1_REGIME_MAX_RISE + 1))
        self.assertIsNone(row["sufficient"])
        self.assertIn("payload-size", row["l1Note"])

    def test_probe_trip_on_base_fee_axis_fails_closed(self):
        # BIG passes, SMALL trips: the second axis must be reached, not short-circuited by the first.
        base = db.L1_REGIME_BASELINE_SMALL_WEI[PRICED]
        row, _ = run_one(PRICED, balance=10**24, small=base * (db.L1_REGIME_MAX_RISE + 1))
        self.assertIsNone(row["sufficient"])
        self.assertIn("base-fee", row["l1Note"])

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
        row = dict(self.OK, chainId=OVERRIDDEN, priceSource="override",
                   gasPriceWei=2_000_000_000, quotedGasPriceWei=31)
        out, _ = run_main([row])
        self.assertIn("PINNED", out)


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
            self._exec_with("L1_FEE_UNMODELLED = {534352}", "L1_FEE_UNMODELLED = {534352, 8453}")

    def test_unpatched_source_imports_cleanly(self):
        # Guards the three tests above: if the module raised for an unrelated reason they would pass
        # for the wrong reason.
        self._exec_with("GAS_PRICE_OVERRIDE_WEI = {", "GAS_PRICE_OVERRIDE_WEI = {")

    def test_invariants_use_raise_not_assert(self):
        # `python -O` strips assert, which would silently delete both gates.
        for line in self.SRC.splitlines():
            stripped = line.strip()
            self.assertFalse(stripped.startswith("assert "),
                             f"bare assert in a gate invariant is stripped under -O: {stripped}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
