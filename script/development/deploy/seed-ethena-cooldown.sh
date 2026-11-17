#!/usr/bin/env bash
# Seed an Ethena sUSDe unstaking cooldown for a demo account on a running dev anvil fork.
#
# Usage:  seed-ethena-cooldown.sh <chainId> [demoAddr] [usdeAmount(wei)]
#   e.g.  seed-ethena-cooldown.sh 1 0x99b9f5f24205cb88e33b1cc72008f644fc23768b 50000000000000000000000
#
# No real KPK Safe is mid-cooldown (cooldowns are transient ~24h), so a local check needs a seeded one.
# This impersonates a USDe whale (sUSDe itself, which custodies USDe) to fund the demo account, then
# impersonates the demo account to deposit USDe -> sUSDe and call cooldownShares — creating a real
# cooldown the EthenaCooldownBalanceAdapter then reports. Default demo account = ETH Alpha prod Safe.
set -euo pipefail

CID=${1:?chainId required}
DEMO=${2:-0x99b9f5f24205cb88e33b1cc72008f644fc23768b}   # ETH Alpha prod Safe (a real KPK Safe)
AMOUNT=${3:-50000000000000000000000}                     # 50,000 USDe (18-dec)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHAINS_CFG="$REPO_ROOT/script/development/config/chains.json"
SUSDE=0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
USDE=0x4c9EDD5852cd905f086C759E8383e09bff1E68B3
WHALE=$SUSDE   # sUSDe custodies USDe (totalAssets); use it as the USDe source on the fork

if ! command -v cast >/dev/null 2>&1; then export PATH="$HOME/.foundry/bin:$PATH"; fi
PORT=$(jq -r ".\"$CID\".port" "$CHAINS_CFG")
RPC="http://127.0.0.1:$PORT"

rpc(){ cast rpc --rpc-url "$RPC" "$@" >/dev/null; }
send(){ cast send --rpc-url "$RPC" --unlocked "$@" >/dev/null; }

echo "=== seed Ethena cooldown  chain=$CID demo=$DEMO amount=$AMOUNT USDe"
# Gas for the impersonated senders.
rpc anvil_setBalance "$WHALE" 0xde0b6b3a7640000
rpc anvil_setBalance "$DEMO"  0xde0b6b3a7640000

# 1) Fund the demo account with USDe (whale -> demo).
rpc anvil_impersonateAccount "$WHALE"
send "$USDE" "transfer(address,uint256)(bool)" "$DEMO" "$AMOUNT" --from "$WHALE"
rpc anvil_stopImpersonatingAccount "$WHALE"

# 2) Demo account: deposit USDe -> sUSDe, then cooldown all shares.
rpc anvil_impersonateAccount "$DEMO"
send "$USDE"  "approve(address,uint256)(bool)" "$SUSDE" "$AMOUNT" --from "$DEMO"
send "$SUSDE" "deposit(uint256,address)(uint256)" "$AMOUNT" "$DEMO" --from "$DEMO"
SHARES=$(cast call "$SUSDE" "balanceOf(address)(uint256)" "$DEMO" --rpc-url "$RPC")
SHARES=${SHARES%% *}
send "$SUSDE" "cooldownShares(uint256)(uint256)" "$SHARES" --from "$DEMO"
rpc anvil_stopImpersonatingAccount "$DEMO"

# 3) Verify.
OUT=$(cast call "$SUSDE" "cooldowns(address)(uint104,uint152)" "$DEMO" --rpc-url "$RPC")
echo "  cooldowns($DEMO) = $OUT"
echo "  -> read $DEMO's Ethena 'USDe Cooldown' leg with cast call; it should equal the underlyingAmount above."
