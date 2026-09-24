#!/usr/bin/env bash
# What the work actually cost, joined to whether it merged.
#
# Refreshes the merge outcome of every item in sessions.jsonl (a PR's state
# from gh; an issue's branch from the remote, the same way status.sh decides),
# caches it in <LOG_DIR>/outcomes.json, then reports cost per item, per route,
# and how much of the merged work never needed a frontier session.
#
# Usage: bash report.sh --project <name> [--no-refresh]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
REFRESH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --no-refresh) REFRESH=0; shift ;;
    -h|--help) echo "usage: bash report.sh --project <name> [--no-refresh]" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "usage: bash report.sh --project <name> [--no-refresh]" >&2; exit 2; }

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?

SESSIONS="$LOG_DIR/sessions.jsonl"
OUTCOMES="$LOG_DIR/outcomes.json"
[ -f "$SESSIONS" ] || { echo "no session log at $SESSIONS (run backfill-sessions.sh first)" >&2; exit 1; }

PY=""
for candidate in python3 python; do
  "$candidate" -c "import sys" >/dev/null 2>&1 && { PY="$candidate"; break; }
done
[ -n "$PY" ] || { echo "report.sh requires python3 or python on PATH" >&2; exit 96; }

if [ "$REFRESH" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "report.sh --refresh requires jq on PATH" >&2; exit 96; }
  cd "$REPO_PATH" || exit 98
  git fetch origin --prune --quiet 2>/dev/null

  # An issue's outcome is whether the branch its session pushed reached the
  # default branch -- the issue number and its eventual PR number differ, so
  # the branch is the only reliable link between them.
  echo "refreshing outcomes..." >&2
  {
    echo "{"
    first=1
    # tr -d '\r': the Windows jq build emits CRLF, which would otherwise end up
    # inside the JSON keys written below.
    for key in $(jq -r '(if (.kind | startswith("pr-")) then "pr" else "issue" end) + "-" + (.item | tostring)' "$SESSIONS" 2>/dev/null | tr -d '\r' | sort -u); do
      num="${key##*-}"
      state="none"
      case "$key" in
        pr-*)
          state=$(gh pr view "$num" --repo "$REPO_SLUG" --json state --jq '.state' 2>/dev/null || echo "none")
          ;;
        issue-*)
          branch=$(git ls-remote --heads origin 2>/dev/null \
            | grep -oE "refs/heads/(feat|fix)/${num}-[^[:space:]]+" | sed 's#refs/heads/##' | head -1)
          if [ -z "$branch" ]; then
            # A merged branch is usually deleted, so "no branch" is ambiguous:
            # fall back to the issue's own state, since the work landing is
            # what closes it.
            if [ "$(gh issue view "$num" --repo "$REPO_SLUG" --json state --jq '.state' 2>/dev/null)" = "CLOSED" ]; then
              state="merged"
            else
              state="no-branch"
            fi
          elif git merge-base --is-ancestor "origin/$branch" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
            state="merged"
          else
            state="open"
          fi
          ;;
      esac
      [ "$first" -eq 1 ] || echo ","
      first=0
      printf '  "%s": "%s"' "$key" "$state"
    done
    echo
    echo "}"
  } > "$OUTCOMES"
fi

exec "$PY" "$SCRIPT_DIR/lib/report.py" "$SESSIONS" "$OUTCOMES" "$SCRIPT_DIR/pools.yaml"
