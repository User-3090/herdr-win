from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
NSI = PROJECT_ROOT / "packaging/windows/herdr-installer.nsi"
HELPER = PROJECT_ROOT / "packaging/windows/herdr-installer-helper.ps1"
PACKAGER = PROJECT_ROOT / "scripts/package_windows_installer.ps1"
POWERSHELL_TEST = PROJECT_ROOT / "scripts/windows_installer_test.ps1"
FAULT_TEST = PROJECT_ROOT / "scripts/windows_installer_fault_test.ps1"
MANAGED_INSTALL = PROJECT_ROOT / "src/managed_install.rs"
WINDOWS_PLATFORM = PROJECT_ROOT / "src/platform/windows.rs"
UPDATE = PROJECT_ROOT / "src/update.rs"


class WindowsInstallerStaticTests(unittest.TestCase):
    def test_expected_owners_exist_and_are_registered(self) -> None:
        for path in (NSI, HELPER, PACKAGER, POWERSHELL_TEST, FAULT_TEST):
            self.assertTrue(path.is_file(), path)
        justfile = (PROJECT_ROOT / "justfile").read_text(encoding="utf-8")
        self.assertIn("scripts.test_windows_installer", justfile)

    def test_helper_owns_exact_markers_and_managed_layout(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn('return "herdr-runtime-v1`nbuild_id=$BuildId`n"', helper)
        self.assertIn('return "herdr-pointer-v1`nbuild_id=$BuildId`n"', helper)
        self.assertIn('$script:ManagedBinMarkerText = "herdr-managed-bin-v1`n"', helper)
        self.assertIn('"herdr-launcher.exe"', helper)
        self.assertIn('"runtime.manifest"', helper)
        self.assertIn("herdr-runtime-manifest-v1", helper)
        self.assertIn("^[0-9a-f]{12}\\.[0-9a-f]{12}$", helper)
        self.assertIn('Join-Path $InstallRoot "runtime', helper)
        self.assertIn('Join-Path $stateDir "active"', helper)
        self.assertIn('Join-Path $stateDir "pending"', helper)
        self.assertIn('Join-Path $stateDir "leases"', helper)
        self.assertIn("[IO.File]::Replace", helper)
        self.assertIn("[IO.FileOptions]::WriteThrough", helper)
        self.assertIn("$stream.Flush($true)", helper)
        self.assertIn("Get-HerdrLeaseStatus", helper)
        self.assertIn('Status = "Pending"', helper)
        self.assertIn("Pending; staged until old sessions exit.", helper)

    def test_crash_artifacts_stay_outside_strict_roots(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn('New-HerdrTransaction -Kind "fresh"', helper)
        self.assertIn('New-HerdrTransaction -Kind "update"', helper)
        self.assertIn('New-HerdrTransaction -Kind "uninstall"', helper)
        self.assertIn("[IO.Directory]::Move($stagedRoot, $InstallRoot)", helper)
        self.assertNotIn('Join-Path $RuntimeRoot (".staging.', helper)
        self.assertIn("uninstall.pending", helper)
        self.assertIn("Assert-HerdrUninstallRetryRoot", helper)

    def test_persistent_sibling_lock_serializes_outer_lifecycle(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn('"$leaf.installer-lifecycle.lock"', helper)
        self.assertIn("permanent rendezvous owner", helper)
        self.assertIn("[IO.FileShare]::None", helper)
        self.assertIn("Invoke-HerdrLifecycleOperation", helper)
        install_entry = helper[helper.index("function Invoke-HerdrInstall {") :]
        uninstall_entry = helper[helper.index("function Invoke-HerdrUninstall {") :]
        self.assertLess(
            install_entry.index("Invoke-HerdrLifecycleOperation"),
            install_entry.index("Install-HerdrLayout"),
        )
        self.assertLess(
            uninstall_entry.index("Invoke-HerdrLifecycleOperation"),
            uninstall_entry.index("Invoke-HerdrUninstallLayout"),
        )
        self.assertNotIn("Remove-Item -LiteralPath $lockPath", helper)

    def test_helper_matches_the_launcher_lock_and_lease_contract(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        launcher_contract = MANAGED_INSTALL.read_text(encoding="utf-8")
        self.assertIn('join(format!("{}.lease", build_id.as_str()))', launcher_contract)
        self.assertIn('join("launcher.lock")', launcher_contract)
        self.assertIn("\\.lease$'", helper)
        self.assertNotIn("[0-9]*)\\.lease", helper)
        self.assertIn('Join-Path $stateDir "launcher.lock"', helper)
        self.assertIn("[IO.FileShare]::None", helper)
        self.assertIn("LockTimeoutMilliseconds", helper)

    def test_runtime_components_never_download_or_force_process_lifecycle(self) -> None:
        runtime_sources = "\n".join(
            (NSI.read_text(encoding="utf-8"), HELPER.read_text(encoding="utf-8"))
        ).lower()
        for forbidden in (
            "invoke-webrequest",
            "start-bitstransfer",
            "http://",
            "https://",
            "/rebootok",
            "stop-process",
            "taskkill",
            "shutdown.exe",
            "itemtype junction",
            "movefileex",
        ):
            self.assertNotIn(forbidden, runtime_sources)

    def test_nsis_is_per_user_silent_safe_and_truthful(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        self.assertIn("RequestExecutionLevel user", nsi)
        self.assertIn('InstallDir "$LOCALAPPDATA\\Programs\\Herdr"', nsi)
        self.assertIn('WriteUninstaller "$PLUGINSDIR\\uninstall.exe"', nsi)
        self.assertIn('VIProductVersion "${HERDR_NUMERIC_VERSION}"', nsi)
        self.assertIn('VIAddVersionKey "ProductVersion" "${HERDR_DISPLAY_VERSION}"', nsi)
        self.assertIn("/PARENT_PID=", nsi)
        self.assertIn("/TIMEOUT=120000", nsi)
        self.assertIn('ReadEnvStr $StartGate "HERDR_INSTALLER_START_GATE_V1"', nsi)
        self.assertIn("Call WaitForUpdaterStartGate", nsi)
        self.assertIn("IntCmp $0 600", nsi)
        self.assertIn("SetErrorLevel 1", nsi)
        self.assertIn("SetErrorLevel 0", nsi)
        self.assertIn('QuietUninstallString', HELPER.read_text(encoding="utf-8"))
        message_boxes = [match.start() for match in re.finditer(r"\bMessageBox\b", nsi)]
        self.assertEqual(len(message_boxes), 2)
        for position in message_boxes:
            self.assertIn("IfSilent", nsi[max(0, position - 120) : position])
        cleanup = nsi[nsi.index("un_cleanup_start:") :]
        ordered_cleanup = (
            'Delete "$INSTDIR\\state\\uninstall.pending"',
            'Delete "$INSTDIR\\state\\launcher.lock"',
            'Delete "$INSTDIR\\state\\installer-helper.ps1"',
            'RMDir "$INSTDIR\\state"',
            'Delete "$INSTDIR\\uninstall.exe"',
            'RMDir "$INSTDIR"',
        )
        positions = [cleanup.index(instruction) for instruction in ordered_cleanup]
        self.assertEqual(positions, sorted(positions))

    def test_nsis_residual_cleanup_is_exact_idempotent_and_fault_injected(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        validator = nsi[
            nsi.index("Function un.ValidateResidualLayout") : nsi.index(
                'Section "Herdr" SEC_HERDR'
            )
        ]
        for exact_name in (
            '"state"',
            '"uninstall.exe"',
            '"installer-helper.ps1"',
            '"launcher.lock"',
            '"uninstall.pending"',
        ):
            self.assertIn(exact_name, validator)
        self.assertIn("FindFirst", validator)
        self.assertIn('"REPARSE_POINT"', validator)
        self.assertIn("un_residual_ready", nsi)
        self.assertNotIn("RMDir /r", nsi)
        for stage in (
            "after-launcher-lock",
            "after-uninstall-pending",
            "after-installer-helper",
            "after-state-directory",
            "before-uninstaller",
        ):
            self.assertEqual(
                nsi.count(f'!insertmacro HerdrUninstallFault "{stage}" '), 1
            )
        fault_test = FAULT_TEST.read_text(encoding="utf-8")
        self.assertIn("Wait-TestCondition", fault_test)
        self.assertIn("WaitForExit", fault_test)
        self.assertIn("Injected uninstall", fault_test)
        self.assertIn("Windows installer fault matrix passed", fault_test)
        self.assertNotIn("Wait-Process", fault_test)

    def test_packager_pins_nsis_and_reuses_conpty_validation(self) -> None:
        packager = PACKAGER.read_text(encoding="utf-8")
        self.assertIn('$NsisVersion = "3.12"', packager)
        self.assertIn(
            '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f',
            packager,
        )
        self.assertIn("downloads.sourceforge.net/project/nsis", packager)
        self.assertIn('"/WX"', packager)
        self.assertIn('"validate"', packager)
        self.assertIn('package_windows_conpty.py', packager)
        self.assertIn('"--max-time", "120"', packager)
        self.assertIn("function Get-Sha256", packager)
        self.assertNotIn("Get-FileHash", packager)
        self.assertIn("separately built launcher", packager)
        self.assertIn("Invoke-HerdrIdentityQuery", packager)
        self.assertIn("WaitForExit", packager)
        self.assertIn('"--herdr-private-launcher-build-id-v1"', packager)
        self.assertIn('ExpectedOutput "herdr $DisplayVersion"', packager)
        self.assertIn("expected exact output", packager)
        self.assertIn("must be <major>.<minor>.<patch>-preview", packager)
        self.assertIn("must match DisplayVersion's major, minor, and patch", packager)
        self.assertIn("HERDR_DISPLAY_VERSION", packager)
        self.assertIn("HERDR_NUMERIC_VERSION", packager)
        self.assertNotIn("Microsoft.Windows.Console.ConPTY", packager)

    def test_updater_owns_a_bounded_kill_on_close_installer_job(self) -> None:
        platform = WINDOWS_PLATFORM.read_text(encoding="utf-8")
        updater = UPDATE.read_text(encoding="utf-8")
        self.assertIn("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", platform)
        self.assertIn("AssignProcessToJobObject", platform)
        self.assertIn("TerminateJobObject", platform)
        self.assertIn("wait_child_bounded", platform)
        installer_boundary = platform[
            platform.index("pub(crate) fn wait_child_bounded") : platform.index(
                "pub fn write_clipboard"
            )
        ]
        self.assertNotIn("child.wait()", installer_boundary)
        self.assertIn("HERDR_INSTALLER_START_GATE_V1", updater)
        self.assertIn("new_kill_on_close", updater)
        self.assertIn("terminate_and_wait", updater)

    def test_conpty_tests_no_longer_assign_website_installer_ownership(self) -> None:
        package_test = (PROJECT_ROOT / "scripts/test_package_windows_conpty.py").read_text(
            encoding="utf-8"
        )
        package_smoke = (
            PROJECT_ROOT / "scripts/windows_install_conpty_package_test.ps1"
        ).read_text(encoding="utf-8")
        self.assertNotIn("website/install.ps1", package_test.replace("\\", "/"))
        self.assertNotIn("website\\install.ps1", package_smoke)
        self.assertIn('"validate"', package_smoke)

        old_installer = (PROJECT_ROOT / "website/install.ps1").read_text(encoding="utf-8")
        self.assertIn("Where-Object { $_.PSIsContainer }", old_installer)
        self.assertIn("managed-install-v1", HELPER.read_text(encoding="utf-8"))

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell contract test")
    def test_powershell_lifecycle_contracts(self) -> None:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(POWERSHELL_TEST),
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )


if __name__ == "__main__":
    unittest.main()
