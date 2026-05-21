#!/usr/bin/env bash
# Spawn one anvil per supported chain. Each anvil:
#   - forks the live chain at the latest block (via the matching $<chain>_URL in .env)
#   - listens on a fixed localhost port (see script/development/config/chains.json)
#   - loads state from script/development/state/<chainId>.json on startup (if file exists)
#   - dumps state to that file on graceful shutdown (SIGTERM) and every 60s for crash safety
# PIDs are written to state/<chainId>.pid so stop-forks.sh can find them later.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CONFIG="$DEV_DIR/config/chains.json"

mkdir -p "$STATE_DIR"

if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "error: $REPO_ROOT/.env not found — needs MAINNET_URL/OP_URL/GNOSIS_URL/ARBITRUM_URL/BASE_URL" >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source "$REPO_ROOT/.env"; set +a

if ! command -v anvil >/dev/null 2>&1; then
  if [ -x "$HOME/.foundry/bin/anvil" ]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "error: anvil not on PATH" >&2; exit 1
  fi
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not on PATH" >&2; exit 1
fi

CHAIN_IDS=$(jq -r 'keys[]' "$CONFIG")

for cid in $CHAIN_IDS; do
  port=$(jq -r ".\"$cid\".port" "$CONFIG")
  name=$(jq -r ".\"$cid\".name" "$CONFIG")
  rpc_env=$(jq -r ".\"$cid\".rpcEnv" "$CONFIG")
  rpc_url="${!rpc_env:-}"
  if [ -z "$rpc_url" ]; then
    echo "skip $name (chain $cid): \$$rpc_env not set in .env" >&2
    continue
  fi

  state_file="$STATE_DIR/$cid.json"
  pid_file="$STATE_DIR/$cid.pid"
  log_file="$STATE_DIR/$cid.log"

  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    echo "already running: $name (chain $cid) pid $(cat "$pid_file") on :$port"
    continue
  fi

  state_args=()
  if [ -f "$state_file" ]; then
    state_args=(--state "$state_file" --state-interval 60)
    state_note="resuming from $state_file"
  else
    state_args=(--state "$state_file" --state-interval 60)
    state_note="fresh fork — will dump state to $state_file"
  fi

  echo "starting $name (chain $cid) on :$port — $state_note"
  nohup anvil \
    --fork-url "$rpc_url" \
    --chain-id "$cid" \
    --port "$port" \
    --host 127.0.0.1 \
    "${state_args[@]}" \
    >"$log_file" 2>&1 &
  echo $! > "$pid_file"
done

# Small wait so the user sees ports come up before the script exits
sleep 1
echo
echo "running anvils:"
for cid in $CHAIN_IDS; do
  pid_file="$STATE_DIR/$cid.pid"
  port=$(jq -r ".\"$cid\".port" "$CONFIG")
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    printf "  chain %-6s pid %-7s http://127.0.0.1:%s\n" "$cid" "$(cat "$pid_file")" "$port"
  fi
done
