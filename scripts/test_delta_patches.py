from __future__ import annotations

import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DELTA_ROOT = PROJECT_ROOT / "patches" / "delta"
PATCH_NAME = re.compile(r"^[0-9]{4}-[a-z0-9-]+\.patch$")
MAILBOX_FROM = re.compile(r"^From [0-9a-f]{40} Mon Sep 17 00:00:00 2001$")
DIFF_PATH = re.compile(r"^diff --git a/(.+?) b/(.+)$", re.MULTILINE)
CONTROL_PATH_PREFIXES = (".github/", "patches/")
CONTROL_PATHS = {"AGENTS.md", "CONTRIBUTING.md", "README.md", "docs/next/README.md"}


def series_entries() -> list[str]:
    entries = []
    for raw_line in (DELTA_ROOT / "series").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#"):
            entries.append(line)
    return entries


class DeltaPatchTests(unittest.TestCase):
    def test_base_is_a_full_commit_id(self) -> None:
        base = (DELTA_ROOT / "BASE").read_text(encoding="utf-8").strip()
        self.assertRegex(base, r"^[0-9a-f]{40}$")

    def test_series_is_unique_and_complete(self) -> None:
        entries = series_entries()
        self.assertGreater(len(entries), 0)
        self.assertEqual(len(entries), len(set(entries)))
        for entry in entries:
            self.assertRegex(entry, PATCH_NAME)
        actual = sorted(path.name for path in DELTA_ROOT.glob("*.patch"))
        self.assertEqual(sorted(entries), actual)

    def test_mailboxes_are_full_git_patches_without_control_plane_files(self) -> None:
        entries = series_entries()
        commits = []
        for position, entry in enumerate(entries, start=1):
            text = (DELTA_ROOT / entry).read_text(encoding="utf-8")
            first_line = text.splitlines()[0]
            self.assertRegex(first_line, MAILBOX_FROM, entry)
            commits.append(first_line.split()[1])
            self.assertIn(
                f"\nSubject: [PATCH {position}/{len(entries)}] ", text, entry
            )
            paths = {
                path
                for before, after in DIFF_PATH.findall(text)
                for path in (before, after)
            }
            self.assertGreater(len(paths), 0, entry)
            disallowed = sorted(
                path
                for path in paths
                if path in CONTROL_PATHS
                or path.startswith(CONTROL_PATH_PREFIXES)
            )
            self.assertEqual(disallowed, [], entry)
        self.assertEqual(len(commits), len(set(commits)))


if __name__ == "__main__":
    unittest.main()
