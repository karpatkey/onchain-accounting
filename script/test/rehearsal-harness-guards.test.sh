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
check "distinct chains -> distinct hosts" "5" "$(tr ' ' '\n' <<<"$hosts" | sort -u | wc -l)"
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
check "FORK_URL is assigned exactly once, from the resolver" "1" \
      "$(grep -vE '^[[:space:]]*#' "$TARGET" | grep -c '^[[:space:]]*\(if ! \)\?FORK_URL=' || true)"
check "unresolvable chain aborts rather than falling back" "yes" \
      "$(sed -n '/^FORK_RPC_NOTE=/,/^fi$/p' "$TARGET" | grep -q 'exit 2' && echo yes || echo no)"

echo "== (3) the reset must clear the key 08 branches on =="
check "AssetKindRegistry is in CLEAR_TOP" "True" \
      "$(py "import reset_deployment_records as r; print('AssetKindRegistry' in r.CLEAR_TOP)")"
# 08 reuses a recorded registry instead of deploying one, so a surviving value makes the step a
# no-op. Drive the real planner against a record where the key IS populated — the post-redeploy
# state, which is when this fires (the key is absent from every record today).
check "a populated key is cleared by the plan" "cleared" \
      "$(py "
import reset_deployment_records as r, chainlib as c, json, copy
rec = c.deployment(1)
tmp = copy.deepcopy(rec); tmp['AssetKindRegistry'] = '0x' + '11'*20
p = c.DEPLOY_DIR / '1.json'; orig = p.read_text()
try:
    p.write_text(json.dumps(tmp, indent=2))
    _, ch = r.plan_for(1)
    print('cleared' if any(x.startswith('AssetKindRegistry') for x in ch) else 'SURVIVED')
finally:
    p.write_text(orig)")"
# And the branch 08 takes must flip as a result.
check "08 would deploy fresh after the reset" "DEPLOY-FRESH" \
      "$(py "
import reset_deployment_records as r, chainlib as c, json, copy
rec = c.deployment(1)
tmp = copy.deepcopy(rec); tmp['AssetKindRegistry'] = '0x' + '11'*20
p = c.DEPLOY_DIR / '1.json'; orig = p.read_text()
try:
    p.write_text(json.dumps(tmp, indent=2))
    out, _ = r.plan_for(1)
    print('REUSE' if out.get('AssetKindRegistry') else 'DEPLOY-FRESH')
finally:
    p.write_text(orig)")"
# The bridge stack must still be left alone — clearing it would be a different, worse bug.
check "bridge keys still NOT cleared" "True" \
      "$(py "
import reset_deployment_records as r
print(not ({'BridgeEscrowImplementation','BridgeEscrowProxy','bridgeAdapters'} & set(r.CLEAR_TOP)))")"
# The planner must not mutate the record on disk.
check "planning leaves the record untouched" "clean" \
      "$(cd "$REPO_ROOT" && py "import reset_deployment_records as r; r.plan_for(1)" >/dev/null 2>&1
         cd "$REPO_ROOT" && [[ -z "$(git status --porcelain -- script/config/deployments)" ]] && echo clean || echo DIRTY)"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
