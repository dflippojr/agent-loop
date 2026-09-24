#!/usr/bin/env bash
# claude SessionStart(compact) hook: hand the snapshot and the agent-kept state
# file back to the post-compaction session as additionalContext.
# Exits 0 always; a hook must never fail the session.
state="${AGENT_STATE_FILE:-}"
[ -n "$state" ] || exit 0
snap="${state%.json}.compact.md"
here="$(dirname "${BASH_SOURCE[0]}")"
text=""
[ -f "$snap" ] && text="$(cat "$snap")"
for py in python3 python; do
  if "$py" -c "import sys" >/dev/null 2>&1; then
    if [ -f "$state" ]; then
      carried="$("$py" "$here/../state.py" render "$state" 2>/dev/null)" && text="$text"$'\n\n'"$carried"
    fi
    [ -n "${text//[[:space:]]/}" ] || exit 0
    printf '%s' "$text" | "$py" -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": sys.stdin.read()}}))'
    break
  fi
done
exit 0
