#!/usr/bin/env python3
"""Deterministic pre-compaction snapshot for a claude session.

  compact_snapshot.py <out.md>   hook payload (JSON) on stdin

Writes what is knowable without the model: files changed in the worktree (git)
and the exact text of the last failing tool calls from the transcript. A hook
cannot make the agent write anything, so free-text compaction is the only thing
that would otherwise carry these across. Never raises: a snapshot is best
effort and must not affect the session.
"""
import json
import os
import subprocess
import sys

MAX_ERRORS = 5
MAX_CHARS = 1500


def git(cwd, *args):
    try:
        out = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True,
                             text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def failing_calls(transcript):
    """(tool, input, output) of the most recent failed tool calls, oldest first."""
    pending, failed = {}, []
    try:
        handle = open(transcript, encoding="utf-8", errors="replace")
    except OSError:
        return []
    with handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            content = (entry.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    pending[block.get("id")] = (block.get("name"), block.get("input"))
                elif block.get("type") == "tool_result" and block.get("is_error"):
                    name, args = pending.get(block.get("tool_use_id"), ("?", None))
                    failed.append((name, args, text_of(block.get("content"))))
    return failed[-MAX_ERRORS:]


def clip(text):
    text = text.strip()
    return text if len(text) <= MAX_CHARS else text[:MAX_CHARS] + " ...[truncated]"


def build(payload):
    cwd = payload.get("cwd") or os.getcwd()
    lines = ["## Snapshot taken just before context compaction",
             "The summary you now carry is lossy. This is exact, from git and the transcript."]
    status = git(cwd, "status", "--porcelain")
    lines += ["", "Uncommitted changes (git status --porcelain):", status or "(none)"]
    base = os.environ.get("AGENT_BASE_REF")
    if base:
        committed = git(cwd, "diff", "--name-status", "%s...HEAD" % base)
        lines += ["", "Committed on this branch vs %s:" % base, committed or "(none)"]
    failed = failing_calls(payload.get("transcript_path") or "")
    if failed:
        lines += ["", "Most recent failing tool calls (exact output):"]
        for name, args, output in failed:
            lines += ["", "- %s %s" % (name, clip(json.dumps(args, sort_keys=True))),
                      "```", clip(output), "```"]
    return "\n".join(lines) + "\n"


def main(argv):
    if len(argv) != 2:
        return 0
    try:
        payload = json.load(sys.stdin)
        body = build(payload)
        with open(argv[1], "w", encoding="utf-8") as out:
            out.write(body)
    except Exception as exc:  # noqa: BLE001 -- best effort by design
        print("compact_snapshot: %s" % exc, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
