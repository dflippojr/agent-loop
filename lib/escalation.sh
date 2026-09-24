#!/usr/bin/env bash
# Dead-end ledger merging and tier escalation after N failed attempts.
# Sourced by run-issue.sh / run-pr.sh; not meant to be executed directly.
#
# Two things live here:
#
#   - Launcher-observed failures feed the same per-item state file the agent's
#     own errors[].dead_end entries already do (lib/state.sh), so "what has
#     already failed on this item" survives even a session that crashed
#     before writing anything itself. Watchdog kills record themselves
#     (lib/watchdog.sh); a hard failure that was NOT a watchdog kill is
#     recorded here.
#   - After N failed attempts (AGENT_ESCALATE_AFTER, default 2) on the same
#     item at the same tier, suggest moving one tier up the fixed ladder
#     (mechanical -> standard -> frontier) rather than trying the same tier
#     again. Suggesting is the default; AGENT_AUTO_ESCALATE=1 / --auto-escalate
#     lets the launcher actually re-dispatch, still gated by the existing pool
#     check -- escalation never bypasses "the pool cannot afford this".
#
# Requires lib/state.sh already sourced (uses its _state_python/_state_py).

tier_after() { # $1=tier -> the next tier up, or empty at the top / on an unknown tier
  case "$1" in
    mechanical) echo standard ;;
    standard) echo frontier ;;
    *) echo "" ;;
  esac
}

# True (exit 0) when this session's own outcome counts as a failed attempt:
# it actually ran (not a pool refusal) and did not end in a clean
# PUSHED/NO_CHANGE. BLOCKED counts too (see the case comment) even though it
# is not the agent's fault, because a human still needs to see it; only a
# pool refusal is a genuine non-attempt.
attempt_was_failure() { # $1=termination $2=result
  case "$1" in pool-refused) return 1 ;; esac
  case "$2" in PUSHED|NO_CHANGE) return 1 ;; esac
  return 0
}

# Appends a dead-end ledger entry for a hard failure that was not a watchdog
# kill (that path already records itself in lib/watchdog.sh), then checks
# whether this item has now failed AGENT_ESCALATE_AFTER times in a row at the
# given tier. Sets ESCALATE_NEXT_TIER (empty when no escalation is due) for
# the caller to act on. Reads this session's own outcome from
# AGENT_LAST_RESULT / AGENT_LAST_TERMINATION (set by record_session).
#
# $1=script_dir $2=log_dir $3=project $4=kind $5=item $6=tier $7=item_label
# $8=state_file $9=worktree $10=base_ref $11=log
escalation_check() {
  local script_dir="$1" log_dir="$2" project="$3" kind="$4" item="$5" tier="$6"
  local item_label="$7" state_file="$8" worktree="$9" base_ref="${10}" log="${11}"
  ESCALATE_NEXT_TIER=""

  local termination="${AGENT_LAST_TERMINATION:-}" result="${AGENT_LAST_RESULT:-}"
  attempt_was_failure "$termination" "$result" || return 0

  # The watchdog already wrote its own ledger entry for this session; do not
  # double up. A hard failure (non-zero exit, or a clean exit that still
  # reported FAILED) gets one here.
  if [ "$termination" != "watchdog" ]; then
    case "$termination:$result" in
      failed:*|*:FAILED)
        state_record_attempt_failure "$state_file" "$worktree" "$base_ref" \
          "session failed (termination=$termination result=${result:-none})" "$log"
        ;;
    esac
  fi

  [ -n "$tier" ] || return 0  # nothing to escalate to without a tier ladder

  local py n threshold next
  py="$(_state_python)" || return 0
  n="$("$py" "$script_dir/lib/escalation.py" count "$log_dir/sessions.jsonl" \
        "$project" "$kind" "$item" "$tier" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) return 0 ;; esac

  threshold="${AGENT_ESCALATE_AFTER:-2}"
  case "$threshold" in ''|*[!0-9]*) threshold=2 ;; esac
  [ "$n" -ge "$threshold" ] || return 0

  next="$(tier_after "$tier")"
  if [ -z "$next" ]; then
    echo "ESCALATE_EXHAUSTED: $item_label failed $n times at $tier (top tier); needs human attention"
    return 0
  fi
  echo "ESCALATE_SUGGESTED: $item_label failed $n times at $tier; next: $next"
  ESCALATE_NEXT_TIER="$next"
}
