#!/usr/bin/env bash
# agent-loop: launch one GitHub issue as a headless, unattended coding-agent
# session (codex / cursor-agent / claude) in its own git worktree.
#
# Usage: bash run-issue.sh --project <name> --issue <N> \
#            (--backend <codex|cursor|claude> | --tier <mechanical|standard|frontier>) \
#            [--effort <low|medium|high|xhigh|max>] [--model <id>]
#
# Effort picks the reasoning level for the session (see lib/backends.sh):
# claude -> --effort, codex -> model_reasoning_effort, cursor -> Grok 4.6 tier.
#
# --tier says what the work needs instead of where it runs, and resolves to the
# cheapest route clearing that bar whose pool can still afford a session
# (see pools.yaml). Anything given explicitly wins over the tier's choice.
#
# Project config lives in projects/<name>.env (see README.md).
# Prerequisites on PATH: git, gh (authenticated), jq (or python), and
# whichever backend CLI you pass to --backend.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/backends.sh
source "$SCRIPT_DIR/lib/backends.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"
# shellcheck source=lib/state.sh
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck source=lib/taskfile.sh
source "$SCRIPT_DIR/lib/taskfile.sh"
# shellcheck source=lib/escalation.sh
source "$SCRIPT_DIR/lib/escalation.sh"
# shellcheck source=lib/watchdog.sh
source "$SCRIPT_DIR/lib/watchdog.sh"

PROJECT=""
ISSUE=""
BACKEND=""
# Effort and model were previously settable only through the environment, which
# left them out of the log header and out of the session record. The flags take
# precedence; an inherited AGENT_EFFORT/AGENT_MODEL still works as the default
# so existing callers do not change behavior.
EFFORT="${AGENT_EFFORT:-}"
MODEL="${AGENT_MODEL:-}"
TIER=""
# Watchdog ceiling/stall minutes; unset means the per-backend default (see
# lib/watchdog.sh). Flags take precedence over an inherited env var.
TIMEOUT_MIN="${AGENT_TIMEOUT_MIN:-}"
STALL_MIN="${AGENT_STALL_MIN:-}"
# Disposable single-task sessions (agent-loop#7): --task-file runs exactly one
# step; --chain runs every <LOG_DIR>/tasks/<project>-<issue>-*.md in order,
# stopping at the first that does not make progress.
TASK_FILE=""
CHAIN=0
# Escalation is suggest-only by default (see lib/escalation.sh); this opts
# into the launcher actually re-dispatching at the next tier up.
AUTO_ESCALATE="${AGENT_AUTO_ESCALATE:-0}"

usage() {
  echo "usage: bash run-issue.sh --project <name> --issue <N> (--backend <codex|cursor|claude> | --tier <mechanical|standard|frontier>) [--effort <low|medium|high|xhigh|max>] [--model <id>] [--timeout <minutes>] [--stall <minutes>] [--auto-escalate] [--task-file <path> | --chain]" >&2
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
    --timeout) TIMEOUT_MIN="${2:-}"; shift 2 ;;
    --stall) STALL_MIN="${2:-}"; shift 2 ;;
    --task-file) TASK_FILE="${2:-}"; shift 2 ;;
    --chain) CHAIN=1; shift ;;
    --auto-escalate) AUTO_ESCALATE=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
case "$TIMEOUT_MIN" in ''|*[!0-9]*) [ -z "$TIMEOUT_MIN" ] || { echo "--timeout must be a number of minutes: $TIMEOUT_MIN" >&2; usage; } ;; esac
case "$STALL_MIN" in ''|*[!0-9]*) [ -z "$STALL_MIN" ] || { echo "--stall must be a number of minutes: $STALL_MIN" >&2; usage; } ;; esac
export AGENT_TIMEOUT_MIN="$TIMEOUT_MIN" AGENT_STALL_MIN="$STALL_MIN" AGENT_AUTO_ESCALATE="$AUTO_ESCALATE"
[ -z "$TASK_FILE" ] || [ "$CHAIN" -eq 0 ] || { echo "--task-file and --chain are mutually exclusive" >&2; usage; }
[ -z "$TASK_FILE" ] || [ -f "$TASK_FILE" ] || { echo "no such task file: $TASK_FILE" >&2; usage; }

[ -n "$PROJECT" ] && [ -n "$ISSUE" ] || usage
[ -n "$BACKEND" ] || [ -n "$TIER" ] || { echo "need --backend or --tier" >&2; usage; }
case "$EFFORT" in ""|low|medium|high|xhigh|max) ;; *) echo "unknown effort: $EFFORT" >&2; usage ;; esac

# A tier says what the work needs, not where it runs: it resolves to the
# cheapest route clearing that bar whose pool can still afford a session.
# Anything given explicitly wins -- the tier only fills what was left open.
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
# what an orchestrator reads. Skipped for --task-file/--chain: each of those
# is its own session and checks the pool itself, right before it runs (see
# run_task_step below) -- a chain must not spend its whole budget on the
# first step's pre-flight check when a later step is what a spent pool stops.
if [ -z "$TASK_FILE" ] && [ "$CHAIN" -eq 0 ]; then
  POOL_VERDICT="$(check_pool "$SCRIPT_DIR" "$BACKEND" "$EFFORT" "$(effective_model "$BACKEND")" 2>&1)"; POOL_RC=$?
  if [ "$POOL_RC" -eq 90 ]; then
    echo "$POOL_VERDICT" >&2
    # Recorded so a refusal is countable next to real sessions; report.sh and
    # pool-status.sh leave it out of cost and burn (no session ran).
    AGENT_TERMINATION="pool-refused" record_session "" "$PROJECT" "build" "$ISSUE" "" "$BACKEND" \
      "$(effective_model "$BACKEND")" "$EFFORT" 90 "$(date +%s)" "" >/dev/null
    exit 90
  fi
fi

OS_NAME="$(detect_os)"
JSON_TOOL="$(find_json_tool)" || { echo "no jq or python found on PATH" >&2; exit 96; }
REPO_NAME="$(basename "$REPO_PATH")"
WORKTREE="$WORKTREE_BASE/${REPO_NAME}-issue-${ISSUE}"

if [ -z "$TASK_FILE" ] && [ "$CHAIN" -eq 0 ]; then

LOG="$(init_log "$LOG_DIR" "$PROJECT" "$ISSUE" "$BACKEND" "build")"
echo "$LOG"

# Per-session accounting (see record_session in lib/session.sh).
TS_START=$(date +%s)
export AGENT_USAGE_FILE="${LOG}.usage.json"

{
echo "=== agent-loop build: project=$PROJECT issue=#$ISSUE backend=$BACKEND effort=${EFFORT:-default} model=${MODEL:-default} tier=${TIER:-none}${TIER_ROUTE:+ route=$TIER_ROUTE} os=$OS_NAME ==="
[ -n "$POOL_VERDICT" ] && echo "$POOL_VERDICT"

# Pace this launch against the others in flight (see acquire_slot).
acquire_slot "$LOG_DIR" "$BACKEND" "$MAX_CONCURRENT" "$LAUNCH_STAGGER"
slot_rc=$?
if [ $slot_rc -ne 0 ]; then echo "___ISSUE_${ISSUE}_${BACKEND}_EXIT_${slot_rc}___"; exit $slot_rc; fi
date

setup_worktree "$REPO_PATH" "$DEFAULT_BRANCH" "$WORKTREE"
rc=$?
if [ $rc -ne 0 ]; then echo "___ISSUE_${ISSUE}_${BACKEND}_EXIT_${rc}___"; exit $rc; fi

ISSUE_JSON=$(fetch_issue_json "$ISSUE" "$REPO_SLUG")
TITLE=$(fetch_issue_title "$ISSUE_JSON" "$JSON_TOOL")
BODY=$(fetch_issue_body "$ISSUE_JSON" "$JSON_TOOL")

echo "--- issue #$ISSUE: $TITLE ---"

STATUS_LINE=""
if [ -n "$STATUS_FILE" ]; then
  STATUS_LINE="- When you finish or stop for any reason, append a short dated entry to $STATUS_FILE describing what you did, the branch name (if any), and test results. Do not delete or rewrite other agents' entries there, only append."
fi

EXTRA_RULES=""
if [ -n "$STANDING_RULES_FILE" ] && [ -f "$STANDING_RULES_FILE" ]; then
  EXTRA_RULES="$(cat "$STANDING_RULES_FILE")"
fi

# Structured state carried across sessions on this issue (see lib/state.sh). A
# re-run reuses the worktree, so it starts from what the last session recorded.
ITEM_STATE="$(state_file_path "$LOG_DIR" "$PROJECT" issue "$ISSUE")"
export AGENT_STATE_FILE="$ITEM_STATE" AGENT_BASE_REF="origin/$DEFAULT_BRANCH"
mkdir -p "$(dirname "$ITEM_STATE")"
STATE_MTIME_BEFORE="$(state_mtime "$ITEM_STATE")"
STATE_RULE="$(state_prompt_rule "$ITEM_STATE")"
SEED_BLOCK=""
export AGENT_STATE_SEEDED=0
if SEED_TEXT="$(state_seed_block "$ITEM_STATE")"; then
  SEED_BLOCK=$'\n'"$SEED_TEXT"$'\n'
  AGENT_STATE_SEEDED=1
  echo "STATE_SEEDED: $ITEM_STATE"
fi

PROMPT=$(cat <<PROMPTEOF
You are working autonomously and unattended on GitHub issue #$ISSUE in $REPO_SLUG: "$TITLE".

Issue body:
$BODY
$SEED_BLOCK
Mandatory standing rules (apply every step, do not wait to be told):
- Work only inside this worktree: $WORKTREE (already checked out from origin/$DEFAULT_BRANCH, detached HEAD). Create your own appropriately named branch there first, e.g. \`git checkout -b feat/${ISSUE}-<short-slug>\` (match existing repo convention: feat/ for features, fix/ for bugs). Do not touch $REPO_PATH directly.
- Confirm live issue state yourself before starting: \`gh issue view $ISSUE --repo $REPO_SLUG\` -- this prompt is a snapshot and could be stale.
- Commit after every discrete step (a green focused-test pass, a finished sub-feature, any working intermediate state). This is mandatory, not optional -- do not let real work sit uncommitted.
- Keep tool output small. Everything a command prints becomes context you carry for the rest of the session, so an unbounded command costs you on every turn that follows, not just the one that ran it. Scope and cap searches (\`rg -n --max-count 5 <pattern> <path>\`), read the region of a file you need (\`sed -n '120,200p' <file>\`) rather than the whole file, and pipe anything that can run long through \`head\`. Single unbounded searches and whole-file reads in this repo have returned 8,000-14,000 lines.
- Iterate with focused tests (\`python -m pytest tests/test_<area>.py -q\`), not the whole suite. Run the full suite once, before you push -- that requirement stands below and CI runs it again on the branch -- but do not re-run it to check an intermediate step.
- Run the full existing test suite before considering anything done, and report the pass/fail counts.
- Push your branch to origin when finished, or when you must stop at a clean checkpoint. Do NOT open a pull request (even though you have \`gh\` access and creating one is one command away -- that is exactly the action this rule prohibits), do NOT merge to $DEFAULT_BRANCH, do NOT close the GitHub issue. A pushed branch with no PR is a complete, successful result here -- opening a PR is not part of finishing the task, it is a separate action reserved for the user.
- Stop cleanly at 95% of your own weekly/session usage if you can read it; do not push toward 99%+ hoping for a reset. If you cannot tell your own usage, say so plainly instead of guessing.
- Never use a computer-use/UI-automation tool or skill to probe or interact with your own provider's account/usage UI, even to check usage.
- If this issue's work turns out to already be blocked on something not yet merged to origin/$DEFAULT_BRANCH (a prerequisite issue), stop immediately without starting implementation, commit nothing, and say so clearly in your final message.
$STATUS_LINE
$STATE_RULE
$EXTRA_RULES
- End your final message with exactly one line of this form (no other text on that line):
ISSUE_${ISSUE}_RESULT: <PUSHED|BLOCKED|FAILED> branch=<branch-name-or-none> tests=<short-summary>
PROMPTEOF
)

case "$BACKEND" in
  codex) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
           run_codex "$WORKTREE" "$PROMPT"; RC=$? ;;
  cursor) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
           run_cursor "$WORKTREE" "$PROMPT" "$OS_NAME"; RC=$? ;;
  claude) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
           run_claude "$WORKTREE" "$PROMPT"; RC=$? ;;
esac

# The prompt says never open a PR; check rather than trust that it listened.
# Known quirk: some backends (observed with cursor-agent) open one anyway as
# part of their own built-in "finish the task" routine, regardless of this
# prompt. Policy (user decision, 2026-09-17): don't block on it -- assign the
# PR to the repo owner per the standing PR-assignee convention and continue.
STRAY_PRS=$(gh pr list --repo "$REPO_SLUG" --state open --json number,headRefName \
  --jq ".[] | select(.headRefName | test(\"^(feat|fix)/${ISSUE}-\")) | .number" 2>/dev/null || true)
if [ -n "$STRAY_PRS" ]; then
  for pr_num in $STRAY_PRS; do
    echo "PR_RULE_VIOLATION: backend opened a pull request despite the no-PR rule: PR #$pr_num for issue #$ISSUE"
    gh pr edit "$pr_num" --repo "$REPO_SLUG" --add-assignee "${REPO_SLUG%%/*}" 2>&1 \
      && echo "PR_RULE_VIOLATION_HANDLED: PR #$pr_num assigned to ${REPO_SLUG%%/*} and left open for review"
  done
fi

# Validate the state file the session was asked to keep, and fill files_modified
# from git rather than from the agent. Logged, never fatal.
state_finalize "$ITEM_STATE" "$WORKTREE" "origin/$DEFAULT_BRANCH" "$STATE_MTIME_BEFORE"

if [ "${WATCHDOG_TRIGGERED:-0}" -eq 1 ]; then
  AGENT_TERMINATION="watchdog" record_session "$LOG" "$PROJECT" "build" "$ISSUE" "" "$BACKEND" \
    "$(effective_model "$BACKEND")" "${AGENT_EFFORT:-}" "$RC" "$TS_START" "$AGENT_USAGE_FILE"
else
  record_session "$LOG" "$PROJECT" "build" "$ISSUE" "" "$BACKEND" \
    "$(effective_model "$BACKEND")" "${AGENT_EFFORT:-}" "$RC" "$TS_START" "$AGENT_USAGE_FILE"
fi

# Merge this session's outcome into the item's dead-end ledger and check
# whether it has now failed enough times at this tier to suggest (or, with
# --auto-escalate, perform) moving up a tier. See lib/escalation.sh.
escalation_check "$SCRIPT_DIR" "$LOG_DIR" "$PROJECT" "build" "$ISSUE" "$TIER" "issue-$ISSUE" \
  "$ITEM_STATE" "$WORKTREE" "origin/$DEFAULT_BRANCH" "$LOG"

echo "___ISSUE_${ISSUE}_${BACKEND}_EXIT_${RC}___"
} >>"$LOG" 2>&1

if [ -n "${ESCALATE_NEXT_TIER:-}" ] && [ "$AUTO_ESCALATE" = "1" ]; then
  echo "AUTO_ESCALATE: re-dispatching issue #$ISSUE at tier $ESCALATE_NEXT_TIER" >&2
  exec bash "$0" --project "$PROJECT" --issue "$ISSUE" --tier "$ESCALATE_NEXT_TIER" --auto-escalate
fi

else
# --- disposable single-task sessions driven by scoped task files (#7) ------
# A session here gets exactly one task file as its entire instruction, not
# the issue body -- see lib/taskfile.py for the required template. The
# worktree and branch are reused across steps (setup_worktree already creates
# once, reuses after), so progress lives in commits, never in a transcript.

ITEM_STATE="$(state_file_path "$LOG_DIR" "$PROJECT" issue "$ISSUE")"
export AGENT_STATE_FILE="$ITEM_STATE" AGENT_BASE_REF="origin/$DEFAULT_BRANCH"
mkdir -p "$(dirname "$ITEM_STATE")"

run_task_step() { # $1=task file $2=step label -> 0 progress made, 1 otherwise
  local task_file="$1" step="$2"
  # record_session's round becomes a bare JSON number; a filename-derived step
  # like "01" would print as the invalid JSON literal 01, so normalize to
  # base 10 first. A non-numeric step token falls back to unknown/null, same
  # as any other round-less session.
  local round_num=""
  case "$step" in ''|*[!0-9]*) round_num="" ;; *) round_num=$((10#$step)) ;; esac

  local reason
  reason="$(taskfile_check "$task_file")"
  if [ "$?" -ne 0 ]; then
    echo "TASKFILE_INVALID: $task_file: $reason" >&2
    return 1
  fi

  local pool_verdict="" pool_rc=0
  pool_verdict="$(check_pool "$SCRIPT_DIR" "$BACKEND" "$EFFORT" "$(effective_model "$BACKEND")" 2>&1)"; pool_rc=$?
  if [ "$pool_rc" -eq 90 ]; then
    echo "$pool_verdict" >&2
    AGENT_TERMINATION="pool-refused" record_session "" "$PROJECT" "task" "$ISSUE" "$round_num" "$BACKEND" \
      "$(effective_model "$BACKEND")" "$EFFORT" 90 "$(date +%s)" "" >/dev/null
    return 1
  fi

  local existed=0
  [ -d "$WORKTREE" ] && existed=1

  local log
  log="$(init_log "$LOG_DIR" "$PROJECT" "$ISSUE" "$BACKEND" "task-$step")"
  echo "$log"

  local ts_start rc watchdog_triggered=0 head_before head_after progress=0
  ts_start=$(date +%s)
  export AGENT_USAGE_FILE="${log}.usage.json"

  {
  echo "=== agent-loop task: project=$PROJECT issue=#$ISSUE step=$step backend=$BACKEND effort=${EFFORT:-default} model=${MODEL:-default} tier=${TIER:-none} os=$OS_NAME task_file=$task_file ==="
  [ -n "$pool_verdict" ] && echo "$pool_verdict"

  acquire_slot "$LOG_DIR" "$BACKEND" "$MAX_CONCURRENT" "$LAUNCH_STAGGER"
  local slot_rc=$?
  if [ "$slot_rc" -ne 0 ]; then echo "___ISSUE_${ISSUE}_${step}_${BACKEND}_EXIT_${slot_rc}___"; exit "$slot_rc"; fi
  date

  setup_worktree "$REPO_PATH" "$DEFAULT_BRANCH" "$WORKTREE"
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "___ISSUE_${ISSUE}_${step}_${BACKEND}_EXIT_${rc}___"; exit "$rc"; fi
  head_before="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"

  local branch_rule
  if [ "$existed" -eq 1 ]; then
    branch_rule="- This worktree already has a branch checked out from an earlier step: $WORKTREE. Stay on it; do NOT create or check out another branch."
  else
    branch_rule="- Work only inside this worktree: $WORKTREE (checked out from origin/$DEFAULT_BRANCH, detached HEAD). Create your own appropriately named branch there first, e.g. \`git checkout -b feat/${ISSUE}-<short-slug>\`, matching this repo's convention (feat/ for features, fix/ for bugs)."
  fi

  local task_body
  task_body="$(taskfile_render "$task_file")"

  local status_line=""
  if [ -n "$STATUS_FILE" ]; then
    status_line="- When you finish or stop for any reason, append a short dated entry to $STATUS_FILE describing what you did, the branch name (if any), and test results. Do not delete or rewrite other agents' entries there, only append."
  fi
  local extra_rules=""
  if [ -n "$STANDING_RULES_FILE" ] && [ -f "$STANDING_RULES_FILE" ]; then
    extra_rules="$(cat "$STANDING_RULES_FILE")"
  fi

  local state_mtime_before state_rule seed_block=""
  state_mtime_before="$(state_mtime "$ITEM_STATE")"
  state_rule="$(state_prompt_rule "$ITEM_STATE")"
  export AGENT_STATE_SEEDED=0
  local seed_text
  if seed_text="$(state_seed_block "$ITEM_STATE")"; then
    seed_block=$'\n'"$seed_text"$'\n'
    AGENT_STATE_SEEDED=1
    echo "STATE_SEEDED: $ITEM_STATE"
  fi

  local prompt
  prompt=$(cat <<PROMPTEOF
You are working autonomously and unattended on ONE SCOPED STEP of GitHub issue #$ISSUE in $REPO_SLUG (step $step of a disposable task chain). The task file below is your ENTIRE instruction for this session -- not a summary of the issue, the whole of it. Do not read the parent issue or expand scope beyond it.

$task_body
$seed_block
Mandatory standing rules (apply every step, do not wait to be told):
$branch_rule
- Stay strictly inside "Files in scope" above; anything else is out of scope for this step even if you notice it needs work.
- Commit as soon as "Done when" is met. Do not keep working past it.
- Keep tool output small (scope searches, read line ranges not whole files, pipe long output through \`head\`).
- Push your branch to origin when finished. Do NOT open a pull request, do NOT merge to $DEFAULT_BRANCH, do NOT close the GitHub issue.
- Stop cleanly at 95% of your own weekly/session usage if you can read it. Never use a computer-use/UI-automation tool on your own provider's account/usage UI.
- If this step turns out to already be blocked or done, make no changes and say so.
$status_line
$state_rule
$extra_rules
- End your final message with exactly one line of this form (no other text on that line):
TASK_${ISSUE}_${step}_RESULT: <PUSHED|FAILED> branch=<branch-name-or-none> tests=<short-summary>
PROMPTEOF
)

  case "$BACKEND" in
    codex) run_with_watchdog "$OS_NAME" "$BACKEND" "$log" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
             run_codex "$WORKTREE" "$prompt"; rc=$? ;;
    cursor) run_with_watchdog "$OS_NAME" "$BACKEND" "$log" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
             run_cursor "$WORKTREE" "$prompt" "$OS_NAME"; rc=$? ;;
    claude) run_with_watchdog "$OS_NAME" "$BACKEND" "$log" "$WORKTREE" "$ITEM_STATE" "origin/$DEFAULT_BRANCH" \
             run_claude "$WORKTREE" "$prompt"; rc=$? ;;
  esac
  watchdog_triggered="${WATCHDOG_TRIGGERED:-0}"

  head_after="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "")"
  if [ -n "$head_after" ] && [ "$head_after" != "$head_before" ]; then
    progress=1
  else
    echo "NO_PROGRESS: issue #$ISSUE step $step made no new commit"
  fi

  local stray_prs
  stray_prs=$(gh pr list --repo "$REPO_SLUG" --state open --json number,headRefName \
    --jq ".[] | select(.headRefName | test(\"^(feat|fix)/${ISSUE}-\")) | .number" 2>/dev/null || true)
  if [ -n "$stray_prs" ]; then
    local pr_num
    for pr_num in $stray_prs; do
      echo "PR_RULE_VIOLATION: backend opened a pull request despite the no-PR rule: PR #$pr_num for issue #$ISSUE"
      gh pr edit "$pr_num" --repo "$REPO_SLUG" --add-assignee "${REPO_SLUG%%/*}" 2>&1 \
        && echo "PR_RULE_VIOLATION_HANDLED: PR #$pr_num assigned to ${REPO_SLUG%%/*} and left open for review"
    done
  fi

  state_finalize "$ITEM_STATE" "$WORKTREE" "origin/$DEFAULT_BRANCH" "$state_mtime_before"

  if [ "$watchdog_triggered" -eq 1 ]; then
    AGENT_TERMINATION="watchdog" record_session "$log" "$PROJECT" "task" "$ISSUE" "$round_num" "$BACKEND" \
      "$(effective_model "$BACKEND")" "${AGENT_EFFORT:-}" "$rc" "$ts_start" "$AGENT_USAGE_FILE"
  else
    record_session "$log" "$PROJECT" "task" "$ISSUE" "$round_num" "$BACKEND" \
      "$(effective_model "$BACKEND")" "${AGENT_EFFORT:-}" "$rc" "$ts_start" "$AGENT_USAGE_FILE"
  fi

  echo "___ISSUE_${ISSUE}_${step}_${BACKEND}_EXIT_${rc}___"
  } >>"$log" 2>&1

  [ "$rc" -eq 0 ] && [ "$watchdog_triggered" -eq 0 ] && [ "$progress" -eq 1 ]
}

if [ -n "$TASK_FILE" ]; then
  run_task_step "$TASK_FILE" "$(taskfile_step_of "$TASK_FILE" "$PROJECT" "$ISSUE")"
  exit $([ $? -eq 0 ] && echo 0 || echo 1)
fi

# --chain: every task file for this item, oldest step first.
STEP_FILES="$(taskfile_chain "$LOG_DIR" "$PROJECT" "$ISSUE")"
if [ -z "$STEP_FILES" ]; then
  echo "no task files found under $LOG_DIR/tasks/${PROJECT}-${ISSUE}-*.md" >&2
  exit 2
fi
CHAIN_RC=0
while IFS= read -r step_file; do
  [ -n "$step_file" ] || continue
  run_task_step "$step_file" "$(taskfile_step_of "$step_file" "$PROJECT" "$ISSUE")"
  CHAIN_RC=$?
  if [ "$CHAIN_RC" -ne 0 ]; then
    echo "CHAIN_STOPPED: $step_file did not complete cleanly; worktree left in place for the orchestrator" >&2
    break
  fi
done <<EOF
$STEP_FILES
EOF
exit "$CHAIN_RC"

fi
