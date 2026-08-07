#!/usr/bin/env bash
# Guard tests for the two rehearsal-harness defects whose shared symptom is "the run goes green
# while testing nothing":
#
#   (1) FORK_URL was hardcoded to Ethereum mainnet while `rehearse_fork.sh` honoured $CHAIN_ID in 17
#       other places, so `rehearse_fork.sh 8453` read Base's config, wrote Base's records and
#       asserted Base's post-conditions against a fork of ETHEREUM. No non-mainnet chain had ever
#       actually been rehearsed.
#   (3) `08_DeployAssetKindRegistry` REUSES a recorded `AssetKindRegistry` when the deployment record
#       names one, and `reset_deployment_records.py` never cleared that key — so once the redeploy
#       writes it, every later rehearsal skips the deploy and (per 08's own header) grants the NEW
#       NAV's MANAGER to a registry still bound to the OLD proxy, completing GREEN.
#
# Both are asserted against the SHIPPING code, not a restatement of it. No network, no RPC, no
# provider units: every case exercises resolution and record logic only.
#
# Not wired into CI (this repo has no bash test runner). Run it by hand:
#   bash script/test/rehearsal-harness-guards.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/script/deploy/preflight/rehearse_fork.sh"
CHAINLIB="$REPO_ROOT/script/deploy/preflight/chainlib.py"
RESET="$REPO_ROOT/script/deploy/preflight/reset_deployment_records.py"
for f in "$TARGET" "$CHAINLIB" "$RESET"; do
  [[ -f "$f" ]] || { echo "cannot find $f" >&2; exit 1; }
done

pass=0
fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %-58s %s\n' "$name" "$got"; pass=$((pass+1))
  else
    printf '  FAIL %-58s want=%s got=%s\n' "$name" "$want" "$got"; fail=$((fail+1))
  fi
}

py() { python3 -c "
import sys, types
sys.modules.setdefault('requests', types.ModuleType('requests'))
sys.path.insert(0, '$REPO_ROOT/script/deploy/preflight')
$1"; }

echo "== (1) the fork endpoint must follow \$CHAIN_ID =="
# A synthetic key so nothing here depends on the operator's real .env, and no real endpoint is used.
export ALCHEMY_API_KEY=guard-test-key
# Clear every per-chain override so the CHAIN CONFIG path is what is under test; otherwise a
# populated $BASE_URL etc. would mask a regression in the config-derived branch.
unset MAINNET_URL BASE_URL ARBITRUM_URL GNOSIS_URL BNB_URL OP_URL HYPEREVM_URL 2>/dev/null || true

# THE REGRESSION. Distinct chains must yield DISTINCT hosts; the old code yielded eth-mainnet for all.
hosts="$(py "
import chainlib
seen=[]
for cid in (1, 8453, 42161, 100, 56):
    u,_ = chainlib.fork_rpc(cid)
    seen.append(u.split('/')[2] if u else 'NONE')
print(' '.join(seen))
")"
check "distinct chains -> distinct hosts" "5" "$(tr ' ' '\n' <<<"$hosts" | sort -u | wc -l | tr -d "[:space:]")"
check "chain 8453 is NOT ethereum mainnet" "base-mainnet.g.alchemy.com" "$(cut -d' ' -f2 <<<"$hosts")"
check "chain 1 is still ethereum mainnet"  "eth-mainnet.g.alchemy.com"  "$(cut -d' ' -f1 <<<"$hosts")"

# The operator override must outrank the chain config — a rehearsal has to fork the endpoint the
# deploy will use, which is how chains the Alchemy app has disabled get reached at all.
check "\$<CHAIN>_URL overrides the chain config" "override.example" \
      "$(BASE_URL=https://override.example/x py "
import chainlib
u,_ = chainlib.fork_rpc(8453); print(u.split('/')[2])")"
check "...and chain 1 honours \$MAINNET_URL, as it always did" "m.example" \
      "$(MAINNET_URL=https://m.example/x py "
import chainlib
u,_ = chainlib.fork_rpc(1); print(u.split('/')[2])")"

# FAIL CLOSED. An unresolvable chain must yield nothing, never another chain's endpoint.
check "unresolvable chain resolves to NOTHING" "None" \
      "$(py "
import chainlib
u,_ = chainlib.fork_rpc(424242); print(u)")"
rc=0; python3 "$CHAINLIB" fork-rpc 424242 >/dev/null 2>&1 || rc=$?
check "...and the CLI exits non-zero for it" "3" "$rc"
rc=0; python3 "$CHAINLIB" fork-rpc 8453 >/dev/null 2>&1 || rc=$?
check "...while a resolvable chain exits 0" "0" "$rc"
# The URL carries the API key, so it must go to stdout ONLY — never mixed into the human note.
check "CLI keeps the key off stderr" "0" \
      "$(python3 "$CHAINLIB" fork-rpc 8453 2>&1 >/dev/null | grep -c 'guard-test-key' || true)"

# The shipped script must actually USE that resolver and must abort, not substitute, on failure.
check "rehearse_fork.sh calls chainlib fork-rpc" "yes" \
      "$(grep -q 'chainlib.py fork-rpc' "$TARGET" && echo yes || echo no)"
# Comment lines are excluded deliberately: the fix's own comment quotes the old line verbatim so a
# reader can see what changed, and matching that would make this assertion permanently red.
# What must be gone is any EXECUTABLE assignment of a mainnet URL to FORK_URL.
check "no executable line hardcodes eth-mainnet into FORK_URL" "0" \
      "$(grep -vE '^[[:space:]]*#' "$TARGET" | grep -c 'FORK_URL=.*eth-mainnet' || true)"
# -E with an explicit optional group: the BRE forms `\(` and `\?` are not portable across grep
# implementations, and these guard scripts are meant to be run by hand on any developer machine.
check "FORK_URL is assigned exactly once, from the resolver" "1" \
      "$(grep -vE '^[[:space:]]*#' "$TARGET" | grep -cE '^[[:space:]]*(if ! )?FORK_URL=' || true)"
check "unresolvable chain aborts rather than falling back" "yes" \
      "$(sed -n '/^FORK_RPC_RC=0/,/^echo "fork endpoint/p' "$TARGET" | grep -q 'exit 2' && echo yes || echo no)"

# THE SECRET MUST NEVER REACH stdout OR stderr. The URL embeds $ALCHEMY_API_KEY, and stdout ends up
# in CI transcripts and shell logs; CodeQL flags precisely this (py/clear-text-logging-sensitive-data,
# high). chainlib therefore emits a SPEC naming the source and the caller assembles the URL itself.
check "CLI emits a spec, never a URL" "yes" \
      "$(python3 "$CHAINLIB" fork-rpc 1 2>/dev/null | grep -qE '^(env|alchemy|literal):' && echo yes || echo no)"
check "no API key in the CLI's combined output" "0" \
      "$(ALCHEMY_API_KEY=SENTINELKEYXYZ python3 "$CHAINLIB" fork-rpc 8453 2>&1 | grep -c 'SENTINELKEYXYZ' || true)"
check "CLI output contains no https:// for an env spec" "0" \
      "$(python3 "$CHAINLIB" fork-rpc 1 2>/dev/null | grep -c 'https://' || true)"

# The shell's `case` must materialise a spec EXACTLY as chainlib._materialise_spec does, or the two
# halves of this design drift and the rehearsal forks something neither side intended.
SPEC_CASE="$(sed -n '/^  case "\$FORK_RPC_SPEC" in/,/^  esac/p' "$TARGET")"
[[ -n "$SPEC_CASE" ]] || { echo "could not extract the spec case block from $TARGET" >&2; exit 1; }
for spec in "env:GUARD_TEST_VAR" "alchemy:base-mainnet" "literal:https://rpc.example/x" "bogus:thing"; do
  b="$( set -uo pipefail
        export GUARD_TEST_VAR="https://from-env/x" ALCHEMY_API_KEY="guard-test-key"
        FORK_RPC_SPEC="$spec"; FORK_URL=""; FORK_RPC_NOTE="n"
        eval "$SPEC_CASE"; printf '%s' "${FORK_URL:-<empty>}" )"
  p="$(GUARD_TEST_VAR="https://from-env/x" ALCHEMY_API_KEY="guard-test-key" py "
import sys, chainlib
sys.stdout.write(chainlib._materialise_spec('$spec') or '<empty>')")"
  check "bash materialises '$spec' as chainlib does" "$p" "$b"
done

# An operator override must be sufficient ON ITS OWN. The script used to refuse outright when
# ALCHEMY_API_KEY was unset, which contradicted this fix's premise: `$<CHAIN>_URL` OUTRANKS the
# chain config, so `MAINNET_URL=https://my-own-node` is a complete rehearsal setup needing no
# Alchemy account. chainlib only emits an `alchemy:` spec when the key exists, so the requirement is
# already enforced per chain, where it applies.
check "override alone resolves chain 1 without an Alchemy key" "env:MAINNET_URL" \
      "$(env -u ALCHEMY_API_KEY MAINNET_URL=https://my-own-node/x \
         python3 "$CHAINLIB" fork-rpc 1 2>/dev/null)"
# In-process, with load_env deliberately NOT called: `env -u` alone proves nothing here, because
# load_env re-reads both variables from the .env files on disk and puts them straight back.
check "a chain needing Alchemy resolves to nothing without the key" "None" \
      "$(py "
import os, chainlib
for v in ('ALCHEMY_API_KEY', 'BASE_URL'):
    os.environ.pop(v, None)
print(chainlib.fork_rpc_spec(8453)[0])")"
check "...and says why" "unresolved (\$ALCHEMY, ALCHEMY_API_KEY)" \
      "$(py "
import os, chainlib
for v in ('ALCHEMY_API_KEY', 'BASE_URL'):
    os.environ.pop(v, None)
print(chainlib.fork_rpc_spec(8453)[1])")"
# ...while the same chain resolves fine once an override is supplied, no Alchemy account needed.
check "...but an override alone is enough for it too" "env:BASE_URL" \
      "$(py "
import os, chainlib
os.environ.pop('ALCHEMY_API_KEY', None)
os.environ['BASE_URL'] = 'https://my-own-base/x'
print(chainlib.fork_rpc_spec(8453)[0])")"
check "no unconditional ALCHEMY_API_KEY gate remains" "0" \
      "$(grep -vE '^[[:space:]]*#' "$TARGET" | grep -c 'z "\${ALCHEMY_API_KEY:-}"' || true)"
# The candidate listing that gate carried was useful; it must survive in the one refusal point.
check "the refusal still lists .env candidates" "yes" \
      "$(sed -n '/^if \[\[ -z "\$FORK_URL" \]\]; then/,/^fi$/p' "$TARGET" \
         | grep -q 'env_candidates' && echo yes || echo no)"

# The public fallback is KEPT deliberately, and its announcement is the property that makes keeping
# it defensible — a fallback run is correct-by-announcement, not silent. Removing the fallback would
# make chains 143/196/204/43111/16661 un-rehearsable entirely, trading a loud correct degradation
# for no capability. So the banner is asserted, not assumed.
BANNER_BLOCK="$(sed -n '/if \[\[ "\$FORK_RPC_NOTE" == public/,/^fi$/p' "$TARGET")"
check "a public fallback raises a banner" "yes" \
      "$([[ -n "$BANNER_BLOCK" ]] && echo yes || echo no)"
check "the banner warns the deploy would fail" "yes" \
      "$(grep -q 'DEPLOY would fail' <<<"$BANNER_BLOCK" && echo yes || echo no)"
check "the banner reaches the step table too" "yes" \
      "$(grep -q 'PUBLIC-FALLBACK' <<<"$BANNER_BLOCK" && echo yes || echo no)"
# ...and must NOT fire for a normally-resolved endpoint, or every run screams.
check "no banner for a normally resolved endpoint" "quiet" \
      "$( FORK_RPC_NOTE="env MAINNET_URL"
          [[ "$FORK_RPC_NOTE" == public\ fallback* ]] && echo BANNER || echo quiet )"

echo "== (3) the reset must clear the key 08 branches on =="
check "AssetKindRegistry is in CLEAR_TOP" "True" \
      "$(py "import reset_deployment_records as r; print('AssetKindRegistry' in r.CLEAR_TOP)")"
# 08 reuses a recorded registry instead of deploying one, so a surviving value makes the step a
# no-op. Drive the real planner against a record where the key IS populated — the post-redeploy
# state, which is when this fires (the key is absent from every record today).
check "a populated key is cleared by the plan" "cleared" \
      "$(py "
import reset_deployment_records as r, chainlib as c, json, copy, tempfile, pathlib, shutil
# Work on a COPY. `script/config/deployments/1.json` is the only record of what production runs;
# an interrupt mid-test must not be able to leave a fabricated address in it.
rec = c.deployment(1)
tmp = copy.deepcopy(rec); tmp['AssetKindRegistry'] = '0x' + '11'*20
d = pathlib.Path(tempfile.mkdtemp())
(d / '1.json').write_text(json.dumps(tmp, indent=2))
c.DEPLOY_DIR = d
_, ch = r.plan_for(1)
shutil.rmtree(d, ignore_errors=True)
print('cleared' if any(x.startswith('AssetKindRegistry') for x in ch) else 'SURVIVED')")"
# And the branch 08 takes must flip as a result.
check "08 would deploy fresh after the reset" "DEPLOY-FRESH" \
      "$(py "
import reset_deployment_records as r, chainlib as c, json, copy, tempfile, pathlib, shutil
rec = c.deployment(1)
tmp = copy.deepcopy(rec); tmp['AssetKindRegistry'] = '0x' + '11'*20
d = pathlib.Path(tempfile.mkdtemp())
(d / '1.json').write_text(json.dumps(tmp, indent=2))
c.DEPLOY_DIR = d
out, _ = r.plan_for(1)
shutil.rmtree(d, ignore_errors=True)
print('REUSE' if out.get('AssetKindRegistry') else 'DEPLOY-FRESH')")"
# The bridge stack must still be left alone — clearing it would be a different, worse bug.
check "an ABSENT CLEAR_TOP key is created blank, not skipped" "created-blank" \
      "$(py "
import reset_deployment_records as r, chainlib as c, json, copy, tempfile, pathlib, shutil
rec = c.deployment(1); tmp = copy.deepcopy(rec); tmp.pop('AssetKindRegistry', None)
d = pathlib.Path(tempfile.mkdtemp()); (d / '1.json').write_text(json.dumps(tmp, indent=2))
c.DEPLOY_DIR = d
out, ch = r.plan_for(1)
shutil.rmtree(d, ignore_errors=True)
ok = out.get('AssetKindRegistry') == '' and any('AssetKindRegistry' in x for x in ch)
print('created-blank' if ok else 'MISSING')")"
# verify_step.step_record_cleared iterates CLEAR_TOP and FAILS on absence, so every CLEAR_TOP key
# must exist in the planned record or runbook gate 1.1 breaks on every chain.
check "every CLEAR_TOP key exists in the planned record" "True" \
      "$(py "
import reset_deployment_records as r, chainlib as c
out, _ = r.plan_for(1)
print(all(k in out for k in r.CLEAR_TOP))")"
# Key CREATION must be scoped. `deployer_balances.scope()` counts `*Assistant` keys by PRESENCE to
# decide whether a chain deploys assistants — 23 of 25 records have none — so creating them would
# make every chain report three and inflate its gas estimate by 10.5M, a false "TOP UP" on chains
# that deploy none. Only AssetKindRegistry may be created: it is absent from ALL records, so it
# carries no signal to destroy.
check "creating keys does not invent assistants" "preserved" \
      "$(py "
import reset_deployment_records as r, chainlib as c
bad = []
for cid in c.all_chain_ids():
    before = len([k for k in c.deployment(cid) if k.endswith('Assistant')])
    after  = len([k for k in r.plan_for(cid)[0] if k.endswith('Assistant')])
    if before != after: bad.append((cid, before, after))
print('preserved' if not bad else 'INVENTED %s' % bad[:3])")"
check "only AssetKindRegistry is create-if-absent" "{'AssetKindRegistry'}" \
      "$(py "import reset_deployment_records as r; print(r.CREATE_IF_ABSENT)")"
check "bridge keys still NOT cleared" "True" \
      "$(py "
import reset_deployment_records as r
print(not ({'BridgeEscrowImplementation','BridgeEscrowProxy','bridgeAdapters'} & set(r.CLEAR_TOP)))")"
# The planner must not mutate the record on disk.
check "planning leaves the record untouched" "clean" \
      "$(cd "$REPO_ROOT" && py "import reset_deployment_records as r; r.plan_for(1)" >/dev/null 2>&1
         cd "$REPO_ROOT" && [[ -z "$(git status --porcelain -- script/config/deployments)" ]] && echo clean || echo DIRTY)"

echo "== (4) the NO-OP detector must catch every skip line the scripts actually emit =="
# Found by sweeping the class behind (3). Exactly one script emits the capitalised
# "  Already deployed at:" the detector originally matched; `02`, `02_2`, `08` and all ~34 custom
# feeds in `03` are lowercase, and `grep -E` is case-sensitive — so the guard against "exited 0
# having done nothing" was blind to nearly every script it covers.
# `sed -E`, not `grep -oP`: PCRE is GNU-only and absent from BSD/macOS grep, and these guard
# scripts are explicitly meant to be run by hand on a developer's machine.
NOOP_RE="$(sed -nE 's/^[[:space:]]*local noop_re="(.*)"$/\1/p' "$TARGET" | head -1)"
[[ -n "$NOOP_RE" ]] || { echo "could not extract noop_re from $TARGET" >&2; exit 1; }
noop_hit() { printf '%s\n' "$1" | grep -qaE "$NOOP_RE" && echo caught || echo missed; }

# Real skip lines, copied from the shipping deploy scripts.
check "04 capitalised skip"                "caught" "$(noop_hit '  Already deployed at: 0x1111')"
check "02_2 [SKIP] NAV proxy"              "caught" "$(noop_hit '[SKIP] NAV proxy already deployed at: 0x2222')"
check "08 registry reuse"                  "caught" "$(noop_hit 'AssetKindRegistry already deployed at: 0x3333')"
check "03 custom feed skip"                "caught" "$(noop_hit 'wstETH_CustomPriceFeed already deployed at: 0x4444')"
check "RegisterAssets precondition unmet"  "caught" "$(noop_hit 'NAVCalculator not deployed for this chain')"
# ...and must NOT fire on lines that report real work, or every rehearsal reads as a no-op.
check "success line is not flagged"        "missed" "$(noop_hit 'Deployed AssetKindRegistry at: 0x5555')"
check "timing line is not flagged"         "missed" "$(noop_hit '  OK  12s  gas=1234')"

# Cross-check against the SOURCE rather than a hand-written list: every distinct skip phrase the
# deploy scripts emit must be matched. This is what stops the detector drifting behind the scripts
# again — a new script with a new phrasing fails here instead of silently scoring OK.
# Harvest on `already deployed` — NOT `already deployed at:`. Keying the harvest to the literal
# the regex matches made this check tautological: it could only ever find phrases that already
# passed, which is exactly how `eETH_CustomPriceFeed already deployed:` and `CrossRate monitor
# already deployed:` (no "at") survived the previous round with the suite green.
harvest() {
  grep -rhoiE '"[^"]*already deployed[^"]*"' "$REPO_ROOT"/script/deploy/*.s.sol 2>/dev/null \
    | tr -d '"' | sort -u
}
missed="$(harvest | while IFS= read -r phrase; do
            printf '%s\n' "$phrase" | grep -qaE "$NOOP_RE" || printf '%s\n' "$phrase"
          done | wc -l | tr -d "[:space:]")"
check "every skip phrase in script/deploy is matched" "0" "$missed"
# ...and the harvest must actually be finding things, or "0 missed" is vacuous.
check "the harvest is non-empty" "yes" "$([[ "$(harvest | wc -l | tr -d "[:space:]")" -ge 20 ]] && echo yes || echo no)"
# It must also cover the two phrasings that have no "at", or it has narrowed again.
check "harvest includes the at-less phrasings" "2" \
      "$(harvest | grep -c 'already deployed:' || true)"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
