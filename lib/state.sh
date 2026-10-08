#!/usr/bin/env bash
# Per-item state file carried across sessions. Sourced, not run.
#
# A launcher cannot see or rewrite a hosted CLI's context, but it does choose
# what the next session for the same item starts with. This gives each work item
# a small structured file (goal, facts, errors with dead ends, next step) that the
# session is told to maintain, the launcher checks afterwards, and the next
# session is seeded from instead of a transcript. Schema and rules live in
# lib/state.py; every failure here is logged, never fatal to the run.
#
# Outcome of the last state_finalize is left in AGENT_STATE_STATUS
# (valid | stale | invalid | missing | unchecked) for record_session.

# shellcheck source=os.sh
source "$(dirname "${BASH_SOURCE[0]}")/os.sh"

# <LOG_DIR>/state/<project>-<issue|pr>-<N>.json
state_file_path() { # $1=log_dir $2=project $3=issue|pr $4=number
  echo "$1/state/${2}-${3}-${4}.json"
}

# Run lib/state.py. Silent no-op (status 127) when python is missing.
_state_py() { # $@=state.py args
  local py
  py="$(find_python)" || return 127
  "$py" "$(dirname "${BASH_SOURCE[0]}")/state.py" "$@"
}

# Prompt block for the session's rules list, telling it to maintain the file.
state_prompt_rule() { # $1=state file
  cat <<EOF
- Maintain this item's state file at $1 (it is outside the worktree; writing it is the one exception to working only inside the worktree). It is how the next session on this item avoids redoing your work and retrying your dead ends, so keep it current as you go and make sure it is final before you exit, including when you stop early or blocked. Write valid JSON with exactly these keys: "goal" (one sentence), "facts" (array of short strings: what you learned that a fresh session would otherwise have to rediscover), "errors" (array of {"what": string, "cause": string, "dead_end": boolean}; dead_end is true for an approach that failed and must not be retried), "next_step" (the single next action, or "done"). Do not write a "files_modified" key; the launcher fills that in from git. Keep entries to a sentence each. If a carried-over state is shown above, update it rather than starting over: keep every fact that is still true and every dead end.
EOF
}

# Seed block for the next session, from an existing state file. Prints nothing
# and returns 1 when there is no usable file, so the caller starts unseeded.
state_seed_block() { # $1=state file
  [ -f "$1" ] || return 1
  if ! _state_py check "$1" >/dev/null 2>&1; then
    echo "STATE_INVALID: not seeding from $1 (fails the schema)" >&2
    return 1
  fi
  _state_py render "$1"
}

state_mtime() { # $1=state file -> epoch seconds, or empty when missing
  [ -f "$1" ] && stat -c%Y "$1" 2>/dev/null
  return 0
}

# Check the file after the run, fill files_modified from git, log the verdict.
# Never returns non-zero: a bad state file must not fail a run that worked.
state_finalize() { # $1=state file $2=worktree $3=base ref $4=mtime before the run
  local file="$1" worktree="$2" base="$3" before="${4:-}" why rc n touched=1
  export AGENT_STATE_STATUS="unchecked"
  # Read the mtime first: finalize rewrites the file and would hide "untouched".
  [ -n "$before" ] && [ "$(state_mtime "$file")" = "$before" ] && touched=0
  why="$(_state_py check "$file" 2>&1)"; rc=$?
  case "$rc" in
    0) ;;
    3) AGENT_STATE_STATUS="missing"; echo "STATE_INVALID: no state file at $file"; return 0 ;;
    127) echo "STATE_UNCHECKED: no python on PATH, cannot validate $file"; return 0 ;;
    *) AGENT_STATE_STATUS="invalid"; echo "STATE_INVALID: $why ($file)"; return 0 ;;
  esac
  n="$(_state_py finalize "$file" "$worktree" "$base")" \
    || echo "STATE_FILES_UNKNOWN: git could not diff $base...HEAD in $worktree; files_modified left out"
  if [ "$touched" -eq 1 ]; then
    AGENT_STATE_STATUS="valid"
    echo "STATE_OK: $file files_modified=${n:-unknown}"
  else
    AGENT_STATE_STATUS="stale"
    echo "STATE_STALE: $file is valid but this session did not update it (files_modified=${n:-unknown})"
  fi
  return 0
}

# Shared by state_record_watchdog and state_record_attempt_failure: gather
# what was in flight -- git status, diff --stat, unpushed commits and a log
# tail -- as one JSON object on stdout, for either to pipe into state.py.
_state_gather_event_info() { # $1=worktree $2=base ref $3=reason $4=log
  local worktree="$1" base="$2" reason="$3" log="$4"
  local status diffstat unpushed tail py
  status="$(cd "$worktree" 2>/dev/null && git status --porcelain 2>/dev/null | head -c 2000)"
  diffstat="$(cd "$worktree" 2>/dev/null && git diff --stat 2>/dev/null | head -c 2000)"
  unpushed="$(cd "$worktree" 2>/dev/null && git log --oneline "${base}..HEAD" 2>/dev/null | head -c 1000)"
  tail=""
  [ -f "$log" ] && tail="$(tail -c 4000 "$log" 2>/dev/null)"
  py="$(find_python)" || return 127
  "$py" -c '
import json, sys
print(json.dumps({
    "reason": sys.argv[1], "git_status": sys.argv[2], "git_diff_stat": sys.argv[3],
    "unpushed": sys.argv[4], "log_tail": sys.argv[5],
}))
' "$reason" "$status" "$diffstat" "$unpushed" "$tail"
}

# Called by the watchdog (lib/watchdog.sh) right after it kills a session.
# Leaves the worktree untouched and appends what was in flight to the item's
# error list, so the next session or a human sees it without re-deriving it.
# Starts a minimal state file if none exists yet (the killed session may never
# have written one). Never fatal.
state_record_watchdog() { # $1=state file $2=worktree $3=base ref $4=reason $5=log
  local file="$1"
  local info
  info="$(_state_gather_event_info "$2" "$3" "$4" "$5")" \
    || { echo "STATE_UNCHECKED: no python on PATH, cannot record watchdog kill for $file"; return 0; }
  printf '%s' "$info" | _state_py watchdog "$file" >/dev/null \
    && echo "STATE_WATCHDOG_RECORDED: $file" \
    || echo "STATE_WATCHDOG_RECORD_FAILED: $file"
}

# Called by the escalation check (lib/escalation.sh) after a hard failure that
# was not a watchdog kill (that path already records itself). Same shape as
# state_record_watchdog, marked dead_end=true: a repeat at the same tier and
# backend, unchanged, would most likely just fail again. Never fatal.
state_record_attempt_failure() { # $1=state file $2=worktree $3=base ref $4=reason $5=log
  local file="$1"
  local info
  info="$(_state_gather_event_info "$2" "$3" "$4" "$5")" \
    || { echo "STATE_UNCHECKED: no python on PATH, cannot record failure for $file"; return 0; }
  printf '%s' "$info" | _state_py attempt-failed "$file" >/dev/null \
    && echo "STATE_ATTEMPT_FAILURE_RECORDED: $file" \
    || echo "STATE_ATTEMPT_FAILURE_RECORD_FAILED: $file"
}
