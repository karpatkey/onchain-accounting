#!/usr/bin/env bash
# Guard tests for refresh-integration-snapshot.sh: `harvest_chain` and
# `finalize_step2_outcomes`.
#
# Why this exists: the defect these guards close was invisible for five weeks and produced a
# report that read like a 19% NAV over-report (PR #174, ACCOUNT_8_COMPOUND_BASE). The bug was
# a counted-but-unchecked variable, so the only way to keep it closed is a test that fails when
# the check is removed. Each case below is mutation-proven — see the PR body.
#
# It extracts `harvest_chain` from the real script rather than restating it, so the code under
# test cannot drift away from the code that ships. `jq_inplace` is stubbed to record writes.
#
# Not wired into CI (this repo has no bash test runner). Run it by hand:
#   bash script/test/refresh-snapshot-guards.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/refresh-integration-snapshot.sh"
[[ -f "$TARGET" ]] || { echo "cannot find $TARGET" >&2; exit 1; }

# Pull the function out of the shipping script verbatim.
fn_src=$(sed -n '/^harvest_chain() {/,/^}/p' "$TARGET")
[[ -n "$fn_src" ]] || { echo "could not extract harvest_chain from $TARGET" >&2; exit 1; }

applied=()
jq_inplace() { applied+=("$1"); }
eval "$fn_src"

pass=0
fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %-52s %s\n' "$name" "$got"
    pass=$((pass+1))
  else
    printf '  FAIL %-52s want=%s got=%s\n' "$name" "$want" "$got"
    fail=$((fail+1))
  fi
}

# Drive one synthetic chain through harvest_chain and report its bucket + write count.
# `rc` and the SNAPSHOT lines are the only inputs harvest_chain reads.
run_case() {
  local rc="$1" lines="$2"
  forge_dir=$(mktemp -d)
  printf '%s' "$rc" > "$forge_dir/999.rc"
  printf '%s' "$lines" > "$forge_dir/999.out"
  : > "$forge_dir/999.err"
  failed_chains=(); ok_chains=(); applied=()
  # Status captured, not discarded: the real script calls `harvest_chain "$chain_id"` bare
  # under `set -euo pipefail`, so a non-zero return would abort the refresh mid-harvest.
  harvest_rc=0
  harvest_chain 999 >/dev/null 2>&1 || harvest_rc=$?
  rm -rf "$forge_dir"
  if (( ${#ok_chains[@]} > 0 )); then bucket=ok; else bucket=failed; fi
  writes=${#applied[@]}
}

HEALTHY='SNAPSHOT|999|0|0xaaaa|12345|false|0
SNAPSHOT|999|1|0xbbbb|67890|false|0'

echo "harvest_chain guard tests"

run_case 0 "$HEALTHY"
check "healthy chain is ok"                    "ok"     "$bucket"
check "healthy chain applies both snapshots"   "2"      "$writes"

# The exact #174 condition: forge succeeded, emitted nothing usable.
run_case 0 ""
check "rc=0 with zero SNAPSHOT lines fails"    "failed" "$bucket"
check "zero-snapshot path returns 0"           "0"      "$harvest_rc"
check "zero-snapshot chain writes nothing"     "0"      "$writes"

run_case 1 "$HEALTHY"
check "rc!=0 fails even with good lines"       "failed" "$bucket"
check "rc!=0 writes nothing"                   "0"      "$writes"

# Health flags: these were parsed into _seq/_stale and discarded, so an unhealthy NAV could be
# pinned as the expectation and every later run would agree with it.
run_case 0 'SNAPSHOT|999|0|0xaaaa|12345|true|0'
check "sequencerDown fails the chain"          "failed" "$bucket"
check "sequencerDown path returns 0"           "0"      "$harvest_rc"
check "sequencerDown writes nothing"           "0"      "$writes"

run_case 0 'SNAPSHOT|999|0|0xaaaa|12345|false|3'
check "stale price assets fail the chain"      "failed" "$bucket"
check "stale-price chain writes nothing"       "0"      "$writes"

# Partial health must fail the WHOLE chain: applying only the healthy accounts would leave the
# rest stale beside an already-advanced forkBlock, which is the original bug in miniature.
run_case 0 'SNAPSHOT|999|0|0xaaaa|12345|false|0
SNAPSHOT|999|1|0xbbbb|67890|false|2'
check "one unhealthy line fails whole chain"   "failed" "$bucket"
check "partial-health chain writes nothing"    "0"      "$writes"


# ── finalize_step2_outcomes: the atomicity guarantee ─────────────────────────────
fin_src=$(sed -n '/^finalize_step2_outcomes() {/,/^}/p' "$TARGET")
[[ -n "$fin_src" ]] || { echo "could not extract finalize_step2_outcomes" >&2; exit 1; }
eval "$fin_src"

declare -A old_fork_block

run_finalize() {
  failed_chains=(); ok_chains=(); applied=(); skipped_chains=()
  chain_ids=$'1\n8453'
  old_fork_block=([1]=100 [8453]=200)
  # shellcheck disable=SC2206
  [[ -n "$1" ]] && failed_chains=($1)
  # shellcheck disable=SC2206
  [[ -n "$2" ]] && ok_chains=($2)
  # Capture the status rather than `|| true`-ing it away. The function early-returns via
  # `(( ... )) && return 0`, and a non-zero status escaping that under the script's
  # `set -euo pipefail` would abort the whole refresh at the point a chain fails — exactly
  # when the rollback is needed. Masking the status would hide that.
  fin_rc=0
  finalize_step2_outcomes >/dev/null 2>&1 || fin_rc=$?
  rollbacks=${#applied[@]}
  narrowed=$(printf '%s' "$chain_ids" | tr '\n' ',')
  skipped=$(printf '%s' "${skipped_chains[*]:-}")
}

echo
echo "finalize_step2_outcomes tests"

run_finalize "" "1 8453"
check "all-ok returns 0 (no set -e abort)"      "0"      "$fin_rc"
check "all-ok leaves chain_ids untouched"       "1,8453" "$narrowed"
check "all-ok rolls back nothing"               "0"      "$rollbacks"
check "all-ok reports no skipped chains"        ""       "$skipped"

# The #174 shape: Base produced no snapshot, mainnet did.
run_finalize "8453" "1"
check "failure path returns 0 (no set -e abort)" "0"     "$fin_rc"
check "failed chain is dropped from chain_ids"  "1"      "$narrowed"
check "failed chain forkBlock rolled back"      "1"      "$rollbacks"
check "failed chain named as skipped"           "8453"   "$skipped"

run_finalize "1 8453" ""
check "all-failed narrows chain_ids to empty"   ""       "$narrowed"
check "all-failed rolls back both"              "2"      "$rollbacks"

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
