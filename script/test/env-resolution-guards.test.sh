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

# Initialise $1 as a git repo with one commit.
mk() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.email t@t.invalid
  git -C "$1" config user.name t
  : > "$1/placeholder"
  git -C "$1" add placeholder
  git -C "$1" commit -qm init
}

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

echo "== precedence: MUST be byte-identical to the pre-fix behaviour =="
# This fix moves path derivation ONLY. Precedence is load-bearing: the OA and OIV .env files share
# 6 keys and disagree on 5 of them, MAINNET_URL included — and MAINNET_URL is the endpoint anvil
# forks from. A silent flip here would repoint the rehearsal at a different RPC for the sibling and
# normal layouts, which is what everyone uses today. So the shipped order is asserted against a
# faithful replay of the ORIGINAL loop, not against a hand-written expectation.
prefix_original() {
  # The pre-fix loop, verbatim: forward `source`, so the LAST file wins.
  local root="$1" var="$2"
  ( set -uo pipefail
    unset ALCHEMY_API_KEY MAINNET_URL OIV_ONLY_URL
    cd "$root" || exit 1
    for ENVF in .env "$(dirname "$root")/onchain-accounting/.env" \
                "$(dirname "$root")/onchain-investment-vehicles/.env"; do
      [[ -f "$ENVF" ]] && { set -a; source "$ENVF"; set +a; }
    done
    printf '%s' "${!var:-<unset>}" )
}
# In the two layouts that WORKED before, new and old must agree key-for-key.
for layout in "sibling:$SIBLING" "normal:$CANON"; do
  name="${layout%%:*}"; root="${layout#*:}"
  for var in ALCHEMY_API_KEY MAINNET_URL OIV_ONLY_URL; do
    check "$name/$var: unchanged vs pre-fix" "$(prefix_original "$root" "$var")" "$(resolve_in "$root" "$var")"
  done
done
# OIV keeps the last word on a shared key, exactly as before. (chainlib.load_env disagrees — it is
# setdefault, so first wins there. That inconsistency predates this fix and is deliberately NOT
# reconciled here; doing so would change which RPC the deploy tooling uses.)
check "OIV still outranks OA on a shared key" "from-oiv" "$(resolve_in "$NESTED" MAINNET_URL)"
# The union still matters: OIV carries endpoints the OA env has none for.
check "OIV-only vars still merge in" "from-oiv" "$(resolve_in "$NESTED" OIV_ONLY_URL)"

echo "== git must not be trusted from a non-worktree-top =="
# Two layouts where git answers rev-parse for a DIFFERENT repo than the caller means. Both must
# fall back to the sibling probes rather than sourcing an unrelated .env. Pre-fix they aborted
# loudly; resolving silently to the wrong file would be worse than the bug this PR fixes.

# (1) Bare-repo-backed worktree: --git-common-dir is the bare repo, whose parent is not a working
#     tree — often $HOME. The stand-in below defines a key the real .env does not, so a leak shows.
B="$TMP/bare"; mkdir -p "$B/onchain-accounting"
git -C "$CANON" clone -q --bare "$CANON" "$B/onchain-accounting.git" 2>/dev/null
printf 'ALCHEMY_API_KEY=leak\nLEAKED_ONLY=yes\n' > "$B/.env"
printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$B/onchain-accounting/.env"
git -C "$B/onchain-accounting.git" worktree add -q --detach "$B/oa-main" 2>/dev/null
check "bare-backed worktree: no leak from the bare repo's parent" "<unset>" \
      "$(resolve_in "$B/oa-main" LEAKED_ONLY)"
check "bare-backed worktree: still resolves the real key" "canonical-sentinel" \
      "$(resolve_in "$B/oa-main")"

# (2) A tree with no .git of its own inside an ancestor repo (vendored copy / tarball / Docker COPY):
#     git walks UP and answers the ancestor's .git.
O="$TMP/outer"; mkdir -p "$O/vendor/onchain-accounting" "$O/vendor/x"
mk "$O"
printf 'ALCHEMY_API_KEY=outer-leak\nOUTER_ONLY=yes\n' > "$O/.env"
printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$O/vendor/onchain-accounting/.env"
check "vendored tree: no leak from the ancestor repo" "<unset>" "$(resolve_in "$O/vendor/x" OUTER_ONLY)"
check "vendored tree: falls back to the sibling probe" "canonical-sentinel" "$(resolve_in "$O/vendor/x")"

# (3) A submodule: --git-common-dir answers `<super>/.git/modules/<name>`, whose parent is not a
#     working tree. Must degrade to the sibling probes, not adopt the SUPERPROJECT as the clone.
S="$TMP/super"; mk "$S"; mk "$TMP/subsrc"
printf 'ALCHEMY_API_KEY=super-leak\nSUPER_ONLY=yes\n' > "$S/.env"
git -C "$S" -c protocol.file.allow=always submodule add -q "$TMP/subsrc" onchain-accounting 2>/dev/null
printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$S/onchain-accounting/.env"
check "submodule: no leak from the superproject" "<unset>" \
      "$(resolve_in "$S/onchain-accounting" SUPER_ONLY)"
check "submodule: still resolves its own .env" "canonical-sentinel" \
      "$(resolve_in "$S/onchain-accounting")"

echo "== hygiene =="

# Dedupe: in a normal checkout the three OA candidates are one file, so the resolved set is exactly
# {OA .env, OIV .env} — two entries from six candidates. Sourcing the same file repeatedly would be
# harmless but would make the error listing lie about what was read.
check "normal clone dedupes 6 candidates to 2 files" "6->2" \
      "$( ( set -uo pipefail; ROOT="$CANON"; eval "$fn_src"; eval "$resolve_src"
            echo "$(env_candidates "$CANON" | wc -l)->${#ENV_FOUND[@]}" ) )"

# Must not error out under `set -e`/`set -u` when there is no repository at all — constraint (b).
# The root is deliberately buried where NO sibling probe can hit: a `$TMP/norepo` would still find
# $TMP/onchain-accounting and $TMP/onchain-investment-vehicles through the belt-and-braces probes,
# leaving ENV_FOUND with 2 entries and the empty-array expansion — the thing that actually breaks
# under `set -u` — never executed. Assert the emptiness explicitly so this cannot silently rot.
NOREPO="$TMP/isolated/deep/norepo"; mkdir -p "$NOREPO"
rc=0
( set -euo pipefail; ROOT="$NOREPO"; eval "$fn_src"; eval "$resolve_src" ) >/dev/null 2>&1 || rc=$?
check "outside a git repo: no error under set -euo" "0" "$rc"
check "outside a git repo: ENV_FOUND really is empty" "0" \
      "$( ( set -uo pipefail; ROOT="$NOREPO"; eval "$fn_src"; eval "$resolve_src"; echo "${#ENV_FOUND[@]}" ) )"
# And no candidate may exist there at all, or the case above is testing the wrong thing.
check "outside a git repo: zero candidates exist" "0" \
      "$( ( set -uo pipefail; eval "$fn_src"
            n=0; while IFS= read -r f; do [[ -f "$f" ]] && n=$((n+1)); done < <(env_candidates "$NOREPO")
            echo "$n" ) )"

echo "== chainlib.py twin =="
# chainlib.load_env feeds five preflight tools and had the identical sibling-derived defect.
# These assert the RESOLVED VALUE and the EXISTING-FILE ORDER, not merely "the path appears
# somewhere in the list" — the weaker form let a candidate be deleted, reordered, or the dedupe
# removed with the suite still green.
chainlib_in() {
  local root="$1" expr="$2"
  # chainlib derives REPO as parents[3] of its own file, so it must sit at the real depth.
  mkdir -p "$root/script/deploy/preflight"
  cp "$CHAINLIB" "$root/script/deploy/preflight/chainlib.py"
  ( cd "$root" && python3 -c "
import sys, types, os, pathlib
sys.modules.setdefault('requests', types.ModuleType('requests'))
sys.path.insert(0, 'script/deploy/preflight')
import chainlib
existing = [p for p in chainlib.DEFAULT_ENV_FILES if p.exists()]
for k in ('ALCHEMY_API_KEY','MAINNET_URL','OIV_ONLY_URL','LEAKED_ONLY','OUTER_ONLY'):
    os.environ.pop(k, None)
chainlib.load_env()
print($expr)
" 2>/dev/null || echo ERR )
  rm -rf "$root/script"
}
for layout in "nested:$NESTED" "sibling:$SIBLING" "normal:$CANON"; do
  name="${layout%%:*}"; root="${layout#*:}"
  # The key must actually RESOLVE — the property that matters, not list membership.
  check "chainlib $name: ALCHEMY_API_KEY resolves" "canonical-sentinel" \
        "$(chainlib_in "$root" "os.environ.get('ALCHEMY_API_KEY','<unset>')")"
  # Exact ordered list of files that exist: pins order, dedupe, and both candidates at once.
  check "chainlib $name: existing candidates, in order" "['$CANON/.env', '$OIV/.env']" \
        "$(chainlib_in "$root" "[str(p.resolve()) for p in existing]")"
  # setdefault means FIRST wins, so the OA env must supply a key both files define.
  check "chainlib $name: OA outranks OIV (setdefault)" "from-canonical" \
        "$(chainlib_in "$root" "os.environ.get('MAINNET_URL','<unset>')")"
  # ...and the OIV-only endpoints must still be merged in.
  check "chainlib $name: OIV-only vars merge in" "from-oiv" \
        "$(chainlib_in "$root" "os.environ.get('OIV_ONLY_URL','<unset>')")"
done
# The same non-worktree-top guard as the shell side.
check "chainlib bare-backed worktree: no leak" "<unset>" \
      "$(chainlib_in "$B/oa-main" "os.environ.get('LEAKED_ONLY','<unset>')")"
check "chainlib vendored tree: no leak" "<unset>" \
      "$(chainlib_in "$O/vendor/x" "os.environ.get('OUTER_ONLY','<unset>')")"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
