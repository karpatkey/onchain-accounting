#!/usr/bin/env bash
# Drift detector for single-file vendored dependencies (ADR 0024).
#
# A vendored file is a VERBATIM copy of an upstream file at a pinned revision. The value of that
# promise is entirely in it staying true: the moment someone edits the copy, a "verifiable copy"
# silently becomes a "maintained fork" and the header turns into a lie that nothing checks.
#
# Two checks, deliberately asymmetric:
#
#   1. MANIFEST (hard, offline, always runs). The normalised body hash of each vendored file must
#      equal the hash recorded below. Catches a local edit with no network involved.
#   2. UPSTREAM (fetches raw.githubusercontent.com at the header's pinned rev). Catches a manifest
#      hash that was updated to match a local edit, and a header rev that does not correspond to
#      the bytes. Soft-skips ONLY on a network/transport failure, and hard-fails on a mismatch.
#
# The asymmetry matters: this repo has already shipped one incident where a guard passed because
# its input was stale, so the offline check is never allowed to be the thing that gets skipped.
#
# "Normalised body" = the file with comment lines and blank lines stripped, i.e. exactly the part
# that must match upstream. The provenance header is ours and is expected to differ.
#
# Usage: script/ci/check-vendored.sh [--update]
#   --update  recompute and rewrite the manifest hashes in this file (use when intentionally
#             re-vendoring at a NEW upstream rev; never to silence a failure).

set -euo pipefail

cd "$(dirname "$0")/../.."

# path|upstream_repo|upstream_path|rev|expected_body_sha256
VENDORED=(
  "src/bridge/adapters/lib/OptimismTypes.sol|ethereum-optimism/optimism|packages/contracts-bedrock/src/libraries/Types.sol|f707883038d527cbf1e9f8ea513fe33255deadbc|ecb592ac17aa61cbbb7c3d9f35f4720ba21c490f5948c55489bde827727bab81"
)

normalise() {
  # strip //, ///, /* and * comment lines, and blank lines
  grep -v -E '^[[:space:]]*(///|//|\*|/\*|\*/)' "$1" | grep -v -E '^[[:space:]]*$'
}

body_hash() { normalise "$1" | sha256sum | cut -d' ' -f1; }

if [[ "${1:-}" == "--update" ]]; then
  for i in "${!VENDORED[@]}"; do
    IFS='|' read -r f _ _ _ _ <<< "${VENDORED[$i]}"
    h=$(body_hash "$f")
    sed -i "s|__HASH${i}__|${h}|" "$0"
    echo "updated hash for $f -> $h"
  done
  echo "Manifest updated. Re-run without --update to verify."
  exit 0
fi

fail=0
net_skipped=0

for entry in "${VENDORED[@]}"; do
  IFS='|' read -r file repo upath rev expected <<< "$entry"

  if [[ ! -f "$file" ]]; then
    echo "FAIL  $file — vendored file is missing"; fail=1; continue
  fi

  # --- check 1: manifest (hard, offline) ---
  actual=$(body_hash "$file")
  if [[ "$expected" == __HASH* ]]; then
    echo "FAIL  $file — manifest hash placeholder was never filled in (run --update once)"; fail=1; continue
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL  $file — body changed since it was vendored"
    echo "        expected $expected"
    echo "        actual   $actual"
    echo "        A vendored file must stay a verbatim copy. If you intended to re-vendor at a new"
    echo "        upstream rev, update the rev in the file header AND in this script, then --update."
    fail=1; continue
  fi

  # --- check 1b: the header's rev must agree with this script's ---
  hdr_rev=$(grep -oE 'Pinned rev:[[:space:]]+[0-9a-f]{40}' "$file" | grep -oE '[0-9a-f]{40}' || true)
  if [[ -n "$hdr_rev" && "$hdr_rev" != "$rev" ]]; then
    echo "FAIL  $file — header rev ($hdr_rev) disagrees with the manifest rev ($rev)"; fail=1; continue
  fi

  # --- check 2: upstream (soft-skip on transport failure only) ---
  url="https://raw.githubusercontent.com/${repo}/${rev}/${upath}"
  tmp=$(mktemp)
  if curl -fsSL --max-time 30 "$url" -o "$tmp" 2>/dev/null; then
    if [[ "$(body_hash "$tmp")" != "$actual" ]]; then
      echo "FAIL  $file — does NOT match upstream ${repo}@${rev:0:12}:${upath}"
      diff <(normalise "$tmp") <(normalise "$file") | head -40 || true
      fail=1
    else
      echo "ok    $file — verbatim vs ${repo}@${rev:0:12}"
    fi
  else
    echo "SKIP  $file — could not fetch upstream (network); manifest check PASSED"
    net_skipped=1
  fi
  rm -f "$tmp"
done

if [[ $fail -ne 0 ]]; then
  echo
  echo "Vendored-dependency drift detected. See docs/decisions/0024-dependency-size-vendor-single-file-deps.md"
  exit 1
fi

[[ $net_skipped -eq 1 ]] && echo "note: at least one upstream comparison was skipped for network reasons."
echo "All vendored files verified."
