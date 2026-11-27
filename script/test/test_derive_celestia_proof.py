#!/usr/bin/env python3
"""Pins derive-celestia-proof.py's offline half: the record decoder, the signed-feed selection and its float
reference of DeriveOptionPricer, against the real-batch fixtures the Solidity tests use; and the settlement
preflight's verdicts against a stubbed chain.

Run from this directory with `python3 -m unittest test_derive_celestia_proof` (also under `python3 -O`). No network.
The reference values asserted here are the ones DeriveCelestiaAttestedBalanceAdapter.t.sol pins for the adapter,
so the two implementations are held to each other; test_scriptFixture_optionsMatchReference closes the loop on
a fixture the script wrote itself.
"""
import contextlib
import copy
import importlib.util
import io
import json
import os
import sys
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


SAFE = "0x8c79753aad88183f5747c91684d6c0cbfcb27476"
OTHER = "0x00000000000000000000000000000000000000bb"
ZERO = "0x" + "00" * 20
CONSUMED = 100


def word(x):
    return f"{x:064x}"


def aword(a):
    return a[2:].lower().rjust(64, "0")


class FakeChain:
    """eth_call and eth_getLogs as a node answers them: logs filtered by address, topics and block range."""

    def __init__(self):
        self.logs, self.calls, self.ranges = [], {}, []
        self.calls[(p.VAPP.lower(), p.SEL_CONSUMED_PUBLIC)] = word(CONSUMED)
        for sel, t in zip(p.SEL_ACTION_TYPES, (1, 2, 3)):
            self.calls[(p.ACTION_MANAGER.lower(), sel)] = word(t)

    def __call__(self, method, params):
        if method == "eth_call":
            to, data = params[0]["to"].lower(), params[0]["data"]
            return "0x" + self.calls.get((to, data), word(0) * 5)
        if method != "eth_getLogs":
            raise AssertionError(method)
        f = params[0]
        lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
        self.ranges.append((f["address"].lower(), lo, hi))
        return [lg for lg in self.logs
                if lg["address"] == f["address"].lower() and lo <= lg["block"] <= hi
                and all(want is None or want == got for want, got in zip(f["topics"], lg["topics"]))]

    def log(self, address, topics, data, block):
        self.logs.append({"address": address.lower(), "topics": topics, "data": "0x" + data, "block": block,
                          "transactionHash": "0x" + word(len(self.logs))})

    def action(self, action_id, sender, action_type, block=p.ACTION_MANAGER_FROM_BLOCK + 5):
        self.log(p.ACTION_MANAGER, [p.TOPIC_PUBLIC_ACTION, "0x" + word(action_id), "0x" + aword(sender),
                                    "0x" + word(action_type)], "", block)

    def enqueued(self, wid, recipient, bucket, index, remaining):
        """A WithdrawalEnqueued log; the entry stays in `bucket` with `remaining` left (0: paid and deleted)."""
        self.log(p.OUTBOX, [p.TOPIC_ENQUEUED, "0x" + word(wid), "0x" + aword(DERIVE_USDC), "0x" + aword(recipient)],
                 word(remaining) + aword(bucket[0]) + aword(bucket[1]) + word(index), p.OUTBOX_FROM_BLOCK + 9)
        if remaining:
            entry = word(wid) + aword(DERIVE_USDC) + word(7) + aword(recipient) + word(remaining)
            key = p.SEL_QUEUE_ENTRY + aword(bucket[0]) + aword(bucket[1]) + word(index)
            self.calls[(p.OUTBOX.lower(), key)] = entry

    def deferred(self, did, recipient, unpaid):
        self.log(p.OUTBOX, [p.TOPIC_DEFERRED, "0x" + word(did), "0x" + word(0xabc + did), "0x" + aword(DERIVE_USDC)],
                 word(7) + aword(recipient) + word(5 * 10**6), p.OUTBOX_FROM_BLOCK + 11)
        if unpaid:
            self.calls[(p.OUTBOX.lower(), p.SEL_DEFERRED + word(did))] = word(0xc0ffee)


class PreflightTest(unittest.TestCase):
    BLOCK = p.OUTBOX_FROM_BLOCK + 25_000

    def setUp(self):
        self.chain = FakeChain()

    def verdict(self, chunk=p.LOG_CHUNK):
        return p.preflight_verdict(self.chain, SAFE, self.BLOCK, chunk)

    def test_nothing_in_flight(self):
        self.chain.action(CONSUMED - 1, SAFE, 1)          # its deposit, already applied by a batch
        self.chain.enqueued(1, SAFE, (ZERO, ZERO), 3, 0)  # queued once, since paid
        self.chain.deferred(0, SAFE, unpaid=False)        # deferred once, since paid
        code, report = self.verdict()
        self.assertEqual((code, report["reasons"]), (0, []))

    def test_action_at_the_consumed_index_is_pending(self):
        self.chain.action(CONSUMED, SAFE, 1)
        code, report = self.verdict()
        self.assertEqual(code, 1)
        self.assertEqual([a["actionId"] for a in report["pendingActions"]], [CONSUMED])

    def test_every_tracked_action_type_is_pending_and_others_are_not(self):
        for i, t in enumerate((1, 2, 3, 7)):  # deposit, deposit to new subaccount, withdrawal request; 7 untracked
            self.chain.action(CONSUMED + i, SAFE, t)
        self.chain.action(CONSUMED + 9, OTHER, 1)  # someone else's deposit
        _, report = self.verdict()
        self.assertEqual([a["actionType"] for a in report["pendingActions"]], [1, 2, 3])

    def test_queued_withdrawal_read_in_the_bucket_it_was_enqueued_in(self):
        # Enqueued in the global bucket; the Safe's current bucketKey may point elsewhere, so it is never consulted.
        self.chain.enqueued(2, SAFE, (ZERO, ZERO), 41, 1_000_000)
        self.chain.enqueued(3, OTHER, (ZERO, ZERO), 42, 9_000_000)
        code, report = self.verdict()
        self.assertEqual(code, 1)
        self.assertEqual([(q["queueIndex"], q["remaining"]) for q in report["queued"]], [(41, 1_000_000)])

    def test_unpaid_deferred_withdrawal_of_the_safe_only(self):
        self.chain.deferred(0, SAFE, unpaid=True)
        self.chain.deferred(1, OTHER, unpaid=True)
        self.chain.deferred(2, SAFE, unpaid=False)
        code, report = self.verdict()
        self.assertEqual(code, 1)
        self.assertEqual([d["deferredId"] for d in report["deferred"]], [0])

    def test_logs_scanned_once_from_deployment_to_the_pinned_block(self):
        self.chain.deferred(0, SAFE, unpaid=True)
        self.chain.logs[-1]["block"] = self.BLOCK  # on the last block of the last chunk
        self.chain.action(CONSUMED, SAFE, 1, block=p.ACTION_MANAGER_FROM_BLOCK)  # on the first block
        _, report = self.verdict(chunk=7_000)
        self.assertEqual((len(report["pendingActions"]), len(report["deferred"])), (1, 1))
        for address, start in ((p.ACTION_MANAGER.lower(), p.ACTION_MANAGER_FROM_BLOCK),
                               (p.OUTBOX.lower(), p.OUTBOX_FROM_BLOCK)):
            spans = sorted({(lo, hi) for a, lo, hi in self.chain.ranges if a == address})
            self.assertEqual(spans[0][0], start)
            self.assertEqual(spans[-1][1], self.BLOCK)
            self.assertTrue(all(b[0] == a[1] + 1 for a, b in zip(spans, spans[1:])), spans)  # no gap, no overlap

    def test_read_failure_is_exit_2(self):
        def failing(method, params):
            if method == "eth_getLogs":
                raise RuntimeError("eth_getLogs: archive requests require a personal token")
            return self.chain(method, params)
        code, report = p.preflight_verdict(failing, SAFE, self.BLOCK)
        self.assertEqual(code, 2)
        self.assertFalse(report["ok"])


E18 = 10**18


class SimChain:
    """One chain's state over its blocks, answering the RPC calls the preflight makes, at any pinned block."""

    def __init__(self, head):
        self.head, self.logs, self.deltas, self.consumed, self.entries = head, [], {}, [(0, 0)], {}

    def mine(self):
        self.head += 1
        return self.head

    def credit(self, token, delta, block):  # token None: native coin
        self.deltas.setdefault(token, []).append((block, delta))

    def balance(self, token, pin):
        return sum(d for b, d in self.deltas.get(token, []) if b <= pin)

    def log(self, address, topics, data, block):
        self.logs.append({"address": address.lower(), "topics": topics, "data": "0x" + data, "block": block,
                          "blockNumber": hex(block), "transactionHash": "0x" + word(len(self.logs))})

    def __call__(self, method, params):
        if method == "eth_blockNumber":
            return hex(self.head)
        if method == "eth_getBalance":
            return hex(self.balance(None, int(params[1], 16)))
        if method == "eth_getLogs":
            f = params[0]
            lo, hi = int(f["fromBlock"], 16), int(f["toBlock"], 16)
            return [lg for lg in self.logs if lg["address"] == f["address"].lower() and lo <= lg["block"] <= hi
                    and all(w is None or w == got for w, got in zip(f["topics"], lg["topics"]))]
        if method != "eth_call":
            raise AssertionError(method)
        to, data, pin = params[0]["to"].lower(), params[0]["data"], int(params[1], 16)
        if (to, data) == (p.VAPP.lower(), p.SEL_CONSUMED_PUBLIC):
            return "0x" + word(max((b, v) for b, v in self.consumed if b <= pin)[1])
        if to == p.ACTION_MANAGER.lower() and data in p.SEL_ACTION_TYPES:
            return "0x" + word(p.SEL_ACTION_TYPES.index(data) + 1)
        if data.startswith(p.SEL_BALANCE_OF):
            return "0x" + word(self.balance(to, pin))
        if data.startswith(p.SEL_QUEUE_ENTRY):
            opened, closed, entry = self.entries.get(data[10:], (None, None, None))
            live = opened is not None and opened <= pin and (closed is None or pin < closed)
            return "0x" + (entry if live else word(0) * 5)
        return "0x" + word(0)  # deferredWithdrawals: none in these flows


class World:
    """The fund across HyperEVM, Ethereum and Derive. `total` is the truth: it moves only on subscribe and redeem
    (and on a payout); every other step moves value between places, some of them invisible to a balance read."""

    EID = {p.ETHEREUM: 30101, p.HYPEREVM: 30367}

    def __init__(self):
        self.chain = {p.ETHEREUM: SimChain(p.OUTBOX_FROM_BLOCK + 1_000), p.HYPEREVM: SimChain(51_000_000)}
        self.since = {c: ch.head for c, ch in self.chain.items()}
        self.total, self.derive, self.next_action, self.guids = 0, [(0, 0)], 0, 0
        self.flight, self.deposits, self.withdrawals, self.queue = {}, [], [], []

    @property
    def eth(self):
        return self.chain[p.ETHEREUM]

    @property
    def hyp(self):
        return self.chain[p.HYPEREVM]

    def _token(self, c):
        return None if c == p.HYPEREVM else p.OFT[p.ETHEREUM].lower()

    def _action(self, action_type):
        b = self.eth.mine()
        self.eth.log(p.ACTION_MANAGER, [p.TOPIC_PUBLIC_ACTION, "0x" + word(self.next_action), "0x" + aword(SAFE),
                                        "0x" + word(action_type)], "", b)
        self.next_action += 1
        return b

    def subscribe(self, amount):
        self.hyp.credit(None, amount, self.hyp.mine())
        self.total += amount

    def redeem(self, amount):
        self.hyp.credit(None, -amount, self.hyp.mine())
        self.total -= amount

    def wrap(self, amount):
        """Native HYPE -> WHYPE on HyperEVM: the fund holds both."""
        b = self.hyp.mine()
        self.hyp.credit(None, -amount, b)
        self.hyp.credit(p.WHYPE.lower(), amount, b)

    def send(self, src, amount, recipient=SAFE, dst_eid=None):
        """LayerZero send from the Safe on `src` to the other chain (or to `dst_eid`); tokens leave at once."""
        b = self.chain[src].mine()
        self.chain[src].credit(self._token(src), -amount, b)
        self.guids += 1
        guid = "0x" + word(0xbeef00 + self.guids)
        dst = p.ETHEREUM if src == p.HYPEREVM else p.HYPEREVM
        self.chain[src].log(p.OFT[src], [p.TOPIC_OFT_SENT, guid, "0x" + aword(SAFE)],
                            word(dst_eid or self.EID[dst]) + word(amount) + word(amount), b)
        self.flight[guid] = (src, dst, amount, recipient)
        if recipient != SAFE:
            self.total -= amount  # a redemption paid out cross-chain leaves the fund when sent
        return guid

    def deliver(self, guid, upper=False):
        src, dst, amount, recipient = self.flight.pop(guid)
        b = self.chain[dst].mine()
        if recipient == SAFE:
            self.chain[dst].credit(self._token(dst), amount, b)
        topic = "0x" + guid[2:].upper() if upper else guid  # nodes return hex in either case
        self.chain[dst].log(p.OFT[dst], [p.TOPIC_OFT_RECEIVED, topic, "0x" + aword(recipient)],
                            word(self.EID[src]) + word(amount), b)

    def inflow(self, dst, amount):
        """Someone else bridges HYPE to the Safe: counted on arrival only."""
        b = self.chain[dst].mine()
        self.chain[dst].credit(self._token(dst), amount, b)
        self.chain[dst].log(p.OFT[dst], [p.TOPIC_OFT_RECEIVED, "0x" + word(0xd00d00 + b), "0x" + aword(SAFE)],
                            word(30184) + word(amount), b)
        self.total += amount

    def noise(self):
        """Other users' transfers on the same OFTs, in both directions: never the Safe's."""
        for c in self.chain:
            b = self.chain[c].mine()
            self.chain[c].log(p.OFT[c], [p.TOPIC_OFT_SENT, "0x" + word(0xaaa000 + b), "0x" + aword(OTHER)],
                              word(30101) + word(9 * E18) + word(9 * E18), b)
            self.chain[c].log(p.OFT[c], [p.TOPIC_OFT_RECEIVED, "0x" + word(0xbbb000 + b), "0x" + aword(OTHER)],
                              word(30367) + word(9 * E18), b)

    def settled(self):
        """Record a settlement at the current heads: the next check scans from here."""
        self.since = {c: ch.head for c, ch in self.chain.items()}

    def deposit(self, amount):
        self.eth.credit(self._token(p.ETHEREUM), -amount, self._action(1))
        self.deposits.append(amount)

    def request_withdrawal(self, amount, throttled=False):
        self._action(3)
        self.withdrawals.append((amount, throttled))

    def batch(self):
        """Applies every queued action; pays withdrawals in the same transaction unless the outbox throttles them."""
        b = self.eth.mine()
        self.eth.consumed.append((b, self.next_action))
        balance = self.derive[-1][1] + sum(self.deposits) - sum(a for a, _ in self.withdrawals)
        self.derive.append((b, balance))
        for amount, throttled in self.withdrawals:
            if not throttled:
                self.eth.credit(self._token(p.ETHEREUM), amount, b)
                continue
            index = len(self.queue)
            wid = word(0xfeed00 + index)
            key = ZERO[2:].rjust(64, "0") * 2 + word(index)
            self.eth.entries[key] = (b, None, wid + aword(DERIVE_USDC) + word(7) + aword(SAFE) + word(amount))
            self.eth.log(p.OUTBOX, [p.TOPIC_ENQUEUED, "0x" + wid, "0x" + aword(DERIVE_USDC), "0x" + aword(SAFE)],
                         word(amount) + aword(ZERO) + aword(ZERO) + word(index), b)
            self.queue.append((key, amount))
        self.deposits, self.withdrawals = [], []

    def process_queue(self):
        b = self.eth.mine()
        for key, amount in self.queue:
            opened, _, entry = self.eth.entries[key]
            self.eth.entries[key] = (opened, b, entry)
            self.eth.credit(self._token(p.ETHEREUM), amount, b)
        self.queue = []

    def settle(self, pin_eth=None, pin_hyp=None):
        """(exit code, report, counted): `counted` is what the operator would add up at these pins, the chains'
        holdings plus the Derive leg the attested adapter reports from the newest batch at the Ethereum pin."""
        pe, ph = pin_eth or self.eth.head, pin_hyp or self.hyp.head
        code, report = p.preflight_verdict(self.eth, SAFE, pe, p.LOG_CHUNK, {
            "rpc": self.hyp, "pin": ph, "since": self.since[p.HYPEREVM], "sinceEth": self.since[p.ETHEREUM],
            "chunk": p.HYPEREVM_LOG_CHUNK})
        if code == 2:
            return code, report, None
        derive_leg = max((b, v) for b, v in self.derive if b <= pe)[1]
        return code, report, report["bridge"]["holdings"]["outsideDerive"] + derive_leg


class LifecycleSimulationTest(unittest.TestCase):
    """One subscription's round trip: HyperEVM -> LayerZero -> Ethereum -> Derive and back. Whenever the check
    settles, what the operator counts equals the fund's true total; whenever value is invisible, it skips."""

    def assertSettles(self, w):
        code, report, counted = w.settle()
        self.assertEqual(code, 0, report.get("reasons") or report.get("error"))
        self.assertEqual(counted, w.total)

    def assertSkips(self, w, reason):
        code, report, _ = w.settle()
        self.assertEqual(code, 1, report.get("error"))
        self.assertTrue(any(reason in r for r in report["reasons"]), report["reasons"])

    def test_round_trip(self):
        w = World()
        self.assertSettles(w)
        w.subscribe(10 * E18)
        self.assertSettles(w)

        g = w.send(p.HYPEREVM, 6 * E18)                  # subscription capital to Ethereum
        self.assertSkips(w, "in flight")
        w.deliver(g)
        self.assertSettles(w)

        w.deposit(6 * E18)                               # into Derive
        self.assertSkips(w, "not yet applied by a batch")
        w.batch()
        self.assertSettles(w)

        w.request_withdrawal(2 * E18)                    # paid inside the batch
        self.assertSkips(w, "not yet applied by a batch")
        w.batch()
        self.assertSettles(w)

        w.request_withdrawal(1 * E18, throttled=True)    # parked in the outbox queue
        w.batch()
        self.assertSkips(w, "queued in the outbox")
        w.process_queue()
        self.assertSettles(w)

        g = w.send(p.ETHEREUM, 3 * E18)                  # back to HyperEVM for redemptions
        self.assertSkips(w, "in flight")
        w.deliver(g)
        self.assertSettles(w)
        w.redeem(3 * E18)
        self.assertSettles(w)
        self.assertEqual(w.total, 7 * E18)

    def test_pins_straddling_a_transfer_count_it_twice_and_are_refused(self):
        w = World()
        w.subscribe(5 * E18)
        stale_hyp = w.hyp.head                          # HyperEVM read before the send
        w.deliver(w.send(p.HYPEREVM, 5 * E18))          # Ethereum read after the arrival
        code, report, counted = w.settle(pin_hyp=stale_hyp)
        self.assertEqual(counted, 10 * E18)             # the danger: twice the fund
        self.assertEqual(code, 1)
        self.assertEqual([t["verdict"] for t in report["bridge"]["transfers"]], ["double count"])

    def test_pins_straddling_the_other_way_miss_it_and_are_refused(self):
        w = World()
        w.subscribe(5 * E18)
        stale_eth = w.eth.head                          # Ethereum read before the arrival
        w.deliver(w.send(p.HYPEREVM, 5 * E18))          # HyperEVM read after the send
        code, report, counted = w.settle(pin_eth=stale_eth)
        self.assertEqual(counted, 0)
        self.assertEqual(code, 1)
        self.assertEqual([t["verdict"] for t in report["bridge"]["transfers"]], ["in flight"])

    def test_cross_chain_payout_leaves_the_fund_on_send(self):
        w = World()
        w.subscribe(5 * E18)
        w.deliver(w.send(p.HYPEREVM, 2 * E18))
        before_payout = w.eth.head
        g = w.send(p.ETHEREUM, 2 * E18, recipient=OTHER)  # a redeemer paid on HyperEVM straight from Ethereum
        self.assertSkips(w, "in flight")                  # recipient unknown until delivered: conservative
        w.deliver(g)
        self.assertSettles(w)
        self.assertEqual(w.total, 3 * E18)
        # Ethereum read before the payout left, HyperEVM after it landed with the redeemer: still the fund's at the
        # Ethereum pin and never the fund's on HyperEVM, so counted once, not a double count.
        code, report, counted = w.settle(pin_eth=before_payout)
        self.assertEqual((code, counted), (0, 5 * E18), report["reasons"])
        self.assertEqual(sorted(t["verdict"] for t in report["bridge"]["transfers"]), ["ok", "payout"])


class BridgeEdgeTest(unittest.TestCase):
    """The cases a round trip does not reach: other users' traffic, inflows, WHYPE, the scan bound, guid case,
    unsupported destinations, broken reads and the CLI flags."""

    def transfers(self, report):
        return [(t["verdict"], t["amount"]) for t in report["bridge"]["transfers"]]

    def test_other_users_traffic_is_ignored_and_amounts_are_read(self):
        w = World()
        w.subscribe(5 * E18)
        w.noise()
        g = w.send(p.HYPEREVM, 2 * E18)
        w.noise()  # other users' receipts on Ethereum must not pass for this transfer's
        code, report, _ = w.settle()
        self.assertEqual((code, self.transfers(report)), (1, [("in flight", 2 * E18)]))
        w.deliver(g, upper=True)  # the receipt's guid in upper case
        w.noise()
        code, report, counted = w.settle()
        self.assertEqual((code, counted), (0, 5 * E18), report["reasons"])
        self.assertEqual(self.transfers(report), [("ok", 2 * E18)])

    def test_inflow_counted_on_arrival(self):
        w = World()
        w.inflow(p.ETHEREUM, 3 * E18)
        code, report, counted = w.settle()
        self.assertEqual((code, counted), (0, 3 * E18), report["reasons"])
        self.assertEqual(self.transfers(report), [("inflow", 3 * E18)])

    def test_whype_counts_as_hype_at_the_pin(self):
        w = World()
        w.subscribe(5 * E18)
        w.wrap(2 * E18)
        pin = w.hyp.head
        w.wrap(1 * E18)
        code, report, counted = w.settle(pin_hyp=pin)
        self.assertEqual((code, counted), (0, 5 * E18), report["reasons"])
        self.assertEqual(report["bridge"]["holdings"]["hyperevmWhype"], 2 * E18)

    def test_scan_starts_after_the_previous_settlement(self):
        w = World()
        w.subscribe(5 * E18)
        w.deliver(w.send(p.HYPEREVM, 2 * E18))
        w.settled()
        w.deliver(w.send(p.ETHEREUM, 1 * E18))
        code, report, counted = w.settle()
        self.assertEqual((code, counted), (0, 5 * E18), report["reasons"])
        self.assertEqual(self.transfers(report), [("ok", 1 * E18)])  # the settled 2 HYPE is not re-read

    def test_send_to_an_unsupported_chain_is_refused(self):
        w = World()
        w.subscribe(5 * E18)
        w.send(p.HYPEREVM, 1 * E18, dst_eid=30184)  # Base: not a chain the fund reads
        code, report, _ = w.settle()
        self.assertEqual(code, 1)
        self.assertEqual(self.transfers(report), [("unknown destination", 1 * E18)])

    def test_bad_bounds_and_broken_reads_are_exit_2(self):
        w = World()
        w.subscribe(5 * E18)
        w.since = {p.ETHEREUM: w.hyp.head, p.HYPEREVM: w.eth.head}  # swapped: Ethereum's bound above its head
        self.assertEqual(w.settle()[0], 2)
        w.since = {c: ch.head for c, ch in w.chain.items()}
        self.assertEqual(w.settle(pin_hyp=w.hyp.head - 1)[0], 2)  # pin before since
        for broken in ("raise", "null"):
            w2 = World()
            hyp = w2.hyp

            def flaky(method, params, hyp=hyp, broken=broken):
                if method == "eth_getLogs":
                    if broken == "raise":
                        raise RuntimeError("eth_getLogs: query timeout")
                    return None
                return hyp(method, params)
            code, report = p.preflight_verdict(w2.eth, SAFE, w2.eth.head, p.LOG_CHUNK, {
                "rpc": flaky, "pin": hyp.head, "since": hyp.head - 5, "sinceEth": w2.eth.head, "chunk": 1_000})
            self.assertEqual(code, 2, (broken, report))

    def test_cli_maps_the_flags_and_refuses_partial_ones(self):
        w = World()
        w.subscribe(5 * E18)
        g = w.send(p.HYPEREVM, 2 * E18)  # in flight: only a correctly wired run sees it
        chains = {"sim://eth": w.eth, "sim://hyp": w.hyp}
        real_eth, argv = p.eth, sys.argv
        p.eth = lambda url, method, params: chains[url](method, params)
        try:
            def run(*args):
                sys.argv = ["derive-celestia-proof.py", "--preflight", SAFE, "--eth-rpc", "sim://eth", *args]
                with self.assertRaises(SystemExit) as cm, contextlib.redirect_stdout(io.StringIO()) as out, \
                        contextlib.redirect_stderr(io.StringIO()):
                    p.main()
                return cm.exception.code, out.getvalue()
            since = ["--since-eth", str(w.since[p.ETHEREUM]), "--since-hyperevm", str(w.since[p.HYPEREVM])]
            code, out = run("--hyperevm-rpc", "sim://hyp", *since)
            self.assertEqual(code, 1)
            self.assertIn("in flight", out)
            self.assertEqual(run(*since)[0], 2)                           # bridge flags without --hyperevm-rpc
            self.assertEqual(run("--hyperevm-rpc", "sim://hyp")[0], 2)  # --hyperevm-rpc without the bounds
            w.deliver(g)
            self.assertEqual(run("--hyperevm-rpc", "sim://hyp", *since)[0], 0)
        finally:
            p.eth, sys.argv = real_eth, argv


@unittest.skipUnless(os.environ.get("DERIVE_LIVE") == "1" and os.environ.get("ALCHEMY_API_KEY"),
                     "network replay: set DERIVE_LIVE=1 and ALCHEMY_API_KEY (archive RPCs for Ethereum and HyperEVM)")
class LiveReplayTest(unittest.TestCase):
    """hype-split's real first deposit, replayed at pinned blocks on both chains: 0.12 HYPE sent from the HyperEVM
    Safe at 51,693,622 (`0x0c6e…297c`), received on Ethereum at 26,450,116 (`0xd095…cb5a`), deposited into Derive
    as action 8651 at 26,450,176, applied by the batch at 26,450,225."""

    SEND_H, RECV_E, DEPOSIT_E, BATCH_E = 51_693_622, 26_450_116, 26_450_176, 26_450_225
    # The Safe's whole bridge history (scanned from block 0 on both chains, 2026-11-27): HyperEVM sends at 51,693,622
    # and 52,030,071, Ethereum receipts at 26,450,116 and 26,477,611, nothing else. These bounds precede all of it.
    SINCE = {"eth": 26_449_000, "hyp": 51_693_000}

    def verdict(self, pin_eth, pin_hyp):
        key = os.environ["ALCHEMY_API_KEY"]
        eth_url = f"https://eth-mainnet.g.alchemy.com/v2/{key}"
        hyp_url = f"https://hyperliquid-mainnet.g.alchemy.com/v2/{key}"
        return p.preflight_verdict(lambda m, a: p.eth(eth_url, m, a), SAFE, pin_eth, p.LOG_CHUNK, {
            "rpc": lambda m, a: p.eth(hyp_url, m, a), "pin": pin_hyp, "since": self.SINCE["hyp"],
            "sinceEth": self.SINCE["eth"], "chunk": p.HYPEREVM_LOG_CHUNK})

    def transfer(self, report):
        return next(t for t in report["bridge"]["transfers"] if t["sentBlock"] == self.SEND_H)

    def test_before_the_send(self):
        code, report = self.verdict(self.RECV_E - 1, self.SEND_H - 1)
        self.assertEqual(code, 0, report.get("reasons") or report.get("error"))
        self.assertEqual(self.transfer(report)["verdict"], "ok")

    def test_mid_bridge(self):
        code, report = self.verdict(self.RECV_E - 1, self.SEND_H)
        self.assertEqual(code, 1, report.get("error"))
        self.assertEqual(self.transfer(report)["verdict"], "in flight")

    def test_arrived_on_ethereum(self):
        code, report = self.verdict(self.RECV_E, self.SEND_H + 100)
        self.assertEqual(code, 0, report.get("reasons") or report.get("error"))
        self.assertEqual(report["bridge"]["holdings"]["ethereumHype"], 12 * 10**16)

    def test_deposit_queued_in_derive(self):
        code, report = self.verdict(self.DEPOSIT_E, self.SEND_H + 100)
        self.assertEqual(code, 1, report.get("error"))
        self.assertEqual([a["actionId"] for a in report["pendingActions"]], [8651])
        self.assertEqual(report["bridge"]["holdings"]["ethereumHype"], 0)

    def test_applied_by_the_batch(self):
        code, report = self.verdict(self.BATCH_E, self.SEND_H + 100)
        self.assertEqual(code, 0, report.get("reasons") or report.get("error"))

    def test_pins_straddling_the_transfer(self):
        code, report = self.verdict(self.RECV_E, self.SEND_H - 1)
        self.assertEqual(code, 1, report.get("error"))
        self.assertEqual(self.transfer(report)["verdict"], "double count")


if __name__ == "__main__":
    unittest.main()
