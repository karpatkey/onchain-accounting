#!/usr/bin/env python3
"""Drift detector for single-file vendored dependencies (ADR 0024).

A vendored file is a VERBATIM copy of an upstream file at a pinned revision. The value of that
promise is entirely in it staying true: the moment someone edits the copy, a "verifiable copy"
silently becomes a "maintained fork" and the header turns into a lie that nothing checks.

Three checks, deliberately asymmetric:

  1. COVERAGE (hard, offline). Every file in the WORKING TREE carrying a "Vendored VERBATIM" header must
     appear in MANIFEST. Deleting a manifest row must not silently drop a file from the guard.
  2. MANIFEST (hard, offline). The normalised body hash of each vendored file must equal the
     recorded hash. Catches a local edit with no network involved.
  3. UPSTREAM (fetches raw.githubusercontent.com at the pinned rev). Catches a manifest hash that
     was updated to match a local edit, and a header rev that does not correspond to the bytes.
     Soft-skips ONLY on a genuine transport failure or a throttle (403/429/5xx), hard-fails on a
     mismatch, and hard-fails on a 404/410 — a status code is a definitive answer that the pinned
     rev/path does not resolve, which makes provenance unverifiable rather than verified.

The asymmetry matters: this repo has already shipped one incident where a guard passed because its
input was stale, so the offline checks are never allowed to be the thing that gets skipped.

WHAT "VERBATIM" DOES AND DOES NOT MEAN HERE
The hash is taken over the file with comments stripped, so this guard enforces CODE-verbatim, not
byte-verbatim. Editing a comment in a vendored file — reflowing the natspec, changing the SPDX tag,
altering a `@custom:storage-location` or `@custom:oz-upgrades-unsafe-allow` annotation — leaves the
hash untouched and the guard still prints "verbatim". That is deliberate: the vendored header block
this repo adds is itself a comment, so a comment-sensitive hash could never match upstream at all.
The cost is real, though: Solidity comments can be load-bearing for tooling and for licence
compliance, and this guard will not notice if one drifts. If a future vendored file carries
semantically meaningful annotations, it needs a stronger check than this one — hashing raw bytes
minus a delimiter-fenced header block would be the way, and it supersedes this note.

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
import tempfile
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


def header_provenance_problem(src: str, repo: str, upath: str) -> str | None:
    """None when the header's repo/path agree with the manifest, else a description of the problem.

    Split out of `verify` so `--self-test` can pin it without a network. Only the pinned REV used
    to be tied to the manifest, and the body hash excludes comments, so nothing stopped the header
    from naming a different repo/path than the one the fetch actually uses.
    """
    hdr_repo = re.search(r"Upstream repo:\s+(\S+)", src)
    hdr_path = re.search(r"Upstream path:\s+(\S+)", src)
    if not hdr_repo or not hdr_path:
        return "header is missing a parseable 'Upstream repo:'/'Upstream path:' line"
    # endswith, not equality: the header records a browsable URL while the manifest records the
    # bare owner/name the raw API needs.
    if not hdr_repo.group(1).rstrip("/").endswith(repo):
        return f"header repo ({hdr_repo.group(1)}) disagrees with the manifest repo ({repo})"
    if hdr_path.group(1) != upath:
        return f"header path ({hdr_path.group(1)}) disagrees with the manifest path ({upath})"
    return None


def _spdx(text: str) -> str | None:
    """The SPDX licence identifier, or None. Compared across local/upstream, never parsed for meaning."""
    m = re.search(r"SPDX-License-Identifier:\s*(\S+)", text)
    return m.group(1) if m else None


def discover_vendored() -> set[str]:
    """Every .sol file in the WORKING TREE carrying the vendored marker.

    Deliberately the working tree and not `git ls-files`: an untracked local copy carrying the
    marker and no manifest row should fail here, before it is ever committed. The cost is that
    such a file fails locally in a way CI cannot reproduce — that is the safe direction, but it
    is why this says working tree rather than "tracked", which an earlier revision claimed.
    """
    found = set()
    # `test/**` is in scope too: the bridge mocks already import vendored code, so a vendored
    # test helper is plausible, and one carrying the marker but no manifest entry would otherwise
    # escape the coverage check entirely.
    for path in (
        list(ROOT.glob("src/**/*.sol"))
        + list(ROOT.glob("script/**/*.sol"))
        + list(ROOT.glob("test/**/*.sol"))
    ):
        try:
            if VENDOR_MARKER in path.read_text(errors="ignore"):
                found.add(str(path.relative_to(ROOT)))
        except OSError:
            continue
    return found


# Statuses that mean "this resource does not exist", as opposed to "we could not reach it".
# 404/410 are the only two that are unambiguous. 403 is deliberately NOT here: GitHub raw has been
# observed serving 403 for rate limiting rather than 429, and hard-failing on it would turn a
# throttle into a red build on an unchanged manifest.
_UNRESOLVABLE_STATUSES = frozenset({404, 410})


class ProvenanceError(Exception):
    """The upstream rev/path does not resolve, so the provenance claim cannot be checked at all."""


def fetch_upstream(repo: str, upath: str, rev: str) -> str | None:
    """Fetch the upstream copy.

    Returns the text, or None when the fetch failed for a reason that is genuinely transport —
    caller degrades to offline-only checks.

    Raises {ProvenanceError} when the server says the resource does not exist. That is NOT a
    network blip and must never soft-skip: a 404 means the pinned rev or the manifest's
    `upstream_path` does not resolve, so "is this file still a verbatim copy of upstream?" is
    unanswerable rather than answered-yes. Treating it as a blip made this composite go
    permanently green: edit the vendored file, run --update so the offline hash matches, then
    point `upstream_path` at a path that does not exist. The header-rev check still passes
    (the rev was never touched) and the only remaining trace is a SKIP line nobody reads.
    """
    url = f"https://raw.githubusercontent.com/{repo}/{rev}/{upath}"
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        # HTTPError is a URLError subclass, so it MUST be caught first or it lands in the
        # soft-skip arm below — which is exactly the bug this taxonomy exists to fix.
        if exc.code in _UNRESOLVABLE_STATUSES:
            raise ProvenanceError(
                f"upstream returned HTTP {exc.code} for {repo}@{rev[:12]}:{upath} — "
                f"the pinned rev or upstream_path does not resolve, so provenance is unverifiable"
            ) from exc
        return None
    except (urllib.error.URLError, TimeoutError, OSError):
        return None


def do_update(allow_offline: bool = False) -> int:
    """Re-record each hash from disk, but ONLY after confirming disk still matches upstream.

    `--update` is the single command that can silence this guard, and it used to record whatever
    was on disk with no validation at all — which is what turned a local edit into a permanently
    green tree: edit the file, `--update`, and every offline check now agrees with the edit. It
    now fetches the pinned upstream rev first and refuses when the normalised bodies differ, so
    re-vendoring stays a deliberate act (bump the rev in the header AND the manifest, then update)
    rather than a laundering step.

    `--update --offline` remains for a genuine network outage. It is deliberately explicit: the
    operator has to say they are recording an unverified hash.
    """
    text = Path(__file__).read_text(encoding="utf-8")
    for rel, (_repo, _upath, _rev, old) in MANIFEST.items():
        local = (ROOT / rel).read_text(encoding="utf-8")
        new = body_hash(local)
        if not allow_offline:
            try:
                upstream = fetch_upstream(_repo, _upath, _rev)
            except ProvenanceError as exc:
                print(f"FAIL  {rel} — {exc}")
                return 1
            if upstream is None:
                print(
                    f"FAIL  {rel} — could not reach upstream, so this hash cannot be validated.\n"
                    f"      Re-run when the network is back, or pass --update --offline to record\n"
                    f"      an UNVERIFIED hash deliberately."
                )
                return 1
            if body_hash(upstream) != new:
                print(
                    f"FAIL  {rel} — refusing to record a hash that does not match upstream\n"
                    f"      {_repo}@{_rev[:12]}:{_upath}\n"
                    f"      --update re-records provenance; it is not a way to accept a local edit.\n"
                    f"      To re-vendor at a NEW rev, change the rev in the file header AND the\n"
                    f"      manifest first, then run --update."
                )
                return 1
        # Replace the 4th tuple element for this entry — matched by position, not by a one-shot
        # placeholder, so --update stays repeatable instead of silently no-opping after first use.
        text, count = _rewrite_entry(text, rel, new)
        if count != 1:
            print(f"FAIL  could not rewrite the hash row for {rel} (matched {count} times)")
            return 1
        print(f"updated {rel} -> {new}")
    Path(__file__).write_text(text, encoding="utf-8")
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

        # `read_text` (text mode) is LOAD-BEARING, not incidental: it applies universal-newline
        # translation, so a lone `\r` becomes `\n` before the normaliser runs. solc treats a bare
        # `\r` as a line-comment terminator but `strip_comments` only terminates on `\n`, so
        # switching this to `read_bytes().decode()` — a natural move if someone later wants
        # byte-exactness — would let `// pad\r  uint256 injected;` hash as pure comment while solc
        # compiles the injected field. Pinned by the CR case in `--self-test`.
        src = path.read_text(encoding="utf-8")
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
        # The header's repo and path must agree with the MANIFEST values the fetch actually uses.
        # Without this only the REV was tied to the manifest, and the body hash excludes comments,
        # so the header could name a different repo/path than the one being verified — the exact
        # shape that lets a hand-edited `upstream_path` send the fetch somewhere harmless.
        problem = header_provenance_problem(src, repo, upath)
        if problem:
            failures.append(f"FAIL  {rel} — {problem}")
            continue

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

        try:
            upstream = fetch_upstream(repo, upath, rev)
        except ProvenanceError as exc:
            failures.append(f"FAIL  {rel} — {exc}")
            continue
        if upstream is None:
            print(f"::warning::vendored: {rel} upstream comparison skipped (network)")
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
        # The SPDX tag is a COMMENT, so the body hash cannot see it. Relicensing a vendored file
        # is exactly the kind of edit a repo-wide header sweep makes by accident: every other file
        # under src/ carries BUSL-1.1, and flipping this one would put MIT-licensed upstream code
        # under the wrong licence with the guard still reporting "verbatim". Compare it to
        # upstream's own tag while we have the upstream bytes in hand.
        if _spdx(src) != _spdx(upstream):
            failures.append(
                f"FAIL  {rel} — SPDX tag ({_spdx(src) or 'missing'}) does not match upstream's "
                f"({_spdx(upstream) or 'missing'}). A vendored file keeps the UPSTREAM licence tag."
            )
            continue
        print(f"ok    {rel} — verbatim vs {repo}@{rev[:12]}")

    if failures:
        print("\n".join(failures))
        print("\nVendored-dependency drift detected. "
              "See docs/decisions/0024-dependency-size-vendor-single-file-deps.md")
        return 1

    if net_skipped:
        print("::warning::vendored: at least one upstream comparison was skipped for network reasons")
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

    # The guard must actually reject a real injected field in each real vendored file.
    #
    # The mutation is APPENDED rather than spliced at a fixed anchor. An earlier revision spliced
    # after the literal `uint256 nonce;`, which exists only in the Optimism file — so the second
    # vendored file the ADR anticipates would have made this arm print "anchor missing" and exit 1
    # on a clean tree, reddening the preflight step for every PR while nothing had drifted. The
    # tempting fix under that pressure is to delete this arm, which would remove the only
    # assertion proving the guard fires on an injected struct member. Appending needs no anchor,
    # works for any vendored file, and still exercises the original defect: code hidden behind an
    # empty block comment. Nothing here compiles the result — it is hashed, not parsed.
    for rel in MANIFEST:
        src = (ROOT / rel).read_text(encoding="utf-8")
        mutated = src + "\n/**/ uint256 injected;\n"
        if body_hash(mutated) == body_hash(src):
            print(f"SELF-TEST FAIL  injected field is invisible to the hash in {rel}")
            failed += 1
        else:
            print(f"self-test ok    injected field changes the hash in {rel}")

    # The lone-CR injection, exercised THROUGH THE READ PATH rather than against `normalise`
    # directly — the defence lives in text-mode I/O, so a test that calls `normalise` on an
    # in-memory string would pass even with the defence removed and assert nothing.
    with tempfile.TemporaryDirectory() as tmp:
        probe = Path(tmp) / "cr.sol"
        probe.write_bytes(b"uint256 a;\n// pad\r        uint256 injected;\n")
        if "injected" not in normalise(probe.read_text(encoding="utf-8")):
            print("SELF-TEST FAIL  lone-CR line comment hides the code after it")
            failed += 1
        else:
            print("self-test ok    lone-CR line comment does NOT hide code")

    # The header/manifest provenance agreement, offline. The repointed-path case is the shape of
    # a real exploit: leave the rev untouched so the rev check still passes, and send the fetch at
    # a path that 404s.
    _REPO, _UPATH = "ethereum-optimism/optimism", "packages/contracts-bedrock/src/libraries/Types.sol"
    _good = f"/// Upstream repo: https://github.com/{_REPO}\n/// Upstream path: {_UPATH}\n"
    for name, hdr, want_problem in (
        ("matching header accepted", _good, False),
        ("repointed path rejected", _good.replace("/src/", "/contracts/"), True),
        ("swapped repo rejected", _good.replace(_REPO, "attacker/optimism"), True),
        ("missing header rejected", "/// no provenance here\n", True),
    ):
        if (header_provenance_problem(hdr, _REPO, _UPATH) is not None) != want_problem:
            print(f"SELF-TEST FAIL  provenance: {name}")
            failed += 1
        else:
            print(f"self-test ok    provenance: {name}")

    # The fetch-failure taxonomy, offline. A 404 means the pinned rev or upstream_path does not
    # resolve, so provenance is UNVERIFIABLE and must fail loudly; a 503 or a transport error is a
    # genuine blip and must soft-skip to offline-only. Before this split, HTTPError was caught
    # alongside URLError and every one of these soft-skipped -- which let a hand-edited file whose
    # upstream_path had been pointed at nowhere stay green forever.
    def _raises_provenance(status: int) -> bool:
        def _boom(*_a, **_kw):
            raise urllib.error.HTTPError(url="u", code=status, msg="m", hdrs=None, fp=None)

        real = urllib.request.urlopen
        urllib.request.urlopen = _boom
        try:
            fetch_upstream("o/r", "p.sol", "0" * 40)
            return False
        except ProvenanceError:
            return True
        finally:
            urllib.request.urlopen = real

    for status, want_hard in ((404, True), (410, True), (403, False), (429, False), (503, False)):
        verdict = "hard-fails" if want_hard else "soft-skips"
        if _raises_provenance(status) != want_hard:
            print(f"SELF-TEST FAIL  HTTP {status} should {verdict}")
            failed += 1
        else:
            print(f"self-test ok    HTTP {status} {verdict}")

    if failed:
        print(f"\n{failed} self-test failure(s).")
        return 1
    print("\nSelf-test passed.")
    return 0


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "--update":
        return do_update(allow_offline="--offline" in sys.argv[2:])
    if arg == "--self-test":
        return self_test()
    if arg:
        print(__doc__)
        return 2
    return verify()


if __name__ == "__main__":
    sys.exit(main())
