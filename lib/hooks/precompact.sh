#!/usr/bin/env bash
# claude PreCompact hook: write the deterministic snapshot next to the item's
# state file. Exits 0 always; a hook must never fail the session.
snap="${AGENT_STATE_FILE:-}"
[ -n "$snap" ] || exit 0
snap="${snap%.json}.compact.md"
for py in python3 python; do
  if "$py" -c "import sys" >/dev/null 2>&1; then
    "$py" "$(dirname "${BASH_SOURCE[0]}")/compact_snapshot.py" "$snap" || true
    break
  fi
done
exit 0
