#!/usr/bin/env bash
# List every issue agent-loop has run for a project, with review status:
# branch, whether it's pushed, PR state, and whether it's merged yet.
# Usage: bash status.sh --project <name>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: bash status.sh --project <name>" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "usage: bash status.sh --project <name>" >&2; exit 2; }

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
command -v jq >/dev/null 2>&1 || { echo "status.sh requires jq on PATH" >&2; exit 96; }

cd "$REPO_PATH" || exit 98
git fetch origin "$DEFAULT_BRANCH" --quiet

ISSUES=$(ls "$LOG_DIR" 2>/dev/null \
  | grep -E "^${PROJECT}-issue-[0-9]+-.*-build\.log$" \
  | sed -E "s/^${PROJECT}-issue-([0-9]+)-.*/\1/" \
  | sort -nu)

if [ -z "$ISSUES" ]; then
  echo "no build logs found for project '$PROJECT' in $LOG_DIR"
  exit 0
fi

printf "%-6s %-38s %-7s %-12s %-7s\n" "ISSUE" "BRANCH" "PUSHED" "PR" "MERGED"
for n in $ISSUES; do
  # Don't trust the agent's self-reported ISSUE_<N>_RESULT line alone --
  # cursor-agent has been inconsistent about actually printing it. Ask the
  # remote directly for a feat/fix/<N>-* branch, which is reliable since
  # every backend follows that naming convention when it pushes.
  branch=$(git ls-remote --heads origin 2>/dev/null \
    | grep -oE "refs/heads/(feat|fix)/${n}-[^[:space:]]+" \
    | sed 's#refs/heads/##' | head -1)

  if [ -z "$branch" ]; then
    latest_log=$(ls -t "$LOG_DIR/${PROJECT}-issue-${n}-"*-build.log 2>/dev/null | head -1)
    branch=$(grep -oE "branch=[^[:space:]]+" "$latest_log" 2>/dev/null | tail -1 | cut -d= -f2)
  fi

  if [ -z "$branch" ] || [ "$branch" = "none" ]; then
    printf "%-6s %-38s %-7s %-12s %-7s\n" "#$n" "(no branch found)" "-" "-" "-"
    continue
  fi

  pushed="no"
  git ls-remote --heads origin "$branch" 2>/dev/null | grep -q . && pushed="yes"

  pr_state="none"
  pr_json=$(gh pr list --repo "$REPO_SLUG" --head "$branch" --state all --json number,state --jq '.[0]' 2>/dev/null)
  if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
    pr_state="#$(printf '%s' "$pr_json" | jq -r '.number') $(printf '%s' "$pr_json" | jq -r '.state')"
  fi

  merged="no"
  if [ "$pushed" = "yes" ] && git merge-base --is-ancestor "origin/$branch" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
    merged="yes"
  fi

  printf "%-6s %-38s %-7s %-12s %-7s\n" "#$n" "$branch" "$pushed" "$pr_state" "$merged"
done
