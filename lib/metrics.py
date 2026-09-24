"""Session-quality signals for one finished session, read from what the run
already left behind. Invoked by record_session in lib/session.sh.

  metrics.py <backend> <log> [<usage-file> [<worktree> <ts_start>]]

Prints one tab-separated line:

  retried_dead_ends <TAB> compactions <TAB> tool_output_chars <TAB> tool_output_max_chars

An empty field means the backend gives no way to know, which is not the same as
zero. cursor's -p text output is only a final message, so the log says nothing;
its numbers come from its local chat store (below), and are empty if that store
has no chat for the session.

Where each comes from:
  codex   the log is the full transcript: `exec` blocks with an exit status and
          the command's output. Retries and output volume are read from those.
          Codex does not report compactions, so that field is empty.
  claude  the session transcript in ~/.claude/projects/*/<session_id>.jsonl (the
          id is in the JSON usage file). Retries and output volume come from its
          tool_use/tool_result blocks; a compaction is a system entry with
          subtype "compact_boundary" (checked against a real /compact).
  cursor  ~/.cursor/chats/md5(<worktree>)/<chatId>/store.db, a SQLite file whose
          `blobs` table holds JSON messages with tool-call / tool-result blocks
          (found by workspace, and by a chat created since ts_start). A result
          fails on an "Error"/"Rejected" prefix or a non-zero "Exit code:".
          Compactions are not exposed, so that field is empty. Output volume is
          the result text the agent was handed; a very large shell output is
          written to a file and the result only names it, so this is a floor.

A retried dead end is a call identical to one that already failed (same tool,
same arguments) with no file edit in between. The edit condition matters:
re-running a failing test after fixing the code is the ordinary red-green loop,
not a dead end. Edits are codex `apply patch` entries and claude Edit/Write
calls; a change made through a shell command (sed -i, a script) is invisible
here, so that case can be over-counted. A retry with tweaked arguments is missed.
"""

import glob
import hashlib
import json
import os
import re
import sqlite3
import sys

# Lines that end an `exec` block's output in a codex transcript.
CODEX_MARKERS = {"exec", "codex", "apply patch", "thinking", "user", "tokens used"}
CLAUDE_EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
CODEX_STATUS = re.compile(r"^ (succeeded|failed|exited -?\d+) in [\d.]+m?s:?")
CODEX_CWD_SUFFIX = re.compile(r" in [A-Za-z]:[\\/].*$")


def norm(text):
    return " ".join(str(text).split())


def codex(log):
    calls = []  # (command, failed, output_chars) in order; None marks a file edit
    try:
        with open(log, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().split("\n")
    except OSError:
        return None
    i, n = 0, len(lines)
    while i < n:
        if lines[i] != "exec":
            if lines[i] == "apply patch":
                calls.append(None)
            i += 1
            continue
        i += 1
        head = []
        while i < n and not CODEX_STATUS.match(lines[i]) and lines[i] not in CODEX_MARKERS:
            head.append(lines[i])
            i += 1
        if i >= n or lines[i] in CODEX_MARKERS:
            continue  # an exec with no status: the run was cut off mid-command
        failed = not lines[i].startswith(" succeeded")
        i += 1
        out = 0
        while i < n and lines[i] not in CODEX_MARKERS:
            out += len(lines[i]) + 1
            i += 1
        command = CODEX_CWD_SUFFIX.sub("", norm(" ".join(head)))
        calls.append((command, failed, out))
    return score(calls, compactions=None)


def score(calls, compactions):
    """calls: in issue order, (key, failed, output_chars) or None for a file edit."""
    failed_since_edit, retries, sizes = set(), 0, []
    for call in calls:
        if call is None:
            failed_since_edit.clear()  # the code changed; a re-run is a new attempt
            continue
        key, failed, chars = call
        sizes.append(chars)
        if key in failed_since_edit:
            retries += 1
        if failed:
            failed_since_edit.add(key)
    return (retries, compactions, sum(sizes), max(sizes) if sizes else 0)


def claude_transcript(usage_file):
    try:
        with open(usage_file, encoding="utf-8") as handle:
            session_id = json.load(handle).get("session_id")
    except (OSError, ValueError, AttributeError):
        return None
    if not session_id:
        return None
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    found = glob.glob(os.path.join(root, "projects", "*", "%s.jsonl" % session_id))
    return found[0] if found else None


def block_chars(content):
    if isinstance(content, str):
        return len(content)
    if isinstance(content, list):
        return sum(len(b.get("text", "")) for b in content if isinstance(b, dict))
    return 0


def claude(usage_file):
    path = claude_transcript(usage_file) if usage_file else None
    if not path:
        return None
    pending, calls, compactions = {}, [], 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") == "system" and entry.get("subtype") == "compact_boundary":
                compactions += 1
                continue
            content = (entry.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    pending[block.get("id")] = (
                        block.get("name"), json.dumps(block.get("input"), sort_keys=True))
                elif block.get("type") == "tool_result" and block.get("tool_use_id") in pending:
                    key = pending.pop(block["tool_use_id"])
                    failed = bool(block.get("is_error"))
                    calls.append((key, failed, block_chars(block.get("content"))))
                    if key[0] in CLAUDE_EDIT_TOOLS and not failed:
                        calls.append(None)
    return score(calls, compactions)


def cursor_chat_dirs(worktree):
    """Chat directories cursor-agent created for this workspace: ~/.cursor/chats/
    md5(<cwd as cursor spells it>)/<chatId>/. Cursor writes a Windows path with
    backslashes, so try each spelling a bash caller might hand over."""
    root = os.path.join(os.path.expanduser("~"), ".cursor", "chats")
    path = worktree.strip()
    match = re.match(r"^/([A-Za-z])/(.*)$", path)  # git-bash /c/Users/... form
    if match:
        path = "%s:/%s" % (match.group(1), match.group(2))
    path = path.rstrip("/\\")
    spellings = set()
    for slashes in ("/", "\\"):
        base = path.replace("/", slashes).replace("\\", slashes)
        spellings.update({base, base[:1].upper() + base[1:], base[:1].lower() + base[1:]})
    found = []
    for spelling in spellings:
        digest = hashlib.md5(spelling.encode("utf-8")).hexdigest()
        found.extend(glob.glob(os.path.join(root, digest, "*", "store.db")))
    return found


def cursor_messages(store):
    """A chat's messages in stored order, or [] if the store cannot be read.
    Opened read-only: the file belongs to cursor-agent."""
    uri = "file:%s?mode=ro" % store.replace("\\", "/")
    conn = sqlite3.connect(uri, uri=True)
    try:
        messages = []
        for (data,) in conn.execute("SELECT data FROM blobs ORDER BY rowid"):
            try:
                entry = json.loads(data.decode("utf-8"))
            except (ValueError, AttributeError):
                continue  # binary blobs share the table with the JSON messages
            if isinstance(entry, dict) and isinstance(entry.get("content"), list):
                messages.append(entry)
        return messages
    finally:
        conn.close()


CURSOR_EDIT_TOOLS = {"StrReplace", "Write", "Delete", "EditNotebook", "ApplyPatch"}
CURSOR_EXIT = re.compile(r"^Exit code: (-?\d+)")


def cursor_failed(text):
    if text.startswith(("Error", "Rejected:", "The command did not complete")):
        return True
    match = CURSOR_EXIT.match(text)
    return bool(match) and match.group(1) != "0"


def cursor(worktree, ts_start):
    """Cursor's -p text mode prints only the final message, but the agent keeps
    every tool call and its result in a per-chat SQLite store. The chat is found
    by workspace and by having been created at or after this session started."""
    if not worktree or not ts_start:
        return None
    since_ms = (int(ts_start) - 5) * 1000
    calls = []
    chats = []
    for store in cursor_chat_dirs(worktree):
        try:
            with open(os.path.join(os.path.dirname(store), "meta.json"), encoding="utf-8") as handle:
                created = json.load(handle).get("createdAtMs", 0)
        except (OSError, ValueError):
            continue
        if created >= since_ms:
            chats.append((created, store))
    if not chats:
        return None
    for _, store in sorted(chats):
        messages = cursor_messages(store)
        # Parallel tool calls can store a result ahead of its call, so pair by id
        # over the whole chat rather than by position.
        issued = {}
        for message in messages:
            for block in message["content"]:
                if isinstance(block, dict) and block.get("type") == "tool-call":
                    issued[block.get("toolCallId")] = (
                        block.get("toolName"), json.dumps(block.get("args"), sort_keys=True))
        for message in messages:
            for block in message["content"]:
                if not isinstance(block, dict) or block.get("type") != "tool-result":
                    continue
                key = issued.get(block.get("toolCallId"))
                if key is None:
                    continue
                result = block.get("result")
                text = result if isinstance(result, str) else json.dumps(result)
                failed = cursor_failed(text)
                calls.append((key, failed, len(text)))
                if key[0] in CURSOR_EDIT_TOOLS and not failed:
                    calls.append(None)
    return score(calls, compactions=None)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    backend, log = argv[1], argv[2]
    usage_file = argv[3] if len(argv) > 3 else ""
    worktree = argv[4] if len(argv) > 4 else ""
    ts_start = argv[5] if len(argv) > 5 else ""
    try:
        if backend == "codex":
            result = codex(log)
        elif backend == "claude":
            result = claude(usage_file)
        elif backend == "cursor":
            result = cursor(worktree, ts_start)
        else:
            result = None
    except Exception as exc:  # accounting must never fail the run it describes
        print("metrics.py: %s" % exc, file=sys.stderr)
        result = None
    print("\t".join("" if v is None else str(v) for v in (result or (None,) * 4)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
