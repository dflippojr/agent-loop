"""Per-item state file: validate it, fill files_modified from git, render it as
a prompt block. Invoked by lib/state.sh; not meant to be run directly.

  state.py check    <file>                     exit 0 valid, 1 invalid, 3 missing
  state.py finalize <file> <worktree> <base>   rewrite files_modified from git
  state.py render   <file>                     prompt block for the next session
  state.py watchdog <file>                     append a watchdog-kill record (info as JSON on stdin)
  state.py attempt-failed <file>                append a hard-failure record (info as JSON on stdin)

The agent owns goal/facts/errors/next_step. files_modified is the launcher's:
an agent asked to list what it changed will list what it meant to change, so it
is always overwritten here from `git diff --name-status <base>...HEAD`.
"""

import json
import os
import subprocess
import sys

CHANGE_WORDS = {
    "A": "added", "M": "modified", "D": "deleted",
    "R": "renamed", "C": "copied", "T": "type changed",
}

# The next session carries this in its prompt for the rest of its run, so a
# state file that has grown is trimmed rather than passed through whole.
MAX_TEXT = 500
MAX_FACTS, MAX_FILES, MAX_ERRORS = 40, 60, 30


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def problem(data):
    """Why `data` is not a valid state file, or None when it is."""
    if not isinstance(data, dict):
        return "top level is not an object"
    if not isinstance(data.get("goal"), str) or not data["goal"].strip():
        return "goal must be a non-empty string"
    if not isinstance(data.get("next_step"), str):
        return "next_step must be a string"
    facts = data.get("facts")
    if not isinstance(facts, list) or not all(isinstance(f, str) for f in facts):
        return "facts must be an array of strings"
    errors = data.get("errors")
    if not isinstance(errors, list):
        return "errors must be an array"
    for i, err in enumerate(errors):
        if not isinstance(err, dict):
            return "errors[%d] is not an object" % i
        if not isinstance(err.get("what"), str) or not err["what"].strip():
            return "errors[%d].what must be a non-empty string" % i
        if not isinstance(err.get("cause"), str):
            return "errors[%d].cause must be a string" % i
        if not isinstance(err.get("dead_end"), bool):
            return "errors[%d].dead_end must be true or false" % i
    return None


def check(path):
    if not os.path.isfile(path):
        print("no state file written")
        return 3
    try:
        data = load(path)
    except ValueError as exc:
        print("not valid JSON: %s" % exc)
        return 1
    why = problem(data)
    if why:
        print(why)
        return 1
    print("ok")
    return 0


def git_changes(worktree, base):
    """[{path, change}] for what this branch changed against `base`, or None
    when git cannot say. Three dots: only this branch's changes, not whatever
    the base has gained since it was cut."""
    proc = subprocess.run(
        ["git", "-C", worktree, "diff", "--name-status", "%s...HEAD" % base],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
    )
    if proc.returncode != 0:
        return None
    changes = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        word = CHANGE_WORDS.get(parts[0][:1], parts[0])
        if len(parts) >= 3:  # rename/copy: status, old, new
            changes.append({"path": parts[2], "change": "%s from %s" % (word, parts[1])})
        else:
            changes.append({"path": parts[1], "change": word})
    return changes


def finalize(path, worktree, base):
    data = load(path)
    changes = git_changes(worktree, base)
    if changes is None:
        # An agent-reported list is worse than none: drop it so nothing
        # downstream mistakes it for git's.
        data.pop("files_modified", None)
        rc = 4
    else:
        data["files_modified"] = changes
        rc = 0
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp, path)
    print(len(changes) if changes is not None else "unknown")
    return rc


def record_launcher_event(path, what, dead_end, next_step_default, info):
    """Append a launcher-observed event (a watchdog kill, a hard failure) to
    the item's dead-end ledger, so the next session or a human sees exactly
    what happened even when the session itself never wrote a state file. This
    is the launcher's half of the ledger; the agent's own errors[].dead_end
    entries are the other half (see state_prompt_rule). Never fails: a bad or
    missing file just starts from a minimal skeleton rather than losing the
    record."""
    data = None
    if os.path.isfile(path):
        try:
            candidate = load(path)
            if not problem(candidate):
                data = candidate
        except ValueError:
            pass
    if data is None:
        data = {"goal": "(unknown -- no session ever wrote a state file for this item)",
                 "facts": [], "errors": [], "next_step": ""}

    parts = ["reason: %s" % info.get("reason", "unknown")]
    for label, key in (("git status", "git_status"), ("diff --stat", "git_diff_stat"),
                        ("unpushed commits", "unpushed"), ("log tail", "log_tail")):
        value = (info.get(key) or "").strip()
        if value:
            parts.append("%s:\n%s" % (label, value))
    data["errors"].append({"what": what, "cause": clip("\n".join(parts)), "dead_end": dead_end})
    if not data.get("next_step", "").strip():
        data["next_step"] = next_step_default

    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp, path)
    return 0


def watchdog(path, info):
    return record_launcher_event(
        path, "session killed by watchdog", False,
        "resume this item: a watchdog-killed session left partial or uncommitted work; "
        "check files_modified and the watchdog error entry above before redoing anything",
        info)


def attempt_failed(path, info):
    # dead_end=True: a repeat at the same tier and backend, unchanged, would
    # most likely just fail the same way. A stronger tier is a different
    # approach, so this does not block escalation -- only an identical retry.
    return record_launcher_event(
        path, "session failed", True,
        "resume this item at a stronger tier or with a different approach; check "
        "files_modified and the failure entry above before retrying anything unchanged",
        info)


def clip(text):
    text = " ".join(str(text).split())
    return text if len(text) <= MAX_TEXT else text[: MAX_TEXT - 3] + "..."


def bullets(items, limit):
    out = ["- %s" % item for item in items[:limit]]
    if len(items) > limit:
        out.append("- (%d more not shown)" % (len(items) - limit))
    return out


def render(path):
    data = load(path)
    lines = [
        "## Carried-over state from earlier sessions on this item",
        "Earlier sessions recorded this. Start from it instead of rediscovering it, and "
        "verify anything you are about to rely on: it may be out of date.",
        "",
        "Goal: %s" % clip(data["goal"]),
    ]
    facts = [clip(f) for f in data["facts"]]
    if facts:
        lines += ["", "Known facts:"] + bullets(facts, MAX_FACTS)
    files = ["%s (%s)" % (f.get("path", "?"), f.get("change", "?"))
             for f in data.get("files_modified") or [] if isinstance(f, dict)]
    if files:
        lines += ["", "Files changed on this branch so far (from git):"] + bullets(files, MAX_FILES)
    errors = ["%s -- cause: %s" % (clip(e["what"]), clip(e["cause"]) or "unknown")
              for e in data["errors"] if not e["dead_end"]]
    if errors:
        lines += ["", "Errors hit along the way:"] + bullets(errors, MAX_ERRORS)
    if data["next_step"].strip():
        lines += ["", "Next step: %s" % clip(data["next_step"])]
    dead = ["%s -- cause: %s" % (clip(e["what"]), clip(e["cause"]) or "unknown")
            for e in data["errors"] if e["dead_end"]]
    if dead:
        lines += ["", "### Dead ends: do not retry these",
                  "Each of these was tried and failed. Do not repeat them; if you think one "
                  "was abandoned wrongly, say why in your final message before trying it again."]
        lines += bullets(dead, MAX_ERRORS)
    print("\n".join(lines))
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "check":
            return check(argv[2])
        if len(argv) == 5 and argv[1] == "finalize":
            return finalize(argv[2], argv[3], argv[4])
        if len(argv) == 3 and argv[1] == "render":
            return render(argv[2])
        if len(argv) == 3 and argv[1] == "watchdog":
            return watchdog(argv[2], json.load(sys.stdin))
        if len(argv) == 3 and argv[1] == "attempt-failed":
            return attempt_failed(argv[2], json.load(sys.stdin))
    except (OSError, ValueError) as exc:
        print("state.py: %s" % exc, file=sys.stderr)
        return 5
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
