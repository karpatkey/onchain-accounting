#!/usr/bin/env python3
"""Pins retire_custom_feeds.py to its one job: blank the named customPriceFeeds keys and archive them, and
touch NOTHING else. Run with `python3 -m unittest` and under `python3 -O` (the CI flag): the guards raise
instead of asserting, so they must survive -O.

The property that matters most is the one the from-scratch reset tool lacks: the NAV proxy, implementation,
libraries, registry and every balance adapter come out byte-identical.
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PREFLIGHT = Path(__file__).resolve().parent
sys.path.insert(0, str(PREFLIGHT))

import retire_custom_feeds as rcf  # noqa: E402

A1 = "0x1111111111111111111111111111111111111111"
A2 = "0x2222222222222222222222222222222222222222"
MON = "0x3333333333333333333333333333333333333333"


def record():
    return {
        "NAVCalculatorProxy": "0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214",
        "NAVCalculatorImplementation": "0xA7243DCDF7e4D6f8FA20A9F022186C0d0778C2b6",
        "PriceFeedLib": "0x0f913658d70BB19b7B42eF9926c3df7c70fafCf2",
        "balanceAdapters": {"ERC20Default": "0x4Bc39Dce61245F5A63189d1FA03E6D76646f1EE6"},
        "customPriceFeeds": {"wstETH": A1, "sDAI": A2, "stETHCrossRate": MON, "stETH": ""},
    }


class Retire(unittest.TestCase):
    def test_only_named_keys_change_and_nav_stack_is_identical(self):
        before = record()
        after = rcf.apply(before, rcf.plan(before, ["wstETH", "sDAI"]), "ADR 0029 redeploy.", "2026-10-21")
        for key in ("NAVCalculatorProxy", "NAVCalculatorImplementation", "PriceFeedLib", "balanceAdapters"):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(after["customPriceFeeds"], {"wstETH": "", "sDAI": "", "stETHCrossRate": MON, "stETH": ""})
        self.assertEqual(after["retiredCustomPriceFeeds"]["wstETH"], A1)
        self.assertEqual(after["retiredCustomPriceFeeds"]["sDAI"], A2)
        self.assertIn("RETIRED 2026-10-21", after["retiredCustomPriceFeeds"]["$wstETH"])
        self.assertEqual(rcf.changed_sections(before, after), {"customPriceFeeds", "retiredCustomPriceFeeds"})
        self.assertEqual(before, record(), "apply() must not mutate its input")

    def test_refuses_top_level_balance_adapter_unknown_blank_and_duplicate(self):
        r = record()
        for bad in (["NAVCalculatorProxy"], ["ERC20Default"], ["nope"], ["stETH"], ["wstETH", "wstETH"], ["$x"]):
            with self.assertRaises(rcf.RetireError, msg=bad):
                rcf.plan(r, bad)

    def test_prior_retirement_is_kept_not_overwritten(self):
        r = record()
        r["retiredCustomPriceFeeds"] = {"wstETH": "0x9999999999999999999999999999999999999999", "$wstETH": "old"}
        after = rcf.apply(r, rcf.plan(r, ["wstETH"]), "again.", "2026-10-21")
        arch = after["retiredCustomPriceFeeds"]
        self.assertEqual(arch["wstETH"], A1)
        self.assertEqual(arch["wstETH@2026-10-21"], "0x9999999999999999999999999999999999999999")
        self.assertEqual(arch["$wstETH@2026-10-21"], "old")

    def test_same_day_retirements_keep_every_address(self):
        # Copilot on #354: retiring deployments A, B and C of one key on the same date used to keep only B under
        # `<key>@<date>` (A was overwritten). Every retired address must survive, in order.
        a, b, c = "0x" + "a" * 40, "0x" + "b" * 40, "0x" + "c" * 40
        r = record()
        for addr in (a, b, c):
            r["customPriceFeeds"]["wstETH"] = addr
            r = rcf.apply(r, rcf.plan(r, ["wstETH"]), "retry.", "2026-10-23")
        arch = r["retiredCustomPriceFeeds"]
        self.assertEqual(arch["wstETH"], c)
        self.assertEqual(arch["wstETH@2026-10-23"], a)
        self.assertEqual(arch["wstETH@2026-10-23#2"], b)
        self.assertIn("$wstETH@2026-10-23", arch)
        self.assertIn("$wstETH@2026-10-23#2", arch)
        self.assertEqual({v for k, v in arch.items() if not k.startswith("$")}, {a, b, c})

    def test_cli_dry_run_writes_nothing_and_apply_writes(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "1.json"
            p.write_text(json.dumps(record()))
            base = [sys.executable, str(PREFLIGHT / "retire_custom_feeds.py"), "--chain", "1", "--keys", "wstETH",
                    "--reason", "test.", "--record", str(p)]
            self.assertEqual(subprocess.run(base, capture_output=True).returncode, 0)
            self.assertEqual(json.loads(p.read_text()), record(), "dry run must not write")
            self.assertEqual(subprocess.run(base + ["--apply"], capture_output=True).returncode, 0)
            self.assertEqual(json.loads(p.read_text())["customPriceFeeds"]["wstETH"], "")
            bad = subprocess.run(base[:5] + ["NAVCalculatorProxy"] + base[6:], capture_output=True)
            self.assertEqual(bad.returncode, 2)

    def test_guards_survive_O(self):
        code = ("import sys; sys.path.insert(0, %r); import retire_custom_feeds as r\n"
                "try:\n r.plan({'customPriceFeeds': {}}, ['x'])\nexcept r.RetireError: print('raised')") % str(PREFLIGHT)
        out = subprocess.run([sys.executable, "-O", "-c", code], capture_output=True, text=True).stdout
        self.assertIn("raised", out)


if __name__ == "__main__":
    unittest.main()
