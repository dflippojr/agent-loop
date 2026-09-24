#!/usr/bin/env bash
# Shared project-config loading, worktree setup, and issue-fetch helpers for
# agent-loop entrypoints (run-issue.sh, refine-issue.sh). Sourced, not run.

load_project_config() {
  local script_dir="$1" project="$2"
  local config_file="$script_dir/projects/${project}.env"
  [ -f "$config_file" ] || { echo "no project config at $config_file" >&2; return 2; }
  # shellcheck disable=SC1090
  source "$config_file"
  : "${REPO_PATH:?REPO_PATH not set in $config_file}"
  : "${REPO_SLUG:?REPO_SLUG not set in $config_file}"
  : "${DEFAULT_BRANCH:=main}"
  : "${LOG_DIR:=$script_dir/logs}"
  : "${WORKTREE_BASE:=$(dirname "$REPO_PATH")}"
  : "${STATUS_FILE:=}"
  : "${STANDING_RULES_FILE:=}"
: "${CURSOR_RULES_EXTRA_FILE:=}"
  # Launch pacing (see acquire_slot). A project may set these; the environment
  # overrides, so one-off runs can widen or disable the gate without an edit.
  : "${MAX_CONCURRENT:=3}"
  : "${LAUNCH_STAGGER:=40}"
  [ -n "${AGENT_MAX_CONCURRENT:-}" ] && MAX_CONCURRENT="$AGENT_MAX_CONCURRENT"
  [ -n "${AGENT_LAUNCH_STAGGER:-}" ] && LAUNCH_STAGGER="$AGENT_LAUNCH_STAGGER"
  return 0
}

# Prints the log file path on stdout. Caller captures it before redirecting
# the rest of the run into it.
init_log() {
  local log_dir="$1" project="$2" issue="$3" backend="$4" kind="$5"
  mkdir -p "$log_dir"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  echo "$log_dir/${project}-issue-${issue}-${ts}-${backend}-${kind}.log"
}

# Creates the worktree if missing, reuses it otherwise. Echoes progress to
# stdout (caller has already redirected to the log by this point).
setup_worktree() {
  local repo_path="$1" default_branch="$2" worktree="$3"
  cd "$repo_path" || return 98
  git fetch origin "$default_branch"
  mkdir -p "$(dirname "$worktree")"
  if [ ! -d "$worktree" ]; then
    git worktree add "$worktree" "origin/$default_branch" || return 97
  else
    echo "worktree already exists at $worktree, reusing"
  fi
}

fetch_issue_json() { # $1=issue $2=repo_slug
  gh issue view "$1" --repo "$2" --json number,title,body,labels
}

fetch_issue_title() { # $1=json $2=json_tool
  if [ "$2" = "jq" ]; then
    printf '%s' "$1" | jq -r '.title'
  else
    printf '%s' "$1" | "$2" -c "import json,sys;print(json.load(sys.stdin)['title'])"
  fi
}

fetch_issue_body() { # $1=json $2=json_tool
  if [ "$2" = "jq" ]; then
    printf '%s' "$1" | jq -r '.body'
  else
    printf '%s' "$1" | "$2" -c "import json,sys;print(json.load(sys.stdin)['body'])"
  fi
}

fetch_issue_labels() { # $1=json $2=json_tool
  if [ "$2" = "jq" ]; then
    printf '%s' "$1" | jq -r '[.labels[].name] | join(",")'
  else
    printf '%s' "$1" | "$2" -c "import json,sys;print(','.join(l['name'] for l in json.load(sys.stdin)['labels']))"
  fi
}

# True (exit 0) if the worktree has no uncommitted changes.
worktree_is_clean() { # $1=worktree
  local status
  status="$(cd "$1" && git status --porcelain)"
  [ -z "$status" ]
}

# --- per-session usage accounting -------------------------------------------
# Every run appends one JSON object to $LOG_DIR/sessions.jsonl. This exists so
# "what did a merged PR actually cost, and on which pool" is answerable from
# data instead of estimated from wall-clock; without it no routing change can
# be validated. Everything recorded is derived from artifacts the run already
# produces, so accounting costs a few greps and no extra model turns:
#   - tokens: from the backend's own report where it has one (codex prints a
#     "tokens used" line; claude's JSON result carries .usage and a cost). The
#     cursor CLI reports neither at any --output-format, so its token/cost
#     fields stay null and duration+outcome are the proxy.
#   - turns: counted from the log's own tool-invocation markers.
#   - result: preferred from the backend's captured final message (reliable)
#     and only then from a grep of the log, since cursor-agent has been
#     inconsistent about printing the sentinel line at all.
# Fields that are null here are honestly unknown, never zero-by-default.

# Quote an arbitrary short value as a JSON string.
json_str() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  s="${s//\\/\\\\}"   # backslashes first, or the next line's escapes get doubled
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# Emit a bare JSON number, or null when the value isn't one.
json_num() {
  case "${1:-}" in
    ''|*[!0-9.]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Which usage pool a (backend, model) route draws on. An unpinned cursor run
# resolves its model server-side ("auto"), and nothing local records what it
# picked -- so it gets its own value rather than being guessed into a pool.
# Replaced by pools.yaml in the pool-routing change; kept here so the log has
# the field from the first session onward.
pool_for_route() { # $1=backend $2=model
  case "$1" in
    codex) echo "chatgpt-pro" ;;
    claude) echo "claude-pro" ;;
    cursor)
      case "${2:-}" in
        "") echo "cursor-auto" ;;
        *grok*|*composer*) echo "cursor-models" ;;
        *) echo "cursor-other" ;;
      esac ;;
    *) echo "unknown" ;;
  esac
}

# Tool invocations visible in the log. Codex marks each one; cursor's text
# output has no markers, so it reports unknown rather than a misleading 0.
count_turns() { # $1=log $2=backend
  case "$2" in
    codex) grep -cE '^(exec|apply_patch)$' "$1" 2>/dev/null ;;
    *) echo "" ;;
  esac
}

# Total tokens a codex session reported for itself (its own trailing summary).
codex_tokens() { # $1=log
  grep -A1 -h '^tokens used$' "$1" 2>/dev/null | tail -1 | tr -d ' ,' | grep -E '^[0-9]+$' || true
}

# Pull tokens, cost, turns and final text out of claude's JSON result as one
# tab-separated line, so a schema change degrades to empty fields rather than
# breaking the run that just finished.
parse_claude_json() { # $1=usage-file -> tokens \t cost_usd \t turns \t result
  local tool
  [ -s "$1" ] || return 0
  tool=$(find_json_tool) || return 0
  if [ "$tool" = "jq" ]; then
    jq -r '[((.usage.input_tokens//0)+(.usage.output_tokens//0)+(.usage.cache_read_input_tokens//0)+(.usage.cache_creation_input_tokens//0)),(.total_cost_usd//""),(.num_turns//""),(.result//"")]|@tsv' "$1" 2>/dev/null || true
  else
    "$tool" -c '
import json,sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    u = d.get("usage") or {}
    tok = sum(int(u.get(k) or 0) for k in
              ("input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"))
    row = [tok, d.get("total_cost_usd",""), d.get("num_turns",""),
           (d.get("result") or "").replace("\t"," ").replace("\n"," ")]
    print("\t".join(str(x) for x in row))
except Exception:
    pass' "$1" 2>/dev/null || true
  fi
}

# The session's final message, raw. Kept separate from parse_claude_json
# because that one goes through @tsv, which would turn real newlines in the
# message into literal \n in the log.
claude_result_text() { # $1=usage-file
  local tool
  [ -s "$1" ] || return 0
  tool=$(find_json_tool) || return 0
  if [ "$tool" = "jq" ]; then
    jq -r '.result // empty' "$1" 2>/dev/null || true
  else
    "$tool" -c '
import json,sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("result") or "")
except Exception:
    pass' "$1" 2>/dev/null || true
  fi
}

# Session-quality signals (see lib/metrics.py for what each is and where it
# comes from). One tab-separated line: retried_dead_ends, compactions,
# tool_output_chars, tool_output_max_chars. An empty field is unknown, never zero;
# no python at all leaves all four unknown.
session_metrics() { # $1=backend $2=log $3=usage_file $4=ts_start (cursor: WORKTREE is read from the caller)
  local py
  py="$(find_python)" || { printf '%b' '\t\t\t\n'; return 0; }
  "$py" "$(dirname "${BASH_SOURCE[0]}")/metrics.py" "$1" "$2" "${3:-}" "${WORKTREE:-}" "${4:-}" 2>/dev/null \
    || printf '%b' '\t\t\t\n'
}

# Append one session record. Call once per run, after the backend returns.
# Positional so the entrypoints stay readable at the call site:
#   $1 log  $2 project  $3 kind  $4 item  $5 round  $6 backend
#   $7 model  $8 effort  $9 exit_code  $10 ts_start(epoch)  $11 usage_file
#   $12 ts_end(epoch), only for backfilling finished runs; live runs end now.
record_session() {
  local log="$1" project="$2" kind="$3" item="$4" round="$5" backend="$6"
  local model="$7" effort="$8" rc="$9" ts_start="${10}" usage_file="${11:-}"
  local out="${LOG_DIR}/sessions.jsonl"

  local ts_end duration tokens cost turns result pool line metrics termination
  ts_end="${12:-$(date +%s)}"
  duration=$((ts_end - ts_start))
  pool=$(pool_for_route "$backend" "$model")
  turns=$(count_turns "$log" "$backend")
  metrics=$(session_metrics "$backend" "$log" "$usage_file" "$ts_start")

  # How the session ended, as a process: a clean exit is "completed" whatever
  # the agent reported (its own verdict is in "result"); a non-zero or missing
  # exit code is "failed". A launcher that refused or killed the session says so
  # through AGENT_TERMINATION (pool-refused, watchdog) instead.
  termination="${AGENT_TERMINATION:-}"
  if [ -z "$termination" ]; then
    if [ "$rc" = "0" ]; then termination="completed"; else termination="failed"; fi
  fi

  case "$backend" in
    codex) tokens=$(codex_tokens "$log") ;;
    claude)
      line=$(parse_claude_json "$usage_file")
      tokens=$(printf '%s' "$line" | cut -f1)
      cost=$(printf '%s' "$line" | cut -f2)
      turns=$(printf '%s' "$line" | cut -f3)
      ;;
  esac

  # The self-reported outcome, preferred from the backend's captured final
  # message over a grep of the whole log: cursor-agent has been inconsistent
  # about printing the sentinel, and a session that repeats the line (seen on
  # #99) leaves two copies behind. The prompt itself shows the sentinel's
  # template, so match only a real verdict, never the template's "<PUSHED|".
  # TASK's id token is "<issue>_<step>" (two numbers, e.g. TASK_42_01_RESULT:),
  # so the id class is wider than a plain [0-9]+ to still match it in one shot.
  local verdicts='(PUSHED|NO_CHANGE|NO_PROGRESS|BLOCKED|FAILED|READY|NEEDS_REFINEMENT)'
  local sentinel=""
  if [ -n "$usage_file" ] && [ -s "${usage_file}.last" ]; then
    sentinel=$(grep -hoE "^(PR|ISSUE|TASK)_[0-9A-Za-z_-]+_(REFINE_)?RESULT: $verdicts" "${usage_file}.last" | tail -1)
  fi
  if [ -z "$sentinel" ]; then
    sentinel=$(grep -hoE "^(PR|ISSUE|TASK)_[0-9A-Za-z_-]+_(REFINE_)?RESULT: $verdicts" "$log" 2>/dev/null | tail -1)
  fi
  result=$(printf '%s' "$sentinel" | awk '{print $2}')

  mkdir -p "$LOG_DIR"
  {
    printf '{"ts_start":%s,"ts_end":%s,"duration_s":%s' "$ts_start" "$ts_end" "$duration"
    printf ',"project":%s,"kind":%s,"item":%s,"round":%s' \
      "$(json_str "$project")" "$(json_str "$kind")" "$(json_str "$item")" "$(json_num "$round")"
    printf ',"backend":%s,"model":%s,"effort":%s,"pool":%s,"tier":%s' \
      "$(json_str "$backend")" "$(json_str "${model:-default}")" "$(json_str "${effort:-default}")" "$(json_str "$pool")" "$(json_str "${AGENT_TIER:-}")"
    printf ',"turns":%s,"tokens":%s,"cost_usd":%s' \
      "$(json_num "${turns:-}")" "$(json_num "${tokens:-}")" "$(json_num "${cost:-}")"
    # Whether this session started from a carried-over state file, and what the
    # post-run check found. null for runs that have no state file (refine, verify).
    local seeded="null" state="null"
    case "${AGENT_STATE_SEEDED:-}" in 1) seeded="true" ;; 0) seeded="false" ;; esac
    [ -z "${AGENT_STATE_STATUS:-}" ] || state="$(json_str "$AGENT_STATE_STATUS")"
    printf ',"state_seeded":%s,"state":%s' "$seeded" "$state"
    printf ',"termination":%s,"retried_dead_ends":%s,"compactions":%s' \
      "$(json_str "$termination")" "$(json_num "$(printf '%s' "$metrics" | cut -f1)")" "$(json_num "$(printf '%s' "$metrics" | cut -f2)")"
    printf ',"tool_output_chars":%s,"tool_output_max_chars":%s' \
      "$(json_num "$(printf '%s' "$metrics" | cut -f3)")" "$(json_num "$(printf '%s' "$metrics" | cut -f4)")"
    printf ',"result":%s,"exit_code":%s,"log":%s}\n' \
      "$(json_str "${result:-}")" "$(json_num "$rc")" "$(json_str "$(basename "$log")")"
  } >>"$out"
  echo "SESSION_RECORDED: $out"

  # Exposed for the caller's escalation check (lib/escalation.sh), which needs
  # this session's own outcome without re-deriving it from the log a second time.
  AGENT_LAST_RESULT="${result:-}"
  AGENT_LAST_TERMINATION="$termination"
}

# --- pool pre-flight --------------------------------------------------------
# Refuse to start a session on a pool that cannot afford one. The hard rule is
# plan-included usage only: when a pool is spent the work waits for its reset,
# it does not fail over to anything paid. There is no override flag on purpose
# -- a wrong refusal is fixed by re-reading the dashboard and updating
# pools.yaml, which is also how the numbers stay honest.
#
# Silently proceeds when pools.yaml or python is absent, so the launcher still
# works in a checkout that has not configured pools.
check_pool() { # $1=script_dir $2=backend $3=effort $4=model -> 0 proceed, 90 refuse
  local script_dir="$1" backend="$2" effort="${3:-}" model="${4:-}"
  local config="$script_dir/pools.yaml"
  [ -f "$config" ] || return 0
  local py=""
  for candidate in python3 python; do
    "$candidate" -c "import sys" >/dev/null 2>&1 && { py="$candidate"; break; }
  done
  [ -n "$py" ] || return 0
  "$py" "$script_dir/lib/pool_status.py" --check "$config" "$backend" "$effort" "$model"
}

# --- launch concurrency -----------------------------------------------------
# Two failure modes show up in the logs when launches are not spaced out:
# cursor-agent races on its own .cursor/cli-config.json when several start at
# once (EPERM on rename), and a burst trips the provider's own rate limiter
# (RetriableError: resource_exhausted). Four fix-findings sessions launched in
# the same second on 2026-09-18 all died without touching their branches.
#
# This was written down as advice in a handoff document, which is not where a
# rule belongs when the thing breaking it is an unattended launcher at 2am.
#
# Slots are tracked as files named for the launcher's pid, so a crashed run
# frees its slot without any cleanup step: a slot whose pid is gone, or that is
# implausibly old, is pruned by the next launcher through here.
# MAX_CONCURRENT=0 disables the gate entirely.
SLOT_MAX_AGE_S=21600   # 6h: longer than any real session, short enough to self-heal
SLOT_WAIT_LIMIT_S=600  # give up waiting after 10 minutes rather than hang forever

acquire_slot() { # $1=log_dir $2=backend $3=max $4=stagger_s -> 0 ok, 89 gave up
  local dir="$1/run-state" backend="$2" max="$3" stagger="$4"
  case "$max" in ''|*[!0-9]*) return 0 ;; esac
  [ "$max" -gt 0 ] || return 0
  mkdir -p "$dir"

  local me="$dir/slot-$$.$backend"
  local waited=0 now
  while :; do
    local live=0 f pid age
    now=$(date +%s)
    for f in "$dir"/slot-*; do
      [ -f "$f" ] || continue
      pid="${f##*/slot-}"; pid="${pid%%.*}"
      age=$(( now - $(stat -c%Y "$f" 2>/dev/null || echo "$now") ))
      if kill -0 "$pid" 2>/dev/null && [ "$age" -lt "$SLOT_MAX_AGE_S" ]; then
        live=$((live + 1))
      else
        rm -f "$f"
      fi
    done
    [ "$live" -lt "$max" ] && break
    if [ "$waited" -ge "$SLOT_WAIT_LIMIT_S" ]; then
      echo "CONCURRENCY_TIMEOUT: $live launches still running (cap $max) after ${waited}s; not starting."
      return 89
    fi
    [ "$waited" -eq 0 ] && echo "waiting for a launch slot: $live of $max in use"
    sleep 10
    waited=$((waited + 10))
  done

  touch "$me"
  # Release on any exit path, so a failure does not leak a slot.
  trap 'rm -f "'"$me"'"' EXIT

  # Space this launch from the previous one on the same backend.
  local stamp="$dir/last-launch.$backend" last delta
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    delta=$(( $(date +%s) - last ))
    if [ "$delta" -lt "$stagger" ]; then
      echo "staggering launch: ${delta}s since the last $backend launch, waiting $(( stagger - delta ))s"
      sleep $(( stagger - delta ))
    fi
  fi
  date +%s > "$stamp"
  return 0
}

# Resolve a task tier to a concrete route (see route_for_tier in
# lib/pool_status.py). Prints "backend<TAB>effort<TAB>model<TAB>name<TAB>pool"
# and returns 0, or returns 90 when nothing in the tier is affordable. Applies
# nothing itself, so the caller can fill only what the user left open.
resolve_tier() { # $1=script_dir $2=tier
  local script_dir="$1" tier="$2"
  local config="$script_dir/pools.yaml"
  [ -f "$config" ] || { echo "--tier needs a pools.yaml at $config" >&2; return 2; }
  local py=""
  for candidate in python3 python; do
    "$candidate" -c "import sys" >/dev/null 2>&1 && { py="$candidate"; break; }
  done
  [ -n "$py" ] || { echo "--tier needs python3 or python on PATH" >&2; return 96; }
  "$py" "$script_dir/lib/pool_status.py" --route "$config" "$tier"
}
