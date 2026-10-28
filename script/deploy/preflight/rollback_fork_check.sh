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

R="$ADR0029_FORK_RPC"
cast rpc anvil_setBalance "$REHEARSAL_COUNCIL" 0x21e19e0c9bab2400000 --rpc-url "$R" >/dev/null
# Explicit, so this also works on a plain `anvil --fork-url` (the rehearsal starts anvil with --auto-impersonate).
cast rpc anvil_impersonateAccount "$REHEARSAL_COUNCIL" --rpc-url "$R" >/dev/null
echo "impl before rollback: $(impl)"
DATA="$(cast calldata "upgradeToAndCall(address,bytes)" "$OLD_IMPL" 0x)"
if [[ "$(cast call $NAV 'hasRole(bytes32,address)(bool)' 0x0000000000000000000000000000000000000000000000000000000000000000 "$REHEARSAL_COUNCIL" --rpc-url "$R")" == true ]]; then
  ST="$(cast send $NAV "$DATA" --from "$REHEARSAL_COUNCIL" --unlocked --rpc-url "$R" --json | jq -r .status)"
  echo "rollback tx status $ST (sent directly by the Council $REHEARSAL_COUNCIL)"
else
  # After the timelock handover the Council holds no NAV role: it proposes through the timelock, waits the delay,
  # and anyone executes. That wait is the rollback's real duration from now on.
  TL="$(jq -r '.TimelockController // ""' "script/config/deployments/${REHEARSAL_CHAIN}.json")"
  DELAY="$(cast call "$TL" 'getMinDelay()(uint256)' --rpc-url "$R" | awk '{print $1}')"
  SALT="$(cast keccak "rollback rehearsal")"; Z=0x0000000000000000000000000000000000000000000000000000000000000000
  S1="$(cast send "$TL" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $NAV 0 "$DATA" $Z "$SALT" "$DELAY" \
        --from "$REHEARSAL_COUNCIL" --unlocked --rpc-url "$R" --json | jq -r .status)"
  cast rpc anvil_removeBlockTimestampInterval --rpc-url "$R" >/dev/null
  NOWTS="$(cast block latest --field timestamp --rpc-url "$R")"
  cast rpc evm_setNextBlockTimestamp "$(printf '0x%x' $((NOWTS + DELAY + 1)))" --rpc-url "$R" >/dev/null
  cast rpc evm_mine --rpc-url "$R" >/dev/null
  ANY=0x00000000000000000000000000000000000ba11c
  cast rpc anvil_setBalance $ANY 0xde0b6b3a7640000 --rpc-url "$R" >/dev/null
  cast rpc anvil_impersonateAccount $ANY --rpc-url "$R" >/dev/null
  ST="$(cast send "$TL" 'execute(address,uint256,bytes,bytes32,bytes32)' $NAV 0 "$DATA" $Z "$SALT" \
        --from $ANY --unlocked --rpc-url "$R" --json | jq -r .status)"
  echo "rollback through the timelock: Council schedule status $S1, executed after ${DELAY} s by any account: status $ST"
  echo "NOTE: the fork's oracles are frozen and the clock moved ${DELAY} s, so every feed now reads stale; the old"
  echo "      library values stale prices at 0, so the snapshot diff below is NOT a valid NAV comparison on this path."
  echo "      What this path proves: the rollback goes through the timelock and lands after the delay."
fi
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
