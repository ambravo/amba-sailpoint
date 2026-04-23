#!/usr/bin/env bash
# Loop poll_and_notify.sh every INTERVAL seconds until killed.
# Ctrl+C or `kill <pid-of-this-script>` stops the whole chain -
# any in-flight child (curl, poll_and_notify.sh, sleep) is killed
# together so you don't end up with zombies still polling.
#
# Usage:
#   ./run_poller.sh [INTERVAL_SECONDS] [-- EXTRA_ARGS_FOR_POLL]
#
# Examples:
#   ./run_poller.sh                    # default 60s
#   ./run_poller.sh 30                 # every 30s
#   ./run_poller.sh 60 -- -v           # every 60s, verbose child
#   ./run_poller.sh 60 -- 24           # every 60s, 24h seed window
#
# To leave it running in background + log to a file:
#   nohup ./run_poller.sh 60 > poll.log 2>&1 &
#   echo $! > poll.pid
#   kill "$(cat poll.pid)"             # later, to stop

set -euo pipefail

INTERVAL="${1:-60}"
shift || true
# Anything after "--" is passed through to poll_and_notify.sh.
if [[ "${1:-}" == "--" ]]; then
  shift
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/poll_and_notify.sh"

# Make sure children die with us on SIGINT/SIGTERM/EXIT. pkill -P kills
# anything spawned by this shell (the current poll_and_notify.sh, its
# curl subprocesses, the sleep). Running as a process group would be
# cleaner but pkill is portable enough for macOS/Linux.
cleanup() {
  local ec=$?
  echo "[run_poller] stopping (signal or exit); killing children..." >&2
  pkill -P $$ 2>/dev/null || true
  exit "$ec"
}
trap cleanup INT TERM
trap 'pkill -P $$ 2>/dev/null || true' EXIT

echo "[run_poller] PID=$$ interval=${INTERVAL}s args=[$*]"
while true; do
  "$POLL" "$@" || echo "[run_poller] poll returned non-zero, continuing" >&2
  # Backgrounded sleep + wait so the trap fires immediately on SIGINT,
  # instead of waiting out the sleep.
  sleep "$INTERVAL" &
  wait $!
done
