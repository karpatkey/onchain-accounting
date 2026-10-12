#!/usr/bin/env bash
# verify_pr338_chain.sh <chainId> — source-verify every contract PR #338 deployed on one chain (Etherscan V2):
# every adapter `04` created (from its broadcast log), NAVRegistryLib, the NAVCalculator impl and PriceFeedLib.
# Skips what is already verified, so it is safe to re-run. Logs go to $PR338_VERIFY_LOGS (default /tmp/pr338-verify).
# The ops Safe needs nothing: explorers match it to the canonical SafeProxy automatically.
# PR338_VERIFIER=sourcify submits to Sourcify instead (keyless) — the fallback when an Etherscan-family queue
# stalls (observed: Arbiscan "Pending in queue" for 1 h+). forge only honours --verifier sourcify when the
# Etherscan key is EMPTY (set, since foundry.toml interpolates it), so that mode blanks it for the call.
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
C="$1"; S="${PR338_VERIFY_LOGS:-/tmp/pr338-verify}"; mkdir -p "$S"
. script/deploy/preflight/pr338_env.sh "$C" > /dev/null || exit 1
set -a; . "${PR338_ENV_FILE:-/home/nicol/projects/onchain-accounting/.env}" >/dev/null 2>&1; set +a   # pr338_env.sh unset the passwords; the API key is re-read here
K="${ETHERSCAN_API_KEY%$'\r'}"; K="${K//\"/}"
unset DEPLOYER_KEYSTORE_PASSWORD DEPLOYER2_KEYSTORE_PASSWORD   # not needed to verify; keep them out of child envs
REC=script/config/deployments/$C.json
targets=()
# adapters created by 04 on this chain (upgrade-only chains ran no 04 — nothing to add)
[[ -f broadcast/04_DeployBalanceAdapters.s.sol/$C/run-latest.json ]] && while IFS=$'\t' read -r key addr; do targets+=("$addr|${key}BalanceAdapter"); done < <(
  jq -r --slurpfile b broadcast/04_DeployBalanceAdapters.s.sol/$C/run-latest.json '
    ($b[0].transactions | map(select(.contractAddress) | .contractAddress | ascii_downcase)) as $new
    | .balanceAdapters | to_entries[] | select((.value|type)=="string" and ((.value|ascii_downcase) as $v | $new | index($v))) | [.key, .value] | @tsv' $REC)
targets+=("0x3D5369B0b2044d62a8f643bf9a2b8CC03775934D|NAVRegistryLib")
targets+=("$(jq -r .NAVCalculatorImplementation $REC)|NAVCalculator")
targets+=("0x0f913658d70BB19b7B42eF9926c3df7c70fafCf2|PriceFeedLib")
for t in "${targets[@]}"; do
  a="${t%%|*}"; n="${t#*|}"
  if [[ "${PR338_VERIFIER:-etherscan}" == sourcify ]]; then
    st=$(curl -s "https://sourcify.dev/server/v2/contract/$C/$a" | jq -r '.match // ""')
  else
    st=$(curl -s "https://api.etherscan.io/v2/api?chainid=$C&module=contract&action=getsourcecode&address=$a&apikey=$K" | jq -r '.result[0].ContractName // ""')
  fi
  if [[ -n "$st" ]]; then echo "$C $n $a ALREADY VERIFIED ($st)"; continue; fi
  p=$(grep -rlE "^(abstract )?(contract|library) $n\b" src/ | head -1)
  [[ -z "$p" ]] && { echo "$C $n $a NO SOURCE FOUND"; continue; }
  if [[ "${PR338_VERIFIER:-etherscan}" == sourcify ]]; then
    timeout 1200 env ETHERSCAN_API_KEY= OPTIMISM_ETHERSCAN_API_KEY= forge verify-contract "$a" "$p:$n" --chain "$C" \
      --verifier sourcify --rpc-url "$RPC" --guess-constructor-args --watch > "$S/verify-$C-$n.log" 2>&1
  else
    timeout 1200 forge verify-contract "$a" "$p:$n" --chain "$C" --etherscan-api-key "$K" --rpc-url "$RPC" \
      --guess-constructor-args --watch > "$S/verify-$C-$n.log" 2>&1
  fi
  # A slow explorer queue makes forge give up while the submission is still "Pending in queue" (observed on
  # Basescan: every submission later passed). Re-check the explorer itself for ~3 min before calling it a failure.
  ok=0; grep -qE "Pass - Verified|already verified|Status: .(exact_)?match" "$S/verify-$C-$n.log" && ok=1
  for _ in 1 2 3 4 5 6 7 8 9; do
    (( ok )) && break; sleep 20
    if [[ "${PR338_VERIFIER:-etherscan}" == sourcify ]]; then
      [[ -n "$(curl -s "https://sourcify.dev/server/v2/contract/$C/$a" | jq -r '.match // ""')" ]] && ok=1
    else
      [[ -n "$(curl -s "https://api.etherscan.io/v2/api?chainid=$C&module=contract&action=getsourcecode&address=$a&apikey=$K" \
               | jq -r '.result[0].ContractName // ""')" ]] && ok=1
    fi
  done
  if (( ok )); then echo "$C $n $a VERIFIED"
  else echo "$C $n $a FAILED: $(grep -E 'Details|Error' "$S/verify-$C-$n.log" | tail -1 | sed 's#https\?://[^ ]*#<url>#g' | cut -c1-160)"; fi
done
