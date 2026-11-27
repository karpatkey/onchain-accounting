#!/usr/bin/env python3
"""Pins derive-celestia-proof.py's offline half: the record decoder, the signed-feed selection and its float
reference of DeriveOptionPricer, against the real-batch fixtures the Solidity tests use.

Run from this directory with `python3 -m unittest test_derive_celestia_proof` (also under `python3 -O`). No network.
The reference values asserted here are the ones DeriveCelestiaAttestedBalanceAdapter.t.sol pins for the adapter,
so the two implementations are held to each other; test_scriptFixture_optionsMatchReference closes the loop on
a fixture the script wrote itself.
"""
import copy
import importlib.util
import json
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent.parent / "test" / "integration" / "derive-celestia"

_spec = importlib.util.spec_from_file_location("derive_celestia_proof", HERE / "derive-celestia-proof.py")
p = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(p)

ETH = "0x4bb4c3cdc7562f08e9910a0c7d8bb7e108861eb4"
HYPE = "0x7344bf2afff9afcd6d024865fc0ca53bf03464d9"
USDC_TOKEN = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
HYPE_TOKEN = "0x0762365e088Fb8D285b295d782BB7b23690713e2"
DERIVE_HYPE = "0x2dd469db6ee0dbf0277f0f3021fd8a6486a751ce"
DERIVE_USDC = "0x57b03e14d409adc7fab6cfc44b5886cad2d5f02b"


def load(name):
    return json.loads((FIXTURES / name).read_text())


def record_of(fixture):
    """Decode the proven record from a fixture's shares, as the adapter does (no prior knowledge of its fields)."""
    proof = fixture["proofs"][0]
    data = b"".join(bytes.fromhex(s["share"][2:])[34 if s["index"] == 0 else 30:] for s in proof["shares"])
    return p.parse_record(data, proof["recordOffset"])


def sub_id(expiry, strike8, is_call):
    return expiry | strike8 << 32 | int(is_call) << 95


class RecordDecodeTest(unittest.TestCase):
    def test_hype_puts_of_119408(self):
        fx = load("mark_119408.json")
        r = record_of(fx)
        self.assertEqual(r["id"], 119408)
        self.assertEqual(r["owner"], fx["account"])
        self.assertEqual(r["perps"], 0)
        self.assertEqual([(o["asset"], p.series(o["subId"]), o["amount"]) for o in r["options"]], [
            (HYPE, (1798185600, 70 * 10**8, False), -3000 * 10**12),
            (HYPE, (1798185600, 82 * 10**8, False), 3000 * 10**12),
        ])

    def test_option_series_of_117522_match_its_signed_feeds(self):
        r = record_of(load("mark_117522.json"))
        feeds = load("mark_feeds.json")["subaccounts"]["117522"]
        self.assertEqual(len(r["options"]), 8)
        got = {(p.OPTION_MARKETS[o["asset"]], p.series(o["subId"])[0]) for o in r["options"]}
        want = {(e["currency"], e["forward"]["expiry"]) for e in feeds["expiries"]}
        self.assertEqual(got, want)
        self.assertEqual({o["amount"] > 0 for o in r["options"]}, {True, False})


class ReferenceValueTest(unittest.TestCase):
    """The float reference lands on the adapter's pinned outputs (DeriveCelestiaAttestedBalanceAdapter.t.sol)."""

    def setUp(self):
        self.mf = load("mark_feeds.json")

    def expected(self, sid):
        r = record_of(load(f"mark_{sid}.json"))
        return p.expected_amounts([r], self.mf["subaccounts"][sid], self.mf["valuationTime"])

    def test_117522_eth_and_btc_calls(self):
        self.assertEqual(self.expected("117522"), {USDC_TOKEN: 26_015_997_422})

    def test_119408_hype_put_spread(self):
        self.assertEqual(self.expected("119408"), {USDC_TOKEN: 88_801_606_434})

    def test_expired_option_at_derives_settlement(self):
        s = self.mf["expiredSettlement"]
        feeds = {"spots": [], "expiries": [s]}
        expiry = s["forward"]["expiry"]
        long_ = {"asset": ETH, "subId": sub_id(expiry, 1800 * 10**8, True), "amount": 10**12}
        short = dict(long_, amount=-10**12)
        # 1819.511710943306838888 − 1800, at 12 decimals: a long rounds down, a short rounds up.
        self.assertEqual(p.option_value12(long_, feeds, expiry + 1), 19_511_710_943_306)
        self.assertEqual(p.option_value12(short, feeds, expiry + 1), -19_511_710_943_307)

    def test_short_exceeding_own_cash_refused(self):
        r = record_of(load("mark_119408.json"))
        r["collateral"] = []
        r["options"] = [o for o in r["options"] if o["amount"] < 0]
        with self.assertRaises(p.FeedError):
            p.expected_amounts([r], self.mf["subaccounts"]["119408"], self.mf["valuationTime"])

    def test_122119_usdc_borrow_comes_out_of_hype(self):
        # test_realBatch_hypeSplitCdp_matchesMarginWatch: the adapter books 91,641,218,458 (12 decimals) HYPE, 0 USDC.
        fx = load("hype_split_122119_cdp.json")
        got = p.expected_amounts([record_of(fx)], fx["subaccounts"]["122119"], fx["valuationTime"])
        self.assertEqual(got, {USDC_TOKEN: 0, HYPE_TOKEN: 91_641_218_458 * 10**6})

    def test_borrow_beyond_collateral_refused(self):
        fx = load("hype_split_122119_cdp.json")
        r = record_of(fx)
        r["collateral"] = [(DERIVE_HYPE, 10**10), (DERIVE_USDC, -3890496741630)]
        with self.assertRaises(p.FeedError):
            p.expected_amounts([r], fx["subaccounts"]["122119"], fx["valuationTime"])

    def test_spot_needed_only_for_equity_records(self):
        held = {"id": 1, "collateral": [(DERIVE_HYPE, 10**12)], "options": []}
        borrowing = dict(held, collateral=[(DERIVE_HYPE, 10**12), (DERIVE_USDC, -10**12)])
        self.assertEqual(p.spot_currencies([held]), set())
        self.assertEqual(p.spot_currencies([held, borrowing]), {"HYPE"})


class MathVectorTest(unittest.TestCase):
    """Against the 50-digit mpmath references that DeriveOptionMath.t.sol also uses."""

    def setUp(self):
        self.v = load("option_math_vectors.json")

    def test_norm_cdf(self):
        for x, want in self.v["cdf"]:
            self.assertAlmostEqual(p.norm_cdf(int(x) / 1e18), int(want) / 1e18, delta=1e-12, msg=x)

    def test_black76(self):
        for fwd, strike, vol, tau, rate, is_call, want in self.v["b76"]:
            got = p.black76(int(fwd) / 1e18, int(strike) / 1e18, int(vol) / 1e18, int(tau) / 1e18,
                            int(rate) / 1e18, is_call)
            self.assertAlmostEqual(got, int(want) / 1e18, delta=max(1e-12, 1e-12 * int(want) / 1e18),
                                   msg=(fwd, strike, vol, tau, rate, is_call))


class BuildFeedsTest(unittest.TestCase):
    """Selection and encoding of Derive's real signed-feed response (signed_feeds_hype.json, trimmed)."""

    LIVE, LIVE2, SETTLED, STALE = 1795248000, 1795334400, 1795161600, 1798704000

    def setUp(self):
        fx = load("signed_feeds_hype.json")
        self.signed, self.now = {"HYPE": fx["result"]}, fx["fetchedAt"]

    def opt(self, expiry, amount=10**12):
        return {"asset": HYPE, "subId": sub_id(expiry, 60 * 10**8, True), "amount": amount}

    def test_live_and_settled_options_take_exactly_their_items(self):
        f = p.build_feeds(self.signed, [self.opt(self.LIVE), self.opt(self.SETTLED)], self.now)
        self.assertEqual([s["currency"] for s in f["spots"]], ["HYPE"])
        self.assertEqual([e["forward"]["expiry"] for e in f["expiries"]], [self.SETTLED, self.LIVE])
        settled, live = f["expiries"]
        self.assertNotIn("rate", settled)
        self.assertNotIn("vol", settled)
        self.assertIn("rate", live)
        self.assertIn("vol", live)

    def test_numbers_are_exact_1e18_and_signatures_kept(self):
        f = p.build_feeds(self.signed, [self.opt(self.LIVE)], self.now)
        src = self.signed["HYPE"]
        spot = f["spots"][0]
        self.assertEqual(spot["price"], "60990852460271100000")  # "60.9908524602711"
        self.assertEqual(spot["signatures"], src["spot_data"]["HYPE"]["signatures"]["signatures"])
        fw, raw = f["expiries"][0]["forward"], src["fwd_data"]["HYPE"][str(self.LIVE)]
        self.assertEqual((fw["start"], fw["latest"]), (raw["spot_aggregate_start"], raw["spot_aggregate_latest"]))
        vol = f["expiries"][0]["vol"]
        self.assertEqual(vol["refTau"], str(int(p.Decimal(src["vol_data"]["HYPE"][str(self.LIVE)]["vol_data"]
                                                        ["SVI_refTau"]) * 10**18)))

    def test_no_spot_when_every_expiry_has_settled(self):
        f = p.build_feeds(self.signed, [self.opt(self.SETTLED)], self.now)
        self.assertEqual(f["spots"], [])

    def test_zero_amount_takes_no_items(self):
        f = p.build_feeds(self.signed, [self.opt(self.LIVE), self.opt(self.LIVE2, 0)], self.now)
        self.assertEqual([e["forward"]["expiry"] for e in f["expiries"]], [self.LIVE])

    def test_collateral_spot_without_options(self):
        f = p.build_feeds(self.signed, [], self.now, {"HYPE"})
        self.assertEqual([s["currency"] for s in f["spots"]], ["HYPE"])
        self.assertEqual(f["expiries"], [])

    def test_refusals(self):
        unsettled = copy.deepcopy(self.signed)
        unsettled["HYPE"]["fwd_data"]["HYPE"][str(self.SETTLED)]["timestamp"] -= 1
        resigned = copy.deepcopy(self.signed)
        resigned["HYPE"]["spot_data"]["HYPE"]["signatures"]["signers"][0] = "0x" + "11" * 20
        cases = {
            "expired without settlement item": (unsettled, [self.opt(self.SETTLED)], self.now),
            "Derive's stale forward for this expiry": (self.signed, [self.opt(self.STALE)], self.now),
            "items older than 5 minutes": (self.signed, [self.opt(self.LIVE)], self.now + p.MAX_FEED_AGE + 10),
            "unknown signer": (resigned, [self.opt(self.LIVE)], self.now),
            "unmapped option asset": (self.signed, [dict(self.opt(self.LIVE), asset="0x" + "22" * 20)], self.now),
        }
        for name, (signed, opts, now) in cases.items():
            with self.subTest(name), self.assertRaises(p.FeedError):
                p.build_feeds(signed, opts, now)


if __name__ == "__main__":
    unittest.main()
