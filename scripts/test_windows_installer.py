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
SKILL = PROJECT_ROOT / "skills" / "herdr" / "SKILL.md"
MANAGED_SKILL_HASHES = PROJECT_ROOT / "packaging/windows/managed-skill-hashes.txt"
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
            MANAGED_SKILL_HASHES,
        ):
            self.assertTrue(path.is_file(), path)
        justfile = (PROJECT_ROOT / "justfile").read_text(encoding="utf-8")
        self.assertIn("scripts.test_windows_installer", justfile)

    def test_managed_skill_hash_manifest_is_exact_and_contains_current_payload(
        self,
    ) -> None:
        lines = MANAGED_SKILL_HASHES.read_text(encoding="utf-8").splitlines()
        self.assertGreaterEqual(len(lines), 2)
        self.assertEqual(lines[0], "herdr-managed-skill-hashes-v1")
        hashes = lines[1:]
        self.assertEqual(hashes, sorted(set(hashes)))
        self.assertTrue(all(re.fullmatch(r"[0-9a-f]{64}", value) for value in hashes))
        self.assertIn(hashlib.sha256(SKILL.read_bytes()).hexdigest(), hashes)

    def test_helper_owns_exact_markers_and_managed_layout(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        self.assertIn('return "herdr-runtime-v1`nbuild_id=$BuildId`n"', helper)
        self.assertIn('return "herdr-pointer-v1`nbuild_id=$BuildId`n"', helper)
        self.assertIn('$script:ManagedBinMarkerText = "herdr-managed-bin-v1`n"', helper)
        self.assertIn("obsolete launcher hop", helper)
        self.assertIn("launcher\\.pending-([0-9a-f]{64})\\.exe", helper)
        self.assertIn('"--herdr-private-launcher-build-id-v1"', helper)
        self.assertIn("Get-HerdrLauncherBuildId", helper)
        self.assertIn("does not match active runtime", helper)
        self.assertIn("Complete-HerdrLauncherUpdateLocked", helper)
        self.assertIn("Remove-HerdrInactiveRuntimes", helper)
        self.assertIn('"CompleteMaintenance"', helper)
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
        self.assertIn("herdr-install-manifest-v1", helper)
        self.assertNotIn("skill_sha256=", helper)

    def test_installer_owns_the_cross_agent_skill_lifecycle(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        nsi = NSI.read_text(encoding="utf-8")
        packager = PACKAGER.read_text(encoding="utf-8")
        lifecycle = POWERSHELL_TEST.read_text(encoding="utf-8")
        self.assertIn('Join-Path $userProfile ".agents\\skills"', helper)
        self.assertIn('Join-Path $ClaudeConfigRoot "skills"', helper)
        self.assertIn('Join-Path $SkillsRoot "herdr"', helper)
        self.assertIn("Test-HerdrClaudeCodeInstalled", helper)
        self.assertIn('Get-Command "claude" -CommandType Application', helper)
        self.assertIn("Test-Path -LiteralPath $defaultConfigRoot -PathType Container", helper)
        self.assertNotIn('".local\\bin\\claude.exe"', helper)
        self.assertNotIn('"Microsoft\\WinGet\\Links\\claude.exe"', helper)
        self.assertIn("Install-HerdrSkillFile", helper)
        self.assertIn("Install-HerdrSkillCopies", helper)
        self.assertIn("Remove-HerdrSkillFile", helper)
        self.assertIn("Remove-HerdrSkillCopies", helper)
        self.assertIn("Read-HerdrManagedSkillHashes", helper)
        self.assertIn("Get-HerdrSkillFileState", helper)
        self.assertIn("Get-HerdrSkillRemovalDefault", helper)
        install_skill = helper[
            helper.index("function Install-HerdrSkillFile {") : helper.index(
                "function Assert-HerdrSkillTarget {"
            )
        ]
        remove_skill = helper[
            helper.index("function Remove-HerdrSkillFile {") : helper.index(
                "function Remove-HerdrSkillCopies {"
            )
        ]
        self.assertIn("[IO.File]::Copy($SourcePath, $destination, $true)", install_skill)
        self.assertIn("Assert-HerdrRegularFile -Path $destination", install_skill)
        self.assertIn("Remove-Item -LiteralPath $state.Path -Force", remove_skill)
        self.assertIn("Get-ChildItem -LiteralPath $target -Force", remove_skill)
        self.assertIn('$KnownHashes -cnotcontains (Get-HerdrSha256 -Path $destination)', install_skill)
        self.assertIn('$Disposition -cne "Remove"', remove_skill)
        self.assertNotIn("-Recurse", install_skill + remove_skill)
        for removed in (
            "AgentSkillTransaction",
            "PinnedSkillFile",
            ".herdr-agent-skill-installer.lock",
            "SetFileInformationByHandle",
            "Add-Type",
        ):
            self.assertNotIn(removed, helper)
        self.assertEqual(
            helper.count(
                'Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest")'
            ),
            3,
        )
        self.assertIn("ARG_SKILL_MD", nsi)
        self.assertIn("ARG_SKILL_HASH_MANIFEST", nsi)
        self.assertIn('/oname=SKILL.md "${ARG_SKILL_MD}"', nsi)
        self.assertIn(
            '/oname=managed-skill-hashes.txt "${ARG_SKILL_HASH_MANIFEST}"', nsi
        )
        self.assertIn('-SkillSourcePath "$PLUGINSDIR\\skill\\SKILL.md"', nsi)
        self.assertIn(
            '-SkillHashManifestPath "$PLUGINSDIR\\skill\\managed-skill-hashes.txt"',
            nsi,
        )
        self.assertIn(
            '$skillSource = Join-Path $projectRoot "skills\\herdr\\SKILL.md"',
            packager,
        )
        self.assertIn('"/DARG_SKILL_MD=$skillSource"', packager)
        self.assertIn('"/DARG_SKILL_HASH_MANIFEST=$skillHashManifest"', packager)
        self.assertIn('$skillValidationText = $skillText.Replace("`r`n", "`n")', packager)
        self.assertIn("Unknown universal SKILL.md was overwritten", lifecycle)
        self.assertIn("Known universal SKILL.md was not updated", lifecycle)
        self.assertIn("Mixed skill state did not keep interactive removal unchecked", lifecycle)
        self.assertIn("Known-or-absent skill state did not select interactive removal", lifecycle)
        self.assertIn("Claude skill install removed a foreign sibling", lifecycle)
        self.assertIn("Automatic uninstall removed an unknown SKILL.md", lifecycle)
        self.assertIn("Explicit skill removal preserved an unknown SKILL.md", lifecycle)
        self.assertIn("Uninstall retained an empty Herdr skill directory", lifecycle)
        self.assertIn("Claude uninstall did not inspect configured and default roots", lifecycle)
        self.assertIn("Managed update removed a foreign skill sibling", lifecycle)
        self.assertIn("Extra-tree uninstall preserved SKILL.md", lifecycle)
        self.assertIn("Uninstall removed a modified Herdr skill", lifecycle)
        fault_test = FAULT_TEST.read_text(encoding="utf-8")
        self.assertIn("Assert-TestSkillInstalled", fault_test)
        self.assertIn("retained universal SKILL.md", fault_test)
        self.assertIn("Sibling-preserving skill uninstall passed", fault_test)
        self.assertIn("AgentUserProfileRoot", fault_test)
        self.assertIn('[string]$ProductName = "Herdr"', fault_test)
        self.assertIn('[string]$PackageName = "Herdr Win"', fault_test)
        self.assertIn("Uninstall\\$PackageName", fault_test)
        self.assertIn("-ProductName $ProductName", fault_test)
        self.assertIn("CLAUDE_CONFIG_DIR", fault_test)

    def test_crash_artifacts_stay_outside_strict_roots(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        lifecycle = POWERSHELL_TEST.read_text(encoding="utf-8")
        self.assertIn('New-HerdrTransaction -Kind "fresh"', helper)
        self.assertIn('New-HerdrTransaction -Kind "update"', helper)
        self.assertIn('New-HerdrTransaction -Kind "uninstall"', helper)
        self.assertIn("[IO.Directory]::Move($stagedRoot, $InstallRoot)", helper)
        self.assertNotIn('Join-Path $RuntimeRoot (".staging.', helper)
        self.assertIn("uninstall.pending", helper)
        self.assertIn("Assert-HerdrUninstallRetryRoot", helper)
        self.assertIn("Complete-HerdrDeadUninstallTransactions", helper)
        self.assertIn("Remove-HerdrUninstallResidual", helper)
        self.assertNotIn(
            "A previous Herdr uninstall transaction is incomplete", helper
        )
        recovery = helper[
            helper.index("function Complete-HerdrDeadUninstallTransactions {") : helper.index(
                "function Test-HerdrLegacyLauncherHop {"
            )
        ]
        gate = recovery.index('Open-HerdrShareModeLock -Path (Join-Path $stateDir "launcher.lock")')
        process_check = recovery.index("$processes = @(Get-HerdrProcessSnapshot)", gate)
        bin_move = recovery.index('[IO.Directory]::Move($source', process_check)
        gate_release = recovery.index("$coordination.Dispose()", bin_move)
        self.assertLess(gate, process_check)
        self.assertLess(process_check, bin_move)
        self.assertLess(bin_move, gate_release)
        self.assertIn("Dead uninstall transaction survived setup recovery", lifecycle)
        self.assertIn("Exact uninstall residual did not recover", lifecycle)
        self.assertIn("Uninstall retained its dead transaction", lifecycle)

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

    def test_path_updates_preserve_raw_registry_ownership(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        lifecycle = POWERSHELL_TEST.read_text(encoding="utf-8")
        for required in (
            "Resolve-HerdrUserPathUpdate",
            "RegistryValueOptions]::DoNotExpandEnvironmentNames",
            "RegistryValueKind]::ExpandString",
            'GetValueKind("PathAdded")',
            "RegistryValueKind]::DWord",
            "Get-HerdrArpPathOwnership",
            'Name "PathAdded"',
            "-InstallerOwned $pathOwned",
        ):
            self.assertIn(required, helper)
        self.assertNotIn('[Environment]::SetEnvironmentVariable("Path"', helper)
        self.assertIn("Equivalent user PATH entry was claimed", lifecycle)
        self.assertIn("remove exactly one owned literal entry", lifecycle)
        self.assertIn("PATH registry kind changed after removal", lifecycle)
        self.assertIn("REG_SZ PATH ownership was accepted", lifecycle)
        self.assertIn("REG_QWORD PATH ownership was accepted", lifecycle)

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
        self.assertIn("spawn_payload", (PROJECT_ROOT / "src/platform/windows/launcher.rs").read_text(encoding="utf-8"))
        self.assertNotIn(
            "runtime_launcher_path",
            MANAGED_INSTALL.read_text(encoding="utf-8"),
        )

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
            "ARG_SKILL_HASH_MANIFEST",
            "ARG_ARTWORK_DIR",
            "APP_BUILD_ID",
            "APP_OUTPUT_PATH",
            "APP_START_GATE_ENV",
            "APP_TEST_MARKER_PREFIX",
            "INFO_PRODUCTNAME",
            "INFO_DISTRIBUTIONNAME",
            "INFO_COMPANYNAME",
            "INFO_COPYRIGHT",
            "INFO_PRODUCTURL",
            "INFO_UPSTREAMURL",
            "INFO_COMMANDNAME",
            "INFO_ORIGINALFILENAME",
            "INFO_PRODUCTVERSION_DISPLAY",
            "INFO_PRODUCTVERSION_FIXED",
            "INFO_PRODUCTVERSION_UI",
        ):
            self.assertIn(f"!ifndef {required}", nsi)
        self.assertNotRegex(nsi, re.compile(r"herdr", re.IGNORECASE))
        self.assertIn('Name "${INFO_DISTRIBUTIONNAME}"', nsi)
        self.assertIn('Caption "${INFO_DISTRIBUTIONNAME} Setup"', nsi)
        self.assertNotIn("BrandingText", nsi)
        self.assertIn('!include "MUI2.nsh"', nsi)
        self.assertIn('!include "nsDialogs.nsh"', nsi)
        self.assertIn('!include "WinMessages.nsh"', nsi)
        self.assertIn("SendMessageTimeoutW", nsi)
        self.assertIn("APP_ENVIRONMENT_BROADCAST_TIMEOUT_MS 100", nsi)
        self.assertEqual(
            nsi.count("i ${APP_ENVIRONMENT_BROADCAST_TIMEOUT_MS}"), 2
        )
        self.assertNotIn("SendNotifyMessage", nsi)
        self.assertIn('-ProductName "${INFO_DISTRIBUTIONNAME}"', nsi)
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
            '!insertmacro MUI_PAGE_LICENSE "${ARG_STAGE_DIR}\\LICENSE.txt"',
            "!insertmacro MUI_PAGE_INSTFILES",
            "!insertmacro MUI_PAGE_FINISH",
        )
        positions = [nsi.index(page) for page in page_order]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("Page custom WelcomePage", nsi)
        self.assertNotIn("Function WelcomePage", nsi)
        self.assertNotIn("MUI_PAGE_DIRECTORY", nsi)
        self.assertNotIn("MUI_PAGE_COMPONENTS", nsi)
        self.assertNotIn("MUI_LICENSEPAGE_TEXT_TOP", nsi)
        self.assertNotIn("MUI_LICENSEPAGE_TEXT_BOTTOM", nsi)
        self.assertNotIn("MUI_FINISHPAGE_RUN", nsi)
        self.assertNotIn("MUI_FINISHPAGE_SHOWREADME", nsi)
        self.assertIn(
            '!define MUI_FINISHPAGE_LINK "Open ${INFO_DISTRIBUTIONNAME} setup and usage guide"',
            nsi,
        )
        self.assertIn(
            '!define MUI_FINISHPAGE_LINK_LOCATION "${INFO_PRODUCTURL}"', nsi
        )
        self.assertIn(
            "!define MUI_PAGE_CUSTOMFUNCTION_SHOW PositionInstallerFinishLink",
            nsi,
        )
        self.assertIn("Function PositionInstallerFinishLink", nsi)
        self.assertIn("USER32::DrawTextW", nsi)
        self.assertIn("USER32::SetWindowPos(p $mui.FinishPage.Text", nsi)
        self.assertIn("USER32::SetWindowPos(p $mui.FinishPage.Link", nsi)
        self.assertIn(
            "This setup installs ${INFO_DISTRIBUTIONNAME}, an unofficial Windows distribution of ${INFO_PRODUCTNAME}",
            nsi,
        )
        self.assertIn(
            '!define MUI_WELCOMEPAGE_TITLE "Install ${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI}"',
            nsi,
        )
        self.assertIn(
            '!define MUI_FINISHPAGE_TITLE "${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI} is installed"',
            nsi,
        )
        welcome_text = next(
            line for line in nsi.splitlines() if line.startswith("!define MUI_WELCOMEPAGE_TEXT")
        )
        self.assertNotIn("$LOCALAPPDATA", welcome_text)
        self.assertNotIn("Programs\\${INFO_PRODUCTNAME}", welcome_text)
        self.assertIn("latest reviewed stable ${INFO_PRODUCTNAME} release", welcome_text)
        self.assertIn("Setup completed successfully", nsi)
        self.assertIn(
            "${INFO_DISTRIBUTIONNAME} is an unofficial distribution; the command remains ${INFO_COMMANDNAME}",
            nsi,
        )
        self.assertIn(
            '${NSD_CreateLink} 120u 185u 195u 10u "Open official ${INFO_PRODUCTNAME} project"',
            nsi,
        )
        self.assertIn("${NSD_OnClick} $UpstreamLink OpenInstallerUpstream", nsi)
        self.assertIn("Function OpenInstallerUpstream", nsi)
        self.assertIn('ExecShell open "${INFO_UPSTREAMURL}"', nsi)
        self.assertIn(
            'DetailPrint "Validating and activating ${INFO_DISTRIBUTIONNAME} ${INFO_PRODUCTVERSION_UI}..."',
            nsi,
        )
        self.assertNotIn(
            "${INFO_PRODUCTNAME} ${INFO_PRODUCTVERSION_DISPLAY} was installed", nsi
        )
        self.assertIn(
            "UninstPage custom un.SettingsPage un.SettingsPageLeave", nsi
        )
        self.assertIn("!insertmacro MUI_UNPAGE_INSTFILES", nsi)
        self.assertNotIn("UninstPage uninstConfirm", nsi)
        self.assertIn(
            "Uninstall always removes the managed program, user PATH entry, and Windows Installed Apps registration",
            nsi,
        )
        self.assertIn(
            "Remove installed ${INFO_PRODUCTNAME} skill copies, including customized SKILL.md files",
            nsi,
        )
        self.assertIn(
            "Also delete ${INFO_PRODUCTNAME} settings and session data", nsi
        )
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
        self.assertNotIn("/PARENT_PID=", nsi)
        self.assertNotIn("LegacyReleasesRoot", helper)
        self.assertNotIn("legacy-backup", helper)
        self.assertNotIn("[switch]$Silent", helper)
        self.assertIn("/TIMEOUT=120000", nsi)
        self.assertIn('ReadEnvStr $StartGate "${APP_START_GATE_ENV}"', nsi)
        self.assertIn("Call WaitForUpdaterStartGate", nsi)
        self.assertIn("IntCmp $0 600", nsi)
        self.assertIn('StrCpy $SettingsDisposition "Keep"', nsi)
        self.assertIn('StrCpy $SkillDisposition "Auto"', nsi)
        self.assertIn('${GetOptions} "$0" "/REMOVE_SETTINGS" $1', nsi)
        self.assertIn('${GetOptions} "$0" "/REMOVE_SKILL" $1', nsi)
        self.assertIn('StrCpy $SettingsDisposition "Remove"', nsi)
        self.assertNotIn("/KEEP_SETTINGS", nsi)
        self.assertIn('${NSD_Check} $SettingsCheckbox', nsi)
        self.assertIn('${NSD_Check} $SkillCheckbox', nsi)
        self.assertIn("-Action GetSkillRemovalDefault", nsi)
        self.assertIn('-SettingsDisposition "$SettingsDisposition"', nsi)
        self.assertIn('-SkillDisposition "$SkillDisposition"', nsi)
        self.assertIn('SettingsDisposition = "Keep"', helper)
        self.assertIn('SkillDisposition = "Auto"', helper)
        self.assertIn('if ($SettingsDisposition -ceq "Remove")', helper)
        self.assertIn("SetErrorLevel 1", nsi)
        self.assertIn("SetErrorLevel 0", nsi)
        self.assertIn("QuietUninstallString", helper)
        message_boxes = [match.start() for match in re.finditer(r"\bMessageBox\b", nsi)]
        self.assertEqual(len(message_boxes), 2)
        for position in message_boxes:
            self.assertIn("IfSilent", nsi[max(0, position - 120) : position])
        self.assertEqual(
            nsi.count('File /oname=installer-helper.ps1 "${ARG_HELPER_PS1}"'), 2
        )
        self.assertIn(
            '-File "$PLUGINSDIR\\installer-helper.ps1" -Action Uninstall', nsi
        )
        for forbidden_cleanup in (
            'Delete "$INSTDIR\\state\\uninstall.pending"',
            'Delete "$INSTDIR\\state\\launcher.lock"',
            'Delete "$INSTDIR\\state\\installer-helper.ps1"',
            'Delete "$INSTDIR\\uninstall.exe"',
            'RMDir "$INSTDIR"',
        ):
            self.assertNotIn(forbidden_cleanup, nsi)
        self.assertIn("Remove-HerdrUninstallResidual", helper)

    def test_helper_owns_fail_closed_optional_settings_removal(self) -> None:
        helper = HELPER.read_text(encoding="utf-8")
        cleanup = helper[
            helper.index("function Remove-HerdrUserSettings {") : helper.index(
                "function Install-HerdrSkillFile {"
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

    def test_helper_residual_cleanup_is_exact_locked_and_fault_injected(self) -> None:
        nsi = NSI.read_text(encoding="utf-8")
        helper = HELPER.read_text(encoding="utf-8")
        cleanup = helper[
            helper.index("function Assert-HerdrUninstallCleanupRoot {") : helper.index(
                "function Assert-HerdrInterruptedUninstallRoot {"
            )
        ]
        for exact_name in (
            '"state"',
            '"uninstall.exe"',
            '"installer-helper.ps1"',
            '"launcher.lock"',
            '"uninstall.pending"',
        ):
            self.assertIn(exact_name, cleanup)
        self.assertIn("Assert-HerdrUninstallCleanupRoot", cleanup)
        self.assertIn("Remove-HerdrUninstallResidual", cleanup)
        self.assertIn("Invoke-HerdrUninstallFault", cleanup)
        self.assertNotIn("Function un.ValidateResidualLayout", nsi)
        self.assertNotIn("AppUninstallFault", nsi)
        self.assertNotIn("RMDir /r", nsi)
        for stage in (
            "after-launcher-lock",
            "after-uninstall-pending",
            "after-installer-helper",
            "after-state-directory",
            "before-uninstaller",
        ):
            self.assertIn(f'"{stage}"', helper)
        lifecycle = helper[
            helper.index("function Invoke-HerdrUninstall {") : helper.index(
                "if ($MyInvocation.InvocationName -ne '.')"
            )
        ]
        self.assertIn("Invoke-HerdrLifecycleOperation", lifecycle)
        self.assertIn("Invoke-HerdrUninstallLayout", lifecycle)
        self.assertIn("Remove-HerdrUninstallFaultMarker", lifecycle)
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
        self.assertIn(
            '$skillHashManifest = Join-Path $projectRoot "packaging\\windows\\managed-skill-hashes.txt"',
            packager,
        )
        self.assertIn('"/DINFO_PRODUCTNAME=$ProductName"', packager)
        self.assertIn('$DistributionName = "Herdr Win"', packager)
        self.assertIn('"/DINFO_DISTRIBUTIONNAME=$DistributionName"', packager)
        self.assertIn('"/DINFO_COMPANYNAME=$CompanyName"', packager)
        self.assertIn('"/DINFO_COPYRIGHT=$Copyright"', packager)
        self.assertIn(
            '$ProductUrl = "https://github.com/User-3090/herdr-win"', packager
        )
        self.assertIn('"/DINFO_PRODUCTURL=$ProductUrl"', packager)
        self.assertIn(
            '$UpstreamUrl = "https://github.com/ogulcancelik/herdr"', packager
        )
        self.assertIn('"/DINFO_UPSTREAMURL=$UpstreamUrl"', packager)
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
        self.assertIn("$UiVersion = Assert-VersionIdentity", packager)
        self.assertIn('"/DINFO_PRODUCTVERSION_UI=$UiVersion"', packager)
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
