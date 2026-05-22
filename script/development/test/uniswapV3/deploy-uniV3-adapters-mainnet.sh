#!/usr/bin/env bash
# Deploy + register the 3 enabled UniswapV3 balance adapters (per chains/1.json) on the
# local-anvil mainnet fork. Used so the dev-anvil NAV dashboard surfaces the verification
# holders' LP positions side-by-side with Debank.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STATE="$REPO_ROOT/script/development/state/1-addresses.json"
RPC=http://127.0.0.1:8545
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

if ! command -v forge >/dev/null 2>&1 || ! command -v cast >/dev/null 2>&1; then
  if [ -x "$HOME/.foundry/bin/forge" ]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "error: forge/cast not on PATH and not at \$HOME/.foundry/bin" >&2
    exit 1
  fi
fi

NAV=$(jq -r '.NAVCalculatorProxy' "$STATE")
echo "NAV proxy: $NAV"

# Canonical NPM on mainnet/Optimism/Arbitrum/Polygon.
NPM=0xC36442b4a4522E871399CD717aBDD847Ab11FE88

declare -a LABELS=( USDC_WETH_500 WETH_USDT_3000 WBTC_WETH_3000 )
declare -A POOLS=(
  [USDC_WETH_500]=0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
  [WETH_USDT_3000]=0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36
  [WBTC_WETH_3000]=0xCBCdF9626bC03E24f779434178A73a0B4bad62eD
)
declare -A LABEL_FOR=(
  [USDC_WETH_500]="USDC/WETH 0.05%"
  [WETH_USDT_3000]="WETH/USDT 0.3%"
  [WBTC_WETH_3000]="WBTC/WETH 0.3%"
)

declare -A DEPLOYED
for key in "${LABELS[@]}"; do
  pool=${POOLS[$key]}
  human=${LABEL_FOR[$key]}
  echo
  echo "=== deploying UniswapV3 adapter for $key ($pool) ==="

  # Canonical positionDetail schema for UniswapV3 per script/config/adapter-identities.json:
  # `{ "protocol": "Uniswap V3", "product": "LP", "name": "<token0/token1 fee%>" }`.
  position_detail="{\"protocol\":\"Uniswap V3\",\"product\":\"LP\",\"name\":\"$human\""

  out=$(forge create src/balances/protocols/uniswap/UniswapV3Pool.sol:UniswapV3PoolBalanceOracle \
    --rpc-url "$RPC" \
    --private-key "$DEV_PRIVATE_KEY" \
    --broadcast \
    --constructor-args "$pool" "$NPM" "Uniswap V3" "$position_detail" "$pool" "$NAV" \
    2>&1)
  addr=$(printf '%s\n' "$out" | grep -E '^Deployed to:' | awk '{print $3}')
  if [ -z "$addr" ]; then
    echo "$out" | tail -20
    echo "error: forge create did not yield an address"
    exit 1
  fi
  echo "adapter: $addr"
  DEPLOYED[$key]=$addr

  echo "registering adapter on NAV..."
  cast send "$NAV" "addBalanceOracle(address)" "$addr" \
    --rpc-url "$RPC" --private-key "$DEV_PRIVATE_KEY" \
    >/dev/null
  echo "done"
done

# Persist deployed addresses for future runs / debugging.
jq -n \
  --arg USDC_WETH_500 "${DEPLOYED[USDC_WETH_500]}" \
  --arg WETH_USDT_3000 "${DEPLOYED[WETH_USDT_3000]}" \
  --arg WBTC_WETH_3000 "${DEPLOYED[WBTC_WETH_3000]}" \
  '{UniswapV3_USDC_WETH_500:$USDC_WETH_500, UniswapV3_WETH_USDT_3000:$WETH_USDT_3000, UniswapV3_WBTC_WETH_3000:$WBTC_WETH_3000}' \
  > "$REPO_ROOT/script/development/state/1-uniV3-adapters.json"

echo
echo "all 3 adapters deployed + registered. summary:"
cat "$REPO_ROOT/script/development/state/1-uniV3-adapters.json"
