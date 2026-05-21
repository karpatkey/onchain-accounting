#!/usr/bin/env bash
# Gracefully stop all dev-fork anvils so each one dumps its --state file before exiting.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE_DIR="$REPO_ROOT/script/development/state"
CONFIG="$REPO_ROOT/script/development/config/chains.json"

if [ ! -d "$STATE_DIR" ]; then
  echo "no state dir at $STATE_DIR — nothing to stop"
  exit 0
fi

shopt -s nullglob
CHAIN_IDS=$(jq -r 'keys[]' "$CONFIG")

stopped=0
for cid in $CHAIN_IDS; do
  pid_file="$STATE_DIR/$cid.pid"
  [ -f "$pid_file" ] || continue
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    echo "stopping chain $cid (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    # wait up to 10s for graceful state dump
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "  pid $pid did not exit after 10s, sending SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
    stopped=$((stopped + 1))
  fi
  rm -f "$pid_file"
done

echo "stopped $stopped fork(s); state files in $STATE_DIR"
