#!/usr/bin/env bash
# Print each usage pool's remaining headroom, reset date, observed burn rate
# and projected end-of-cycle usage, plus how many sessions that headroom
# actually buys on the pool's cheapest route.
#
# Reads pools.yaml (edit the numbers there, not here) and the session log
# written by record_session. Launches nothing and costs nothing.
#
# Usage: bash pool-status.sh [--project <name>] [--config <pools.yaml>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
CONFIG="$SCRIPT_DIR/pools.yaml"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --config) CONFIG="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: bash pool-status.sh [--project <name>] [--config <pools.yaml>]" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$CONFIG" ] || { echo "no pools config at $CONFIG" >&2; exit 2; }

# A project only supplies the log directory; without one, fall back to the
# default so the table still prints (with no burn rate).
if [ -n "$PROJECT" ]; then
  load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
else
  LOG_DIR="$SCRIPT_DIR/logs"
fi

PY="$(find_python)" || { echo "pool-status.sh requires python3 or python on PATH" >&2; exit 96; }

exec "$PY" "$SCRIPT_DIR/lib/pool_status.py" "$CONFIG" "$LOG_DIR/sessions.jsonl" "$LOG_DIR"
