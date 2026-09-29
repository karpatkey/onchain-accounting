# shellcheck shell=bash
# Source per chain before any PR #338 live step:   . script/deploy/preflight/pr338_env.sh <chainId>
#
# Sets, for ONE chain, everything the execution sheet's commands reference, and refuses (returns non-zero)
# unless the endpoint really is that chain and the keystore really is the deployer:
#
#   CHAIN RPC NAV COUNCIL DEPLOYER OPS PRE_IMPL ADMIN_ROLE MANAGER_ROLE
#   FORGE_SIGNER / CAST_SIGNER   arrays: keystore account + a 0600 password FILE (never argv, never printed)
#   FORGE_GAS / CAST_GAS         arrays: the chain's broadcast workarounds (REDEPLOY_RUNBOOK.md §1.10)
#
# The RPC URL embeds an API key: it is resolved into $RPC and never echoed. The password file is created
# under $XDG_RUNTIME_DIR (or the system temp dir), mode 0600, and removed when the sourcing shell exits.

pr338_env_fail() { echo "pr338_env: $*" >&2; return 1; }

CHAIN="${1:-}"
[[ "$CHAIN" =~ ^[0-9]+$ ]] || { pr338_env_fail "usage: . pr338_env.sh <chainId>"; return 1; }
[[ "$CHAIN" == 1101 ]] && { pr338_env_fail "1101 has no live NAV — excluded from PR #338"; return 1; }

PR338_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PR338_ENV_FILE="${PR338_ENV_FILE:-/home/nicol/projects/onchain-accounting/.env}"
[[ -f "$PR338_ENV_FILE" ]] || { pr338_env_fail "no .env at $PR338_ENV_FILE"; return 1; }
set -a; . "$PR338_ENV_FILE" >/dev/null 2>&1; set +a

# URL and its source note, NUL-separated, so the URL is never printed but the note can be.
{ IFS= read -r -d '' RPC; IFS= read -r -d '' RPC_NOTE; } < <(cd "$PR338_ROOT/script/deploy/preflight" && python3 -c "
import sys, chainlib as c
c.load_env()
url, note, _ = c.probe_rpc($CHAIN)
sys.stdout.write((url or '') + '\0' + note + '\0')" 2>/dev/null)
[[ -n "$RPC" ]] || { pr338_env_fail "no working RPC for chain $CHAIN"; return 1; }
# chainlib's PUBLIC fallbacks are for READS; broadcasting through one is opt-in.
if [[ "$RPC_NOTE" == public* && "${PR338_ALLOW_PUBLIC_RPC:-0}" != 1 ]]; then
  pr338_env_fail "chain $CHAIN resolves only to a PUBLIC RPC ($RPC_NOTE) — add a private endpoint to .env, or set PR338_ALLOW_PUBLIC_RPC=1 deliberately"
  return 1
fi
[[ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null)" == "$CHAIN" ]] \
  || { pr338_env_fail "endpoint does not report chain id $CHAIN"; return 1; }

REC="$PR338_ROOT/script/config/deployments/${CHAIN}.json"
CFG="$PR338_ROOT/script/config/chains/${CHAIN}.json"
NAV="$(jq -r '.NAVCalculatorProxy // ""' "$REC")"
COUNCIL="$(jq -r '.addresses.securityCouncil' "$CFG")"
DEPLOYER="$(jq -r '.addresses.admin' "$CFG")"
[[ "$NAV" == 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214 ]] || { pr338_env_fail "unexpected NAV proxy $NAV"; return 1; }
[[ "$DEPLOYER" == 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72 ]] || { pr338_env_fail "unexpected deployer $DEPLOYER"; return 1; }
# The fleet-wide throwaway ops Safe (ops_safe.py, salt keccak("kpk.pr338.ops-safe"), owner = deployer).
OPS=0xEEd8dC3c034Be12ff66646cCaAf07D35C43E8AA1
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
MANAGER_ROLE=0xaf290d8680820aad922855f39b306097b20e28774d6c1ad35a20325630c3a02c   # keccak256("MANAGER")
[[ "$(cast keccak MANAGER)" == "$MANAGER_ROLE" ]] || { pr338_env_fail "MANAGER role hash mismatch"; return 1; }
# Rollback target: the implementation live on every chain before PR #338 (preflight 2026-09-28).
PRE_IMPL=0x40e4134849308d53F85A8B685324E2189b13ff7D

PW="${DEPLOYER_KEYSTORE_PASSWORD%$'\r'}"; PW="${PW%\"}"; PW="${PW#\"}"
ACCT="${DEPLOYER_NAME:-kpk-deployer}"; ACCT="${ACCT%$'\r'}"; ACCT="${ACCT%\"}"; ACCT="${ACCT#\"}"
PWF="$(mktemp "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/pr338pw.XXXXXX")"; chmod 600 "$PWF"
printf '%s' "$PW" > "$PWF"; unset PW
# `.env` was exported wholesale; drop the plaintext passwords so no child process inherits them — forge/cast
# read $PWF, and chainlib re-reads .env itself when it needs anything.
unset DEPLOYER_KEYSTORE_PASSWORD DEPLOYER2_KEYSTORE_PASSWORD
trap 'rm -f "$PWF"' EXIT
[[ "$(cast wallet address --account "$ACCT" --password-file "$PWF" 2>/dev/null)" == "$DEPLOYER" ]] \
  || { pr338_env_fail "keystore $ACCT does not unlock to $DEPLOYER"; return 1; }
FORGE_SIGNER=(--account "$ACCT" --password-file "$PWF" --sender "$DEPLOYER")
CAST_SIGNER=(--account "$ACCT" --password-file "$PWF")

# On the swap chains the ops Safe is used: its address must be what ops_safe.py actually predicts here,
# so a MANAGER grant can never go to an address the tool will not deploy.
# Once deployed, the factory's prediction call reverts (the proxy exists), so check the deployed Safe instead.
case "$CHAIN" in 1|10|100|137|8453|42161|5042)
  if [[ "$(cast code "$OPS" --rpc-url "$RPC" 2>/dev/null)" == 0x ]]; then
    PRED="$(python3 "$PR338_ROOT/script/deploy/preflight/ops_safe.py" address --rpc-url "$RPC" --owner "$DEPLOYER" 2>/dev/null)"
    [[ "${PRED,,}" == "${OPS,,}" ]] || { pr338_env_fail "ops Safe predicted ${PRED:-<error>} != pinned $OPS"; return 1; }
  else
    OWN="$(cast call "$OPS" 'getOwners()(address[])' --rpc-url "$RPC" 2>/dev/null)"
    THR="$(cast call "$OPS" 'getThreshold()(uint256)' --rpc-url "$RPC" 2>/dev/null)"
    [[ "${OWN,,}" == "[${DEPLOYER,,}]" && "$THR" == 1 ]] \
      || { pr338_env_fail "deployed ops Safe $OPS is not 1/1 owned by the deployer (owners $OWN, threshold $THR)"; return 1; }
  fi ;;
esac

FORGE_GAS=(); CAST_GAS=()
case "$CHAIN" in
  100)   FORGE_GAS=(--with-gas-price 2000000000 --priority-gas-price 2000000000)  # tip-driven; BOTH flags
         CAST_GAS=(--gas-price 2000000000 --priority-gas-price 2000000000) ;;
  999)   FORGE_GAS=(--legacy); CAST_GAS=(--legacy) ;;  # + big blocks ON for the deployer before 01_2
  43111) GP=$(( $(cast gas-price --rpc-url "$RPC") * 2 ))                          # fee floor
         FORGE_GAS=(--with-gas-price "$GP"); CAST_GAS=(--gas-price "$GP") ;;
esac

cd "$PR338_ROOT" || return 1
echo "pr338_env: chain $CHAIN ready — RPC via $RPC_NOTE, NAV $NAV, deployer $DEPLOYER (keystore verified), council $COUNCIL, gas flags: ${FORGE_GAS[*]:-none}"
