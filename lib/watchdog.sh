#!/usr/bin/env bash
# Kill stalled or crashed backend sessions and salvage the partial worktree.
# Sourced by run-issue.sh / run-pr.sh; not meant to be executed directly.
#
# Cursor is the worst offender (it halts on limits and hangs), but any backend
# can wedge, and nothing else here bounds a session's runtime. A wedged session
# holds a concurrency slot and a worktree and produces nothing until a human
# notices, so every backend invocation gets wrapped:
#
#   - a hard wall-clock ceiling (AGENT_TIMEOUT_MIN, per backend default below)
#   - a stall check that kills earlier when the log stops growing AND the
#     worktree stops changing for AGENT_STALL_MIN. A ceiling alone either kills
#     legitimate long runs or waits too long on a real hang; the stall check is
#     what actually catches a hang in minutes rather than at the ceiling.
#
# Real duration data (from one machine's sessions.jsonl,
# 2026-09-22, n=79/27/7) put cursor's p95 at ~30min with three outliers past
# 68min, codex maxing out at 46min, and too few claude samples to trust a tight
# number. So defaults below sit above each backend's observed p95 rather than
# the 15min figure floated in the issue -- 15min would have killed roughly 1
# in 10 real cursor sessions outright. The stall check, not the ceiling, is the
# actual hang-catcher.
#
# Enabled by default for cursor only (the "worst offender"); available for any
# backend via AGENT_WATCHDOG=1, or implicitly once AGENT_TIMEOUT_MIN /
# AGENT_STALL_MIN is set. AGENT_WATCHDOG=0 forces it off even for cursor.

WATCHDOG_POLL_S=30
WATCHDOG_DEFAULT_STALL_MIN=10

watchdog_default_enabled() { # $1=backend -> 1|0
  case "$1" in
    cursor) echo 1 ;;
    *) echo 0 ;;
  esac
}

watchdog_default_ceiling_min() { # $1=backend
  case "$1" in
    cursor) echo 45 ;;
    codex) echo 60 ;;
    claude) echo 90 ;;
    *) echo 60 ;;
  esac
}

# Prints "enabled<TAB>ceiling_s<TAB>stall_s".
watchdog_resolve() { # $1=backend
  local backend="$1" enabled ceiling_min stall_min
  if [ -n "${AGENT_WATCHDOG:-}" ]; then
    enabled="$AGENT_WATCHDOG"
  else
    enabled="$(watchdog_default_enabled "$backend")"
  fi
  # An explicit ceiling or stall override means the caller wants the watchdog
  # on regardless of the backend's default.
  if [ -n "${AGENT_TIMEOUT_MIN:-}" ] || [ -n "${AGENT_STALL_MIN:-}" ]; then
    enabled=1
  fi
  ceiling_min="${AGENT_TIMEOUT_MIN:-$(watchdog_default_ceiling_min "$backend")}"
  stall_min="${AGENT_STALL_MIN:-$WATCHDOG_DEFAULT_STALL_MIN}"
  printf '%s\t%s\t%s\n' "$enabled" "$((ceiling_min * 60))" "$((stall_min * 60))"
}

# A cheap fingerprint of "has this worktree changed": the branch tip plus the
# working-tree status, so both new commits and uncommitted edits count as
# activity. Uses only git, so it behaves the same on every OS this runs on
# (unlike find -printf or GNU-only stat flags).
worktree_signature() { # $1=worktree
  ( cd "$1" 2>/dev/null && { git rev-parse HEAD 2>/dev/null; git status --porcelain 2>/dev/null; } ) 2>/dev/null | cksum
}

# Recursively signal a POSIX process tree, children first. pgrep/kill are both
# present on macOS and Linux; if pgrep is missing this degrades to signaling
# just the one pid, which is still better than nothing.
kill_tree_posix() { # $1=pid $2=signal
  local pid="$1" sig="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree_posix "$child" "$sig"
  done
  kill -s "$sig" "$pid" 2>/dev/null
}

# MSYS bash's own pid (what $! gives you) is NOT the Windows PID taskkill
# needs -- `ps -W` carries both in one row (PID PPID PGID WINPID ...).
# Confirmed by hand: a plain `sleep 60 &` had bash $!=1977 but ps -W's WINPID
# column showed 12380; taskkill //PID 1977 fails with "process not found"
# against the real one.
#
# taskkill's own /T (native Windows parent-child walk) turned out not to
# reach a child spawned via a further `&` inside the backgrounded function --
# MSYS's fork emulation does not always preserve that link as a real Windows
# parent/child pair. So recursion happens at the MSYS layer instead, using
# ps -W's own PPID column (which does reflect what MSYS actually forked),
# translating and killing each node's real WINPID individually rather than
# asking Windows to walk a tree it does not fully see.
_winpid_for() { # $1=msys pid
  ps -W 2>/dev/null | awk -v p="$1" '$1 == p { print $4; exit }'
}

_msys_children_of() { # $1=msys pid (as PPID)
  ps -W 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'
}

kill_tree_windows() { # $1=msys pid
  local pid="$1" child winpid
  for child in $(_msys_children_of "$pid"); do
    kill_tree_windows "$child"
  done
  winpid="$(_winpid_for "$pid")"
  taskkill //PID "${winpid:-$pid}" //F >/dev/null 2>&1
}

# Kill the whole process tree rooted at $1.
kill_process_tree() { # $1=pid $2=os_name
  local pid="$1" os_name="$2"
  case "$os_name" in
    windows)
      kill_tree_windows "$pid"
      ;;
    *)
      kill_tree_posix "$pid" TERM
      sleep 2
      kill_tree_posix "$pid" KILL
      ;;
  esac
}

# Run a backend invocation under the watchdog. $1=os_name $2=backend $3=log
# $4=worktree $5=state_file $6=base_ref (already qualified, e.g. origin/main),
# then the command to run (typically run_codex/run_cursor/run_claude and its
# args). Sets WATCHDOG_TRIGGERED (0|1) and WATCHDOG_REASON for the caller;
# returns the backend's own exit code, or 99 when the watchdog had to kill it.
run_with_watchdog() {
  local os_name="$1" backend="$2" log="$3" worktree="$4" state_file="$5" base_ref="$6"; shift 6
  WATCHDOG_TRIGGERED=0
  WATCHDOG_REASON=""

  local resolved enabled ceiling_s stall_s
  resolved="$(watchdog_resolve "$backend")"
  enabled="$(printf '%s' "$resolved" | cut -f1)"
  ceiling_s="$(printf '%s' "$resolved" | cut -f2)"
  stall_s="$(printf '%s' "$resolved" | cut -f3)"

  if [ "$enabled" != "1" ]; then
    "$@"
    return $?
  fi

  echo "WATCHDOG_ARMED: ceiling=${ceiling_s}s stall=${stall_s}s poll=${WATCHDOG_POLL_S}s"

  "$@" &
  local bg_pid=$!
  local start_ts last_activity_ts last_size last_sig now size sig elapsed stall rc
  start_ts=$(date +%s); last_activity_ts=$start_ts; last_size=0; last_sig=""

  while :; do
    if ! kill -0 "$bg_pid" 2>/dev/null; then
      wait "$bg_pid"; rc=$?
      break
    fi
    sleep "$WATCHDOG_POLL_S"
    now=$(date +%s)
    size=$(wc -c <"$log" 2>/dev/null || echo 0)
    sig="$(worktree_signature "$worktree")"
    if [ "$size" != "$last_size" ] || [ "$sig" != "$last_sig" ]; then
      last_activity_ts=$now
    fi
    last_size="$size"; last_sig="$sig"

    elapsed=$((now - start_ts))
    if [ "$elapsed" -ge "$ceiling_s" ]; then
      WATCHDOG_REASON="ceiling: no completion within ${ceiling_s}s (AGENT_TIMEOUT_MIN)"
    else
      stall=$((now - last_activity_ts))
      if [ "$stall" -ge "$stall_s" ]; then
        WATCHDOG_REASON="stall: no log growth or worktree change for ${stall_s}s (AGENT_STALL_MIN)"
      fi
    fi

    if [ -n "$WATCHDOG_REASON" ]; then
      kill_process_tree "$bg_pid" "$os_name"
      wait "$bg_pid" 2>/dev/null
      rc=99
      WATCHDOG_TRIGGERED=1
      break
    fi
  done

  if [ "$WATCHDOG_TRIGGERED" -eq 1 ]; then
    echo "AGENT_WATCHDOG: killed after $WATCHDOG_REASON"
    # Salvage, not discard: the worktree is left exactly as the kill left it.
    state_record_watchdog "$state_file" "$worktree" "$base_ref" "$WATCHDOG_REASON" "$log"
  fi
  return "$rc"
}
