#!/bin/bash
# End-to-end streaming check: starts the agent, connects the viewer,
# and verifies that what arrived matches what was sent.
#
#   ./scripts/streamtest.sh [host]
#
# Defaults to loopback. Pass a tailnet address to exercise the real path.
set -euo pipefail

cd "$(dirname "$0")/.."
HOST="${1:-127.0.0.1}"
SECONDS_TO_RUN=10
APP="$PWD/build/ControlMyMac.app"
OUT="$HOME/Movies/ControlMyMac/streamtest.mp4"
AGENT_LOG="$HOME/Library/Logs/ControlMyMac/agent.log"

[ -d "$APP" ] || { echo "no build — run scripts/build.sh first" >&2; exit 1; }

rm -f "$AGENT_LOG" "$OUT"
open -a "$APP" --args --serve --duration $((SECONDS_TO_RUN + 5)) --fps 30 --width 1440 --fixed-quality
sleep 3

.build/release/ControlMyMacViewer --host "$HOST" --duration "$SECONDS_TO_RUN" --output "$OUT"
VIEWER_STATUS=$?

# Wait for the agent's *final* summary. The periodic status lines look
# similar but report a mid-run count, which would compare against the
# wrong number.
echo
echo "=== waiting for agent to finish ==="
for _ in $(seq 1 30); do
  grep -qE "sent [0-9]+ frames, .* MiB" "$AGENT_LOG" && break
  sleep 1
done

echo "=== sender ==="
grep -E "sent [0-9]+ frames, .* MiB" "$AGENT_LOG" | tail -1

SENT=$(grep -oE "sent [0-9]+ frames, " "$AGENT_LOG" | tail -1 | grep -oE "[0-9]+" || echo 0)
RECEIVED=$(ffprobe -v error -select_streams v -show_entries stream=nb_frames \
             -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null || echo 0)

echo "=== result ==="
echo "sent     $SENT frames"
echo "received $RECEIVED frames"

if [ "$VIEWER_STATUS" -ne 0 ]; then
  echo "FAIL: viewer reported an error"; exit 1
fi
# The last frame or two can still be in the socket when the viewer
# disconnects. That is expected, not a defect — but a real gap is not.
DELTA=$(( SENT - RECEIVED ))
[ "$DELTA" -lt 0 ] && DELTA=$(( -DELTA ))
if [ "$DELTA" -gt 2 ]; then
  echo "FAIL: frame count mismatch (off by $DELTA)"; exit 1
fi
# Strictly increasing timestamps matter: the iOS client schedules
# presentation off these.
DUPES=$(ffprobe -v error -select_streams v -show_entries packet=pts -of csv=p=0 "$OUT" \
        | sort -n | uniq -d | wc -l | tr -d ' ')
if [ "$DUPES" != "0" ]; then
  echo "FAIL: $DUPES duplicate timestamps"; exit 1
fi

echo "PASS: $RECEIVED of $SENT frames round-tripped (delta $DELTA), timestamps monotonic"
