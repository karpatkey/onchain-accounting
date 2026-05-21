#!/usr/bin/env bash
# Show one-line status per dev fork: chain, pid, port, block number, NAV deployed (if any).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEV_DIR="$REPO_ROOT/script/development"
STATE_DIR="$DEV_DIR/state"
CONFIG="$DEV_DIR/config/chains.json"

if ! command -v cast >/dev/null 2>&1; then
  if [ -x "$HOME/.foundry/bin/cast" ]; then
    export PATH="$HOME/.foundry/bin:$PATH"
  else
    echo "error: cast not on PATH" >&2; exit 1
  fi
fi

printf "%-6s %-12s %-7s %-15s %-12s %s\n" "chain" "name" "pid" "endpoint" "block" "NAV proxy"
printf "%-6s %-12s %-7s %-15s %-12s %s\n" "-----" "----" "---" "--------" "-----" "---------"

for cid in $(jq -r 'keys[]' "$CONFIG"); do
  name=$(jq -r ".\"$cid\".name" "$CONFIG")
  port=$(jq -r ".\"$cid\".port" "$CONFIG")
  pid_file="$STATE_DIR/$cid.pid"
  addr_file="$STATE_DIR/$cid-addresses.json"

  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
    pid=$(cat "$pid_file")
    block=$(cast block-number --rpc-url "http://127.0.0.1:$port" 2>/dev/null || echo "?")
  else
    pid="-"
    block="-"
  fi

  nav="-"
  if [ -f "$addr_file" ]; then
    nav=$(jq -r '.NAVCalculatorProxy // "-"' "$addr_file")
  fi

  printf "%-6s %-12s %-7s 127.0.0.1:%-5s %-12s %s\n" "$cid" "$name" "$pid" "$port" "$block" "$nav"
done
