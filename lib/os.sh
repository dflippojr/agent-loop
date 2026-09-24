#!/usr/bin/env bash
# OS detection and backend-binary discovery helpers for agent-loop.
# Sourced by run-issue.sh; not meant to be executed directly.

detect_os() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *) echo "unknown" ;;
  esac
}

# Print the resolvable cursor-agent binary path, or fail.
find_cursor_agent() {
  if command -v cursor-agent >/dev/null 2>&1; then
    command -v cursor-agent
    return 0
  fi
  if command -v cursor-agent.cmd >/dev/null 2>&1; then
    command -v cursor-agent.cmd
    return 0
  fi
  # Known Windows install location when the .cmd shim isn't on PATH in this shell.
  local win_path="$HOME/AppData/Local/cursor-agent/cursor-agent.cmd"
  if [ -f "$win_path" ]; then
    echo "$win_path"
    return 0
  fi
  return 1
}

# Windows only: print "node.exe index.js" as two lines (the real binary
# behind cursor-agent.cmd). Its .cmd -> powershell.exe chain re-parses argv
# through cmd.exe's ~8191-character command-line limit, which a long issue
# prompt can exceed; calling node.exe directly skips that hop and gets
# Windows' much higher ~32K CreateProcess argv limit instead.
find_cursor_node_windows() {
  local base="$HOME/AppData/Local/cursor-agent"
  if [ -f "$base/node.exe" ] && [ -f "$base/index.js" ]; then
    printf '%s\n%s\n' "$base/node.exe" "$base/index.js"
    return 0
  fi
  local latest
  latest=$(ls -1 "$base/versions" 2>/dev/null | sort -V | tail -1)
  if [ -n "$latest" ] && [ -f "$base/versions/$latest/node.exe" ]; then
    printf '%s\n%s\n' "$base/versions/$latest/node.exe" "$base/versions/$latest/index.js"
    return 0
  fi
  return 1
}

# Print a python that actually runs (see find_json_tool for why "on PATH" is not enough).
find_python() {
  local candidate
  for candidate in python3 python; do
    if "$candidate" -c "import sys" >/dev/null 2>&1; then echo "$candidate"; return 0; fi
  done
  return 1
}

# Print the JSON extraction tool to use (jq preferred; falls back to python).
find_json_tool() {
  if command -v jq >/dev/null 2>&1; then
    echo "jq"
    return 0
  fi
  # Probe by running it, not just by finding it: on Windows, python3 is
  # usually a Microsoft Store stub that is on PATH and exits 49 when invoked.
  if python3 -c "import sys" >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  if python -c "import sys" >/dev/null 2>&1; then
    echo "python"
    return 0
  fi
  return 1
}
