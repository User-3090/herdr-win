from __future__ import annotations

import hashlib
import re
import struct
import subprocess
import sys
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent.parent
NSI = PROJECT_ROOT / "packaging/windows/installer/project.nsi"
HELPER = PROJECT_ROOT / "packaging/windows/herdr-installer-helper.ps1"
PACKAGER = PROJECT_ROOT / "scripts/package_windows_installer.ps1"
POWERSHELL_TEST = PROJECT_ROOT / "scripts/windows_installer_test.ps1"
FAULT_TEST = PROJECT_ROOT / "scripts/windows_installer_fault_test.ps1"
MANAGED_INSTALL = PROJECT_ROOT / "src/managed_install.rs"
WINDOWS_PLATFORM = PROJECT_ROOT / "src/platform/windows.rs"
UPDATE = PROJECT_ROOT / "src/update.rs"
SKILL = PROJECT_ROOT / "SKILL.md"
ARTWORK = NSI.parent / "artwork"
ARTWORK_SOURCE = ARTWORK / "installer-welcome-finish-source.png"
ARTWORK_DERIVATIVES = {
    "installer-welcome-finish-164x314.bmp": (
        164,
        314,
        "e8a07fbbce2eabc1bd705de7f54743f14027a7d58674044691cf13275e99247c",
    ),
    "installer-welcome-finish-205x393.bmp": (
        205,
        393,
        "bc71f8adeb53809492393165533ab6fc130d4d6e570edb21e95878878b422d4c",
    ),
    "installer-welcome-finish-246x471.bmp": (
        246,
        471,
        "7e9dc0595270ca68736382bb4c852dce038ffbb3ea7bb481e77bd91d3c077edc",
    ),
    "installer-welcome-finish-287x550.bmp": (
        287,
        550,
        "8571db6e74e9bc5efef33a8708acaaa35887464a4bdeaf0453525ea5de2b371e",
    ),
    "installer-welcome-finish-328x628.bmp": (
        328,
        628,
        "e055e2515966dfc4e192daef2df76075ac23d3e68d62154b529a476081ea1c6c",
    ),
}


class WindowsInstallerStaticTests(unittest.TestCase):
    def test_expected_owners_exist_and_are_registered(self) -> None:
        for path in (
            NSI,
            HELPER,
            PACKAGER,
            POWERSHELL_TEST,
            FAULT_TEST,
            SKILL,
        ):
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
        self.assertIn("herdr-install-manifest-v2", helper)
        self.assertIn("skill_sha256=", helper)

    def test_installer_owns_the_cross_agent_skill_lifecycle(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        nsi = NSI.read_text(encoding="utf-8")
        packager = PACKAGER.read_text(encoding="utf-8")
        lifecycle = POWERSHELL_TEST.read_text(encoding="utf-8")
        self.assertIn('Join-Path $userProfile ".agents\\skills"', helper)
        self.assertIn('Join-Path $AgentSkillsRoot "herdr"', helper)
        self.assertIn("New-HerdrAgentSkillTransaction", helper)
        self.assertIn("Publish-HerdrAgentSkillTransaction", helper)
        self.assertIn("Complete-HerdrAgentSkillTransaction", helper)
        self.assertIn("Start-HerdrInstalledAgentSkillRemoval", helper)
        self.assertIn("Complete-HerdrInstalledAgentSkillRemoval", helper)
        self.assertIn("Remove-HerdrInstalledAgentSkill", helper)
        self.assertIn("Restore-HerdrAgentSkillTransactions", helper)
        self.assertIn(".herdr-agent-skill-installer.lock", helper)
        self.assertIn("Refusing to replace a reparse-point Herdr agent skill", helper)
        removal_start = helper[
            helper.index("function Start-HerdrInstalledAgentSkillRemoval {") : helper.index(
                "function Publish-HerdrAgentSkillRemovalCandidate {"
            )
        ]
        removal_publish = helper[
            helper.index("function Publish-HerdrAgentSkillRemovalCandidate {") : helper.index(
                "function Commit-HerdrAgentSkillRemovalCandidate {"
            )
        ]
        removal_commit = helper[
            helper.index("function Commit-HerdrAgentSkillRemovalCandidate {") : helper.index(
                "function Remove-HerdrInstalledAgentSkill {"
            )
        ]
        self.assertIn(
            'Move-HerdrAgentSkillPath -Source $target -Destination (Join-Path $transactionPath "previous")',
            removal_start,
        )
        self.assertIn(
            "[Herdr.Installer.PinnedSkillFile]::Open($entries[0].FullName)",
            removal_publish,
        )
        self.assertIn("$pinned.MoveTo($candidate)", removal_publish)
        self.assertLess(
            removal_commit.index("[IO.Directory]::Delete($previous)"),
            removal_commit.index("$pinned.DeleteByHandle()"),
        )
        self.assertIn("SetFileInformationByHandle", helper)
        self.assertIn("FileFlagOpenReparsePoint", helper)
        self.assertIn(
            "-ReferencedAssemblies @([ComponentModel.Win32Exception].Assembly.Location)",
            helper,
        )
        self.assertIn('$script:AgentSkillRemovalOwnerName = ".herdr-agent-skill-removal"', helper)
        self.assertIn("AgentSkillRemovalCleanupPattern", helper)
        self.assertIn("[IO.Directory]::Move($state.Path, $cleanup)", helper)
        cleanup_restore = helper[
            helper.index("function Restore-HerdrAgentSkillTransactions {") : helper.index(
                "$transactions = @(",
                helper.index("function Restore-HerdrAgentSkillTransactions {"),
            )
        ]
        self.assertIn("Get-ChildItem -LiteralPath $AgentSkillsRoot -Force |", cleanup_restore)
        self.assertNotIn("-Force -Directory", cleanup_restore)
        self.assertIn("A Herdr agent skill removal transaction cannot use install rollback", helper)
        self.assertNotIn(
            "Move-HerdrAgentSkillPath -Source $target -Destination $discard",
            removal_commit,
        )
        self.assertEqual(
            helper.count(
                'Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest")'
            ),
            3,
        )
        self.assertIn("ARG_SKILL_MD", nsi)
        self.assertIn('/oname=SKILL.md "${ARG_SKILL_MD}"', nsi)
        self.assertIn('-SkillSourcePath "$PLUGINSDIR\\skill\\SKILL.md"', nsi)
        self.assertIn('$skillSource = Join-Path $projectRoot "SKILL.md"', packager)
        self.assertIn('"/DARG_SKILL_MD=$skillSource"', packager)
        self.assertIn('$skillValidationText = $skillText.Replace("`r`n", "`n")', packager)
        self.assertIn("retained files from the previous Herdr skill version", lifecycle)
        self.assertIn("Owned skill remained public after atomic detach", lifecycle)
        self.assertIn("Concurrent skill replacement was deleted", lifecycle)
        self.assertIn("Exact concurrent replacement was deleted", lifecycle)
        self.assertIn("Late detached content was deleted", lifecycle)
        self.assertIn("Committed removal recovery restored a public target", lifecycle)
        self.assertIn("Extra-tree uninstall removed nested user content", lifecycle)
        self.assertIn("Removal cleanup crash subset", lifecycle)
        self.assertIn("Strict-name removal cleanup file bypassed validation", lifecycle)
        self.assertIn("Strict-name removal cleanup junction bypassed validation", lifecycle)
        self.assertIn("shadowed System.dll", lifecycle)
        self.assertIn("Uninstall removed a modified Herdr skill", lifecycle)
        fault_test = FAULT_TEST.read_text(encoding="utf-8")
        self.assertIn("Assert-TestSkillInstalled", fault_test)
        self.assertIn("retained the unchanged owned Herdr skill", fault_test)
        self.assertIn("Modified skill tree uninstall passed", fault_test)
        self.assertIn("AgentUserProfileRoot", fault_test)
        self.assertIn('[string]$ProductName = "Herdr"', fault_test)
        self.assertIn("-ProductName $ProductName", fault_test)
        self.assertIn("requires no interrupted Herdr agent skill transaction", fault_test)

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

    def test_nsis_template_is_product_neutral_and_uses_native_mui2_presentation(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        for required in (
            "ARG_STAGE_DIR",
            "ARG_LAUNCHER_EXE",
            "ARG_HELPER_PS1",
            "ARG_SKILL_MD",
            "ARG_ARTWORK_DIR",
            "APP_BUILD_ID",
            "APP_OUTPUT_PATH",
            "APP_START_GATE_ENV",
            "APP_TEST_MARKER_PREFIX",
            "INFO_PRODUCTNAME",
            "INFO_COMPANYNAME",
            "INFO_COPYRIGHT",
            "INFO_COMMANDNAME",
            "INFO_ORIGINALFILENAME",
            "INFO_PRODUCTVERSION_DISPLAY",
            "INFO_PRODUCTVERSION_FIXED",
        ):
            self.assertIn(f"!ifndef {required}", nsi)
        self.assertNotRegex(nsi, re.compile(r"herdr", re.IGNORECASE))
        self.assertIn('Name "${INFO_PRODUCTNAME}"', nsi)
        self.assertIn('Caption "${INFO_PRODUCTNAME} Setup"', nsi)
        self.assertIn('BrandingText "${INFO_PRODUCTNAME}"', nsi)
        self.assertIn('!include "MUI2.nsh"', nsi)
        self.assertIn('!include "nsDialogs.nsh"', nsi)
        self.assertIn('!insertmacro MUI_LANGUAGE "English"', nsi)
        self.assertEqual(nsi.count("!insertmacro MUI_LANGUAGE"), 1)
        self.assertNotIn("LANG_GERMAN", nsi)
        self.assertNotIn("APP_SELECT_INSTALLER_LANGUAGE", nsi)
        self.assertNotIn("MUI_ICON", nsi)
        self.assertNotIn("MUI_UNICON", nsi)
        self.assertIn("MUI_WELCOMEFINISHPAGE_BITMAP", nsi)
        self.assertIn(
            "MUI_WELCOMEFINISHPAGE_BITMAP_STRETCH NoStretchNoCropNoAlign", nsi
        )
        self.assertIn("MUI_CUSTOMFUNCTION_GUIINIT SelectInstallerWelcomeBitmap", nsi)
        self.assertEqual(nsi.count("!pragma verifyloadimage"), 4)
        for threshold in (108, 132, 156, 180):
            self.assertIn(f"$0 >= {threshold}", nsi)
        page_order = (
            "!insertmacro MUI_PAGE_WELCOME",
            "!insertmacro MUI_PAGE_INSTFILES",
            "!insertmacro MUI_PAGE_FINISH",
        )
        positions = [nsi.index(page) for page in page_order]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("Page custom WelcomePage", nsi)
        self.assertNotIn("Function WelcomePage", nsi)
        self.assertNotIn("MUI_PAGE_DIRECTORY", nsi)
        self.assertNotIn("MUI_PAGE_COMPONENTS", nsi)
        self.assertNotIn("MUI_FINISHPAGE_RUN", nsi)
        self.assertNotIn("MUI_FINISHPAGE_SHOWREADME", nsi)
        self.assertNotIn("MUI_FINISHPAGE_LINK", nsi)
        self.assertIn(
            "UninstPage custom un.SettingsPage un.SettingsPageLeave", nsi
        )
        self.assertIn("!insertmacro MUI_UNPAGE_INSTFILES", nsi)
        self.assertNotIn("UninstPage uninstConfirm", nsi)
        self.assertIn("SetCompressor lzma", nsi)
        self.assertIn("SetDatablockOptimize on", nsi)
        self.assertIn("SetCompressorDictSize 8", nsi)
        self.assertIn("SetCompressor /SOLID /FINAL lzma", nsi)
        compression_order = (
            nsi.index("SetCompressor lzma"),
            nsi.index("SetDatablockOptimize on"),
            nsi.index("SetCompressorDictSize 8"),
            nsi.index("SetCompressor /SOLID /FINAL lzma"),
        )
        self.assertEqual(compression_order, tuple(sorted(compression_order)))
        self.assertIn("AllowSkipFiles off", nsi)
        self.assertIn("ManifestDPIAware true", nsi)

    def test_installer_artwork_is_an_exact_native_bmp3_set(self) -> None:
        expected_files = {
            "README.md",
            ARTWORK_SOURCE.name,
            *ARTWORK_DERIVATIVES,
        }
        self.assertEqual({path.name for path in ARTWORK.iterdir()}, expected_files)

        source = ARTWORK_SOURCE.read_bytes()
        self.assertEqual(source[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(source[12:16], b"IHDR")
        self.assertEqual(
            struct.unpack(">IIBBBBB", source[16:29]),
            (906, 1736, 8, 2, 0, 0, 0),
        )
        self.assertEqual(
            hashlib.sha256(source).hexdigest(),
            "6bb6db2684d5b77aace0cfa7a8925277c656f74c60451013e3f890d631fbccf1",
        )

        for filename, (width, height, expected_hash) in ARTWORK_DERIVATIVES.items():
            bitmap = (ARTWORK / filename).read_bytes()
            row_size = ((width * 3 + 3) // 4) * 4
            pixel_size = row_size * height
            self.assertEqual(bitmap[:2], b"BM", filename)
            self.assertEqual(struct.unpack_from("<I", bitmap, 2)[0], len(bitmap), filename)
            self.assertEqual(struct.unpack_from("<I", bitmap, 10)[0], 54, filename)
            self.assertEqual(struct.unpack_from("<I", bitmap, 14)[0], 40, filename)
            self.assertEqual(struct.unpack_from("<ii", bitmap, 18), (width, height), filename)
            self.assertEqual(struct.unpack_from("<H", bitmap, 26)[0], 1, filename)
            self.assertEqual(struct.unpack_from("<H", bitmap, 28)[0], 24, filename)
            self.assertEqual(struct.unpack_from("<I", bitmap, 30)[0], 0, filename)
            self.assertEqual(struct.unpack_from("<I", bitmap, 34)[0], pixel_size, filename)
            self.assertEqual(len(bitmap), 54 + pixel_size, filename)
            self.assertEqual(hashlib.sha256(bitmap).hexdigest(), expected_hash, filename)

        artwork_notes = (ARTWORK / "README.md").read_text(encoding="utf-8")
        self.assertIn("ImageMagick", artwork_notes)
        self.assertIn("7.1.2-29 Q16-HDRI", artwork_notes)
        self.assertIn("-colorspace RGB", artwork_notes)
        self.assertIn("-filter Lanczos", artwork_notes)
        self.assertIn("filter:lobes=3", artwork_notes)
        self.assertIn("-colorspace sRGB", artwork_notes)
        self.assertIn('"BMP3:installer-welcome-finish-$size.bmp"', artwork_notes)

    def test_nsis_is_per_user_silent_safe_and_truthful(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn("RequestExecutionLevel user", nsi)
        self.assertIn(
            'InstallDir "$LOCALAPPDATA\\Programs\\${INFO_PRODUCTNAME}"', nsi
        )
        self.assertIn('WriteUninstaller "$PLUGINSDIR\\uninstall.exe"', nsi)
        self.assertIn('VIProductVersion "${INFO_PRODUCTVERSION_FIXED}"', nsi)
        self.assertIn(
            '"ProductVersion" "${INFO_PRODUCTVERSION_DISPLAY}"', nsi
        )
        self.assertIn('"OriginalFilename" "${INFO_ORIGINALFILENAME}"', nsi)
        self.assertIn("/PARENT_PID=", nsi)
        self.assertIn("/TIMEOUT=120000", nsi)
        self.assertIn('ReadEnvStr $StartGate "${APP_START_GATE_ENV}"', nsi)
        self.assertIn("Call WaitForUpdaterStartGate", nsi)
        self.assertIn("IntCmp $0 600", nsi)
        self.assertIn('StrCpy $SettingsDisposition "Remove"', nsi)
        self.assertIn('${GetOptions} "$0" "/KEEP_SETTINGS" $1', nsi)
        self.assertIn('StrCpy $SettingsDisposition "Keep"', nsi)
        self.assertIn('${NSD_Check} $SettingsCheckbox', nsi)
        self.assertIn('-SettingsDisposition "$SettingsDisposition"', nsi)
        self.assertIn('SettingsDisposition = "Keep"', helper)
        self.assertIn('if ($SettingsDisposition -ceq "Remove")', helper)
        self.assertIn("SetErrorLevel 1", nsi)
        self.assertIn("SetErrorLevel 0", nsi)
        self.assertIn("QuietUninstallString", helper)
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

    def test_helper_owns_fail_closed_optional_settings_removal(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        cleanup = helper[
            helper.index("function Remove-HerdrUserSettings {") : helper.index(
                "function Move-HerdrAgentSkillPath {"
            )
        ]
        self.assertIn('Join-Path $profileRoot ".herdr"', cleanup)
        self.assertIn("Assert-HerdrRegularDirectory -Path $profileRoot", cleanup)
        self.assertIn("Test-HerdrPathWithin", cleanup)
        self.assertIn("Assert-HerdrRegularDirectory -Path $settingsRoot", cleanup)
        self.assertIn(
            "Remove-HerdrReplaceableAgentSkillPath -Path $settingsRoot", cleanup
        )
        self.assertNotIn("Remove-Item -LiteralPath $settingsRoot -Recurse", cleanup)
        self.assertIn("DisplayName = $script:ProductName", helper)

    def test_nsis_residual_cleanup_is_exact_idempotent_and_fault_injected(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        validator = nsi[
            nsi.index("Function un.ValidateResidualLayout") : nsi.index(
                'Section "${INFO_PRODUCTNAME}" SEC_APP'
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
                nsi.count(f'!insertmacro AppUninstallFault "{stage}" '), 1
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
        self.assertIn(
            '$installerScript = Join-Path $projectRoot "packaging\\windows\\installer\\project.nsi"',
            packager,
        )
        self.assertIn(
            '$artworkDir = Join-Path $projectRoot "packaging\\windows\\installer\\artwork"',
            packager,
        )
        self.assertIn('"/DARG_ARTWORK_DIR=$artworkDir"', packager)
        self.assertIn('"/DINFO_PRODUCTNAME=$ProductName"', packager)
        self.assertIn('"/DINFO_COMPANYNAME=$CompanyName"', packager)
        self.assertIn('"/DINFO_COPYRIGHT=$Copyright"', packager)
        self.assertIn('"/DINFO_COMMANDNAME=$CommandName"', packager)
        self.assertIn(
            '"/DINFO_ORIGINALFILENAME=$InstallerOriginalFilename"', packager
        )
        self.assertIn(
            "$InstallerOriginalFilename = [System.IO.Path]::GetFileName($OutputPath)",
            packager,
        )
        self.assertIn(
            '"/DINFO_PRODUCTVERSION_DISPLAY=$DisplayVersion"', packager
        )
        self.assertIn('"/DINFO_PRODUCTVERSION_FIXED=$NumericVersion"', packager)
        self.assertIn(
            '"/DAPP_START_GATE_ENV=$InstallerStartGateEnvironmentVariable"',
            packager,
        )
        self.assertIn('"/DTEST_UNINSTALL_FAULT=$TestUninstallFault"', packager)
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
