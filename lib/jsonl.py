"""Shared reader for the session log (sessions.jsonl)."""

import json
import os


def load_jsonl(path, log_dir):
    """Read a log confined to the caller's configured session-log directory.

    log_dir is a trusted boundary supplied separately by the shell wrapper,
    never inferred from the possibly untrusted path. Resolve symlinks and '..'
    before checking containment, including when the requested file is missing.
    Relative paths retain their usual meaning relative to the working directory.
    """
    log_dir = os.path.realpath(log_dir)
    path = os.path.realpath(path)
    try:
        inside = os.path.commonpath([log_dir, path]) == log_dir
    except ValueError:  # Different drives on Windows cannot share a directory.
        inside = False
    if not inside:
        raise ValueError("session log path must stay inside %s: %s" % (log_dir, path))

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
