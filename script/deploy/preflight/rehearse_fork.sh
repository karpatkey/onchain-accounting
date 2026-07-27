#!/usr/bin/env bash
# Rehearse the full from-scratch NAV deploy against a LOCAL anvil fork.
#
# Runs the real script sequence with the real config, so anything that would break on the day breaks
# here instead: 01 -> 01_2 -> 02_2 -> RegisterAssets -> 03 -> 04 -> 06. Records gas and wall-clock per
# step and asserts the things that are easy to get silently wrong:
#   * `initialize()` minted a FRESH ERC20Default (a new proxy is the entire reason for this deploy)
#   * the NAV proxy address is NOT the live one (if it is, DeploySalts.NAV_PROXY must be bumped)
#   * the meta-instance reconcile landed exactly the configured set
#
# SAFETY: this script REFUSES to run against anything but a loopback RPC. It is the only place in the
# preflight tooling that broadcasts, and it must only ever broadcast to the local fork.
#
# The repo's `script/config/deployments/1.json` is archived before the run and restored afterwards
# (the deploy scripts write to it), so the rehearsal leaves the tree clean. `git diff` is checked at
# the end to prove it.
#
# usage:
#   script/deploy/preflight/rehearse_fork.sh [chainId] [forkBlock]
set -uo pipefail

CHAIN_ID="${1:-1}"
FORK_BLOCK="${2:-}"
PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="${REHEARSAL_DIR:-/tmp/nav-rehearsal-${CHAIN_ID}}"
cd "$ROOT"

# --- safety rail -------------------------------------------------------------
case "$RPC" in
  http://127.0.0.1:*|http://localhost:*) ;;
  *) echo "REFUSING: rehearsal RPC '$RPC' is not loopback."; exit 2 ;;
esac

mkdir -p "$WORK"
: > "$WORK/steps.tsv"
echo -e "step\tseconds\tgas\tstatus" >> "$WORK/steps.tsv"

if [[ -f .env ]]; then set -a; source .env; set +a; fi
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY must be set}"
FORK_URL="${MAINNET_URL:-https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}}"

DEPLOYER="$(jq -r '.addresses.admin' "script/config/chains/${CHAIN_ID}.json")"
LIVE_PROXY="$(jq -r '.NAVCalculatorProxy // ""' "script/config/deployments/${CHAIN_ID}.json")"
LIVE_DEFAULT="$(jq -r '.balanceAdapters.ERC20Default // ""' "script/config/deployments/${CHAIN_ID}.json")"
echo "deployer=$DEPLOYER  live proxy=$LIVE_PROXY  live ERC20Default=$LIVE_DEFAULT"

# --- anvil -------------------------------------------------------------------
ANVIL_ARGS=(--fork-url "$FORK_URL" --port "$PORT" --auto-impersonate --silent
            --gas-limit 60000000 --disable-block-gas-limit)
[[ -n "$FORK_BLOCK" ]] && ANVIL_ARGS+=(--fork-block-number "$FORK_BLOCK")
anvil "${ANVIL_ARGS[@]}" > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!

RESTORED=0
cleanup() {
  if [[ $RESTORED -eq 0 && -f "$WORK/deployments-${CHAIN_ID}.orig.json" ]]; then
    cp "$WORK/deployments-${CHAIN_ID}.orig.json" "script/config/deployments/${CHAIN_ID}.json"
    RESTORED=1
    echo "restored script/config/deployments/${CHAIN_ID}.json"
  fi
  kill "$ANVIL_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null 2>&1 || { echo "anvil never came up; see $WORK/anvil.log"; exit 1; }
echo "anvil up at $RPC, fork block $(cast block-number --rpc-url "$RPC")"

cast rpc anvil_setBalance "$DEPLOYER" 0x21e19e0c9bab2400000 --rpc-url "$RPC" >/dev/null

# --- clear the deployment record so 03/04 actually deploy --------------------
cp "script/config/deployments/${CHAIN_ID}.json" "$WORK/deployments-${CHAIN_ID}.orig.json"
python3 script/deploy/preflight/reset_deployment_records.py --apply \
  --tag "rehearsal-$$" "$CHAIN_ID" > "$WORK/reset.log" 2>&1 || {
    echo "reset_deployment_records failed; see $WORK/reset.log"; exit 1; }
rm -rf "script/deploy/preflight/archive/rehearsal-$$"
echo "cleared deployments/${CHAIN_ID}.json (original archived in $WORK)"

# --- run a step --------------------------------------------------------------
run_step() {
  local label="$1"; shift
  local log="$WORK/${label}.log"
  echo "--- $label"
  local t0 t1 rc gas
  t0=$(date +%s)
  PERSIST_DEPLOYMENTS=1 forge script "$@" \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow \
    > "$log" 2>&1
  rc=$?
  t1=$(date +%s)
  # forge prints "Estimated gas price"/"Total Paid"; the authoritative number is the sum of the
  # broadcast receipts, which --broadcast writes into broadcast/<script>/<chainId>/run-latest.json.
  gas=$(grep -aoE "Total Paid: [0-9.]+ ETH \(([0-9]+) gas" "$log" | grep -oE "\(([0-9]+)" | tr -d '(' | paste -sd+ | bc 2>/dev/null)
  [[ -z "$gas" ]] && gas=0
  if [[ $rc -eq 0 ]] && ! grep -qa "^Error" "$log"; then
    echo -e "${label}\t$((t1-t0))\t${gas}\tOK" >> "$WORK/steps.tsv"
    echo "    OK  $((t1-t0))s  gas=${gas}"
  else
    echo -e "${label}\t$((t1-t0))\t${gas}\tFAIL" >> "$WORK/steps.tsv"
    echo "    FAIL ($((t1-t0))s) — tail of $log:"
    tail -25 "$log" | sed 's/^/      /'
    return 1
  fi
}

FAILED=0
run_step 01_DeployImplementations   script/deploy/01_DeployImplementations.s.sol   || FAILED=1
run_step 01_2_DeployNAVImplementation script/deploy/01_2_DeployNAVImplementation.s.sol || FAILED=1
run_step 02_2_DeployNAVProxy        script/deploy/02_2_DeployNAVProxy.s.sol        || FAILED=1
run_step RegisterAssets             script/manage/RegisterAssets.s.sol             || FAILED=1
run_step 03_DeployPriceFeeds        script/deploy/03_DeployPriceFeeds.s.sol        || FAILED=1
run_step 04_DeployBalanceAdapters   script/deploy/04_DeployBalanceAdapters.s.sol   || FAILED=1
run_step 06_Configure               script/deploy/06_Configure.s.sol               || FAILED=1

# --- assertions --------------------------------------------------------------
echo
echo "=== post-conditions ==="
NEW_PROXY="$(jq -r '.NAVCalculatorProxy // ""' "script/config/deployments/${CHAIN_ID}.json")"
NEW_DEFAULT="$(jq -r '.balanceAdapters.ERC20Default // ""' "script/config/deployments/${CHAIN_ID}.json")"
echo "new proxy         : $NEW_PROXY"
echo "new ERC20Default  : $NEW_DEFAULT"

assert() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILED=1; fi; }

assert "NAV proxy address differs from the live one (else bump DeploySalts.NAV_PROXY)" \
       '[[ -n "$NEW_PROXY" && "${NEW_PROXY,,}" != "${LIVE_PROXY,,}" ]]'
assert "initialize() minted a FRESH ERC20Default" \
       '[[ -n "$NEW_DEFAULT" && "${NEW_DEFAULT,,}" != "${LIVE_DEFAULT,,}" ]]'

if [[ -n "$NEW_PROXY" ]]; then
  ONCHAIN_DEFAULT=$(cast call "$NEW_PROXY" "erc20DefaultBalanceAdapter()(address)" --rpc-url "$RPC")
  assert "on-chain erc20DefaultBalanceAdapter matches the recorded one" \
         '[[ "${ONCHAIN_DEFAULT,,}" == "${NEW_DEFAULT,,}" ]]'
  ADAPTERS=$(cast call "$NEW_PROXY" "getAdapterCount()(uint256)" --rpc-url "$RPC")
  ASSETS=$(cast call "$NEW_PROXY" "getAssetCount()(uint256)" --rpc-url "$RPC")
  echo "adapters registered: $ADAPTERS   assets registered: $ASSETS"

  # meta-instance reconcile: sum getMetaInstances over every registered adapter and compare with config
  TOTAL=0
  for A in $(cast call "$NEW_PROXY" "getAllAdapters()(address[])" --rpc-url "$RPC" | tr -d '[]' | tr ',' ' '); do
    N=$(cast call "$NEW_PROXY" "getMetaInstances(address)(bytes32[])" "$A" --rpc-url "$RPC" \
        | tr -d '[]' | tr ',' '\n' | grep -c '0x' || true)
    TOTAL=$((TOTAL + N))
  done
  WANT=$(jq '[to_entries[] | select(.value.enabled == true)
             | ((.value.instances//[])|length) + ((.value.instancesRaw//[])|length)] | add // 0' \
         "script/config/nav-config/meta-balance-adapters/${CHAIN_ID}.json")
  echo "meta instances on-chain=$TOTAL configured=$WANT"
  assert "meta-instance reconcile landed exactly the configured set" '[[ "$TOTAL" == "$WANT" ]]'
fi

cp "script/config/deployments/${CHAIN_ID}.json" "$WORK/deployments-${CHAIN_ID}.result.json"
cleanup

echo
echo "=== per-step timing / gas ==="
column -t "$WORK/steps.tsv"
echo
echo "logs + result record in $WORK"
if ! git diff --quiet -- "script/config/deployments/${CHAIN_ID}.json"; then
  echo "WARNING: script/config/deployments/${CHAIN_ID}.json is still modified — restore it by hand."
  FAILED=1
else
  echo "tree clean: deployments/${CHAIN_ID}.json restored"
fi
exit $FAILED
