"""Parse and validate a disposable-session task file (agent-loop#7). Invoked
by lib/taskfile.sh; not meant to be run directly.

  taskfile.py check  <file>   exit 0 valid, 1 invalid, 3 missing
  taskfile.py render <file>   the file's content as the session's prompt body

A task file is the ENTIRE instruction for one disposable session -- not a
supplement to the issue body, a replacement for it. Fixed template (## headers,
any order, case-insensitive):

  ## Goal
  One sentence, one deliverable.

  ## Files in scope
  - path/one
  - path/two

  ## Done when
  A checkable exit condition.

  ## Do not
  Optional: what adjacent steps own.

  ## Context
  Optional: only what this step needs.

Goal, Files in scope and Done when must be non-empty; a file missing any of
them, or with no recognizable section at all, is invalid. "Do not" and
"Context" are optional -- most steps need one or neither.
"""

import os
import re
import sys

REQUIRED = ("goal", "files in scope", "done when")
KNOWN = REQUIRED + ("do not", "context")

SECTION_RE = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)


def sections(text):
    """{lowercased header: body text} for every ## section in the file."""
    matches = list(SECTION_RE.finditer(text))
    out = {}
    for i, match in enumerate(matches):
        name = match.group(1).strip().lower()
        start = match.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        out[name] = text[start:end].strip()
    return out


def problem(text):
    """Why `text` is not a valid task file, or None when it is."""
    found = sections(text)
    if not found:
        return "no '## ' section headers found at all"
    for name in REQUIRED:
        if not found.get(name, "").strip():
            return "missing or empty required section: '## %s'" % name.title()
    return None


def check(path):
    if not os.path.isfile(path):
        print("no task file at %s" % path)
        return 3
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    why = problem(text)
    if why:
        print(why)
        return 1
    print("ok")
    return 0


def render(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    why = problem(text)
    if why:
        print("taskfile.py: refusing to render an invalid task file: %s" % why, file=sys.stderr)
        return 1
    print(text.strip())
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        return check(argv[2])
    if len(argv) == 3 and argv[1] == "render":
        return render(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
