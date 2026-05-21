#!/usr/bin/env bash
# Deploy + register 6 UniswapV2 balance adapters on the local-anvil mainnet fork.
# Used so the dev-anvil NAV dashboard surfaces LP positions for the verification holder.
set -euo pipefail

# Derive REPO_ROOT relative to this script so it works for any contributor / CI environment.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STATE="$REPO_ROOT/script/development/state/1-addresses.json"
RPC=http://127.0.0.1:8545
DEV_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Match the pattern used elsewhere in script/development/**: only adjust PATH when forge/cast
# aren't already discoverable (don't unconditionally clobber the user's Foundry install location).
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

declare -a LABELS=( USDC_WETH USDT_WETH DAI_WETH WBTC_WETH USDC_USDT DAI_USDC )
declare -A PAIRS=(
  [USDC_WETH]=0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc
  [USDT_WETH]=0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852
  [DAI_WETH]=0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11
  [WBTC_WETH]=0xBb2b8038a1640196FbE3e38816F3e67Cba72D940
  [USDC_USDT]=0x3041CbD36888bECc7bbCBc0045E3B1f144466f5f
  [DAI_USDC]=0xAE461cA67B15dc8dc81CE7615e0320dA1A9aB8D5
)
declare -A LABEL_FOR=(
  [USDC_WETH]="USDC/WETH"
  [USDT_WETH]="USDT/WETH"
  [DAI_WETH]="DAI/WETH"
  [WBTC_WETH]="WBTC/WETH"
  [USDC_USDT]="USDC/USDT"
  [DAI_USDC]="DAI/USDC"
)

declare -A DEPLOYED
for key in "${LABELS[@]}"; do
  pair=${PAIRS[$key]}
  human=${LABEL_FOR[$key]}
  echo
  echo "=== deploying UniswapV2 adapter for $key ($pair) ==="

  # Canonical positionDetail schema for UniswapV2 per script/config/adapter-identities.json:
  # `{ "protocol": "Uniswap V2", "product": "LP", "name": "<token0/token1>" }`.
  position_detail="{\"protocol\":\"Uniswap V2\",\"product\":\"LP\",\"name\":\"$human\""

  out=$(forge create src/balances/protocols/UniswapV2.sol:UniswapV2BalanceOracle \
    --rpc-url "$RPC" \
    --private-key "$DEV_PRIVATE_KEY" \
    --broadcast \
    --constructor-args "$pair" "Uniswap V2" "$position_detail" "$pair" "$NAV" \
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

# Persist for future re-runs / debugging.
jq -n \
  --arg USDC_WETH "${DEPLOYED[USDC_WETH]}" \
  --arg USDT_WETH "${DEPLOYED[USDT_WETH]}" \
  --arg DAI_WETH "${DEPLOYED[DAI_WETH]}" \
  --arg WBTC_WETH "${DEPLOYED[WBTC_WETH]}" \
  --arg USDC_USDT "${DEPLOYED[USDC_USDT]}" \
  --arg DAI_USDC "${DEPLOYED[DAI_USDC]}" \
  '{UniswapV2_USDC_WETH:$USDC_WETH, UniswapV2_USDT_WETH:$USDT_WETH, UniswapV2_DAI_WETH:$DAI_WETH, UniswapV2_WBTC_WETH:$WBTC_WETH, UniswapV2_USDC_USDT:$USDC_USDT, UniswapV2_DAI_USDC:$DAI_USDC}' \
  > "$REPO_ROOT/script/development/state/1-uniV2-adapters.json"

echo
echo "all 6 adapters deployed + registered. summary:"
cat "$REPO_ROOT/script/development/state/1-uniV2-adapters.json"
