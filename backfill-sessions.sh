#!/usr/bin/env bash
# Reconstruct sessions.jsonl from logs written before per-session accounting
# existed, so cost-per-merged-PR has a baseline to compare against instead of
# starting from zero. Reads only the logs already on disk; launches nothing.
#
# Idempotent: a log already present in sessions.jsonl is skipped, so this can
# be re-run after more history shows up.
#
# Usage: bash backfill-sessions.sh --project <name> [--dry-run]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/os.sh
source "$SCRIPT_DIR/lib/os.sh"
# shellcheck source=lib/backends.sh
source "$SCRIPT_DIR/lib/backends.sh"
# shellcheck source=lib/session.sh
source "$SCRIPT_DIR/lib/session.sh"

PROJECT=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) echo "usage: bash backfill-sessions.sh --project <name> [--dry-run]" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "usage: bash backfill-sessions.sh --project <name> [--dry-run]" >&2; exit 2; }

load_project_config "$SCRIPT_DIR" "$PROJECT" || exit $?

OUT="$LOG_DIR/sessions.jsonl"
already() { # $1=log basename -- already recorded?
  [ -f "$OUT" ] && grep -qF "\"log\":\"$1\"" "$OUT"
}

# The launcher names logs <project>-{issue,pr}-<id>-<YYYYmmdd-HHMMSS>-<backend>-<kind>.log.
# Timestamps come from the name rather than the log's own date line, which
# varies by backend; the end time is the file's last write.
n=0
skipped=0
for f in "$LOG_DIR"/*.log; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  if already "$base"; then skipped=$((skipped + 1)); continue; fi

  stamp="$(printf '%s' "$base" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1)"
  [ -n "$stamp" ] || { echo "skip (no timestamp): $base" >&2; continue; }
  d="${stamp%-*}"; t="${stamp#*-}"
  ts_start="$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null)"
  [ -n "$ts_start" ] || { echo "skip (bad timestamp): $base" >&2; continue; }
  ts_end="$(stat -c%Y "$f" 2>/dev/null)"

  backend="$(printf '%s' "$base" | grep -oE '(cursor|codex|claude)' | head -1)"
  [ -n "$backend" ] || { echo "skip (no backend): $base" >&2; continue; }

  # kind and item id. cifix predates run-pr.sh's fix-ci task; keep its own
  # name so the two aren't silently merged in the numbers.
  case "$base" in
    *-pr-fix-findings.log) kind="pr-fix-findings" ;;
    *-pr-merge-main.log)   kind="pr-merge-main" ;;
    *-pr-fix-ci.log)       kind="pr-fix-ci" ;;
    *-pr-custom.log)       kind="pr-custom" ;;
    *-refine.log)          kind="refine" ;;
    *-cifix.log)           kind="cifix" ;;
    *-build.log)           kind="build" ;;
    *)                     kind="build" ;;   # legacy issue-<N>-<ts>-<backend>.log
  esac
  item="$(printf '%s' "$base" | sed -E 's/^.*-(issue|pr)-([0-9]+)-[0-9]{8}.*/\2/')"
  case "$item" in ''|*[!0-9]*) item="$(printf '%s' "$base" | grep -oE '(issue|pr)-[a-z0-9]+' | head -1 | cut -d- -f2)" ;; esac

  # Effort/model: run-pr.sh records both in its header; run-issue.sh records
  # neither, so fall back to codex's own banner, which states the effort it ran at.
  # Read them off the launcher's own header line only. A bare grep for
  # "model=" matches session text too (cfg.models.get, SessionResponse, ...).
  header="$(grep -m1 -E '^=== agent-loop (pr|build|refine):' "$f" 2>/dev/null)"
  effort="$(printf '%s' "$header" | grep -oE 'effort=[A-Za-z0-9._-]+' | cut -d= -f2)"
  [ -n "$effort" ] || effort="$(grep -m1 -E '^reasoning effort: ' "$f" 2>/dev/null | awk '{print $3}')"
  [ "$effort" = "default" ] && effort=""
  model="$(printf '%s' "$header" | grep -oE 'model=[A-Za-z0-9._-]+' | cut -d= -f2)"
  [ "$model" = "default" ] && model=""
  # Resolve a cursor effort tier back to the model id it actually selected.
  if [ -z "$model" ]; then
    model="$(AGENT_EFFORT="$effort" AGENT_MODEL="" effective_model "$backend")"
  fi

  rc="$(grep -oE '___(ISSUE|PR)_[0-9]+_[a-z]+_(REFINE_)?EXIT_[0-9]+___' "$f" 2>/dev/null | tail -1 | grep -oE '[0-9]+___$' | tr -d '_')"
  [ -n "$rc" ] || rc=""   # no sentinel: the run never finished

  # Review rounds, reconstructed in chronological order per PR.
  round=""
  if [ "$kind" = "pr-fix-findings" ]; then
    round=0
    for g in "$LOG_DIR"/*-pr-"$item"-*-pr-fix-findings.log; do
      [ -f "$g" ] || continue
      [ ! "$g" -nt "$f" ] && round=$((round + 1))
    done
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%-62s %-7s %-16s item=%-5s effort=%-7s model=%s\n' \
      "$base" "$backend" "$kind" "$item" "${effort:-none}" "${model:-default}"
  else
    usage=""; [ -f "$f.usage.json" ] && usage="$f.usage.json"
    record_session "$f" "$PROJECT" "$kind" "$item" "$round" "$backend" \
      "$model" "$effort" "$rc" "$ts_start" "$usage" "$ts_end" >/dev/null
  fi
  n=$((n + 1))
done

echo "backfilled $n sessions into $OUT (skipped $skipped already recorded)"
