#!/usr/bin/env python3
"""Pins redstone_declared_heartbeats.py's verdicts, offline: a synthetic config tree under a temporary REPO and an
injected manifest fetch. Run with `python3 -m unittest` and under `python3 -O` (the CI flag).

The custom-feed-leg path (issue #356) is the one most worth pinning: a RedStone feed used INSIDE a custom feed is
invisible to the nav-config rows, and a leg found in neither catalogue must fail loudly — that is how a sunset
RedStone feed looks, and silently assuming "it must be a Chainlink leg" hid two dead monitors.
"""

import json
import sys
import tempfile
import unittest
from pathlib import Path

PREFLIGHT = Path(__file__).resolve().parent
sys.path.insert(0, str(PREFLIGHT))

import redstone_declared_heartbeats as rdh  # noqa: E402

RS = "0x" + "aa" * 20  # a RedStone feed declared at 43200 by the fake manifest
CL = "0x" + "bb" * 20  # a Chainlink feed in the Chainlink snapshot
GHOST = "0x" + "cc" * 20  # in neither catalogue
DEAD = "0x" + "dd" * 20  # in neither, but recorded as an exception


def _manifest(_path):
    return {"updateTriggers": {"timeSinceLastUpdateInMilliseconds": 86_400_000},
            "priceFeeds": {"X": {"priceFeedAddress": RS,
                                 "updateTriggersOverrides": {"timeSinceLastUpdateInMilliseconds": 43_200_000}}}}


class CustomFeedLegs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "script/config/nav-config/assets-and-price-feeds").mkdir(parents=True)
        (root / "script/config/contracts-deployment-config/custom-price-feeds").mkdir(parents=True)
        (root / "script/deploy/preflight").mkdir(parents=True)
        (root / "script/config/nav-config/assets-and-price-feeds/1.json").write_text("{}")
        (root / "script/deploy/preflight/chainlink_declared_heartbeats.json").write_text(
            json.dumps({"chains": {"1": {CL: {"declaredHeartbeat": 3600}}}}))
        self.root = root
        self._repo, self._exc, self._man = rdh.REPO, dict(rdh.UNCATALOGUED_EXCEPTIONS), dict(rdh.MANIFESTS)
        rdh.REPO = root
        rdh.MANIFESTS = {"1": ["fake.json"]}
        rdh.UNCATALOGUED_EXCEPTIONS.clear()
        rdh.UNCATALOGUED_EXCEPTIONS[("1", DEAD)] = "sunset; recorded"

    def tearDown(self):
        rdh.REPO = self._repo
        rdh.MANIFESTS = self._man
        rdh.UNCATALOGUED_EXCEPTIONS.clear()
        rdh.UNCATALOGUED_EXCEPTIONS.update(self._exc)
        self.tmp.cleanup()

    def _feeds(self, feeds):
        (self.root / "script/config/contracts-deployment-config/custom-price-feeds/1.json").write_text(
            json.dumps(feeds))
        return rdh.findings("1", fetch=_manifest)

    def _errs(self, got):
        return [m for lvl, m in got if lvl == rdh.ERROR]

    def test_redstone_leg_at_declared_is_clean(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"yToXFeed": RS, "yToXHeartbeat": "43200"}}})
        self.assertEqual(got, [])

    def test_redstone_leg_mismatch_is_an_error(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"yToXFeed": RS, "yToXHeartbeat": "86400"}}})
        self.assertTrue(any("MISMATCH" in m and "43200" in m for m in self._errs(got)))

    def test_chainlink_leg_is_left_to_the_chainlink_guard(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"rateChainlink": CL, "rateHeartbeat": "3600"}}})
        self.assertEqual(got, [])

    def test_leg_in_neither_catalogue_is_an_error(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"yToXFeed": GHOST, "yToXHeartbeat": "86400"}}})
        self.assertTrue(any("NO declared cadence" in m for m in self._errs(got)))

    def test_recorded_exception_is_a_warn_not_an_error(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"yToXFeed": DEAD, "yToXHeartbeat": "86400"}}})
        self.assertEqual(self._errs(got), [])
        self.assertTrue(any(lvl == rdh.WARN and "RECORDED EXCEPTION" in m for lvl, m in got))

    def test_only_enabled_true_entries_are_read(self):
        for flag in (False, None):
            entry = {"constructor": {"yToXFeed": GHOST, "yToXHeartbeat": "86400"}}
            if flag is not None:
                entry["enabled"] = flag
            self.assertEqual(self._feeds({"F": entry}), [], msg=f"enabled={flag!r}")

    def test_unpaired_heartbeat_is_reported(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {"oddHeartbeat": "86400", "otherFeed": RS}}})
        self.assertTrue(any(lvl == rdh.ERROR and "NOT checked" in m for lvl, m in got))

    def test_ambiguous_stem_is_reported(self):
        got = self._feeds({"F": {"enabled": True, "constructor": {
            "rateHeartbeat": "43200", "rateA": RS, "rateB": GHOST}}})
        self.assertTrue(any(lvl == rdh.ERROR and "2 address keys" in m for lvl, m in got))

    def test_top_level_key_wins_over_constructor(self):
        # The deployer resolves `.<feed>.<key>` before `.<feed>.constructor.<key>`; the guard must check that value.
        got = self._feeds({"F": {"enabled": True, "yToXHeartbeat": "86400",
                                 "constructor": {"yToXFeed": RS, "yToXHeartbeat": "43200"}}})
        self.assertTrue(any("MISMATCH" in m for m in self._errs(got)))

    def test_missing_nav_config_still_checks_custom_legs(self):
        (self.root / "script/config/nav-config/assets-and-price-feeds/1.json").unlink()
        got = self._feeds({"F": {"enabled": True, "constructor": {"yToXFeed": RS, "yToXHeartbeat": "86400"}}})
        self.assertTrue(any("MISMATCH" in m for m in self._errs(got)))

    def test_missing_custom_feed_file_is_fine(self):
        (self.root / "script/config/contracts-deployment-config/custom-price-feeds").rmdir()
        self.assertEqual(rdh.findings("1", fetch=_manifest), [])

    def test_unfetched_manifest_still_fails_closed(self):
        def _boom(_path):
            raise OSError("offline")
        (self.root / "script/config/contracts-deployment-config/custom-price-feeds/1.json").write_text(
            json.dumps({"F": {"enabled": True, "constructor": {"yToXFeed": RS, "yToXHeartbeat": "43200"}}}))
        got = rdh.findings("1", fetch=_boom)
        self.assertTrue(any("could NOT be fetched" in m for m in self._errs(got)))


if __name__ == "__main__":
    unittest.main()
