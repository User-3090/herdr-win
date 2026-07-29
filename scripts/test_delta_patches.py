from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DELTA_ROOT = PROJECT_ROOT / "patches" / "delta"
PATCH_NAME = re.compile(r"^[0-9]{4}-[a-z0-9-]+\.patch$")
MAILBOX_FROM = re.compile(r"^From [0-9a-f]{40} Mon Sep 17 00:00:00 2001$")
DIFF_PATH = re.compile(r"^diff --git a/(.+?) b/(.+)$", re.MULTILINE)
CONTROL_PATH_PREFIXES = (".github/", "patches/")
CONTROL_PATHS = {
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "docs/next/README.md",
    "website/preview.json",
}
FORK_RELEASE_PREFIX = "https://github.com/User-3090/herdr-win/releases/download/"
FORK_RAW_PREFIX = "https://raw.githubusercontent.com/User-3090/herdr-win/"
WINDOWS_ZIP_TARGET = "windows-x86_64"
WINDOWS_INSTALLER_TARGET = "windows-x86_64-installer"
WINDOWS_INSTALLER_NAME = "herdr-windows-x86_64-installer.exe"
FORBIDDEN_DISTRIBUTION_ENV = (
    "HERDR_BUILD_CHANNEL",
    "HERDR_PREVIEW_MANIFEST_URL",
    "HERDR_WINDOWS_INSTALLER_URL",
)


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

    def test_preview_manifest_is_bootstrap_empty_or_fork_owned(self) -> None:
        manifest = json.loads(
            (PROJECT_ROOT / "website" / "preview.json").read_text(encoding="utf-8")
        )
        if manifest == {}:
            return

        self.assertEqual(manifest.get("channel"), "preview")
        self.assertRegex(
            str(manifest.get("build_id", "")), r"^[0-9a-f]{12}\.[0-9a-f]{12}$"
        )
        asset_groups = [manifest.get("assets", {})]
        asset_groups.extend(
            build.get("assets", {}) for build in manifest.get("builds", {}).values()
        )
        for assets in asset_groups:
            self.assertIsInstance(assets, dict)
            self.assertIn(WINDOWS_ZIP_TARGET, assets)
            self.assertLessEqual(
                set(assets), {WINDOWS_ZIP_TARGET, WINDOWS_INSTALLER_TARGET}
            )
            windows = assets[WINDOWS_ZIP_TARGET]
            self.assertIsInstance(windows, dict)
            self.assertTrue(
                str(windows.get("url", "")).startswith(FORK_RELEASE_PREFIX)
            )
            self.assertRegex(str(windows.get("sha256", "")), r"^[0-9a-f]{64}$")
            self.assertEqual(windows.get("format"), "zip")
            if WINDOWS_INSTALLER_TARGET in assets:
                installer = assets[WINDOWS_INSTALLER_TARGET]
                self.assertIsInstance(installer, dict)
                self.assertTrue(
                    str(installer.get("url", "")).startswith(FORK_RELEASE_PREFIX)
                )
                self.assertTrue(
                    str(installer.get("url", "")).endswith(
                        f"/{WINDOWS_INSTALLER_NAME}"
                    )
                )
                self.assertRegex(
                    str(installer.get("sha256", "")), r"^[0-9a-f]{64}$"
                )
                self.assertEqual(installer.get("format"), "nsis")

    def test_distribution_configuration_is_fork_owned_and_env_free(self) -> None:
        distribution = (PROJECT_ROOT / "src" / "distribution.rs").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            f'{FORK_RAW_PREFIX}master/website/preview.json', distribution
        )
        self.assertIn("WINDOWS_RELEASE_DOWNLOAD_PREFIX", distribution)
        self.assertIn(FORK_RELEASE_PREFIX, distribution)
        self.assertNotIn("WINDOWS_INSTALLER_URL", distribution)
        self.assertNotIn("https://herdr.dev", distribution)

        product_sources = "\n".join(
            (PROJECT_ROOT / path).read_text(encoding="utf-8")
            for path in (
                "build.rs",
                "src/build_info.rs",
                "src/remote/attach.rs",
                "src/update.rs",
            )
        )
        workflow = (
            PROJECT_ROOT / ".github" / "workflows" / "windows-nightly.yml"
        ).read_text(encoding="utf-8")
        for variable in FORBIDDEN_DISTRIBUTION_ENV:
            self.assertNotIn(variable, product_sources)
            self.assertNotIn(variable, workflow)

        patch = (DELTA_ROOT / "0004-windows-managed-distribution.patch").read_text(
            encoding="utf-8"
        )
        added = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        for variable in FORBIDDEN_DISTRIBUTION_ENV:
            self.assertNotIn(variable, added)
        self.assertNotIn("https://herdr.dev/latest.json", added)
        self.assertNotIn("https://herdr.dev/preview.json", added)
        self.assertNotIn("https://herdr.dev/install.ps1", added)

    def test_public_readme_mirror_and_nightly_installer_contract(self) -> None:
        readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")
        self.assertEqual(
            readme.encode(),
            (PROJECT_ROOT / "docs" / "next" / "README.md").read_bytes(),
        )
        self.assertIn(
            r"%USERPROFILE%\.agents\skills\herdr\SKILL.md",
            readme,
        )
        self.assertIn("replacing the complete previous `herdr` skill directory", readme)
        self.assertIn("preserving modified skill content", readme)
        workflow = (
            PROJECT_ROOT / ".github" / "workflows" / "windows-nightly.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(WINDOWS_INSTALLER_NAME, workflow)
        self.assertIn(WINDOWS_INSTALLER_TARGET, workflow)
        self.assertIn('format -cne "nsis"', workflow)
        self.assertIn("installer_sha", workflow)
        self.assertNotIn("PREVIEW_GENERATOR.py", workflow)
        self.assertIn(
            'generator="$GITHUB_WORKSPACE/control/scripts/preview.py"', workflow
        )
        self.assertIn(
            "replayed preview generator differs from the selected control revision",
            workflow,
        )
        self.assertEqual(workflow.count("[void] $descendant.Handle"), 2)


if __name__ == "__main__":
    unittest.main()
