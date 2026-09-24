#!/usr/bin/env bash
# Idempotently ensure a PR exists for a completed issue's branch: creates
# one from the issue's own title if missing, assigns the repo owner, and
# just prints the existing URL if one's already there (including the ones
# a backend opened on its own despite the rule -- see run-issue.sh).
#
# run-issue.sh deliberately never opens a PR; this is the explicit,
# human-invoked step that does, so review always happens through one.
#
# Usage: bash open-pr.sh --project <name> --issue <N>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
ISSUE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: bash open-pr.sh --project <name> --issue <N>" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$ISSUE" ] || { echo "usage: bash open-pr.sh --project <name> --issue <N>" >&2; exit 2; }

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
command -v jq >/dev/null 2>&1 || { echo "open-pr.sh requires jq on PATH" >&2; exit 96; }

cd "$REPO_PATH" || exit 98

git fetch origin --quiet 2>/dev/null

# Ask the remote directly first -- cursor-agent has been inconsistent about
# actually printing the ISSUE_<N>_RESULT sentinel line, so the log alone
# isn't reliable. Every backend follows the feat/fix/<N>-* naming convention
# when it pushes.
branch=$(git ls-remote --heads origin 2>/dev/null \
  | grep -oE "refs/heads/(feat|fix)/${ISSUE}-[^[:space:]]+" \
  | sed 's#refs/heads/##' | head -1)

if [ -z "$branch" ]; then
  latest_log=$(ls -t "$LOG_DIR/${PROJECT}-issue-${ISSUE}-"*-build.log 2>/dev/null | head -1)
  [ -n "$latest_log" ] || { echo "no build log found for issue #$ISSUE in $LOG_DIR" >&2; exit 1; }
  branch=$(grep -oE "branch=[^[:space:]]+" "$latest_log" | tail -1 | cut -d= -f2)
fi
[ -n "$branch" ] && [ "$branch" != "none" ] || { echo "no pushed branch found for issue #$ISSUE" >&2; exit 1; }

existing=$(gh pr list --repo "$REPO_SLUG" --head "$branch" --state all --json number,url --jq '.[0]' 2>/dev/null)
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  echo "PR already exists: $(printf '%s' "$existing" | jq -r '.url')"
  exit 0
fi

title=$(gh issue view "$ISSUE" --repo "$REPO_SLUG" --json title --jq '.title')
owner="${REPO_SLUG%%/*}"

gh pr create --repo "$REPO_SLUG" --base "$DEFAULT_BRANCH" --head "$branch" \
  --title "$title" --body "Closes #$ISSUE" --assignee "$owner"
