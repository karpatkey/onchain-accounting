#!/usr/bin/env bash
# Nuke all dev-fork state files (state, pid, logs, addresses).
# Use this after an interface change so the next start-forks.sh begins from a fresh fork
# and the next deploy.sh re-deploys everything cleanly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STATE_DIR="$REPO_ROOT/script/development/state"

if [ ! -d "$STATE_DIR" ]; then
  echo "no state dir at $STATE_DIR — nothing to reset"
  exit 0
fi

# Safety: refuse to reset while any anvil is still running
running=0
for pid_file in "$STATE_DIR"/*.pid; do
  [ -f "$pid_file" ] || continue
  pid=$(cat "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    echo "anvil still running (pid $pid, $(basename "$pid_file" .pid)); run stop-forks.sh first" >&2
    running=$((running + 1))
  fi
done
[ "$running" -gt 0 ] && exit 1

rm -f "$STATE_DIR"/*.json "$STATE_DIR"/*.pid "$STATE_DIR"/*.log
echo "reset $STATE_DIR"
