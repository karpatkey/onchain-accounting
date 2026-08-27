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
     Hard-fails on a mismatch, and hard-fails on 404/410 — those two are a definitive answer that
     the pinned rev/path does not resolve, which makes provenance unverifiable rather than
     verified. EVERY other HTTP status (403 and 429 throttles, 5xx, and also 401/451) soft-skips
     along with genuine transport errors, because reddening CI on an unchanged manifest would make
     upstream availability a build dependency.

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
                                          failure. FETCHES upstream and refuses to record a hash
                                          that does not match it, so it needs network
  script/ci/check_vendored.py --update --offline
                                          same, but skip the upstream check and record the hash with an
                                          UNVERIFIED: prefix. For a genuine outage only. That prefix is
                                          PERSISTED: until a networked --update replaces it, a run that
                                          cannot reach upstream FAILS rather than passing on a hash
                                          nothing ever validated
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


# The labelled lines a vendored header must carry. Every one is cross-checked against the manifest,
# because they are COMMENTS and so invisible to the body hash.
_PROVENANCE_LABELS = ("Source:", "Upstream repo:", "Upstream path:", "Pinned rev:")


def _header_region(src: str) -> list[str]:
    r"""The contiguous comment block at the TOP of the file, stripped of comment markers.

    Scanning the whole file for a label was the defect that survived three rewrites. It gave the
    attacker a free choice of where the satisfying text lives: a decoy line ABOVE a fully repointed
    header passed, and so did a header whose labels were Cyrillic homoglyphs with a real ASCII line
    appended at the bottom of the file. Both produced "verbatim" on a file whose visible provenance
    was a lie. The header is a bounded region, so bound it: stop at the first line that is not a
    comment and not blank — which for a Solidity source is the `pragma`, the `contract`, or an
    import, i.e. always past the header.
    """
    out: list[str] = []
    for raw in src.splitlines():
        line = raw.strip()
        # Stop at the declaration. Everything a vendored header can legitimately occupy — the SPDX
        # line, the pragma, imports, and the natspec block — precedes it, and nothing after it is
        # header. Bounding on the declaration rather than on "first non-comment line" is what makes
        # this work for a real Solidity file, where the pragma sits between the SPDX comment and
        # the natspec block.
        if re.match(r"^(abstract\s+)?(contract|library|interface)\b", line):
            break
        if line.startswith(("///", "//", "*", "/*")):
            out.append(re.sub(r"^\s*(?:///|//|/\*|\*)\s?", "", raw).rstrip())
        else:
            out.append("")
    return out


def _header_field(src: str, label: str) -> str | None:
    r"""The single value belonging to `label` within the HEADER REGION. None if absent or empty.

    Three properties, each of which a previous revision lacked and an attacker used:
    1. **Region-bounded** — only the top-of-file comment block is searched (see {_header_region}),
       so text elsewhere in the file cannot satisfy a header check.
    2. **ASCII-only labels and values** — a line containing non-ASCII is skipped outright. Cyrillic
       `о`/`а`/`е` are invisible to `str.find` and were used to make a header that reads correctly
       to a human match nothing at all, letting a truth line elsewhere satisfy the check.
    3. **No trailing content** — the value must be the ONLY token after the label. Previously
       `parts[0]` silently discarded a tail, so `Pinned rev: f7078...  <- SUPERSEDED, real rev is
       dede...` passed while telling a reader the opposite.

    Tolerates natspec wrapping: the value may sit on the label's own line or the next line, and a
    following line that is itself a label is not consumed.
    """
    lines = _header_region(src)
    for i, ln in enumerate(lines):
        if not ln.isascii():
            continue
        at = ln.find(label)
        if at < 0:
            continue
        rest = ln[at + len(label):].strip()
        if not rest and i + 1 < len(lines):
            nxt = lines[i + 1].strip()
            if nxt.isascii() and not any(other in nxt for other in _PROVENANCE_LABELS):
                rest = nxt
        parts = rest.split()
        if not parts:
            return None
        # Exactly one token: a tail is a lie waiting to happen, not a formatting nicety.
        return parts[0] if len(parts) == 1 else None
    return None


def header_provenance_problem(src: str, repo: str, upath: str, rev: str) -> str | None:
    """None when every labelled provenance line agrees with the manifest, else what disagrees.

    Split out of `verify` so `--self-test` can pin it without a network, and written as a uniform
    per-label loop rather than a chain of bespoke comparisons. That shape is deliberate: the
    bespoke chain it replaced kept growing a new special case per review round, and each new case
    made the previous ones VACUOUS — mutation-testing showed the `Upstream repo:` and
    `Upstream path:` checks could both be deleted with the whole self-test still green, because a
    later file-wide check happened to catch the same mutants. One rule per label, one arm per
    label, each independently pinned.
    """
    want = {
        # The URL a human auditor clicks. It independently encodes repo, rev and path.
        "Source:": f"https://github.com/{repo}/blob/{rev}/{upath}",
        # The full canonical URL, NOT the bare `owner/name` the manifest row uses.
        "Upstream repo:": f"https://github.com/{repo}",
        "Upstream path:": upath,
        "Pinned rev:": rev,
    }
    for label, expected in want.items():
        got = _header_field(src, label)
        if got is None:
            return f"header has no '{label}' value (expected exactly {expected})"
        if got != expected:
            return f"header '{label}' is {got!r}, expected exactly {expected!r}"
    return None


def _read_source(path: Path) -> str:
    r"""Read a source file the way the guard must read it.

    TEXT MODE IS LOAD-BEARING, not incidental. It applies universal-newline translation, so a lone
    `\r` becomes `\n` before the normaliser runs. solc treats a bare `\r` as a line-comment
    terminator but `strip_comments` only terminates on `\n`, so `read_bytes().decode()` — a natural
    move if someone later wants byte-exactness — would let `// pad\r  uint256 injected;` hash as
    pure comment while solc compiles the injected struct member.

    This exists as a function so `--self-test` exercises THE SAME read the guard uses. An earlier
    revision inlined the read here and had the self-test call `read_text` itself; the comment
    claimed the arm pinned the defence and it did not — the defence could be removed with all
    self-test arms still green. Do not inline this again.
    """
    return path.read_text(encoding="utf-8")


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


UNVERIFIED_PREFIX = "UNVERIFIED:"


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
        local = _read_source(ROOT / rel)
        try:
            new = body_hash(local)
        except DriftError as exc:
            # Wrapped for the same reason both call sites in `verify` are: an unterminated comment
            # should print a FAIL line, not a traceback.
            print(f"FAIL  {rel} — {exc}")
            return 1
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
            try:
                upstream_hash = body_hash(upstream)
            except DriftError as exc:
                print(f"FAIL  {rel} — upstream copy could not be normalised: {exc}")
                return 1
            if upstream_hash != new:
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
        # PERSIST the unverified state. Printing "[UNVERIFIED]" told the operator and nobody else: once the
        # process exited, the manifest was indistinguishable from an online-validated one, so a later run that
        # soft-skipped the fetch would accept a hash that had NEVER been compared to upstream. The prefix makes
        # the state a property of the RECORD rather than of one console session.
        if allow_offline:
            new = UNVERIFIED_PREFIX + new

        text, count = _rewrite_entry(text, rel, new)
        if count != 1:
            print(f"FAIL  could not rewrite the hash row for {rel} (matched {count} times)")
            return 1
        print(f"updated {rel} -> {new}" + ("  [UNVERIFIED — recorded offline]" if allow_offline else ""))
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

        src = _read_source(path)
        try:
            actual = body_hash(src)
        except DriftError as exc:
            failures.append(f"FAIL  {rel} — {exc}")
            continue

        # An offline-recorded hash was never compared to upstream, so the offline half alone proves only
        # that the file still matches ITSELF. It is a provisional record, and the upstream comparison is
        # the thing that would make it real — so a soft-skip must NOT pass here (see below).
        unverified = expected.startswith(UNVERIFIED_PREFIX)
        if unverified:
            expected = expected[len(UNVERIFIED_PREFIX):]

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
        problem = header_provenance_problem(src, repo, upath, rev)
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
        if upstream is None and unverified:
            failures.append(
                f"FAIL  {rel} — the manifest hash was recorded with `--update --offline` and has NEVER been\n"
                f"        validated against upstream, and this run could not reach upstream either. There is no\n"
                f"        verified baseline for this file, so passing would attest nothing. When the network is\n"
                f"        back, re-run `--update` (WITHOUT --offline) to replace it with a validated hash —\n"
                f"        `verify()` does not rewrite the manifest, so the marker persists until you do."
            )
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
        src = _read_source(ROOT / rel)
        mutated = src + "\n/**/ uint256 injected;\n"
        if body_hash(mutated) == body_hash(src):
            print(f"SELF-TEST FAIL  injected field is invisible to the hash in {rel}")
            failed += 1
        else:
            print(f"self-test ok    injected field changes the hash in {rel}")

    # The lone-CR injection, exercised through `_read_source` — THE SAME helper `verify` reads
    # through. The defence lives in text-mode I/O, so an arm that called `read_text` itself would
    # stay green with the defence removed and assert nothing. That was measured, not theorised:
    # with the read swapped to `read_bytes().decode()`, every self-test arm passed while a real
    # CR-hidden struct member verified as "verbatim".
    with tempfile.TemporaryDirectory() as tmp:
        probe = Path(tmp) / "cr.sol"
        probe.write_bytes(b"uint256 a;\n// pad\r        uint256 injected;\n")
        if "injected" not in normalise(_read_source(probe)):
            print("SELF-TEST FAIL  lone-CR line comment hides the code after it")
            failed += 1
        else:
            print("self-test ok    lone-CR line comment does NOT hide code")

    # END-TO-END: run `verify()` itself against a scratch tree. Every arm above pins a HELPER;
    # none of them pinned `verify()`'s own checks, and mutation-testing found 8 of 20 defences
    # survived their own deletion — including the manifest compare, which this module's docstring
    # calls the check that is "never allowed to be the thing that gets skipped". An arm that
    # asserts `body_hash(mutated) != body_hash(src)` proves the HASH changes; it does not prove
    # `verify()` acts on it. These two arms do.
    def _verify_against(tree_body: str, upstream_body: str | None) -> int:
        rel = next(iter(MANIFEST))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(tree_body, encoding="utf-8")
            real_root, real_fetch = globals()["ROOT"], globals()["fetch_upstream"]
            globals()["ROOT"] = root
            globals()["fetch_upstream"] = lambda *_a, **_k: upstream_body
            try:
                return verify()
            finally:
                globals()["ROOT"], globals()["fetch_upstream"] = real_root, real_fetch

    _pristine = _read_source(ROOT / next(iter(MANIFEST)))
    _tampered = _pristine.replace("uint256 nonce;", "uint256 nonce;\n        /**/ uint256 injected;", 1)
    for name, body, upstream, want_rc in (
        ("verify() passes on the real tree", _pristine, _pristine, 0),
        ("verify() FAILS on an injected struct member", _tampered, _pristine, 1),
        ("verify() FAILS when upstream disagrees", _pristine, _tampered, 1),
        # ISOLATES THE OFFLINE MANIFEST COMPARE. Upstream is given the SAME tampered body, so the
        # upstream comparison agrees and cannot be what fails — only the recorded manifest hash
        # disagrees. Without this the previous arm passed via the upstream check and the offline
        # one stayed unpinned: neutering `if actual != expected:` left the whole self-test green.
        # This is the scenario the module exists for — an attacker who controls the upstream copy
        # too, or an upstream that has simply moved on.
        ("verify() FAILS on manifest drift even when upstream agrees", _tampered, _tampered, 1),
    ):
        got = _verify_against(body, upstream)
        if got != want_rc:
            print(f"SELF-TEST FAIL  {name} (rc={got}, want {want_rc})")
            failed += 1
        else:
            print(f"self-test ok    {name}")

    # The header/manifest provenance agreement, offline. The repointed-path case is the shape of
    # a real exploit: leave the rev untouched so the rev check still passes, and send the fetch at
    # a path that 404s.
    _REPO = "ethereum-optimism/optimism"
    _UPATH = "packages/contracts-bedrock/src/libraries/Types.sol"
    _REV = "f707883038d527cbf1e9f8ea513fe33255deadbc"

    # ONE ARM PER LABEL, each mutating exactly that label's value and nothing else. That
    # discipline is the point, not tidiness: a previous revision built its negative cases by
    # string-replacing a fragment shared by several labels, so one later check caught every
    # mutant and the other checks became VACUOUS — mutation-testing showed two of them could be
    # deleted outright with the self-test still fully green. Each arm below fails if, and only
    # if, its own check is removed.
    def _hdr(source=None, repo=None, upath=None, rev=None):
        return (
            f"/// @dev Vendored VERBATIM. Source:\n"
            f"///      {source or f'https://github.com/{_REPO}/blob/{_REV}/{_UPATH}'}\n"
            f"///\n"
            f"///      Upstream repo: {repo or f'https://github.com/{_REPO}'}\n"
            f"///      Upstream path: {upath or _UPATH}\n"
            f"///      Pinned rev:    {rev or _REV}\n"
        )

    for name, hdr, want_problem in (
        ("matching header accepted", _hdr(), False),
        # Source: — the URL a human auditor clicks, and the one that was checked by nothing.
        ("Source repointed to a fork", _hdr(source=f"https://github.com/evil-{_REPO}/blob/{_REV}/{_UPATH}"), True),
        ("Source at the wrong rev", _hdr(source=f"https://github.com/{_REPO}/blob/{'0' * 40}/{_UPATH}"), True),
        ("Source on a foreign host", _hdr(source=f"https://evil.example.com/{_REPO}/blob/{_REV}/{_UPATH}"), True),
        # The canonical URL present ELSEWHERE must not satisfy the Source check. This is the
        # bypass that a file-wide `re.search` allowed: repoint the real line, leave the canonical
        # string in a "previously vendored from" note.
        (
            "canonical URL in a footnote does not excuse a repointed Source",
            _hdr(source=f"https://github.com/evil-{_REPO}/blob/{_REV}/{_UPATH}")
            + f"///      Previously vendored from\n///      https://github.com/{_REPO}/blob/{_REV}/{_UPATH}\n",
            True,
        ),
        # Upstream repo: — independently pinned.
        ("repo suffix-org rejected", _hdr(repo=f"https://github.com/evil-{_REPO}"), True),
        ("repo bare owner/name rejected", _hdr(repo=_REPO), True),
        # Upstream path: — independently pinned.
        ("path repointed rejected", _hdr(upath=_UPATH.replace("/src/", "/contracts/")), True),
        # Pinned rev: — independently pinned.
        ("rev mismatch rejected", _hdr(rev="0" * 40), True),
        # Absent labels.
        ("missing header rejected", "/// no provenance here\n", True),
        ("missing Source value rejected", _hdr().replace(
            f"///      https://github.com/{_REPO}/blob/{_REV}/{_UPATH}\n", "", 1), True),
    ):
        if (header_provenance_problem(hdr, _REPO, _UPATH, _REV) is not None) != want_problem:
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
