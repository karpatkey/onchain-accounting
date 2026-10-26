#!/usr/bin/env bash
# Fork-only rollback rehearsal (ADR0029_ROLLOUT.md, "Rollback"), run as rehearse_adr0029_fork.sh's POST_CHECK:
# the Council upgrades the NAV back to the previous implementation and KEEPS the new feeds; a fresh snapshot is then
# diffed against the PRE-rollout snapshot. Passes when the rollback lands and the snapshot reads with 0 errors; read
# the diff (expected: the intended removals only, account NAVs equal within block-to-block interest).
#
# usage: POST_CHECK="bash script/deploy/preflight/rollback_fork_check.sh <previousImplementation>"
set -uo pipefail
: "${ADR0029_FORK_RPC:?}" "${REHEARSAL_WORK:?}" "${REHEARSAL_CHAIN:?}" "${REHEARSAL_URL_VAR:?}" "${REHEARSAL_COUNCIL:?}"
OLD_IMPL="${1:?usage: rollback_fork_check.sh <previousImplementation>}"
case "$ADR0029_FORK_RPC" in http://127.0.0.1:*|http://localhost:*) ;; *) echo "REFUSING: not a loopback fork"; exit 2 ;; esac
NAV=0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
impl() { cast parse-bytes32-address "$(cast storage $NAV $SLOT --rpc-url "$ADR0029_FORK_RPC")"; }

cast rpc anvil_setBalance "$REHEARSAL_COUNCIL" 0x21e19e0c9bab2400000 --rpc-url "$ADR0029_FORK_RPC" >/dev/null
echo "impl before rollback: $(impl)"
ST="$(cast send $NAV "upgradeToAndCall(address,bytes)" "$OLD_IMPL" 0x --from "$REHEARSAL_COUNCIL" --unlocked \
      --rpc-url "$ADR0029_FORK_RPC" --json | jq -r .status)"
echo "rollback tx status $ST (sent by the Council $REHEARSAL_COUNCIL)"
NOW="$(impl)"; echo "impl after rollback: $NOW"
[[ "$ST" == 0x1 && "${NOW,,}" == "${OLD_IMPL,,}" ]] || { echo "FAIL: implementation not rolled back"; exit 1; }

OUT="$REHEARSAL_WORK/rollback"
rm -rf "${OUT:?}"
env ALCHEMY_API_KEY= "$REHEARSAL_URL_VAR=$ADR0029_FORK_RPC" python3 script/deploy/preflight/snapshot_production.py \
  --out "$OUT" "$REHEARSAL_CHAIN" > "$OUT.log" 2>&1 || { echo "FAIL: snapshot after rollback"; tail -3 "$OUT.log"; exit 1; }
ERRS="$(jq '.errors | length' "$OUT/$REHEARSAL_CHAIN.json")"
echo "snapshot after rollback: $ERRS read error(s)"
python3 script/deploy/preflight/diff_snapshots.py "$REHEARSAL_WORK/pre" "$OUT" --json "$REHEARSAL_WORK/rollback-diff.json" \
  > "$REHEARSAL_WORK/rollback-diff.log" 2>&1
echo "--- diff PRE-rollout -> after rollback"; grep -E "DIFF|ok    account|difference" "$REHEARSAL_WORK/rollback-diff.log"
[[ "$ERRS" == 0 ]]
