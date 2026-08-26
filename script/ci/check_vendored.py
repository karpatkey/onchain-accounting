#!/usr/bin/env python3
"""Drift detector for single-file vendored dependencies (ADR 0024).

A vendored file is a VERBATIM copy of an upstream file at a pinned revision. The value of that
promise is entirely in it staying true: the moment someone edits the copy, a "verifiable copy"
silently becomes a "maintained fork" and the header turns into a lie that nothing checks.

Three checks, deliberately asymmetric:

  1. COVERAGE (hard, offline). Every file in the tree carrying a "Vendored VERBATIM" header must
     appear in MANIFEST. Deleting a manifest row must not silently drop a file from the guard.
  2. MANIFEST (hard, offline). The normalised body hash of each vendored file must equal the
     recorded hash. Catches a local edit with no network involved.
  3. UPSTREAM (fetches raw.githubusercontent.com at the pinned rev). Catches a manifest hash that
     was updated to match a local edit, and a header rev that does not correspond to the bytes.
     Soft-skips ONLY on a network/transport failure, and hard-fails on a mismatch.

The asymmetry matters: this repo has already shipped one incident where a guard passed because its
input was stale, so the offline checks are never allowed to be the thing that gets skipped.

WHY THE NORMALISER IS A TOKENISER AND NOT A grep
An earlier version of this guard stripped comments with a line-anchored regex. That is not merely
imprecise, it is exploitable: `/**/` is a legal empty Solidity comment, so a line beginning
`/**/ uint256 injectedField;` is compiler-visible code that a leading-character match erases. Such a
line was demonstrably invisible to BOTH halves of the guard at once — the offline hash matched
because the line was stripped locally, and the upstream comparison matched because the same
normaliser was applied to both sides — while solc saw a struct with an extra field. That is exactly
the ABI drift this file exists to prevent, so comments are now removed by scanning tokens, with
string and comment state tracked properly.

Usage:
  script/ci/check_vendored.py             verify (this is what CI runs)
  script/ci/check_vendored.py --update    rewrite the recorded hashes; use ONLY when deliberately
                                          re-vendoring at a NEW upstream rev, never to silence a
                                          failure
  script/ci/check_vendored.py --self-test prove the normaliser and the guard actually fire
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# path -> (upstream_repo, upstream_path, pinned_rev, expected_body_sha256)
MANIFEST: dict[str, tuple[str, str, str, str]] = {
    "src/bridge/adapters/lib/OptimismTypes.sol": (
        "ethereum-optimism/optimism",
        "packages/contracts-bedrock/src/libraries/Types.sol",
        "f707883038d527cbf1e9f8ea513fe33255deadbc",
        "ecb592ac17aa61cbbb7c3d9f35f4720ba21c490f5948c55489bde827727bab81",
    ),
}

# Marker every vendored file carries; used for the coverage check.
VENDOR_MARKER = "Vendored VERBATIM"


class DriftError(Exception):
    pass


def strip_comments(src: str) -> str:
    """Remove Solidity comments, tracking string and comment state.

    Deliberately a character scanner rather than a regex: the point is that code sharing a line with
    a comment survives, and that a `//` inside a string literal is not treated as a comment.
    """
    out: list[str] = []
    i, n = 0, len(src)
    in_line = in_block = False
    quote: str | None = None

    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if in_line:
            if c == "\n":
                in_line = False
                out.append(c)
            i += 1
        elif in_block:
            if c == "*" and nxt == "/":
                in_block = False
                i += 2
            else:
                # keep newlines so line structure (and blank-line stripping) stays sane
                if c == "\n":
                    out.append(c)
                i += 1
        elif quote is not None:
            out.append(c)
            if c == "\\":                      # escape: consume the next char verbatim
                if i + 1 < n:
                    out.append(nxt)
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
        else:
            if c in ("'", '"'):
                quote = c
                out.append(c)
                i += 1
            elif c == "/" and nxt == "/":
                in_line = True
                i += 2
            elif c == "/" and nxt == "*":
                in_block = True
                i += 2
            else:
                out.append(c)
                i += 1

    if in_block or quote is not None:
        raise DriftError("unterminated comment or string literal while normalising")
    return "".join(out)


def normalise(src: str) -> str:
    """Comment-free, blank-line-free, trailing-whitespace-free body."""
    stripped = strip_comments(src)
    lines = [ln.rstrip() for ln in stripped.splitlines()]
    body = [ln for ln in lines if ln.strip()]
    if not body:
        # An empty normalisation must be a loud failure, not a hash of "".
        raise DriftError("file normalises to nothing (empty or comment-only) — refusing to hash it")
    return "\n".join(body) + "\n"


def body_hash(src: str) -> str:
    return hashlib.sha256(normalise(src).encode()).hexdigest()


def discover_vendored() -> set[str]:
    """Every tracked .sol file carrying the vendored marker."""
    found = set()
    for path in list(ROOT.glob("src/**/*.sol")) + list(ROOT.glob("script/**/*.sol")):
        try:
            if VENDOR_MARKER in path.read_text(errors="ignore"):
                found.add(str(path.relative_to(ROOT)))
        except OSError:
            continue
    return found


def fetch_upstream(repo: str, upath: str, rev: str) -> str | None:
    url = f"https://raw.githubusercontent.com/{repo}/{rev}/{upath}"
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return resp.read().decode()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None


def do_update() -> int:
    """Rewrite the recorded hashes in place, substituting whatever is currently there."""
    text = Path(__file__).read_text()
    for rel, (_repo, _upath, _rev, old) in MANIFEST.items():
        new = body_hash((ROOT / rel).read_text())
        # Replace the 4th tuple element for this entry — matched by position, not by a one-shot
        # placeholder, so --update stays repeatable instead of silently no-opping after first use.
        text, count = _rewrite_entry(text, rel, new)
        if count != 1:
            print(f"FAIL  could not rewrite the hash row for {rel} (matched {count} times)")
            return 1
        print(f"updated {rel} -> {new}")
    Path(__file__).write_text(text)
    print("Manifest updated. Re-run without --update to verify.")
    return 0


def _rewrite_entry(text: str, rel: str, new_hash: str) -> tuple[str, int]:
    """Replace the 4th string in the tuple for `rel`. Returns (text, n_replacements)."""
    pat = re.compile(
        r'("' + re.escape(rel) + r'":\s*\(\s*(?:"[^"]*",\s*){3}")([^"]*)(")',
        re.S,
    )
    return pat.subn(lambda m: m.group(1) + new_hash + m.group(3), text, count=1)


def verify() -> int:
    failures: list[str] = []
    net_skipped = False

    declared = set(MANIFEST)
    discovered = discover_vendored()
    for missing in sorted(discovered - declared):
        failures.append(
            f"FAIL  {missing} — carries a '{VENDOR_MARKER}' header but is NOT in MANIFEST. "
            f"A vendored file outside the guard is a fork waiting to happen."
        )

    for rel, (repo, upath, rev, expected) in MANIFEST.items():
        path = ROOT / rel
        if not path.exists():
            failures.append(f"FAIL  {rel} — vendored file is missing")
            continue

        src = path.read_text()
        try:
            actual = body_hash(src)
        except DriftError as exc:
            failures.append(f"FAIL  {rel} — {exc}")
            continue

        if expected == "PLACEHOLDER":
            failures.append(f"FAIL  {rel} — manifest hash was never filled in (run --update once)")
            continue

        if actual != expected:
            failures.append(
                f"FAIL  {rel} — body changed since it was vendored\n"
                f"        expected {expected}\n"
                f"        actual   {actual}\n"
                f"        A vendored file must stay a verbatim copy. If you intended to re-vendor at\n"
                f"        a new upstream rev, update the rev in the header AND here, then --update."
            )
            continue

        # The header rev must agree with the manifest. `///` lines are stripped from the body hash,
        # so nothing else ties the two together. An unparseable header is a FAILURE, not a pass —
        # otherwise drifting the header wording silently disables this check.
        m = re.search(r"Pinned rev:\s+([0-9a-f]{40})", src)
        if not m:
            failures.append(
                f"FAIL  {rel} — no parseable 'Pinned rev: <40-hex>' line in the header; "
                f"the header/manifest agreement cannot be checked"
            )
            continue
        if m.group(1) != rev:
            failures.append(
                f"FAIL  {rel} — header rev ({m.group(1)}) disagrees with the manifest rev ({rev})"
            )
            continue

        upstream = fetch_upstream(repo, upath, rev)
        if upstream is None:
            print(f"SKIP  {rel} — could not fetch upstream (network); offline checks PASSED")
            net_skipped = True
            continue
        try:
            up_hash = body_hash(upstream)
        except DriftError as exc:
            failures.append(f"FAIL  {rel} — upstream copy could not be normalised: {exc}")
            continue
        if up_hash != actual:
            failures.append(
                f"FAIL  {rel} — does NOT match upstream {repo}@{rev[:12]}:{upath}"
            )
            continue
        print(f"ok    {rel} — verbatim vs {repo}@{rev[:12]}")

    if failures:
        print("\n".join(failures))
        print("\nVendored-dependency drift detected. "
              "See docs/decisions/0024-dependency-size-vendor-single-file-deps.md")
        return 1

    if net_skipped:
        print("note: at least one upstream comparison was skipped for network reasons.")
    print("All vendored files verified.")
    return 0


def self_test() -> int:
    """Prove the normaliser and the guard actually fire. Runs offline."""
    cases: list[tuple[str, str, str]] = [
        ("line comment stripped", "uint256 a;\n// gone\n", "uint256 a;\n"),
        ("doc comment stripped", "uint256 a;\n/// gone\n", "uint256 a;\n"),
        ("block comment stripped", "uint256 a;\n/* gone\n   gone */\n", "uint256 a;\n"),
        # The defect that motivated the rewrite: an empty block comment must NOT hide the code
        # that follows it on the same line.
        ("empty block comment does NOT hide code", "/**/ uint256 injected;\n", " uint256 injected;\n"),
        ("trailing comment keeps code", "uint256 a; // note\n", "uint256 a;\n"),
        ("code after block comment kept", "/* x */ uint256 a;\n", " uint256 a;\n"),
        ("slashes inside a string survive", 'string s = "http://x";\n', 'string s = "http://x";\n'),
    ]
    failed = 0
    for name, src, want in cases:
        got = normalise(src)
        if got != want:
            print(f"SELF-TEST FAIL  {name}\n  want {want!r}\n  got  {got!r}")
            failed += 1
        else:
            print(f"self-test ok    {name}")

    # An all-comment file must raise, not hash to a constant.
    try:
        normalise("// only a comment\n")
        print("SELF-TEST FAIL  comment-only file should raise DriftError")
        failed += 1
    except DriftError:
        print("self-test ok    comment-only file raises")

    # The guard must actually reject a real injected field in the real vendored file.
    for rel in MANIFEST:
        src = (ROOT / rel).read_text()
        mutated = src.replace("uint256 nonce;", "uint256 nonce;\n        /**/ uint256 injected;", 1)
        if mutated == src:
            print(f"SELF-TEST FAIL  could not mutate {rel} (anchor missing)")
            failed += 1
            continue
        if body_hash(mutated) == body_hash(src):
            print(f"SELF-TEST FAIL  injected field is invisible to the hash in {rel}")
            failed += 1
        else:
            print(f"self-test ok    injected field changes the hash in {rel}")

    if failed:
        print(f"\n{failed} self-test failure(s).")
        return 1
    print("\nSelf-test passed.")
    return 0


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--update":
        return do_update()
    if arg == "--self-test":
        return self_test()
    if arg:
        print(__doc__)
        return 2
    return verify()


if __name__ == "__main__":
    sys.exit(main())
