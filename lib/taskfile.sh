#!/usr/bin/env bash
# Disposable single-task sessions driven by scoped task files (agent-loop#7).
# Sourced by run-issue.sh; not meant to be executed directly.

# shellcheck source=os.sh
source "$(dirname "${BASH_SOURCE[0]}")/os.sh"

# Prints "ok" and returns 0, or prints the reason and returns 1/3 (see
# lib/taskfile.py). Returns 127 with a message when no python is on PATH --
# unlike the state file (best-effort), a task file IS the session's entire
# instruction, so an unvalidated one must not be allowed to run.
taskfile_check() { # $1=path
  local py
  py="$(find_python)" || { echo "no python on PATH; cannot validate task files"; return 127; }
  "$py" "$(dirname "${BASH_SOURCE[0]}")/taskfile.py" check "$1"
}

# The task file's content, to use as the session's prompt body.
taskfile_render() { # $1=path
  local py
  py="$(find_python)" || return 127
  "$py" "$(dirname "${BASH_SOURCE[0]}")/taskfile.py" render "$1"
}

# The step token from a task file's own name (the launcher's ordering key, not
# something read from its content): <project>-<issue>-<step>.md -> <step>.
taskfile_step_of() { # $1=path $2=project $3=issue
  local base="$(basename "$1")" prefix="$2-$3-"
  base="${base#"$prefix"}"
  base="${base%.md}"
  printf '%s' "$base"
}

# Every task file for this item under <log_dir>/tasks, oldest step first. Step
# tokens sort numerically when they parse as plain integers (the documented
# convention: 01, 02, ...); anything else falls back to a plain string sort so
# a non-numeric token still produces a stable, if arbitrary, order rather than
# an error.
taskfile_chain() { # $1=log_dir $2=project $3=issue
  local dir="$1/tasks" project="$2" issue="$3" f step
  [ -d "$dir" ] || return 0
  local -a files=()
  for f in "$dir/${project}-${issue}-"*.md; do
    [ -f "$f" ] || continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  for f in "${files[@]}"; do
    step="$(taskfile_step_of "$f" "$project" "$issue")"
    case "$step" in
      ''|*[!0-9]*) printf '9999999999\t%s\t%s\n' "$step" "$f" ;;
      *) printf '%010d\t%s\t%s\n' "$step" "$step" "$f" ;;
    esac
  done | sort -k1,1 -k2,2 | cut -f3-
}
