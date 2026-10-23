#!/usr/bin/env python3
"""Pins adr0029_census.py's verdicts offline: a fake reader serves hand-encoded ABI replies, no network.
Run with `python3 -m unittest` and under `python3 -O` (the CI flag).

The two properties most worth pinning: Rule 1 FAILS on a feed that is still a pre-rollout address (otherwise the
census passes before anything is deployed, because the record still holds the live addresses), and an unreadable
reply is an ERROR, never a silent pass.
"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import adr0029_census as ac  # noqa: E402

PROXY = ac.NAV_PROXY
A1 = "0x" + "a1" * 20
A2 = "0x" + "a2" * 20
NEW = "0x" + "11" * 20  # a feed in this tree's record
OLD = "0x" + "22" * 20  # a feed in the pre-rollout record
GHOST = "0x" + "33" * 20  # in neither
CL = "0x" + "44" * 20  # a Chainlink feed
IMPL = "0x" + "55" * 20
SEQ = "0x" + "66" * 20
CHAINLINK, REDSTONE, CUSTOM = 0, 1, 3


def _w(x: int) -> str:
    return x.to_bytes(32, "big").hex()


def _a(addr: str) -> str:
    return addr[2:].lower().rjust(64, "0")


def enc_assets(assets: list[str]) -> str:
    """ABI-encode Asset[] = tuple(address, string, uint8)[] (symbol "X", decimals 18)."""
    elems = [_a(a) + _w(96) + _w(18) + _w(1) + "58".ljust(64, "0") for a in assets]  # each 5 words
    head, off = "", 32 * len(assets)
    for e in elems:
        head += _w(off)
        off += len(e) // 2
    return "0x" + _w(32) + _w(len(assets)) + head + "".join(elems)


def enc_feeds(cfgs: list[tuple[str, int, int]]) -> str:
    """ABI-encode PriceFeedConfig[] = (address, uint8 decimals, uint8 priceType, uint256 heartbeat)[]."""
    return "0x" + _w(32) + _w(len(cfgs)) + "".join(_a(f) + _w(8) + _w(t) + _w(hb) for f, t, hb in cfgs)


class Fake:
    def __init__(self, assets, primaries, monitors, nav_of=None, broken=()):
        self.assets, self.p, self.m, self.nav_of, self.broken = assets, primaries, monitors, nav_of or {}, set(broken)

    def storage(self, addr, slot):
        return "0x" + _a(IMPL)

    def call(self, to, data):
        sel, arg = data[:10], data[10:]
        if to == PROXY and sel in self.broken:
            raise RuntimeError("rpc error")
        if to == PROXY and sel == ac.SEL_GET_REGISTERED_ASSETS:
            return enc_assets(self.assets)
        if to == PROXY and sel == ac.SEL_SEQUENCER_FEED:
            return "0x" + _a(SEQ)
        asset = "0x" + arg[-40:]
        if to == PROXY and sel == ac.SEL_GET_PRICE_FEEDS:
            return enc_feeds(self.p.get(asset, []))
        if to == PROXY and sel == ac.SEL_GET_MONITOR_FEEDS:
            return enc_feeds(self.m.get(asset, []))
        if sel == ac.SEL_NAV:
            if to in self.nav_of:
                return "0x" + _a(self.nav_of[to])
            raise RuntimeError("execution reverted")
        raise AssertionError(f"unexpected call {to} {sel}")


def errs(f):
    return [m for lvl, m in f if lvl == ac.ERROR]


class Census(unittest.TestCase):
    def test_all_new_feeds_pass(self):
        r = Fake([A1, A2], {A1: [(NEW, CUSTOM, 3600)], A2: [(CL, CHAINLINK, 86400)]}, {A1: [(CL, CHAINLINK, 3600)]})
        f, s = ac.census(1, r, {NEW}, {OLD})
        self.assertEqual(errs(f), [])
        self.assertEqual(s["assets"], 2)
        self.assertEqual(s["impl"], IMPL)
        self.assertEqual(s["sequencerFeed"], SEQ)
        self.assertEqual([c["feed"] for c in s["custom"]], [NEW])

    def test_pre_rollout_feed_is_an_error_even_if_still_in_the_record(self):
        # Before 03 runs the record still holds the live (old) address: it is in BOTH sets, and must still fail.
        r = Fake([A1], {A1: [(OLD, CUSTOM, 3600)]}, {})
        f, _ = ac.census(1, r, {OLD}, {OLD})
        self.assertTrue(any("PRE-ROLLOUT" in m for m in errs(f)))

    def test_custom_monitor_is_checked_too(self):
        r = Fake([A1], {A1: [(CL, CHAINLINK, 3600)]}, {A1: [(OLD, CUSTOM, 86400)]})
        f, _ = ac.census(1, r, {NEW}, {OLD})
        self.assertTrue(any("monitor[0]" in m and "PRE-ROLLOUT" in m for m in errs(f)))

    def test_unknown_custom_feed_is_an_error(self):
        r = Fake([A1], {A1: [(GHOST, CUSTOM, 3600)]}, {})
        f, _ = ac.census(1, r, {NEW}, {OLD})
        self.assertTrue(any("not in this tree's customPriceFeeds" in m for m in errs(f)))

    def test_custom_type_value_is_three(self):
        # Pins the enum: Chainlink 0, Redstone 1, API3 2, Custom 3. A wrong constant would wave every feed through.
        self.assertEqual(ac.CUSTOM, 3)
        r = Fake([A1], {A1: [(GHOST, 2, 3600)]}, {})  # API3, not Custom
        self.assertEqual(errs(ac.census(1, r, {NEW}, {OLD})[0]), [])

    def test_nav_sourced_feed_is_marked(self):
        r = Fake([A1], {A1: [(OLD, CUSTOM, 3600)]}, {}, nav_of={OLD: PROXY})
        f, s = ac.census(1, r, {NEW}, {OLD})
        self.assertTrue(s["custom"][0]["readsNav"])
        self.assertTrue(any("sequencer hazard" in m for m in errs(f)))

    def test_rule2_primary_heartbeat_at_7_days_is_an_error(self):
        r = Fake([A1], {A1: [(CL, CHAINLINK, ac.MAX_STALE_PRICE_AGE)]}, {})
        self.assertTrue(any("RULE 2" in m for m in errs(ac.census(1, r, {NEW}, {OLD})[0])))

    def test_rule2_below_cap_uint_max_and_monitors_pass(self):
        r = Fake([A1, A2], {A1: [(CL, CHAINLINK, ac.MAX_STALE_PRICE_AGE - 1)], A2: [(CL, REDSTONE, ac.UINT256_MAX)]},
                 {A1: [(CL, CHAINLINK, 10 * ac.MAX_STALE_PRICE_AGE)]})
        self.assertEqual(errs(ac.census(1, r, {NEW}, {OLD})[0]), [])

    def test_unreadable_asset_list_is_an_error(self):
        r = Fake([A1], {}, {}, broken={ac.SEL_GET_REGISTERED_ASSETS})
        f, _ = ac.census(1, r, {NEW}, {OLD})
        self.assertTrue(any("NOTHING was checked" in m for m in errs(f)))

    def test_unreadable_feed_list_is_an_error(self):
        r = Fake([A1], {}, {}, broken={ac.SEL_GET_PRICE_FEEDS})
        self.assertTrue(any("NOT checked" in m for m in errs(ac.census(1, r, {NEW}, {OLD})[0])))

    def test_truncated_reply_is_an_error(self):
        class Short(Fake):
            def call(self, to, data):
                out = super().call(to, data)
                return out[:-64] if data.startswith(ac.SEL_GET_PRICE_FEEDS) else out
        r = Short([A1], {A1: [(NEW, CUSTOM, 3600)]}, {})
        self.assertTrue(any("NOT checked" in m for m in errs(ac.census(1, r, {NEW}, {OLD})[0])))

    def test_transport_error_text_never_carries_the_rpc_url(self):
        secret = "https://eth-mainnet.g.alchemy.com/v2/SuperSecretKey1234567890abcdefgh"

        class Leaky(Fake):
            def call(self, to, data):
                if data.startswith(ac.SEL_GET_PRICE_FEEDS):
                    raise RuntimeError(f"eth_call failed after 4 attempts: HTTPSConnectionPool(host='eth-mainnet.g."
                                       f"alchemy.com', port=443): Max retries exceeded with url: {secret[33:]} (caused by x) {secret}")
                return super().call(to, data)

            def storage(self, addr, slot):
                raise RuntimeError(f"eth_getStorageAt failed: Failed to resolve 'eth-mainnet.g.alchemy.com' (x); "
                                   f"Invalid URL 'eth-mainnet.g.alchemy.com/v2/SuperSecretKey1': No scheme supplied; "
                                   f"No connection adapters were found for 'wss://x.io/SuperSecretKey2'")
        f, _ = ac.census(1, Leaky([A1], {}, {}), {NEW}, {OLD})
        text = " ".join(m for _, m in f)
        self.assertTrue(errs(f), "the failure is still reported")
        for leak in ("SuperSecretKey", "alchemy.com", "/v2/"):
            self.assertNotIn(leak, text)

    def test_live_only_lists_custom_feeds_as_warnings(self):
        r = Fake([A1], {A1: [(OLD, CUSTOM, 518_400)]}, {})
        f, _ = ac.census(4663, r, None, None)
        self.assertEqual(errs(f), [])
        self.assertTrue(any(lvl == ac.WARN and "live-only" in m for lvl, m in f))

    def test_record_addresses_skip_notes_and_blanks(self):
        rec = {"customPriceFeeds": {"$x": "note", "a": NEW, "b": ""}, "retiredCustomPriceFeeds": {"c": OLD}}
        self.assertEqual(ac.record_addresses(rec), {NEW})
        self.assertEqual(ac.all_record_addresses(rec), {NEW, OLD})


class DecodersAgainstEthAbi(unittest.TestCase):
    """Cross-checks the hand decoders against eth_abi where it is installed (not on CI, which has `requests` only)."""

    def setUp(self):
        try:
            import eth_abi  # noqa: F401
        except ImportError:
            self.skipTest("eth_abi not installed")

    def test_assets_and_feeds_match_eth_abi(self):
        from eth_abi import encode
        assets = [(A1, "WETH", 18), (A2, "a much longer symbol than one word, over 32 bytes long", 6)]
        raw = "0x" + encode(["(address,string,uint8)[]"], [assets]).hex()
        self.assertEqual(ac.decode_assets(raw), [A1, A2])
        cfgs = [(NEW, 8, CUSTOM, 3600), (CL, 8, CHAINLINK, ac.UINT256_MAX)]
        raw = "0x" + encode(["(address,uint8,uint8,uint256)[]"], [cfgs]).hex()
        self.assertEqual(ac.decode_feed_configs(raw), [{"feed": NEW, "type": CUSTOM, "heartbeat": 3600},
                                                       {"feed": CL, "type": CHAINLINK, "heartbeat": ac.UINT256_MAX}])


if __name__ == "__main__":
    unittest.main()
