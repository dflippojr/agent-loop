#!/usr/bin/env bash
# Per-backend headless invocation. Sourced by run-issue.sh; not meant to be
# executed directly. Each function runs one backend against $1=worktree with
# $2=prompt, streaming its own stdout/stderr (the caller redirects to the log).
#
# Optional reasoning-effort control, read from the environment so the existing
# call signatures stay unchanged:
#   AGENT_EFFORT  low|medium|high|xhigh|max   (unset = backend default)
#   AGENT_MODEL   explicit model id for the backend (overrides the effort map)
# claude -> --effort; codex -> -c model_reasoning_effort=; cursor has no effort
# flag, effort is part of the model id, so it maps to a Grok 4.6 tier (4.7 is opt-in via AGENT_MODEL: token-hungry).

# Prints the cursor model id for the current AGENT_EFFORT/AGENT_MODEL, or
# nothing (cursor's own default) when neither is set.
cursor_model_for_effort() {
  if [ -n "${AGENT_MODEL:-}" ]; then printf '%s' "$AGENT_MODEL"; return 0; fi
  case "${AGENT_EFFORT:-}" in
    low) echo "cursor-grok-4.6-low" ;;
    medium) echo "cursor-grok-4.6-medium" ;;
    high) echo "cursor-grok-4.6-high" ;;
    xhigh|max) echo "cursor-grok-4.6-xhigh" ;;
    "") ;;
    *) echo "unknown AGENT_EFFORT: $AGENT_EFFORT" >&2; return 2 ;;
  esac
}

# The model id a run will actually use, for the session record. Cursor's
# effort tiers ARE model ids, so an --effort-only cursor run is pinned even
# though AGENT_MODEL is empty; an empty result there means a genuinely
# unpinned run whose model cursor picks server-side. For codex and claude an
# empty AGENT_MODEL means that CLI's own configured default, which is a fixed
# account setting rather than a per-session choice.
effective_model() { # $1=backend
  case "$1" in
    cursor) cursor_model_for_effort ;;
    *) printf '%s' "${AGENT_MODEL:-}" ;;
  esac
}

run_codex() {
  local worktree="$1" prompt="$2"
  # --approve-for-me already implies workspace-write sandbox; passing
  # --sandbox alongside it is rejected by the CLI.
  local effort_args=()
  [ -n "${AGENT_MODEL:-}" ] && effort_args+=(-m "$AGENT_MODEL")
  [ -n "${AGENT_EFFORT:-}" ] && effort_args+=(-c "model_reasoning_effort=\"$AGENT_EFFORT\"")
  # -o writes the final message to its own file, so the result sentinel can be
  # read from a two-line file instead of grepping a multi-megabyte log.
  [ -n "${AGENT_USAGE_FILE:-}" ] && effort_args+=(-o "${AGENT_USAGE_FILE}.last")
  codex exec -C "$worktree" --approve-for-me "${effort_args[@]}" "$prompt"
}

# Standing rules for cursor sessions (agent-loop#8). Cursor has no hooks, so the
# only channel it treats as standing instructions is .cursor/rules. The file is
# written into the worktree at launch and excluded from git so it can never land
# in a branch or PR; a killed run may leave it behind, which is harmless because
# it is excluded (git status and the worktree-clean check never see it).
AGENT_LOOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURSOR_RULES_REL=".cursor/rules/agent-loop.mdc"

cursor_rules_install() { # $1=worktree
  local worktree="$1" exclude dest
  dest="$worktree/$CURSOR_RULES_REL"
  exclude="$(git -C "$worktree" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 0
  mkdir -p "$(dirname "$dest")" "$(dirname "$exclude")" || return 0
  cat "$AGENT_LOOP_LIB_DIR/cursor-rules.mdc" >"$dest" || return 0
  if [ -n "${CURSOR_RULES_EXTRA_FILE:-}" ] && [ -f "$CURSOR_RULES_EXTRA_FILE" ]; then
    { echo; cat "$CURSOR_RULES_EXTRA_FILE"; } >>"$dest"
  fi
  grep -qxF "/$CURSOR_RULES_REL" "$exclude" 2>/dev/null || echo "/$CURSOR_RULES_REL" >>"$exclude"
  return 0
}

cursor_rules_remove() { # $1=worktree
  rm -f "$1/$CURSOR_RULES_REL"
  rmdir "$1/.cursor/rules" "$1/.cursor" 2>/dev/null
  return 0
}

run_cursor() {
  local worktree="$1" rc
  cursor_rules_install "$worktree"
  _run_cursor_agent "$@"; rc=$?
  cursor_rules_remove "$worktree"
  return $rc
}

_run_cursor_agent() {
  local worktree="$1" prompt="$2" os_name="$3"
  local sandbox_args=()
  # Cursor's --sandbox mode is macOS/Linux only; Windows runs allowlist mode
  # via --force alone.
  if [ "$os_name" = "macos" ] || [ "$os_name" = "linux" ]; then
    sandbox_args=(--sandbox enabled)
  fi

  local model_args=() cursor_model
  cursor_model=$(cursor_model_for_effort) || return 2
  [ -n "$cursor_model" ] && model_args=(--model "$cursor_model")

  if [ "$os_name" = "windows" ]; then
    local node_pair node_bin index_js
    node_pair=$(find_cursor_node_windows) || { echo "cursor-agent node.exe not found" >&2; return 127; }
    node_bin=$(printf '%s' "$node_pair" | sed -n 1p)
    index_js=$(printf '%s' "$node_pair" | sed -n 2p)
    "$node_bin" "$index_js" -p --output-format text --force "${sandbox_args[@]}" "${model_args[@]}" --workspace "$worktree" "$prompt"
    return $?
  fi

  local bin
  bin=$(find_cursor_agent) || { echo "cursor-agent not found on PATH" >&2; return 127; }
  "$bin" -p --output-format text --force "${sandbox_args[@]}" "${model_args[@]}" --workspace "$worktree" "$prompt"
}

# Per-run settings file wiring the compaction hooks (lib/hooks/). Injected with
# --settings so the target repo's own .claude/settings.json is never edited.
# Prints the file path, or nothing when there is no state file to snapshot to.
claude_hook_settings() {
  [ -n "${AGENT_STATE_FILE:-}" ] || return 0
  local dir out
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/hooks" && pwd)"
  command -v cygpath >/dev/null 2>&1 && dir="$(cygpath -m "$dir")"
  out="$(mktemp "${TMPDIR:-/tmp}/agent-loop-hooks.XXXXXX")" || return 0
  cat >"$out" <<EOF_SETTINGS
{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"bash \"$dir/precompact.sh\""}]}],
"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"bash \"$dir/sessionstart.sh\""}]}]}}
EOF_SETTINGS
  printf '%s' "$out"
}

run_claude() {
  local worktree="$1" prompt="$2"
  # --permission-mode auto mirrors the same auto-mode classifier gating a
  # normal interactive session gets, rather than bypassing checks outright.
  local effort_args=()
  [ -n "${AGENT_MODEL:-}" ] && effort_args+=(--model "$AGENT_MODEL")
  [ -n "${AGENT_EFFORT:-}" ] && effort_args+=(--effort "$AGENT_EFFORT")
  local hook_settings
  hook_settings="$(claude_hook_settings)"
  [ -n "$hook_settings" ] && effort_args+=(--settings "$hook_settings")

  # Without usage capture, keep the plain text stream the log has always had.
  if [ -z "${AGENT_USAGE_FILE:-}" ]; then
    ( cd "$worktree" && claude -p "$prompt" --permission-mode auto --output-format text "${effort_args[@]}" )
    return $?
  fi

  # With it, ask for JSON instead: it carries .usage and .total_cost_usd, the
  # only exact per-session cost any backend here reports. The readable part is
  # still printed to the log afterwards, so the log format is unchanged and
  # anything tailing it for the sentinel keeps working.
  local rc result
  ( cd "$worktree" && claude -p "$prompt" --permission-mode auto --output-format json "${effort_args[@]}" ) >"$AGENT_USAGE_FILE"
  rc=$?
  result="$(claude_result_text "$AGENT_USAGE_FILE")"
  if [ -n "$result" ]; then
    printf '%s\n' "$result"
  else
    # Unparseable (crash, or a schema change): show whatever came back rather
    # than swallowing the session's only output.
    cat "$AGENT_USAGE_FILE" 2>/dev/null
  fi
  return $rc
}
