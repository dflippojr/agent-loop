#!/usr/bin/env bash
# agent-loop: launch one PR work item (address review findings, merge the
# default branch in, fix CI, or a custom task) as a headless, unattended
# coding-agent session in the worktree that owns the PR's branch.
#
# Usage:
#   bash run-pr.sh --project <name> --pr <N> --task <fix-findings|merge-main|fix-ci|custom> \
#        [--backend <codex|cursor|claude>] [--effort <low|medium|high|xhigh|max>] \
#        [--model <id>] [--note "<extra instructions>"] [--prompt-file <file>] \
#        [--max-rounds <N>] [--new-session]
#
# Unlike run-issue.sh this never starts from origin/<default>: it stays on the
# PR's existing branch, merges (never rebases, never force-pushes) and pushes
# that same branch. Like run-issue.sh it never opens/merges a PR or closes an
# issue -- merging is the orchestrator's job.
#
# Review-round cap: each completed `fix-findings` run on a PR is one review round.
# After --max-rounds (default 3, env AGENT_MAX_REVIEW_ROUNDS) the launcher refuses to
# start another one in the same context: it writes a handoff brief and exits 91.
# A fresh session then continues with `--new-session`, which resets the counter and
# gives the agent the brief (or the orchestrator recommends merging with a follow-up
# issue instead). merge-main / fix-ci / custom runs are not rounds.
#
# Effort picks the reasoning level for the session (see lib/backends.sh):
# claude -> --effort, codex -> model_reasoning_effort, cursor -> Grok 4.6 tier.
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
# shellcheck source=lib/escalation.sh
source "$SCRIPT_DIR/lib/escalation.sh"
# shellcheck source=lib/watchdog.sh
source "$SCRIPT_DIR/lib/watchdog.sh"

PROJECT="" PR="" TASK="" BACKEND="cursor" EFFORT="" MODEL="" NOTE="" PROMPT_FILE=""
MAX_ROUNDS="${AGENT_MAX_REVIEW_ROUNDS:-3}" NEW_SESSION=0
# "cursor" above is a default, not a choice, so a --tier may override it. Only
# an explicit --backend outranks the tier.
TIER="" BACKEND_EXPLICIT=0
# Watchdog ceiling/stall minutes; unset means the per-backend default (see
# lib/watchdog.sh). Flags take precedence over an inherited env var.
TIMEOUT_MIN="${AGENT_TIMEOUT_MIN:-}"
STALL_MIN="${AGENT_STALL_MIN:-}"
# Escalation is suggest-only by default (see lib/escalation.sh); this opts
# into the launcher actually re-dispatching at the next tier up.
AUTO_ESCALATE="${AGENT_AUTO_ESCALATE:-0}"

usage() {
  echo "usage: bash run-pr.sh --project <name> --pr <N> --task <fix-findings|merge-main|fix-ci|custom> [--backend <codex|cursor|claude>] [--tier <mechanical|standard|frontier>] [--effort <low|medium|high|xhigh|max>] [--model <id>] [--note <text>] [--prompt-file <file>] [--max-rounds <N>] [--new-session] [--timeout <minutes>] [--stall <minutes>] [--auto-escalate]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --pr) PR="${2:-}"; shift 2 ;;
    --task) TASK="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-}"; BACKEND_EXPLICIT=1; shift 2 ;;
    --effort) EFFORT="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --tier) TIER="${2:-}"; shift 2 ;;
    --note) NOTE="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="${2:-}"; shift 2 ;;
    --new-session) NEW_SESSION=1; shift ;;
    --timeout) TIMEOUT_MIN="${2:-}"; shift 2 ;;
    --stall) STALL_MIN="${2:-}"; shift 2 ;;
    --auto-escalate) AUTO_ESCALATE=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done
case "$TIMEOUT_MIN" in ''|*[!0-9]*) [ -z "$TIMEOUT_MIN" ] || { echo "--timeout must be a number of minutes: $TIMEOUT_MIN" >&2; usage; } ;; esac
case "$STALL_MIN" in ''|*[!0-9]*) [ -z "$STALL_MIN" ] || { echo "--stall must be a number of minutes: $STALL_MIN" >&2; usage; } ;; esac
export AGENT_TIMEOUT_MIN="$TIMEOUT_MIN" AGENT_STALL_MIN="$STALL_MIN" AGENT_AUTO_ESCALATE="$AUTO_ESCALATE"

[ -n "$PROJECT" ] && [ -n "$PR" ] && [ -n "$TASK" ] || usage
case "$BACKEND" in codex|cursor|claude) ;; *) echo "unknown backend: $BACKEND" >&2; exit 2 ;; esac
case "$TASK" in fix-findings|merge-main|fix-ci|custom) ;; *) echo "unknown task: $TASK" >&2; usage ;; esac
case "$EFFORT" in ""|low|medium|high|xhigh|max) ;; *) echo "unknown effort: $EFFORT" >&2; usage ;; esac
if [ "$TASK" = "custom" ] && [ -z "$PROMPT_FILE" ] && [ -z "$NOTE" ]; then
  echo "--task custom needs --prompt-file or --note" >&2; exit 2
fi
[ -z "$PROMPT_FILE" ] || [ -f "$PROMPT_FILE" ] || { echo "no such prompt file: $PROMPT_FILE" >&2; exit 2; }

# See run-issue.sh: the tier fills only what was left open.
TIER_ROUTE=""
if [ -n "$TIER" ]; then
  TIER_LINE="$(resolve_tier "$SCRIPT_DIR" "$TIER")" || exit $?
  [ "$BACKEND_EXPLICIT" -eq 1 ] || BACKEND="$(printf '%s' "$TIER_LINE" | cut -f1)"
  [ -n "$EFFORT" ] || EFFORT="$(printf '%s' "$TIER_LINE" | cut -f2)"
  [ -n "$MODEL" ]  || MODEL="$(printf '%s' "$TIER_LINE" | cut -f3)"
  TIER_ROUTE="$(printf '%s' "$TIER_LINE" | cut -f4)"
  case "$BACKEND" in codex|cursor|claude) ;; *) echo "tier resolved to an unknown backend: $BACKEND" >&2; exit 2 ;; esac
fi
export AGENT_TIER="$TIER"

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?
export AGENT_EFFORT="$EFFORT" AGENT_MODEL="$MODEL"

# Refuse to start on a pool that cannot afford this session. Captured rather
# than printed directly so the first stdout line stays the log path, which is
# what an orchestrator reads.
POOL_VERDICT="$(check_pool "$SCRIPT_DIR" "$BACKEND" "$EFFORT" "$(effective_model "$BACKEND")" 2>&1)"; POOL_RC=$?
if [ "$POOL_RC" -eq 90 ]; then
  echo "$POOL_VERDICT" >&2
  # Recorded so a refusal is countable next to real sessions; report.sh and
  # pool-status.sh leave it out of cost and burn (no session ran).
  AGENT_TERMINATION="pool-refused" record_session "" "$PROJECT" "pr-$TASK" "$PR" "" "$BACKEND" \
    "$(effective_model "$BACKEND")" "$EFFORT" 90 "$(date +%s)" "" >/dev/null
  exit 90
fi

case "$MAX_ROUNDS" in ''|*[!0-9]*) echo "--max-rounds must be a number: $MAX_ROUNDS" >&2; exit 2 ;; esac

# --- review-round cap -------------------------------------------------------
STATE_DIR="$LOG_DIR/pr-state"
mkdir -p "$STATE_DIR"
ROUND_MARKER="$STATE_DIR/${PROJECT}-pr-${PR}.reset"
HANDOFF_BRIEF="$STATE_DIR/${PROJECT}-pr-${PR}-handoff.md"
# Structured per-item state (goal, facts, dead ends, next step; see lib/state.sh).
# Every session on this PR is seeded from it and told to keep it current.
ITEM_STATE="$(state_file_path "$LOG_DIR" "$PROJECT" pr "$PR")"
export AGENT_STATE_FILE="$ITEM_STATE"
mkdir -p "$(dirname "$ITEM_STATE")"

# Completed fix-findings runs (they end with a real PR_<n>_RESULT line; the prompt's
# own template line contains "<PUSHED|" and must not count) newer than the last reset.
count_review_rounds() {
  local n=0 f
  for f in "$LOG_DIR"/${PROJECT}-pr-${PR}-*-pr-fix-findings.log; do
    [ -f "$f" ] || continue
    if [ -f "$ROUND_MARKER" ] && [ ! "$f" -nt "$ROUND_MARKER" ]; then continue; fi
    grep -qE "^PR_${PR}_RESULT: (PUSHED|NO_CHANGE|BLOCKED|FAILED)" "$f" && n=$((n + 1))
  done
  echo "$n"
}

write_handoff_brief() { # $1=rounds
  {
    echo "# Handoff brief: PR #$PR ($PROJECT), $1 review rounds so far"
    echo
    echo "Written $(date '+%Y-%m-%d %H:%M %Z') by run-pr.sh because the review-round cap ($MAX_ROUNDS) was reached."
    echo
    # The goal, facts, dead ends and next step live in the state file and are
    # seeded into the new session from there; the brief links rather than repeats.
    if [ -f "$ITEM_STATE" ]; then
      echo "Structured state (goal, facts, dead ends, next step): $ITEM_STATE"
      echo
    fi
    gh pr view "$PR" --repo "$REPO_SLUG" --json title,headRefName,headRefOid,state,mergeStateStatus       --jq '"PR: \(.title)
Branch: \(.headRefName)  head: \(.headRefOid[0:7])  state: \(.state)/\(.mergeStateStatus)"' 2>/dev/null
    echo
    echo "## Rounds so far (oldest first: log, result line)"
    local f
    for f in "$LOG_DIR"/${PROJECT}-pr-${PR}-*-pr-fix-findings.log; do
      [ -f "$f" ] || continue
      if [ -f "$ROUND_MARKER" ] && [ ! "$f" -nt "$ROUND_MARKER" ]; then continue; fi
      echo "- $(basename "$f")"
      grep -E "^PR_${PR}_RESULT: (PUSHED|NO_CHANGE|BLOCKED|FAILED)" "$f" | tail -1 | cut -c1-300 | sed 's/^/    /'
    done
    echo
    echo "## Newest automated review comments (trimmed)"
    gh api "repos/$REPO_SLUG/issues/$PR/comments"       --jq '[.[]|select(.user.login=="github-actions[bot]" and (.body|test("Quality Gate")|not))]|.[-2:][]|"### \(.created_at)
\(.body[0:2500])
"' 2>/dev/null
    echo
    echo "## Guidance for the new session"
    echo "- Do NOT just patch the newest finding: read the earlier findings above; they usually share one class. Fix the class (single source of truth, closed grammar, one transition function, model-based test)."
    echo "- Or, if only small edge cases remain (no crash, data loss or security), recommend merging with a follow-up issue."
    echo "- Continue with: run-pr.sh --pr $PR --task fix-findings --new-session [--effort high|xhigh]"
  } > "$HANDOFF_BRIEF"
}

ROUNDS_DONE="$(count_review_rounds)"
if [ "$TASK" = "fix-findings" ] && [ "$ROUNDS_DONE" -ge "$MAX_ROUNDS" ] && [ "$NEW_SESSION" -eq 0 ]; then
  write_handoff_brief "$ROUNDS_DONE"
  echo "REVIEW_ROUND_CAP: PR #$PR has had $ROUNDS_DONE completed review rounds (cap $MAX_ROUNDS). Not starting another in the same context." >&2
  echo "Handoff brief: $HANDOFF_BRIEF" >&2
  echo "Next: start a NEW session with --new-session (resets the counter and passes the brief), or merge and track the rest as a follow-up issue." >&2
  exit 91
fi
HANDOFF_TEXT=""
if [ "$NEW_SESSION" -eq 1 ]; then
  [ -f "$HANDOFF_BRIEF" ] || write_handoff_brief "$ROUNDS_DONE"
  HANDOFF_TEXT="$(head -c 7000 "$HANDOFF_BRIEF")"
  touch "$ROUND_MARKER"   # counter restarts: rounds are counted from logs newer than this
fi
# ---------------------------------------------------------------------------

OS_NAME="$(detect_os)"
REPO_NAME="$(basename "$REPO_PATH")"

LOG="$(init_log "$LOG_DIR" "$PROJECT" "$PR" "$BACKEND" "pr-$TASK")"
# init_log names it <project>-issue-<id>-...; make it obviously a PR log.
LOG="${LOG/-issue-/-pr-}"
echo "$LOG"

# Per-session accounting (see record_session in lib/session.sh). ROUNDS_DONE is
# the count before this run, so this session is the round after it.
TS_START=$(date +%s)
export AGENT_USAGE_FILE="${LOG}.usage.json"
THIS_ROUND=""
[ "$TASK" = "fix-findings" ] && THIS_ROUND=$((ROUNDS_DONE + 1))

{
echo "=== agent-loop pr: project=$PROJECT pr=#$PR task=$TASK backend=$BACKEND effort=${EFFORT:-default} model=${MODEL:-default} tier=${TIER:-none}${TIER_ROUTE:+ route=$TIER_ROUTE} os=$OS_NAME ==="
[ -n "$POOL_VERDICT" ] && echo "$POOL_VERDICT"

# Pace this launch against the others in flight (see acquire_slot).
acquire_slot "$LOG_DIR" "$BACKEND" "$MAX_CONCURRENT" "$LAUNCH_STAGGER"
slot_rc=$?
if [ $slot_rc -ne 0 ]; then echo "___PR_${PR}_${BACKEND}_EXIT_${slot_rc}___"; exit $slot_rc; fi
date

PR_JSON=$(gh pr view "$PR" --repo "$REPO_SLUG" --json number,title,headRefName,baseRefName,headRefOid,state) || {
  echo "cannot read PR #$PR"; echo "___PR_${PR}_${BACKEND}_EXIT_95___"; exit 95; }
BRANCH=$(printf '%s' "$PR_JSON" | jq -r '.headRefName')
BASE=$(printf '%s' "$PR_JSON" | jq -r '.baseRefName')
export AGENT_BASE_REF="origin/$BASE"
TITLE=$(printf '%s' "$PR_JSON" | jq -r '.title')
STATE=$(printf '%s' "$PR_JSON" | jq -r '.state')
if [ "$STATE" != "OPEN" ]; then echo "PR #$PR is $STATE, refusing"; echo "___PR_${PR}_${BACKEND}_EXIT_94___"; exit 94; fi
echo "--- PR #$PR: $TITLE ($BRANCH -> $BASE) ---"

# Find the worktree that already has the branch checked out (the issue-<N>
# worktrees from run-issue.sh); git forbids a second checkout of one branch.
cd "$REPO_PATH" || exit 98
git fetch origin --prune -q
WORKTREE=$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
  /^worktree /{wt=substr($0,10)} $1=="branch" && $2==b {print wt; exit}')
if [ -n "$WORKTREE" ]; then
  echo "reusing worktree $WORKTREE"
  if ! worktree_is_clean "$WORKTREE"; then
    echo "worktree $WORKTREE has uncommitted changes -- another session may own it; refusing"
    echo "___PR_${PR}_${BACKEND}_EXIT_93___"; exit 93
  fi
else
  WORKTREE="$WORKTREE_BASE/${REPO_NAME}-pr-${PR}"
  mkdir -p "$WORKTREE_BASE"
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE" "$BRANCH" || { echo "___PR_${PR}_${BACKEND}_EXIT_97___"; exit 97; }
  else
    git worktree add -b "$BRANCH" "$WORKTREE" "origin/$BRANCH" || { echo "___PR_${PR}_${BACKEND}_EXIT_97___"; exit 97; }
  fi
  echo "created worktree $WORKTREE"
fi
# Bring the local branch to the remote tip (fast-forward only; never rewrites).
git -C "$WORKTREE" merge --ff-only "origin/$BRANCH" || {
  echo "local $BRANCH has diverged from origin/$BRANCH; refusing to touch it"
  echo "___PR_${PR}_${BACKEND}_EXIT_92___"; exit 92; }
HEAD_BEFORE=$(git -C "$WORKTREE" rev-parse --short HEAD)
echo "branch tip before: $HEAD_BEFORE"

STATUS_LINE=""
if [ -n "$STATUS_FILE" ]; then
  STATUS_LINE="- When you finish or stop for any reason, append a short dated entry to $STATUS_FILE (branch, what you changed, test results). Append only; never delete or rewrite other agents' entries."
fi
EXTRA_RULES=""
if [ -n "$STANDING_RULES_FILE" ] && [ -f "$STANDING_RULES_FILE" ]; then EXTRA_RULES="$(cat "$STANDING_RULES_FILE")"; fi

# A new session starts from standing rules + the state file + the task, not the
# earlier transcript. With --new-session it also gets the handoff brief, which
# carries what the state file does not (PR state, round results, review comments).
STATE_MTIME_BEFORE="$(state_mtime "$ITEM_STATE")"
STATE_RULE="$(state_prompt_rule "$ITEM_STATE")"
SEED_BLOCK=""
export AGENT_STATE_SEEDED=0
if SEED_TEXT="$(state_seed_block "$ITEM_STATE")"; then
  SEED_BLOCK=$'\n'"$SEED_TEXT"$'\n'
  AGENT_STATE_SEEDED=1
  echo "STATE_SEEDED: $ITEM_STATE"
fi
[ -z "$HANDOFF_TEXT" ] || SEED_BLOCK="$SEED_BLOCK"$'\n'"$HANDOFF_TEXT"$'\n'

case "$TASK" in
  fix-findings) TASK_BODY=$(cat <<'T'
## Your task: address the automated code-review findings on this PR

1. Read every review comment on the PR: `gh api repos/__SLUG__/issues/__PR__/comments --jq '.[] | "--- \(.user.login) \(.created_at)\n\(.body)"'` (also `gh pr view __PR__ --repo __SLUG__ --comments`). The review bot posts findings as `file:line` bullets with a failure scenario. Later comments may repeat or supersede earlier ones.
2. For each finding, reproduce it against the CURRENT branch tip first (a focused failing test is best). Findings can be stale (already fixed by a later commit) or wrong -- if so, do not change code for it; record why in your STATUS entry.
3. Fix each real finding at its root cause with a regression test that fails before and passes after. Do not weaken or delete existing tests, and do not do drive-by refactors.
4. If fixing a finding needs a product/design decision you cannot make, stop on that one, leave it unfixed, and say exactly what decision is needed. Finish the others.
T
);;
  merge-main) TASK_BODY=$(cat <<'T'
## Your task: bring this PR up to date with origin/__BASE__

Run `git fetch origin` then `git merge origin/__BASE__` (merge, NEVER rebase or force-push). Resolve conflicts keeping BOTH sides' intent: read `git log origin/__BASE__ ^HEAD --oneline` and the conflicting hunks first, do not resolve by picking one side wholesale, and do not drop tests from either side. Recurring conflict patterns in this repo: `harness/db.py` schema migrations (both sides added migration N -- renumber sequentially, keep both), `docs/*-api.md` changelog/version lines (keep both entries, bump versions sequentially), `harness/config.py` / `harness/doctor.py` (keep both additions), `harness/web/app.js`. Keep `.github/workflows/*` exactly as on origin/__BASE__ unless this PR is about workflows. Commit the merge.
T
);;
  fix-ci) TASK_BODY=$(cat <<'T'
## Your task: make this PR's failing CI green

Inspect the latest runs: `gh run list --repo __SLUG__ --branch __BRANCH__ --limit 6` then `gh run view <id> --log-failed`. Distinguish real failures on this branch from flakes (rerun locally 3x before calling a test flaky, and report the flake instead of masking it with a skip/retry) and from infra artifacts (Sonar gate shared-project noise -- do not weaken the gate or edit sonar config unless this PR is about it). Fix real failures at the root cause.
T
);;
  custom) TASK_BODY="## Your task"$'\n';;
esac
TASK_BODY="${TASK_BODY//__SLUG__/$REPO_SLUG}"; TASK_BODY="${TASK_BODY//__PR__/$PR}"
TASK_BODY="${TASK_BODY//__BASE__/$BASE}"; TASK_BODY="${TASK_BODY//__BRANCH__/$BRANCH}"
[ -z "$PROMPT_FILE" ] || TASK_BODY="$TASK_BODY"$'\n'"$(cat "$PROMPT_FILE")"
[ -z "$NOTE" ] || TASK_BODY="$TASK_BODY"$'\n\n'"Orchestrator notes for this item:"$'\n'"$NOTE"

PROMPT=$(cat <<PROMPTEOF
You are working autonomously and unattended on GitHub PR #$PR in $REPO_SLUG: "$TITLE" (branch $BRANCH -> $BASE).

$TASK_BODY
$SEED_BLOCK
Mandatory standing rules (apply every step, do not wait to be told):
- Work only inside this worktree: $WORKTREE (already on branch $BRANCH at the remote tip). Stay on that branch; do not create another. Do not touch $REPO_PATH directly.
- Re-check live PR state yourself first (\`gh pr view $PR --repo $REPO_SLUG --json state,headRefOid,mergeStateStatus,statusCheckRollup\`) -- this prompt is a snapshot.
- Commit after every discrete step; do not let real work sit uncommitted.
- Keep tool output small. Everything a command prints becomes context you carry for the rest of the session, so an unbounded command costs you on every turn that follows, not just the one that ran it. Scope and cap searches (\`rg -n --max-count 5 <pattern> <path>\`), read the region of a file you need (\`sed -n '120,200p' <file>\`) rather than the whole file, and pipe anything that can run long through \`head\`. Single unbounded searches and whole-file reads in this repo have returned 8,000-14,000 lines. When reading review comments or CI logs, read the newest first and stop once you have what you need.
- Iterate with focused tests (\`python -m pytest tests/test_<area>.py -q\`), not the whole suite. Run the full suite once, before you push -- that requirement stands below and CI runs it again on the branch -- but do not re-run it to check an intermediate step.
- Run the full test suite (\`python -m pytest tests -q\`; if imports are missing, \`python -m pip install -r requirements.txt\` first) before considering anything done, and report pass/fail counts. A red suite is not done; if a failure predates your work, prove it on origin/$BASE and say so.
- Push $BRANCH to origin when finished or at a clean checkpoint. Plain \`git push\` only -- never force-push, never rebase pushed history.
- Do NOT merge the PR, do NOT merge into $BASE, do NOT close the PR or any issue, do NOT open new PRs, do NOT post PR comments or reviews (the orchestrator does that), and do NOT edit .github/workflows unless the task above says so.
- Stop cleanly at 95% of your own weekly/session usage if you can read it; do not push toward 99%+. Never use computer-use/UI automation on your own provider's account/usage UI.
- If you discover the work is blocked on something not on origin/$BASE yet, or needs a decision only the owner can make, stop that part and say so plainly.
$STATUS_LINE
$STATE_RULE
$EXTRA_RULES
- End your final message with exactly one line of this form (no other text on that line):
PR_${PR}_RESULT: <PUSHED|NO_CHANGE|BLOCKED|FAILED> branch=$BRANCH head=<short-sha> tests=<short-summary> open=<none|short description of anything left unresolved>
PROMPTEOF
)

case "$BACKEND" in
  codex) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$BASE" \
           run_codex "$WORKTREE" "$PROMPT"; RC=$? ;;
  cursor) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$BASE" \
           run_cursor "$WORKTREE" "$PROMPT" "$OS_NAME"; RC=$? ;;
  claude) run_with_watchdog "$OS_NAME" "$BACKEND" "$LOG" "$WORKTREE" "$ITEM_STATE" "origin/$BASE" \
           run_claude "$WORKTREE" "$PROMPT"; RC=$? ;;
esac

echo "branch tip before: $HEAD_BEFORE  after: $(git -C "$WORKTREE" rev-parse --short HEAD)  pushed-tip: $(git -C "$REPO_PATH" ls-remote origin "refs/heads/$BRANCH" | cut -c1-7)"

# Validate the state file the session was asked to keep, and fill files_modified
# from git rather than from the agent. Logged, never fatal.
state_finalize "$ITEM_STATE" "$WORKTREE" "origin/$BASE" "$STATE_MTIME_BEFORE"

if [ "${WATCHDOG_TRIGGERED:-0}" -eq 1 ]; then
  AGENT_TERMINATION="watchdog" record_session "$LOG" "$PROJECT" "pr-$TASK" "$PR" "$THIS_ROUND" "$BACKEND" \
    "$(effective_model "$BACKEND")" "$EFFORT" "$RC" "$TS_START" "$AGENT_USAGE_FILE"
else
  record_session "$LOG" "$PROJECT" "pr-$TASK" "$PR" "$THIS_ROUND" "$BACKEND" \
    "$(effective_model "$BACKEND")" "$EFFORT" "$RC" "$TS_START" "$AGENT_USAGE_FILE"
fi

# Merge this session's outcome into the item's dead-end ledger and check
# whether it has now failed enough times at this tier to suggest (or, with
# --auto-escalate, perform) moving up a tier. See lib/escalation.sh.
escalation_check "$SCRIPT_DIR" "$LOG_DIR" "$PROJECT" "pr-$TASK" "$PR" "$TIER" "pr-$PR" \
  "$ITEM_STATE" "$WORKTREE" "origin/$BASE" "$LOG"

echo "___PR_${PR}_${BACKEND}_EXIT_${RC}___"
} >>"$LOG" 2>&1

if [ -n "${ESCALATE_NEXT_TIER:-}" ] && [ "$AUTO_ESCALATE" = "1" ]; then
  echo "AUTO_ESCALATE: re-dispatching PR #$PR ($TASK) at tier $ESCALATE_NEXT_TIER" >&2
  EXTRA_ARGS=()
  [ "$TASK" = "fix-findings" ] && EXTRA_ARGS+=(--new-session)
  [ -z "$NOTE" ] || EXTRA_ARGS+=(--note "$NOTE")
  [ -z "$PROMPT_FILE" ] || EXTRA_ARGS+=(--prompt-file "$PROMPT_FILE")
  exec bash "$0" --project "$PROJECT" --pr "$PR" --task "$TASK" --tier "$ESCALATE_NEXT_TIER" \
    --auto-escalate "${EXTRA_ARGS[@]}"
fi
