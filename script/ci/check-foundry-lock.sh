#!/usr/bin/env bash
# Assert foundry.lock agrees with the committed submodule gitlinks.
#
# WHY THIS EXISTS
# The gitlink is what actually resolves: `actions/checkout --recursive` in CI, and `forge build`/`forge install`
# locally, both check out the gitlink even when a valid foundry.lock names a different revision (measured on forge
# 1.7.1). But `forge update` DOES act on the lock, and `forge build` parses it and warns. So a lock that disagrees
# with the tree is a live trap for anyone who runs `forge update`, and misleading documentation for everyone else.
#
# The drift returns by construction without this check: the documented dependency-bump flow is a plain
# `git -C lib/<dep> checkout <rev> && git add lib/<dep>`, which moves the gitlink and leaves the lock untouched,
# and `forge build` never writes the lock back. Nothing else in CI compares the two.
#
# WHAT IT CHECKS
#   1. foundry.lock is valid JSON               (it was not: a trailing comma made it unparseable)
#   2. every gitlink has a lock entry, and vice versa
#   3. every lock revision equals its gitlink   (six of nine disagreed when this was written)
#
# Reads the committed tree via `git ls-tree HEAD`, so it needs no submodule content and no network.
# Requires: git, jq. Usage: script/ci/check-foundry-lock.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

LOCK=foundry.lock

if [[ ! -f "$LOCK" ]]; then
  echo "::error::$LOCK is missing"
  exit 1
fi

# 1. Valid JSON. jq exits non-zero and prints the offending position, which is the whole diagnosis for a
#    trailing comma or a truncated file.
if ! jq empty "$LOCK" 2>/tmp/lockerr; then
  echo "::error::$LOCK is not valid JSON"
  sed 's/^/  /' /tmp/lockerr
  exit 1
fi

fail=0

# Gitlinks from the committed tree — the authoritative side.
declare -A gitlink
while read -r _mode _type sha path; do
  gitlink["$path"]="$sha"
done < <(git ls-tree HEAD lib/)

# 2 + 3. Compare in both directions.
for path in "${!gitlink[@]}"; do
  # A lock entry is either {"rev": …} or {"tag": {"name": …, "rev": …}}.
  rev=$(jq -r --arg p "$path" '.[$p] // empty | (.rev // .tag.rev) // empty' "$LOCK")
  if [[ -z "$rev" ]]; then
    echo "::error::$LOCK has no revision for $path (gitlink ${gitlink[$path]})"
    fail=1
  elif [[ "$rev" != "${gitlink[$path]}" ]]; then
    echo "::error::$path: lock says $rev, gitlink is ${gitlink[$path]}"
    fail=1
  fi
done

while read -r path; do
  [[ -n "${gitlink[$path]+x}" ]] && continue
  echo "::error::$LOCK has an entry for $path, which is not a submodule in the tree"
  fail=1
done < <(jq -r 'keys[]' "$LOCK")

if [[ "$fail" -ne 0 ]]; then
  cat >&2 <<'MSG'

foundry.lock disagrees with the committed submodule gitlinks.

The lock follows the tree, never the reverse — do NOT move a submodule pointer to satisfy this check.
Refresh the lock so each entry records the gitlink, e.g. for one dependency:

  jq --arg p lib/<dep> --arg r "$(git ls-tree HEAD lib/<dep> | awk '{print $3}')" \
     '.[$p] = {rev: $r}' foundry.lock > foundry.lock.tmp && mv foundry.lock.tmp foundry.lock

Prefer a bare {"rev": …} over {"tag": {…}}: on the `forge update` path forge resolves the mutable tag NAME and
discards the recorded rev, so a tag entry is not a pin. Do not add a terminating newline — forge's serialiser
does not emit one and `forge install` will strip it, leaving a permanently dirty file.
MSG
  exit 1
fi

echo "foundry.lock matches all ${#gitlink[@]} submodule gitlinks."
