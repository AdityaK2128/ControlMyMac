#!/bin/bash
# Launches the agent through LaunchServices and tails its log.
#
# `open` matters: it gives the process its own TCC identity instead of
# inheriting the terminal's. Run the binary directly only when you
# already know the permission is settled.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="$PWD/build/ControlMyMac.app"
LOG="$HOME/Library/Logs/ControlMyMac/agent.log"

[ -d "$APP" ] || { echo "no build — run scripts/build.sh first" >&2; exit 1; }

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

open -a "$APP" --args "$@"

echo "==> tailing $LOG (ctrl-c to stop)"
# Follow until the summary lands, then stop on its own.
tail -f "$LOG" &
TAIL_PID=$!
trap 'kill $TAIL_PID 2>/dev/null' EXIT

for _ in $(seq 1 120); do
  sleep 1
  grep -q -- "-------------------------" "$LOG" 2>/dev/null && break
  grep -q "ERROR" "$LOG" 2>/dev/null && break
done
sleep 0.5
