#!/usr/bin/env python3
"""Proves the `KEEP` invariant in reset_deployment_records.py is a mechanism, not a comment.

Run with `python3 -m unittest`, and also under `python3 -O` — see WHY -O MATTERS below.

WHY THIS EXISTS. `KEEP` names the three bridge keys the redeploy reset must never touch. For its whole
life it appeared exactly once in the repo: its own assignment. Nothing read it. The keys survived only
because they happen to be absent from `CLEAR_TOP` and `CLEAR_SECTIONS` — coincidence, not enforcement —
while the name told every reviewer the case was handled. Issue #303 catalogued it as "dead code that
reads as coverage": a guard whose absence is undetectable because nothing exercises it.

Wiring the invariant without a test would reproduce the same defect one level up, so this suite asserts
the guard FIRES, not merely that the module imports.

WHY -O MATTERS. The preflight CI job runs `python3 -O -m unittest` (foundry.yml). `-O` strips `assert`
statements, so an invariant written as a bare `assert` would silently evaporate under the exact flag CI
uses — a guard that disappears in CI is the defect it was meant to prevent. The module therefore raises
explicitly, and `test_guard_survives_O` pins that choice so a future edit cannot quietly downgrade it.
"""

import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

PREFLIGHT = Path(__file__).resolve().parent
sys.path.insert(0, str(PREFLIGHT))

import reset_deployment_records as rdr  # noqa: E402


class KeepInvariant(unittest.TestCase):
    def test_keep_is_disjoint_from_everything_mutated(self):
        """The property the name has always claimed, now checked."""
        mutated = set(rdr.CLEAR_TOP) | set(rdr.CLEAR_SECTIONS) | rdr.CREATE_IF_ABSENT
        self.assertEqual(
            rdr.KEEP & mutated,
            set(),
            "KEEP names keys this module also mutates",
        )

    def test_bridge_keys_are_actually_in_keep(self):
        """A KEEP emptied to make the invariant pass would satisfy it vacuously."""
        self.assertEqual(
            rdr.KEEP,
            {"BridgeEscrowImplementation", "BridgeEscrowProxy", "bridgeAdapters"},
            "the bridge stack is out of redeploy scope and must stay named here",
        )

    def _import_with_patch(self, patch: str, flags: list[str]) -> subprocess.CompletedProcess:
        """Imports the module in a subprocess after applying `patch` to its constants."""
        prog = textwrap.dedent(
            f"""
            import sys
            sys.path.insert(0, {str(PREFLIGHT)!r})
            import builtins, importlib.util
            spec = importlib.util.spec_from_file_location(
                "rdr_patched", {str(PREFLIGHT / "reset_deployment_records.py")!r}
            )
            src = open(spec.origin).read()
            src = src.replace({patch!r}, "PATCHED_MARKER")
            assert "PATCHED_MARKER" in src, "patch target not found in module source"
            exec(compile(src.replace("PATCHED_MARKER", {patch!r}.replace(
                'CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]',
                'CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds", "bridgeAdapters"]')),
                spec.origin, "exec"), {{"__name__": "rdr_patched"}})
            """
        )
        return subprocess.run(
            [sys.executable, *flags, "-c", prog], capture_output=True, text=True, cwd=PREFLIGHT
        )

    def test_guard_fires_when_a_protected_key_is_added_to_clear_sections(self):
        """The concrete regression from #303: adding bridgeAdapters to CLEAR_SECTIONS must be rejected."""
        r = self._import_with_patch('CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]', [])
        self.assertNotEqual(r.returncode, 0, "importing with bridgeAdapters in CLEAR_SECTIONS must fail")
        self.assertIn("KEEP claims to protect keys this module also mutates", r.stderr)
        self.assertIn("bridgeAdapters", r.stderr)

    def test_guard_survives_O(self):
        """Same patch under -O. A bare `assert` would be stripped and this would pass silently."""
        r = self._import_with_patch('CLEAR_SECTIONS = ["balanceAdapters", "customPriceFeeds"]', ["-O"])
        self.assertNotEqual(
            r.returncode, 0, "guard vanished under -O, which is exactly how CI runs the preflight suite"
        )
        self.assertIn("bridgeAdapters", r.stderr)


if __name__ == "__main__":
    unittest.main()
