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
# The block runs from `ENV_FOUND=()` to the `fi` closing the source loop, both at column 0.
fn_src="$(sed -n '/^env_candidates() {/,/^}/p' "$TARGET")"
[[ -n "$fn_src" ]] || { echo "could not extract env_candidates from $TARGET" >&2; exit 1; }
load_src="$(sed -n '/^load_env_files() {/,/^}/p' "$TARGET")"
[[ -n "$load_src" ]] || { echo "could not extract load_env_files from $TARGET" >&2; exit 1; }
resolve_src="$(sed -n '/^ENV_FOUND=()/,/^fi$/p' "$TARGET")"
[[ -n "$resolve_src" ]] || { echo "could not extract the resolution block from $TARGET" >&2; exit 1; }
# A silently-truncated or runaway extraction would make every case below vacuous, so assert the
# region's shape rather than merely that it is non-empty.
# -F throughout: these anchors contain `$` and `(`, which an ERE would read as metacharacters.
while IFS= read -r anchor; do
  grep -qF -- "$anchor" <<<"$resolve_src" || {
    echo "extracted block is missing '$anchor' — the sed range has drifted from $TARGET" >&2; exit 1; }
done <<'ANCHORS'
ENV_FOUND=()
env_candidates "$ROOT"
load_env_files
ANCHORS
grep -qx 'fi' <<<"$resolve_src" || {
  echo "extracted block does not end at the closing 'fi' — the sed range has drifted" >&2; exit 1; }
grep -q 'ALCHEMY_API_KEY is not set' <<<"$resolve_src" && {
  echo "extracted block overran into the refusal check — see the range comment" >&2; exit 1; }

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
    eval "$load_src"
    eval "$resolve_src"
    printf '%s' "${!var:-<unset>}"
  )
}

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

echo "== the git-derived candidate must be LOAD-BEARING, not a duplicate =="
# The fixture above names the canonical clone literally `onchain-accounting`, which is realistic —
# and is exactly why the cases above cannot, on their own, prove the git-derived candidate does any
# work: it comes out byte-identical to the hardcoded-name sibling probe, so deleting it leaves them
# green. This second fixture names the clone something else, so NOTHING that hardcodes the
# directory name can find it and only `--git-common-dir` can. (The precedence cases below still use
# the realistically-named clone, because their pre-fix replay depends on that name.)
REN="$TMP/renamed/oa-canonical"
mk "$REN"
printf 'ALCHEMY_API_KEY=renamed-sentinel\n' > "$REN/.env"
REN_SIB="$TMP/renamed/wt-sibling"
git -C "$REN" worktree add -q --detach "$REN_SIB"
REN_NEST="$REN/.claude/worktrees/nested"
mkdir -p "$(dirname "$REN_NEST")"
git -C "$REN" worktree add -q --detach "$REN_NEST"
check "renamed clone, normal:  only git can find it" "renamed-sentinel" "$(resolve_in "$REN")"
check "renamed clone, sibling: only git can find it" "renamed-sentinel" "$(resolve_in "$REN_SIB")"
check "renamed clone, nested:  only git can find it" "renamed-sentinel" "$(resolve_in "$REN_NEST")"
check "renamed clone: chainlib finds it too" "renamed-sentinel" \
      "$(chainlib_in "$REN_NEST" "os.environ.get('ALCHEMY_API_KEY','<unset>')")"
# Prove the premise: no directory named onchain-accounting exists anywhere near it, so a
# name-hardcoding probe cannot possibly succeed and these four cases isolate the git-derived path.
check "renamed clone: no name-hardcoded probe could hit" "0" \
      "$( ( set -uo pipefail
            n=0
            for r in "$REN" "$REN_SIB" "$REN_NEST"; do
              [[ -f "$(dirname "$r")/onchain-accounting/.env" ]] && n=$((n+1))
            done; echo "$n" ) )"

echo "== precedence: FIRST wins, and bash must agree with chainlib =="
# The invariant asserted here CHANGED deliberately. It used to be "byte-identical to the pre-fix
# behaviour", which pinned bash to forward-`source` (LAST file wins -> OIV) while chainlib used
# `setdefault` (FIRST wins -> OA). The two therefore disagreed on 5 of the 6 keys the real .env
# files share, MAINNET_URL among them — the endpoint the rehearsal forks — so the script's own
# "one endpoint inventory" claim was false. The rule is now FIRST-wins on both sides, stated
# explicitly rather than emerging from `source` order versus `setdefault`.
#
# Precedence, highest first: environment > local .env > canonical clone > OIV. Union still applies,
# so a key only OIV defines still arrives.
check "first wins: canonical outranks OIV on a shared key" "from-canonical" \
      "$(resolve_in "$NESTED" MAINNET_URL)"
check "union: an OIV-only key still merges in" "from-oiv" "$(resolve_in "$NESTED" OIV_ONLY_URL)"
# A value already exported beats every file — the `setdefault` half of the rule. `source` did not do
# this, so an operator's `FOO=... rehearse_fork.sh` used to be silently overridden by a .env.
check "environment outranks every file" "from-the-shell" \
      "$( ( set -uo pipefail; export MAINNET_URL=from-the-shell; ROOT="$NESTED"
            eval "$fn_src"; eval "$load_src"; eval "$resolve_src"; printf '%s' "$MAINNET_URL" ) )"
# A local .env outranks the canonical clone (it is earlier in candidate order).
printf 'MAINNET_URL=from-local\n' > "$NESTED/.env"
check "local .env outranks the canonical clone" "from-local" "$(resolve_in "$NESTED" MAINNET_URL)"
rm -f "$NESTED/.env"

# QUOTE TORTURE. Every .env this suite writes was bare KEY=value — not one test value contained a
# quote character — so the invariant below could not exercise the quote rule it exists to pin. That
# gap hid two divergences: `A="\'x\'"` resolved to `x` in bash and `\'x\'` in chainlib, and `C="\'"`
# made bash evaluate a negative-length substring and ABORT the whole script under `set -uo pipefail`.
QT="$TMP/quote-torture"; mkdir -p "$QT"
printf 'Q_A="\x27x\x27"\nQ_B=\x27"y"\x27\nQ_C="\x27"\nQ_D="\x27\x27"\nQ_E=""\nQ_F=\x27\x27\nQ_G="unterminated\n' > "$QT/.env"
qt_rc=0
( set -uo pipefail; eval "$load_src"; load_env_files "$QT/.env" ) >/dev/null 2>&1 || qt_rc=$?
check "quoted values do not abort the loader" "0" "$qt_rc"
for qk in Q_A Q_B Q_C Q_D Q_E Q_F Q_G; do
  qb="$( set -uo pipefail; eval "$load_src"; load_env_files "$QT/.env" 2>/dev/null
         printf '%s' "${!qk-<UNSET>}" )"
  qp="$(python3 -c "
import sys, types, pathlib, os
sys.modules.setdefault('requests', types.ModuleType('requests'))
sys.path.insert(0, '$REPO_ROOT/script/deploy/preflight')
import chainlib
chainlib.load_env(pathlib.Path('$QT/.env'))
sys.stdout.write(os.environ.get('$qk', '<UNSET>'))")"
  check "quote rule: bash == chainlib for $qk" "$qp" "$qb"
done

# THE CROSS-IMPLEMENTATION INVARIANT. This is the assertion the divergence would have had to break:
# every key, resolved through the shipped bash parser and through chainlib.load_env, must match.
for var in ALCHEMY_API_KEY MAINNET_URL OIV_ONLY_URL; do
  b="$(resolve_in "$NESTED" "$var")"
  p="$(chainlib_in "$NESTED" "os.environ.get('$var','<unset>')")"
  check "bash == chainlib for $var" "$b" "$p"
done

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

# (4) The guard must fail CLOSED when it cannot RESOLVE a path, not just when git refuses.
#     `readlink -f` does not exist on BSD/macOS and prints nothing when it cannot resolve, so a
#     readlink-based comparison degrades to "" == "" — passing precisely when nothing was verified,
#     and re-opening the vendored-tree leak on every non-GNU box. Simulated by shadowing readlink
#     with a stub that produces no output, which is what those platforms effectively give us.
#     (A plain nonexistent root does NOT exercise this: `git rev-parse` fails first.)
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\nexit 1\n' > "$STUB/readlink"; chmod +x "$STUB/readlink"
check "readlink unavailable: vendored tree still no leak" "<unset>" \
      "$( PATH="$STUB:$PATH" resolve_in "$O/vendor/x" OUTER_ONLY )"
check "readlink unavailable: bare-backed still no leak" "<unset>" \
      "$( PATH="$STUB:$PATH" resolve_in "$B/oa-main" LEAKED_ONLY )"
# ...and a genuinely unresolvable root must still not error out.
check "unresolvable root: no error under set -euo" "0" \
      "$( rc=0; ( set -euo pipefail; ROOT="$TMP/does/not/exist"; eval "$fn_src"; eval "$load_src"; eval "$resolve_src" ) \
          >/dev/null 2>&1 || rc=$?; echo $rc )"

# (5) A bare repo whose PARENT is itself a working tree — a dotfiles-managed $HOME is the ordinary
#     case. `$canon` is then a genuine worktree top, so checking only that is NOT enough: the guard
#     must confirm $canon OWNS the git dir it was derived from, or the dotfiles .env is sourced.
H="$TMP/home"; mk "$H"
printf 'ALCHEMY_API_KEY=leak\nDOTFILES_ONLY=yes\n' > "$H/.env"
mk "$TMP/hsrc"
git clone -q --bare "$TMP/hsrc" "$H/onchain-accounting.git" 2>/dev/null
mkdir -p "$H/onchain-accounting"; printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$H/onchain-accounting/.env"
git -C "$H/onchain-accounting.git" worktree add -q --detach "$H/oa-main" 2>/dev/null
check "bare repo inside a repo: no dotfiles leak" "<unset>" "$(resolve_in "$H/oa-main" DOTFILES_ONLY)"
check "bare repo inside a repo: real key still resolves" "canonical-sentinel" "$(resolve_in "$H/oa-main")"
check "chainlib: no dotfiles leak" "<unset>" \
      "$(chainlib_in "$H/oa-main" "os.environ.get('DOTFILES_ONLY','<unset>')")"

# (6) GIT_DIR exported. git sets it for hooks, so a rehearsal launched from one hits this. With it
#     set and no GIT_WORK_TREE, `rev-parse --show-toplevel` echoes the cwd for ANY directory, which
#     makes both guards vacuous unless the git environment is cleared for the discovery calls.
E="$TMP/evil"; mk "$E"; printf 'ALCHEMY_API_KEY=evil\nEVIL_ONLY=yes\n' > "$E/.env"
check "GIT_DIR set: no leak from the pointed-at repo" "<unset>" \
      "$( GIT_DIR="$E/.git" resolve_in "$NESTED" EVIL_ONLY )"
check "GIT_DIR set: canonical still resolves" "canonical-sentinel" \
      "$( GIT_DIR="$E/.git" resolve_in "$NESTED" )"
check "chainlib GIT_DIR set: no leak" "<unset>" \
      "$( GIT_DIR="$E/.git" chainlib_in "$NESTED" "os.environ.get('EVIL_ONLY','<unset>')" )"

# (7) `git init --separate-git-dir=<dir>` where <dir>'s parent is a working tree. This is the
#     SUPPORTED way to relocate a git dir (it writes a `.git` file, not a symlink), and it reaches
#     the same hole as (5) by a different route: --git-common-dir is absolute and elsewhere.
SEP="$TMP/sepdir"; mk "$SEP/homeish"
printf 'ALCHEMY_API_KEY=leak\nSEPDIR_ONLY=yes\n' > "$SEP/homeish/.env"
mkdir -p "$SEP/work"
git init -q --separate-git-dir="$SEP/homeish/oa.git" "$SEP/work/onchain-accounting"
printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$SEP/work/onchain-accounting/.env"
check "separate-git-dir: no leak from the gitdir's parent" "<unset>" \
      "$(resolve_in "$SEP/work/onchain-accounting" SEPDIR_ONLY)"
check "chainlib separate-git-dir: no leak" "<unset>" \
      "$(chainlib_in "$SEP/work/onchain-accounting" "os.environ.get('SEPDIR_ONLY','<unset>')")"

# (8) A clone whose .git is a hand-made SYMLINK into an unrelated working tree. CHARACTERISATION
#     ONLY, not mutation-proven: git never creates .git as a symlink, and the gitdir-ownership
#     check in (5)/(7) rejects this regardless of whether the parent is taken lexically or after
#     resolving. Kept to pin the behaviour, not counted as coverage for the lexical-parent choice.
L="$TMP/linked/onchain-accounting"; mkdir -p "$TMP/linked"; mk "$L"
printf 'ALCHEMY_API_KEY=canonical-sentinel\n' > "$L/.env"
U="$TMP/unrelated"; mk "$U"; printf 'ALCHEMY_API_KEY=unrelated\nUNRELATED_ONLY=yes\n' > "$U/.env"
mv "$L/.git" "$U/oa-gitdir" && ln -s "$U/oa-gitdir" "$L/.git"
check "symlinked .git: no leak from the target's tree" "<unset>" "$(resolve_in "$L" UNRELATED_ONLY)"
check "chainlib symlinked .git: no leak" "<unset>" \
      "$(chainlib_in "$L" "os.environ.get('UNRELATED_ONLY','<unset>')")"

echo "== hygiene =="

# Dedupe: in a normal checkout the three OA candidates are one file, so the resolved set is exactly
# {OA .env, OIV .env} — two entries from six candidates. Sourcing the same file repeatedly would be
# harmless but would make the error listing lie about what was read.
check "normal clone dedupes 6 candidates to 2 files" "6->2" \
      "$( ( set -uo pipefail; ROOT="$CANON"; eval "$fn_src"; eval "$load_src"; eval "$resolve_src"
            echo "$(env_candidates "$CANON" | wc -l)->${#ENV_FOUND[@]}" ) )"

# Must not error out under `set -e`/`set -u` when there is no repository at all — constraint (b).
# The root is deliberately buried where NO sibling probe can hit: a `$TMP/norepo` would still find
# $TMP/onchain-accounting and $TMP/onchain-investment-vehicles through the belt-and-braces probes,
# leaving ENV_FOUND with 2 entries, so the zero-candidate path would never run at all.
#
# Scope note: on bash >= 4.4 `"${arr[@]}"` on an empty array is already safe under `set -u`, so
# these two cases do NOT detect removal of the `(( ${#ENV_FOUND[@]} > 0 ))` guard — that guard is
# belt-and-braces for older bash. What they DO catch is any expansion that indexes the array
# unguarded (e.g. `${ENV_FOUND[0]}`), which is mutation-proven.
NOREPO="$TMP/isolated/deep/norepo"; mkdir -p "$NOREPO"
rc=0
( set -euo pipefail; ROOT="$NOREPO"; eval "$fn_src"; eval "$load_src"; eval "$resolve_src" ) >/dev/null 2>&1 || rc=$?
check "outside a git repo: no error under set -euo" "0" "$rc"
check "outside a git repo: ENV_FOUND really is empty" "0" \
      "$( ( set -uo pipefail; ROOT="$NOREPO"; eval "$fn_src"; eval "$load_src"; eval "$resolve_src"; echo "${#ENV_FOUND[@]}" ) )"
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
