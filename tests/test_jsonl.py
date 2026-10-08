"""Session-log containment and integration regressions.

Run with python -m unittest discover -s tests -v.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from lib.jsonl import load_jsonl


class SessionLogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root / "custom-logs"
        self.logs.mkdir()
        self.log = self.logs / "sessions.jsonl"
        self.row = {"project": "example", "kind": "build", "item": 7,
                    "tier": "standard", "result": "FAILED", "ts_start": 1,
                    "backend": "codex", "note": "café"}
        self.log.write_text("\ninvalid JSON\n" + json.dumps(self.row) + "\n",
                            encoding="utf-8")
        self.outside = self.root / "sessions.jsonl"
        self.outside.write_text(json.dumps(self.row), encoding="utf-8")

    def assert_rejected(self, path):
        with patch("builtins.open") as open_file:
            with self.assertRaisesRegex(ValueError, "session log path must stay inside"):
                load_jsonl(path, self.logs)
            open_file.assert_not_called()

    def test_allowed_absolute_and_relative_paths(self):
        self.assertEqual(load_jsonl(self.log, self.logs), [self.row])
        relative = os.path.relpath(self.log)
        self.assertEqual(load_jsonl(relative, self.logs), [self.row])

    def test_missing_log_and_malformed_lines(self):
        self.assertEqual(load_jsonl(self.logs / "missing.jsonl", self.logs), [])
        self.assertEqual(load_jsonl(self.log, self.logs), [self.row])

    def test_dot_dot_escape(self):
        self.assert_rejected(self.logs / ".." / "sessions.jsonl")

    def test_absolute_outside_path(self):
        self.assert_rejected(self.outside)

    def test_missing_outside_path(self):
        self.assert_rejected(self.root / "missing.jsonl")

    def test_sibling_with_same_directory_prefix(self):
        sibling = self.root / "custom-logs-other"
        sibling.mkdir()
        self.assert_rejected(sibling / "sessions.jsonl")

    def test_symlink_escape(self):
        link = self.logs / "linked.jsonl"
        try:
            link.symlink_to(self.outside)
        except (OSError, NotImplementedError) as exc:
            self.skipTest("symlinks unavailable: %s" % exc)
        self.assert_rejected(link)

    def test_directory_symlink_escape(self):
        link = self.logs / "linked-directory"
        try:
            link.symlink_to(self.root, target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest("symlinks unavailable: %s" % exc)
        self.assert_rejected(link / "sessions.jsonl")

    @unittest.skipUnless(os.name == "nt", "Windows junction regression")
    def test_directory_junction_escape(self):
        import _winapi

        link = self.logs / "junction"
        _winapi.CreateJunction(str(self.root), str(link))
        self.addCleanup(link.rmdir)
        self.assert_rejected(link / "sessions.jsonl")

    def test_all_cli_consumers(self):
        config = self.root / "pools.yaml"
        config.write_text("pools: {}\nroutes: []\n", encoding="utf-8")
        repo = Path(__file__).resolve().parents[1]
        for script, args, expected in (
            ("report.py", [str(self.root / "outcomes.json"), str(config)],
             "Cost by outcome"),
            ("pool_status.py", [], "Percent is comparable only within a pool"),
            ("escalation.py", ["example", "build", "7", "standard"], "1\n"),
        ):
            for path, allowed in ((self.log, True), (self.outside, False)):
                with self.subTest(script=script, allowed=allowed):
                    prefix = (["count"] if script == "escalation.py" else
                              [str(config)] if script == "pool_status.py" else [])
                    result = subprocess.run(
                        [sys.executable, str(repo / "lib" / script), *prefix,
                         str(path), *args, str(self.logs)],
                        capture_output=True, text=True, check=False,
                    )
                    if allowed:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn(expected, result.stdout)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("session log path must stay inside", result.stderr)
                        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
