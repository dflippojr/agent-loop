"""Consecutive-failure counting for tier escalation. Invoked by
lib/escalation.sh; not meant to be run directly.

  escalation.py count <sessions.jsonl> <project> <kind> <item> <tier>

Prints one line: "<consecutive_failures>". Walks sessions for this exact
(project, kind, item, tier) in start-time order and counts backwards from the
most recent one, stopping at the first session that was not a failure (a
success resets the streak) or the start of the list. A row counts as a
failure when it actually ran (termination != pool-refused) and did not end in
a clean PUSHED/NO_CHANGE result -- FAILED, BLOCKED, a watchdog kill, and a
crash that never printed a result line all count, since none of them are a
completed, working attempt. Tier is matched exactly: a session run without
--tier (tier "") never contributes to a tier's escalation count, and does not
break another tier's streak either.
"""

import json
import os
import sys

OK_RESULTS = {"PUSHED", "NO_CHANGE"}


def load_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    return rows


def is_failure(row):
    if row.get("termination") == "pool-refused":
        return None  # did not actually run; does not count as an attempt at all
    result = row.get("result") or ""
    return result not in OK_RESULTS


def count(sessions_path, project, kind, item, tier):
    rows = [
        r for r in load_jsonl(sessions_path)
        if r.get("project") == project and r.get("kind") == kind
        and str(r.get("item")) == str(item) and (r.get("tier") or "") == tier
    ]
    rows.sort(key=lambda r: r.get("ts_start") or 0)
    streak = 0
    for row in rows:
        verdict = is_failure(row)
        if verdict is None:
            continue
        streak = streak + 1 if verdict else 0
    return streak


def main(argv):
    if len(argv) == 7 and argv[1] == "count":
        print(count(argv[2], argv[3], argv[4], argv[5], argv[6]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
