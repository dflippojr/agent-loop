#!/usr/bin/env bash
# agent-loop: refine one GitHub issue into a consistently well-specified,
# implementation-ready issue -- or, when it genuinely needs a human product
# decision, into a clear list of the open questions. Never touches code,
# branches, or tests; its only side effect is `gh issue edit`.
#
# Usage: bash refine-issue.sh --project <name> --issue <N> \
#            (--backend <codex|cursor|claude> | --tier <mechanical|standard|frontier>) \
#            [--effort <low|medium|high|xhigh|max>] [--model <id>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/backends.sh
source "$SCRIPT_DIR/lib/backends.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
ISSUE=""
BACKEND=""
# Flags take precedence; an inherited AGENT_EFFORT/AGENT_MODEL still works as
# the default so existing callers do not change behavior.
EFFORT="${AGENT_EFFORT:-}"
MODEL="${AGENT_MODEL:-}"
TIER=""

usage() {
  echo "usage: bash refine-issue.sh --project <name> --issue <N> (--backend <codex|cursor|claude> | --tier <mechanical|standard|frontier>) [--effort <low|medium|high|xhigh|max>] [--model <id>]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --issue) ISSUE="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --tier) TIER="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$PROJECT" ] && [ -n "$ISSUE" ] || usage
[ -n "$BACKEND" ] || [ -n "$TIER" ] || { echo "need --backend or --tier" >&2; usage; }
case "$EFFORT" in ""|low|medium|high|xhigh|max) ;; *) echo "unknown effort: $EFFORT" >&2; usage ;; esac

# See run-issue.sh: the tier fills only what was left open.
TIER_ROUTE=""
if [ -n "$TIER" ]; then
  TIER_LINE="$(resolve_tier "$SCRIPT_DIR" "$TIER")" || exit $?
  [ -n "$BACKEND" ] || BACKEND="$(printf '%s' "$TIER_LINE" | cut -f1)"
  [ -n "$EFFORT" ]  || EFFORT="$(printf '%s' "$TIER_LINE" | cut -f2)"
  [ -n "$MODEL" ]   || MODEL="$(printf '%s' "$TIER_LINE" | cut -f3)"
  TIER_ROUTE="$(printf '%s' "$TIER_LINE" | cut -f4)"
fi
export AGENT_TIER="$TIER"

case "$BACKEND" in codex|cursor|claude) ;; *) echo "unknown backend: $BACKEND (want codex|cursor|claude)" >&2; exit 2 ;; esac

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
export AGENT_EFFORT="$EFFORT" AGENT_MODEL="$MODEL"

# Refuse to start on a pool that cannot afford this session. Captured rather
# than printed directly so the first stdout line stays the log path, which is
# what an orchestrator reads.
POOL_VERDICT="$(check_pool "$SCRIPT_DIR" "$BACKEND" "$EFFORT" "$(effective_model "$BACKEND")" 2>&1)"; POOL_RC=$?
if [ "$POOL_RC" -eq 90 ]; then echo "$POOL_VERDICT" >&2; exit 90; fi

OS_NAME="$(detect_os)"
JSON_TOOL="$(find_json_tool)" || { echo "no jq or python found on PATH" >&2; exit 96; }
REPO_NAME="$(basename "$REPO_PATH")"
# Refinement worktrees are disposable (no commits expected) but still
# isolated from the main checkout, and from build worktrees for the same
# issue, in case both are in flight.
WORKTREE="$WORKTREE_BASE/${REPO_NAME}-issue-${ISSUE}-refine"

LOG="$(init_log "$LOG_DIR" "$PROJECT" "$ISSUE" "$BACKEND" "refine")"
echo "$LOG"

# Per-session accounting (see record_session in lib/session.sh).
TS_START=$(date +%s)
export AGENT_USAGE_FILE="${LOG}.usage.json"

{
echo "=== agent-loop refine: project=$PROJECT issue=#$ISSUE backend=$BACKEND effort=${EFFORT:-default} model=${MODEL:-default} tier=${TIER:-none}${TIER_ROUTE:+ route=$TIER_ROUTE} os=$OS_NAME ==="
[ -n "$POOL_VERDICT" ] && echo "$POOL_VERDICT"

# Pace this launch against the others in flight (see acquire_slot).
acquire_slot "$LOG_DIR" "$BACKEND" "$MAX_CONCURRENT" "$LAUNCH_STAGGER"
slot_rc=$?
if [ $slot_rc -ne 0 ]; then echo "___ISSUE_${ISSUE}_${BACKEND}_REFINE_EXIT_${slot_rc}___"; exit $slot_rc; fi
date

setup_worktree "$REPO_PATH" "$DEFAULT_BRANCH" "$WORKTREE"
rc=$?
if [ $rc -ne 0 ]; then echo "___ISSUE_${ISSUE}_${BACKEND}_REFINE_EXIT_${rc}___"; exit $rc; fi

ISSUE_JSON=$(fetch_issue_json "$ISSUE" "$REPO_SLUG")
TITLE=$(fetch_issue_title "$ISSUE_JSON" "$JSON_TOOL")
BODY=$(fetch_issue_body "$ISSUE_JSON" "$JSON_TOOL")
LABELS=$(fetch_issue_labels "$ISSUE_JSON" "$JSON_TOOL")

echo "--- issue #$ISSUE: $TITLE [$LABELS] ---"

PROMPT=$(cat <<PROMPTEOF
You are refining GitHub issue #$ISSUE in $REPO_SLUG: "$TITLE" -- turning it into a
consistently well-specified issue, or, when it genuinely can't be, into a
clear list of the open questions a human needs to answer. You do this by
editing the issue directly with the GitHub CLI; you are not implementing it.

Current issue body:
$BODY

Current labels: $LABELS

Mandatory standing rules (apply every step, do not wait to be told):
- You have a worktree at $WORKTREE (checked out from origin/$DEFAULT_BRANCH, detached HEAD) purely so you can read code, docs, and existing conventions for grounding. Read-only: do NOT create a branch, do NOT edit, create, or delete any file in it, do NOT commit, do NOT run tests. Your only mutating action is \`gh issue edit\`.
- Confirm live issue state yourself before starting: \`gh issue view $ISSUE --repo $REPO_SLUG\` and check related/open issues with \`gh issue list --repo $REPO_SLUG\` for real dependencies -- this prompt is a snapshot and could be stale.
- Explore the repository as needed (grep, read files) to ground the issue in what actually exists: correct paths, existing patterns, real module/feature names. Do not invent scope, APIs, or file paths that don't exist. Keep that exploration bounded -- scope and cap searches (\`rg -n --max-count 5 <pattern> <path>\`) and read the region of a file you need (\`sed -n '120,200p' <file>\`) rather than whole files. Grounding a spec needs the shape of the code, not all of it, and this session is meant to be a cheap one.
- Decide whether this issue is now specified enough that an unattended coding-agent session could implement it with zero further product or design decisions. That is the bar for "ready" -- not "clear enough for a human to muddle through."
  - If yes: rewrite the issue body into a clear, consistently structured spec. A structure like this works well for this repo (adapt as the issue needs, don't force sections that don't apply): an Outcome/summary, explicit scope boundaries (what's in scope, what's explicitly out), any decisions you're recording (with today's date), real dependencies on other issues by number, and a concrete acceptance-criteria checklist. Then run \`gh issue edit $ISSUE --repo $REPO_SLUG --body-file <tmpfile> --add-label ready\` (and \`--remove-label needs-refinement\` if it's currently set).
  - If no: do not guess at the missing product/business/design decision yourself. Rewrite the body to clearly and specifically enumerate exactly what's unresolved and what decision or input is needed for each -- not a vague "needs more detail". Then run \`gh issue edit $ISSUE --repo $REPO_SLUG --body-file <tmpfile> --add-label needs-refinement\` (and \`--remove-label ready\` if it's currently set).
- If the issue title itself is vague or inaccurate given the real scope, also update it with \`gh issue edit $ISSUE --repo $REPO_SLUG --title "..."\`.
- Never use a computer-use/UI-automation tool or skill to probe or interact with your own provider's account/usage UI.
- End your final message with exactly one line of this form (no other text on that line):
ISSUE_${ISSUE}_REFINE_RESULT: <READY|NEEDS_REFINEMENT|FAILED> summary=<short-summary>
PROMPTEOF
)

case "$BACKEND" in
  codex) run_codex "$WORKTREE" "$PROMPT"; RC=$? ;;
  cursor) run_cursor "$WORKTREE" "$PROMPT" "$OS_NAME"; RC=$? ;;
  claude) run_claude "$WORKTREE" "$PROMPT"; RC=$? ;;
esac

if worktree_is_clean "$WORKTREE"; then
  git -C "$REPO_PATH" worktree remove "$WORKTREE" --force 2>&1 || true
else
  echo "REFINE_SAFETY_VIOLATION: worktree $WORKTREE has uncommitted changes after a refine-only session -- left in place for inspection, not removed."
  ( cd "$WORKTREE" && git status --short )
fi

record_session "$LOG" "$PROJECT" "refine" "$ISSUE" "" "$BACKEND" \
  "$(effective_model "$BACKEND")" "${AGENT_EFFORT:-}" "$RC" "$TS_START" "$AGENT_USAGE_FILE"

echo "___ISSUE_${ISSUE}_${BACKEND}_REFINE_EXIT_${RC}___"
} >>"$LOG" 2>&1
