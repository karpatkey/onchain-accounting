#!/usr/bin/env bash
# Deploy each custom price-oracle contract individually with `forge create`, then register the
# matching asset on NAV via `cast send`. Avoids the slow simulation phase of `forge script` against
# a fork (which times out when many cross-contract calls accumulate).
#
# Usage:  deploy-custom-feeds.sh <chainId>
# State:  appends each deployed feed address to script/development/state/<cid>-feeds.json,
#         registers the matching token in NAV (Custom price type), and updates
#         <cid>-addresses.json customAssetsRegistered count.
set -uo pipefail

CID=${1:?chainId required}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
ASSETS_JSON="$REPO_ROOT/script/config/assets.json"
CHAINS_CFG="$DEV_DIR/config/chains.json"

PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"

PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
NAV=$(jq -r '.NAVCalculatorProxy' "$STATE_DIR/$CID-addresses.json")

if ! command -v forge >/dev/null 2>&1; then
  export PATH="$HOME/.foundry/bin:$PATH"
fi

FEEDS_FILE="$STATE_DIR/$CID-feeds.json"
[ -f "$FEEDS_FILE" ] || echo '{}' > "$FEEDS_FILE"

# Per-oracle table: tokenSymbol_in_assets.json | feedName_in_assets.json | source:contract | constructor arg keys (in order)
# tokenSymbol is the key in tokens.<cid> we register against NAV.
# feedName is the key in priceFeeds.<feedName>.<cid> for constructor args.
# Each arg is either an address (a=key) or uint (u=key).

declare -A FEEDS
# Mainnet
FEEDS[1.wstETH]="wstETH|src/prices/protocols/wstETH_Price.sol:wstETH_PriceOracle|a=wstEth|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.rETH]="rETH|src/prices/protocols/rETH_Price.sol:rETH_PriceOracle|a=rEth|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.weETH]="weETH|src/prices/protocols/weETH_Price.sol:weETH_PriceOracle|a=weEth|a=weEthToEthChainlinkOracle|a=ethToUsdChainlinkOracle|u=weEthToEthChainlinkHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.eETH]="eETH|src/prices/protocols/eETH_Price.sol:eETH_PriceOracle|a=eEth|a=weEth|a=weEthToEthChainlinkOracle|a=ethToUsdChainlinkOracle|u=weEthToEthChainlinkHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.ezETH]="ezETH|src/prices/protocols/ezETH_Price.sol:ezETH_PriceOracle|a=ezEth|a=restakeManager|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.rsETH]="rsETH|src/prices/protocols/rsETH_Price.sol:rsETH_PriceOracle|a=rsEth|a=rateProvider|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.ETHx]="ETHx|src/prices/protocols/ETHx_Price.sol:ETHx_PriceOracle|a=ethx|a=stakePoolsManager|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[1.ETHPlus]="ETH+|src/prices/protocols/ETHPlus_Price.sol:ETHPlus_PriceOracle|a=ethPlus|u=reserveProtocolHeartbeat"
FEEDS[1.sUSDe]="sUSDe|src/prices/protocols/sUSDe_Price.sol:sUSDe_PriceOracle|a=sUsde|a=usdeToUsdChainlinkAddress|u=usdeToUsdChainlinkHeartbeat"
FEEDS[1.sUSDS]="sUSDS|src/prices/protocols/sUSDS_Price.sol:sUSDS_PriceOracle|a=sUsds|a=usdsToUsdChainlinkAddress|u=usdsToUsdChainlinkHeartbeat"
# sDAI is NOT registered in production for mainnet — its priceFeeds entry doesn't exist in
# assets.json and there's no sDAI key under tokens.1. Kept here as a noop comment so the
# fact is recorded; if mainnet ever adds sDAI, re-enable the FEEDS[1.sDAI] line above.
FEEDS[1.syrupUSDC]="syrupUSDC|src/prices/protocols/syrupUSDC_Price.sol:syrupUSDC_PriceOracle|a=syrupUsdc|a=usdcToUsdChainlinkAddress|u=usdcToUsdChainlinkHeartbeat"

# Gnosis
FEEDS[100.sXDAI]="sDAI|src/prices/protocols/sXDAI_Price.sol:sDAI_PriceOracle|a=sXdai|a=xDaiToUsdChainlinkOracle|u=xDaiToUsdChainlinkHeartbeat"
FEEDS[100.wstETH_L2]="wstETH|src/prices/protocols/wstETH_L2_Price.sol:wstETH_L2_PriceOracle|a=wstEth|a=wstEthToEthChainlink|a=ethToUsdChainlinkOracle|u=wstEthToEthHeartbeat|u=ethToUsdChainlinkHeartbeat"

# Arbitrum
FEEDS[42161.wstETH_L2]="wstETH|src/prices/protocols/wstETH_L2_Price.sol:wstETH_L2_PriceOracle|a=wstEth|a=wstEthToEthChainlink|a=ethToUsdChainlinkOracle|u=wstEthToEthHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[42161.weETH_L2]="weETH|src/prices/protocols/weETH_L2_Price.sol:weETH_L2_PriceOracle|a=weEth|a=weEthToEethChainlink|a=ethToUsdChainlinkOracle|u=weEthToEethHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[42161.rsETH_L2]="rsETH|src/prices/protocols/rsETH_L2_Price.sol:rsETH_L2_PriceOracle|a=rsEth|a=rsEthToEthChainlink|a=ethToUsdChainlinkOracle|u=rsEthToEthHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[42161.ezETH_L2]="ezETH|src/prices/protocols/ezETH_L2_Price.sol:ezETH_L2_PriceOracle|a=ezEth|a=xRenzoDeposit|a=ethToUsdChainlinkOracle|u=ethToUsdChainlinkHeartbeat"
FEEDS[42161.syrupUSDC_L2]="syrupUSDC|src/prices/protocols/syrupUSDC_L2_Price.sol:syrupUSDC_L2_PriceOracle|a=syrupUsdc|a=syrupUsdcToUsdcChainlink|a=usdcToUsdChainlinkOracle|u=syrupUsdcToUsdcHeartbeat|u=usdcToUsdChainlinkHeartbeat"

# Base
FEEDS[8453.wstETH_L2]="wstETH|src/prices/protocols/wstETH_L2_Price.sol:wstETH_L2_PriceOracle|a=wstEth|a=wstEthToEthChainlink|a=ethToUsdChainlinkOracle|u=wstEthToEthHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[8453.weETH_L2]="weETH|src/prices/protocols/weETH_L2_Price.sol:weETH_L2_PriceOracle|a=weEth|a=weEthToEethChainlink|a=ethToUsdChainlinkOracle|u=weEthToEethHeartbeat|u=ethToUsdChainlinkHeartbeat"
FEEDS[8453.cbETH_L2]="cbETH|src/prices/protocols/cbETH_L2_Price.sol:cbETH_L2_PriceOracle|a=cbEth|a=cbEthToEthChainlink|a=ethToUsdChainlinkOracle|u=cbEthToEthHeartbeat|u=ethToUsdChainlinkHeartbeat"

CUSTOM=1  # PriceType.Custom

ok=0; fail=0; skip=0
for key in "${!FEEDS[@]}"; do
  [[ "$key" == "$CID."* ]] || continue
  IFS='|' read -ra parts <<< "${FEEDS[$key]}"
  oracle_name="${key#$CID.}"
  token_sym="${parts[0]}"
  contract_ref="${parts[1]}"

  # Build constructor args (positional). Each part is "a=<key>" or "u=<key>".
  args=""
  read_ok=1
  for ((i=2; i<${#parts[@]}; i++)); do
    kind="${parts[$i]%%=*}"
    paramkey="${parts[$i]#*=}"
    val=$(jq -r ".priceFeeds.\"$oracle_name\".\"$CID\".constructor.\"$paramkey\" // \"\"" "$ASSETS_JSON")
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      printf "  skip   %-14s missing arg %s\n" "$oracle_name" "$paramkey"
      read_ok=0; break
    fi
    args="$args $val"
  done
  if [ "$read_ok" = "0" ]; then skip=$((skip+1)); continue; fi

  # Token address + heartbeat for the asset registration
  token_addr=$(jq -r ".tokens.\"$CID\".\"$token_sym\".address // \"\"" "$ASSETS_JSON")
  token_hb=$(jq -r ".tokens.\"$CID\".\"$token_sym\".heartbeat // 0" "$ASSETS_JSON")
  if [ -z "$token_addr" ] || [ "$token_hb" = "0" ] || [ "$token_hb" = "null" ]; then
    printf "  skip   %-14s token %s missing in assets.json\n" "$oracle_name" "$token_sym"
    skip=$((skip+1)); continue
  fi

  # Deploy via forge create — capture address from stdout
  if ! deploy_out=$(forge create $contract_ref --rpc-url "$RPC" --private-key "$PK" --broadcast --constructor-args $args 2>&1); then
    snippet=$(echo "$deploy_out" | grep -iE "revert|error|failed" | head -1 | tr -d '\n' | cut -c1-100)
    printf "  FAIL   %-14s deploy: %s\n" "$oracle_name" "$snippet"
    fail=$((fail+1)); continue
  fi
  feed_addr=$(echo "$deploy_out" | grep -E "Deployed to" | head -1 | awk '{print $NF}')
  if [ -z "$feed_addr" ]; then
    printf "  FAIL   %-14s deploy: no address in output\n" "$oracle_name"
    fail=$((fail+1)); continue
  fi

  # Register on NAV (or setPriceFeed if pre-registered)
  REG=$(cast call "$NAV" "isAssetRegistered(address)(bool)" "$token_addr" --rpc-url "$RPC" 2>/dev/null || echo "false")
  if [ "$REG" = "true" ]; then sel="setPriceFeed(address,address,uint8,uint256)"; action="setFd"
  else sel="registerAsset(address,address,uint8,uint256)"; action="reg"
  fi
  if reg_out=$(cast send "$NAV" "$sel" "$token_addr" "$feed_addr" "$CUSTOM" "$token_hb" --rpc-url "$RPC" --private-key "$PK" --from "$SENDER" 2>&1); then
    printf "  %-6s %-14s token=%s feed=%s\n" "$action" "$oracle_name" "$token_sym" "$feed_addr"
    ok=$((ok+1))
    # Persist to feeds.json
    jq --arg n "$oracle_name" --arg a "$feed_addr" --arg t "$token_addr" \
      '.[$n] = {feed:$a, token:$t}' "$FEEDS_FILE" > "$FEEDS_FILE.tmp" && mv "$FEEDS_FILE.tmp" "$FEEDS_FILE"
  else
    snippet=$(echo "$reg_out" | grep -iE "revert|error|failed" | head -1 | tr -d '\n' | cut -c1-100)
    printf "  FAIL   %-14s register: %s\n" "$oracle_name" "$snippet"
    fail=$((fail+1))
  fi
done

echo "--- chain $CID custom-feeds: ok=$ok fail=$fail skip=$skip"

# Stamp count for idempotency
jq --argjson n "$ok" '. + {customAssetsRegistered: $n}' "$STATE_DIR/$CID-addresses.json" \
  > "$STATE_DIR/$CID-addresses.json.tmp" && mv "$STATE_DIR/$CID-addresses.json.tmp" "$STATE_DIR/$CID-addresses.json"
