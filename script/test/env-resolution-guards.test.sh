#!/usr/bin/env bash
# Guard tests for the .env resolution in rehearse_fork.sh (and its chainlib.py twin).
#
# Why this exists: the fallback used to be `$(dirname "$ROOT")/onchain-accounting/.env`, which only
# resolves when the worktree happens to sit as a SIBLING of the canonical clone. From a worktree
# nested at `<repo>/.claude/worktrees/<name>` it probed `.../worktrees/onchain-accounting/.env`,
# found nothing, and rehearse_fork.sh aborted outright on its ALCHEMY_API_KEY check — costing a
# session real time and forcing one rehearsal to run from a hand-placed .env. A fallback path that
# is never exercised from the layout it is meant to cover is not a fallback, so each layout below
# is driven end-to-end against a real throwaway git repo.
#
# It extracts the resolution block from the real script rather than restating it, so the code under
# test cannot drift away from the code that ships. No network, no RPC, no Alchemy call.
#
# Not wired into CI (this repo has no bash test runner). Run it by hand:
#   bash script/test/env-resolution-guards.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/script/deploy/preflight/rehearse_fork.sh"
CHAINLIB="$REPO_ROOT/script/deploy/preflight/chainlib.py"
[[ -f "$TARGET" ]] || { echo "cannot find $TARGET" >&2; exit 1; }

# Pull the shipping code out verbatim: the candidate function, then the dedupe+source block.
# `/^done$/` terminates on the for-loop's bare `done` — the while-loop's is `done < <(...)`.
fn_src="$(sed -n '/^env_candidates() {/,/^}/p' "$TARGET")"
[[ -n "$fn_src" ]] || { echo "could not extract env_candidates from $TARGET" >&2; exit 1; }
resolve_src="$(sed -n '/^ENV_FOUND=()/,/^done$/p' "$TARGET")"
[[ -n "$resolve_src" ]] || { echo "could not extract the resolution block from $TARGET" >&2; exit 1; }

pass=0
fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %-56s %s\n' "$name" "$got"
    pass=$((pass+1))
  else
    printf '  FAIL %-56s want=%s got=%s\n' "$name" "$want" "$got"
    fail=$((fail+1))
  fi
}

# --- synthetic layouts -------------------------------------------------------
# One canonical clone carrying the sentinel .env, plus a sibling worktree and a nested worktree —
# the three layouts the resolution has to cover.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CANON="$TMP/onchain-accounting"
mkdir -p "$CANON"
git -C "$CANON" init -q
git -C "$CANON" config user.email t@t.invalid
git -C "$CANON" config user.name t
printf 'ALCHEMY_API_KEY=canonical-sentinel\nMAINNET_URL=from-canonical\n' > "$CANON/.env"
: > "$CANON/placeholder"
git -C "$CANON" add placeholder
git -C "$CANON" commit -qm init

SIBLING="$TMP/oa-sibling"
git -C "$CANON" worktree add -q --detach "$SIBLING"

NESTED="$CANON/.claude/worktrees/nested"
mkdir -p "$(dirname "$NESTED")"
git -C "$CANON" worktree add -q --detach "$NESTED"

# A separate sibling repo standing in for onchain-investment-vehicles.
OIV="$TMP/onchain-investment-vehicles"
mkdir -p "$OIV"
printf 'OIV_ONLY_URL=from-oiv\nMAINNET_URL=from-oiv\n' > "$OIV/.env"

eval "$fn_src"

# Run the SHIPPED resolution block against one root and report what ALCHEMY_API_KEY became.
# Each case runs in a subshell so a sourced .env cannot leak into the next.
resolve_in() {
  local root="$1" var="${2:-ALCHEMY_API_KEY}"
  (
    set -uo pipefail
    ROOT="$root"
    unset ALCHEMY_API_KEY MAINNET_URL OIV_ONLY_URL
    eval "$fn_src"
    eval "$resolve_src"
    printf '%s' "${!var:-<unset>}"
  )
}

echo "== layout proofs: the shipped resolution block =="
# THE REGRESSION CASE. This is the one that aborted before the fix.
check "nested worktree resolves ALCHEMY_API_KEY"  "canonical-sentinel" "$(resolve_in "$NESTED")"
check "sibling worktree resolves ALCHEMY_API_KEY" "canonical-sentinel" "$(resolve_in "$SIBLING")"
check "normal clone resolves ALCHEMY_API_KEY"     "canonical-sentinel" "$(resolve_in "$CANON")"

echo "== candidate derivation =="
# The canonical clone must be among the candidates for every layout — via git, not via dirname.
for layout in "nested:$NESTED" "sibling:$SIBLING" "normal:$CANON"; do
  name="${layout%%:*}"; root="${layout#*:}"
  # ">=1", not "==1": the git-derived and the belt-and-braces $root-derived probes coincide in the
  # normal and sibling layouts. Duplicates are expected here and are collapsed by the dedupe below.
  n="$(env_candidates "$root" | grep -cFx "$CANON/.env" || true)"
  check "$name: canonical .env is a candidate" "yes" "$([[ $n -ge 1 ]] && echo yes || echo no)"
  # And the OIV env, which is sibling-derived and had the identical nested-layout defect.
  n="$(env_candidates "$root" | grep -cFx "$OIV/.env" || true)"
  check "$name: OIV .env is a candidate" "yes" "$([[ $n -ge 1 ]] && echo yes || echo no)"
done
# The old mechanism, asserted to be insufficient on its own: from the nested worktree the
# sibling-derived probe points somewhere that does not exist. If this ever starts passing, the
# nested layout changed and the git-derived candidate is no longer load-bearing.
check "nested: sibling-derived probe is a dead path" "absent" \
      "$([[ -f "$(dirname "$NESTED")/onchain-accounting/.env" ]] && echo present || echo absent)"

echo "== precedence and hygiene =="
# A hand-placed worktree .env must WIN over the canonical clone's — that was the documented
# workaround for this very bug, and the fix must not silently override it.
printf 'ALCHEMY_API_KEY=local-sentinel\n' > "$NESTED/.env"
check "worktree-local .env beats canonical" "local-sentinel" "$(resolve_in "$NESTED")"
rm -f "$NESTED/.env"

# The union still matters: OIV carries endpoints the OA env has none for.
check "OIV-only vars still merge in" "from-oiv" "$(resolve_in "$NESTED" OIV_ONLY_URL)"
# ...but must not outrank the canonical clone on a shared key (chainlib.load_env's setdefault
# precedence; the pre-fix forward source order gave OIV the last word here).
check "canonical outranks OIV on a shared key" "from-canonical" "$(resolve_in "$NESTED" MAINNET_URL)"

# Dedupe: in a normal checkout the three OA candidates are one file, so the resolved set is exactly
# {OA .env, OIV .env} — two entries from six candidates. Sourcing the same file repeatedly would be
# harmless but would make the error listing lie about what was read.
check "normal clone dedupes 6 candidates to 2 files" "6->2" \
      "$( ( set -uo pipefail; ROOT="$CANON"; eval "$fn_src"; eval "$resolve_src"
            echo "$(env_candidates "$CANON" | wc -l)->${#ENV_FOUND[@]}" ) )"

# Must not error out under `set -e`/`set -u` when there is no repository at all.
NOREPO="$TMP/norepo"; mkdir -p "$NOREPO"
rc=0
( set -euo pipefail; ROOT="$NOREPO"; eval "$fn_src"; eval "$resolve_src" ) >/dev/null 2>&1 || rc=$?
check "outside a git repo: no error under set -euo" "0" "$rc"

echo "== chainlib.py twin =="
# chainlib.load_env feeds five preflight tools and had the identical sibling-derived defect.
for layout in "nested:$NESTED" "sibling:$SIBLING" "normal:$CANON"; do
  name="${layout%%:*}"; root="${layout#*:}"
  mkdir -p "$root/script/deploy/preflight"
  cp "$CHAINLIB" "$root/script/deploy/preflight/chainlib.py"
  got="$(cd "$root" && python3 -c '
import sys, pathlib
sys.path.insert(0, "script/deploy/preflight")
sys.modules.setdefault("requests", type(sys)("requests"))
import chainlib
print(int(pathlib.Path("'"$CANON"'/.env").resolve() in [p.resolve() for p in chainlib.DEFAULT_ENV_FILES]))
' 2>/dev/null || echo ERR)"
  check "chainlib $name: canonical .env is a candidate" "1" "$got"
  rm -rf "$root/script"
done

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
