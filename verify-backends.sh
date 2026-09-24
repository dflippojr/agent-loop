#!/usr/bin/env bash
# Prove each backend CLI is reachable, authenticated and returns text -- at the
# cheapest invocation that can prove it.
#
# This exists because "does the codex backend work" and "can this model do the
# work" are different questions, and only the second one needs a real session.
# Verifying wiring with a representative workload is how 30 points of a weekly
# pool go into test runs: on 2026-09-19 a backend-routing feature was tested by
# running full PR reviews on each backend, which cost roughly seven frontier
# sessions to answer a question a one-word prompt answers.
#
# So every probe here uses the lowest effort the backend offers, a prompt that
# needs no tools and no repository, and a scratch directory rather than a
# worktree. Cost is reported so the claim "this is cheap" stays checkable.
#
# Usage: bash verify-backends.sh [--project <name>] [--backend <codex|cursor|claude>]...
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/backends.sh
source "$SCRIPT_DIR/lib/backends.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
BACKENDS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --backend) BACKENDS="$BACKENDS ${2:-}"; shift 2 ;;
    -h|--help) echo "usage: bash verify-backends.sh [--project <name>] [--backend <codex|cursor|claude>]..." >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BACKENDS" ] || BACKENDS="codex cursor claude"

if [ -n "$PROJECT" ]; then
  load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
else
  LOG_DIR="$SCRIPT_DIR/logs"
fi
mkdir -p "$LOG_DIR"

OS_NAME="$(detect_os)"
SCRATCH="$LOG_DIR/verify"
mkdir -p "$SCRATCH"

# No tools, no repository, one word back. Anything more is measuring the model
# rather than the wiring.
PROBE='Reply with exactly the word READY and nothing else. Do not use any tools.'

# A probe is orders of magnitude smaller than a session, and being unable to
# find out whether a backend works because its pool is low is worse than the
# probe's own cost. So an off-limits pool is still refused, but a merely low
# one is reported and probed anyway.
pool_note() { # $1=backend
  local verdict
  verdict="$(check_pool "$SCRIPT_DIR" "$1" low 2>&1)" || true
  case "$verdict" in
    POOL_OFF_LIMITS*) echo "REFUSED $verdict"; return 1 ;;
    *) printf '%s' "$verdict" ;;
  esac
  return 0
}

printf "%-8s %-8s %7s %10s %10s  %s\n" "BACKEND" "RESULT" "SECONDS" "TOKENS" "COST" "REPLY"
rc_all=0
for backend in $BACKENDS; do
  case "$backend" in codex|cursor|claude) ;; *) echo "unknown backend: $backend" >&2; exit 2 ;; esac

  note="$(pool_note "$backend")" || { printf "%-8s %-8s %7s %10s %10s  %s\n" "$backend" "SKIP" "-" "-" "-" "$note"; continue; }

  out="$SCRATCH/probe-$backend.log"
  export AGENT_USAGE_FILE="$SCRATCH/probe-$backend.usage.json"
  export AGENT_EFFORT="low" AGENT_MODEL=""
  # Cursor's effort tiers are model ids, so low resolves to the cheapest Grok.
  ts=$(date +%s)
  case "$backend" in
    codex)  run_codex  "$SCRATCH" "$PROBE" >"$out" 2>&1; rc=$? ;;
    cursor) run_cursor "$SCRATCH" "$PROBE" "$OS_NAME" >"$out" 2>&1; rc=$? ;;
    claude) run_claude "$SCRATCH" "$PROBE" >"$out" 2>&1; rc=$? ;;
  esac
  secs=$(( $(date +%s) - ts ))

  tokens="-"; cost="-"
  case "$backend" in
    codex) tokens="$(codex_tokens "$out")" ;;
    claude)
      line="$(parse_claude_json "$AGENT_USAGE_FILE")"
      tokens="$(printf '%s' "$line" | cut -f1)"
      cost="$(printf '%s' "$line" | cut -f2)"
      ;;
  esac
  reply="$(tr -d '\r' <"$out" | grep -viE '^\s*$|^(openai|workdir|model|provider|approval|sandbox|reasoning|session|-----|tokens used|[0-9,]+$)' | tail -1 | cut -c1-40)"

  if [ $rc -eq 0 ] && printf '%s' "$reply" | grep -qi 'READY'; then
    result="OK"
  else
    result="FAIL"; rc_all=1
  fi
  printf "%-8s %-8s %7s %10s %10s  %s\n" \
    "$backend" "$result" "$secs" "${tokens:--}" "${cost:--}" "${reply:-(no reply; see $out)}"

  # Recorded like any other session, so the cost of verifying is visible next
  # to the cost of working rather than being invisible overhead.
  record_session "$out" "${PROJECT:-none}" "verify" "$backend" "" "$backend" \
    "$(effective_model "$backend")" "low" "$rc" "$ts" "$AGENT_USAGE_FILE" >/dev/null
done

exit $rc_all
