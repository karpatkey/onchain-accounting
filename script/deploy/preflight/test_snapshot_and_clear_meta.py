#!/usr/bin/env python3
"""Proves snapshot_and_clear_meta clears ONLY enabled, present, non-blank meta keys.

Run with `python3 -m unittest`, and also under `python3 -O` — the preflight CI job runs `-O`, which
strips `assert` statements, so the module guards its invariants with `raise` and this suite must pass
either way (it uses unittest's own assertions, which are real method calls, not the `assert` keyword).

WHY THIS EXISTS. The clear step is destructive-adjacent: it blanks deployment-record keys so `04`
redeploys the moved meta adapters, and it must NOT touch a plain adapter, a disabled meta entry, or a
`$schema`/`$comment` config key. A silent over-clear would blank an address with no redeploy behind
it; a silent under-clear would leave `04` skipping a moved adapter. Both are exercised here.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

PREFLIGHT = Path(__file__).resolve().parent
sys.path.insert(0, str(PREFLIGHT))

import chainlib as c  # noqa: E402
import snapshot_and_clear_meta as sc  # noqa: E402


class EnabledMetaNamesTest(unittest.TestCase):
    def test_filters_disabled_and_dollar_keys(self):
        cfg = {
            "$schema": "x",
            "AaveV3InstancesMeta": {"enabled": True},
            "DisabledMeta": {"enabled": False},
            "MissingFlagMeta": {},  # no `enabled` -> treated as disabled
            "MorphoVaultsMeta": {"enabled": True},
        }
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "1.json").write_text(json.dumps(cfg))
            orig = sc.META_CONFIG_DIR
            sc.META_CONFIG_DIR = Path(d)
            try:
                names = sc.enabled_meta_names(1)
            finally:
                sc.META_CONFIG_DIR = orig
        self.assertEqual(names, ["AaveV3InstancesMeta", "MorphoVaultsMeta"])

    def test_no_config_returns_empty(self):
        with tempfile.TemporaryDirectory() as d:
            orig = sc.META_CONFIG_DIR
            sc.META_CONFIG_DIR = Path(d)
            try:
                self.assertEqual(sc.enabled_meta_names(999999), [])
            finally:
                sc.META_CONFIG_DIR = orig

    def test_non_object_entry_raises(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "1.json").write_text(json.dumps({"Bad": "not-an-object"}))
            orig = sc.META_CONFIG_DIR
            sc.META_CONFIG_DIR = Path(d)
            try:
                with self.assertRaises(RuntimeError):
                    sc.enabled_meta_names(1)
            finally:
                sc.META_CONFIG_DIR = orig


class PlanForTest(unittest.TestCase):
    def _run(self, record, enabled):
        orig_dep, orig_names = c.deployment, sc.enabled_meta_names
        c.deployment = lambda cid: json.loads(json.dumps(record))
        sc.enabled_meta_names = lambda cid: enabled
        try:
            return sc.plan_for(1)
        finally:
            c.deployment, sc.enabled_meta_names = orig_dep, orig_names

    def test_clears_present_enabled_nonblank_only(self):
        record = {"balanceAdapters": {"A": "0xaaa", "B": "0xbbb", "Plain": "0xccc"}}
        new, cleared, warnings = self._run(record, ["A", "B"])
        self.assertEqual(new["balanceAdapters"]["A"], "")
        self.assertEqual(new["balanceAdapters"]["B"], "")
        self.assertEqual(new["balanceAdapters"]["Plain"], "0xccc")  # a non-meta key is untouched
        self.assertEqual(len(cleared), 2)
        self.assertEqual(warnings, [])

    def test_warns_on_absent_and_blank_never_clears_them(self):
        record = {"balanceAdapters": {"A": "", "Plain": "0xccc"}}
        new, cleared, warnings = self._run(record, ["A", "Missing"])
        self.assertEqual(cleared, [])  # A already blank, Missing absent -> nothing cleared
        self.assertEqual(len(warnings), 2)
        self.assertEqual(new["balanceAdapters"]["Plain"], "0xccc")

    def test_missing_adapters_section_raises(self):
        with self.assertRaises(RuntimeError):
            self._run({"noAdapters": {}}, ["A"])


class ApplyChainTest(unittest.TestCase):
    """A second --apply must NOT overwrite the pre-swap snapshot with the already-cleared record (Copilot)."""

    def test_rerun_preserves_old_address_snapshot(self):
        old = {"balanceAdapters": {"A": "0xOLD", "Plain": "0xppp"}}
        cleared = {"balanceAdapters": {"A": "", "Plain": "0xppp"}}
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            (tmp / "1.json").write_text(json.dumps(old))
            orig_dir, orig_dep, orig_names = c.DEPLOY_DIR, c.deployment, sc.enabled_meta_names
            c.DEPLOY_DIR = tmp
            c.deployment = lambda cid: json.loads((tmp / f"{cid}.json").read_text())
            sc.enabled_meta_names = lambda cid: ["A"]
            try:
                # first apply: writes the snapshot (OLD addresses) + the cleared record
                first = sc.apply_chain(1, cleared)
                self.assertTrue(first)
                snap = json.loads((tmp / "1.pre-swap.json").read_text())
                self.assertEqual(snap["balanceAdapters"]["A"], "0xOLD")
                self.assertEqual(json.loads((tmp / "1.json").read_text())["balanceAdapters"]["A"], "")

                # second apply, now that the record is already cleared: snapshot must be PRESERVED
                second = sc.apply_chain(1, cleared)
                self.assertFalse(second)
                snap2 = json.loads((tmp / "1.pre-swap.json").read_text())
                self.assertEqual(snap2["balanceAdapters"]["A"], "0xOLD")  # NOT overwritten with ""
            finally:
                c.DEPLOY_DIR, c.deployment, sc.enabled_meta_names = orig_dir, orig_dep, orig_names


class PreservedSnapshotCheckTest(unittest.TestCase):
    """A preserved snapshot must be fresh and belong to the current record, else it is refused (claude-review)."""

    NOW = 2_000_000_000
    RECORD = {"NAVCalculatorProxy": "0xPROXY", "balanceAdapters": {"A": "", "Plain": "0xppp"}}

    def _snap(self, **over):
        snap = {"NAVCalculatorProxy": "0xPROXY", "balanceAdapters": {"A": "0xOLD", "Plain": "0xppp"},
                sc.PRE_SWAP_META_KEY: {"capturedAtUnix": self.NOW - 3600}}
        snap.update(over)
        return snap

    def _check(self, snap):
        orig = sc.enabled_meta_names
        sc.enabled_meta_names = lambda cid: ["A"]
        try:
            sc.check_preserved_snapshot(1, snap, self.RECORD, now=self.NOW)
        finally:
            sc.enabled_meta_names = orig

    def test_fresh_consistent_snapshot_is_accepted(self):
        self._check(self._snap())  # meta key A differs (expected); must not raise

    def test_stale_snapshot_is_refused(self):
        with self.assertRaises(RuntimeError):
            self._check(self._snap(**{sc.PRE_SWAP_META_KEY: {"capturedAtUnix": self.NOW - 8 * 24 * 3600}}))

    def test_unstamped_snapshot_is_refused(self):
        snap = self._snap(); del snap[sc.PRE_SWAP_META_KEY]
        with self.assertRaises(RuntimeError):
            self._check(snap)

    def test_different_proxy_is_refused(self):
        with self.assertRaises(RuntimeError):
            self._check(self._snap(NAVCalculatorProxy="0xOTHER"))

    def test_non_meta_adapter_drift_is_refused(self):
        with self.assertRaises(RuntimeError):
            self._check(self._snap(balanceAdapters={"A": "0xOLD", "Plain": "0xDIFFERENT"}))


if __name__ == "__main__":
    unittest.main()
