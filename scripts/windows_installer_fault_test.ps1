[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [Parameter(Mandatory = $true)][string]$InstallerHelperExe,
    [Parameter(Mandatory = $true)][string]$BuildId,
    [Parameter(Mandatory = $true)][string]$DisplayVersion,
    [Parameter(Mandatory = $true)][string]$NumericVersion,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$ProductName = "Herdr",
    [string]$PackageName = "Herdr Win",
    [string]$AgentUserProfileRoot,
    [string[]]$Faults = @(
        "after-uninstall-pending",
        "after-launcher-lock",
        "after-installer-helper",
        "after-state-directory",
        "before-uninstaller",
        "after-uninstaller"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$packager = Join-Path $PSScriptRoot "package_windows_installer.ps1"
$originalUserProfile = $env:USERPROFILE
$originalLocalAppData = $env:LOCALAPPDATA
$originalClaudeConfigDir = $env:CLAUDE_CONFIG_DIR
$userEnvironmentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
if ($null -eq $userEnvironmentKey) {
    throw "HKCU\\Environment is unavailable; refusing to run the installer fault matrix."
}
try {
    $originalUserPathExists = @($userEnvironmentKey.GetValueNames()) -contains "Path"
    $originalUserPath = if ($originalUserPathExists) {
        $userEnvironmentKey.GetValue(
            "Path",
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
    } else {
        $null
    }
    $originalUserPathKind = if ($originalUserPathExists) {
        $userEnvironmentKey.GetValueKind("Path")
    } else {
        $null
    }
} finally {
    $userEnvironmentKey.Dispose()
}

if (-not ("HerdrTestEnvironmentBroadcast" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HerdrTestEnvironmentBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr parameter, string value, uint flags, uint timeout, out IntPtr result);
}
'@
}

function Restore-TestUserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    if ($null -eq $key) {
        throw "HKCU\\Environment is unavailable while restoring the installer fault test."
    }
    try {
        if ($originalUserPathExists) {
            $key.SetValue("Path", $originalUserPath, $originalUserPathKind)
        } else {
            $key.DeleteValue("Path", $false)
        }
    } finally {
        $key.Dispose()
    }

    $result = [IntPtr]::Zero
    $sent = [HerdrTestEnvironmentBroadcast]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [IntPtr]::Zero,
        "Environment",
        0x0002,
        100,
        [ref]$result
    )
    if ($sent -eq [IntPtr]::Zero) {
        throw "Restored the user PATH but failed to broadcast the environment change."
    }
}

function Assert-TestUserPathRestored {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
    if ($null -eq $key) {
        throw "HKCU\Environment is unavailable while verifying PATH restoration."
    }
    try {
        $actualExists = @($key.GetValueNames()) -contains "Path"
        if ($actualExists -ne $originalUserPathExists) {
            throw "Uninstall did not restore whether the user PATH value exists."
        }
        if ($actualExists) {
            $actualValue = $key.GetValue(
                "Path",
                $null,
                [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
            )
            $actualKind = $key.GetValueKind("Path")
            if ([string]$actualValue -cne [string]$originalUserPath -or $actualKind -ne $originalUserPathKind) {
                throw "Uninstall did not restore the exact user PATH value and registry kind. Expected '$originalUserPath' ($originalUserPathKind), got '$actualValue' ($actualKind)."
            }
        }
    } finally {
        $key.Dispose()
    }
}

$ownsAgentUserProfile = [string]::IsNullOrWhiteSpace($AgentUserProfileRoot)
function Remove-TestOwnedUserProfile {
    if (-not $ownsAgentUserProfile -or [string]::IsNullOrWhiteSpace($AgentUserProfileRoot)) {
        return
    }
    if (Test-Path -LiteralPath $AgentUserProfileRoot) {
        Remove-Item -LiteralPath $AgentUserProfileRoot -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $AgentUserProfileRoot) {
        throw "Installer fault test left its temporary user profile behind: $AgentUserProfileRoot"
    }
}

try {
if ($ownsAgentUserProfile) {
    $AgentUserProfileRoot = Join-Path ([IO.Path]::GetTempPath()) ("hs-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $AgentUserProfileRoot | Out-Null
} elseif (-not (Test-Path -LiteralPath $AgentUserProfileRoot -PathType Container)) {
    throw "AgentUserProfileRoot must be an existing test-owned directory: $AgentUserProfileRoot"
}
$AgentUserProfileRoot = [IO.Path]::GetFullPath($AgentUserProfileRoot)
$env:USERPROFILE = $AgentUserProfileRoot
$env:LOCALAPPDATA = Join-Path $env:USERPROFILE "AppData\Local"
$env:CLAUDE_CONFIG_DIR = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
}
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\$ProductName"
$arpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$PackageName"
$skillSource = Join-Path $projectRoot "skills\herdr\SKILL.md"
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills\herdr"
$skillPath = Join-Path $skillRoot "SKILL.md"
$claudeSkillRoot = Join-Path $env:CLAUDE_CONFIG_DIR "skills\herdr"
$claudeSkillPath = Join-Path $claudeSkillRoot "SKILL.md"
$settingsRoot = Join-Path $env:USERPROFILE ".herdr"
$inheritedUserProfileDecoy = Join-Path $AgentUserProfileRoot "inherited-userprofile-decoy"
New-Item -ItemType Directory -Path $inheritedUserProfileDecoy | Out-Null
$env:USERPROFILE = $inheritedUserProfileDecoy
$allowedFaults = @(
    "after-uninstall-pending",
    "after-launcher-lock",
    "after-installer-helper",
    "after-state-directory",
    "before-uninstaller",
    "after-uninstaller"
)
if ($ProductName -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?$') {
    throw "Invalid product name '$ProductName'."
}

function Wait-TestCondition {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$TimeoutMilliseconds = 30000
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "$Description did not reach terminal state within $TimeoutMilliseconds ms."
}

function Start-TestProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMilliseconds = 120000
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "$FilePath exceeded its $TimeoutMilliseconds ms process deadline."
        }
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function New-TestIdentityLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Identity
    )

    $source = "$Path.cs"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($source, @"
using System;
internal static class Program {
    public static int Main(string[] args) {
        if (args.Length == 1 && String.Equals(args[0], "--herdr-private-launcher-build-id-v1", StringComparison.Ordinal)) {
            Console.Out.WriteLine("$Identity");
            return 0;
        }
        return 64;
    }
}
"@, [Text.UTF8Encoding]::new($false))
    $compiler = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $compiler) {
        throw "The Windows .NET Framework C# compiler is required for the pending-update test."
    }
    $exitCode = Start-TestProcess -FilePath $compiler -Arguments @(
        "/nologo", "/target:exe", "/platform:x64", "/out:$Path", $source
    )
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Could not build the pending-update launcher fixture."
    }
}

function New-TestHelperPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$AppLauncher,
        [Parameter(Mandatory = $true)][string]$Uninstaller
    )

    if (Test-Path -LiteralPath $Root) {
        throw "Native helper package fixture already exists: $Root"
    }
    New-Item -ItemType Directory -Path $Root | Out-Null
    Copy-Item -LiteralPath $StageDir -Destination (Join-Path $Root "payload") -Recurse
    New-Item -ItemType Directory -Path (Join-Path $Root "skill") | Out-Null
    [IO.File]::Copy($AppLauncher, (Join-Path $Root "app-launcher.exe"), $false)
    [IO.File]::Copy($InstallerHelperExe, (Join-Path $Root "installer-helper.exe"), $false)
    [IO.File]::Copy($skillSource, (Join-Path $Root "skill\SKILL.md"), $false)
    [IO.File]::Copy(
        (Join-Path $projectRoot "packaging\windows\managed-skill-hashes.txt"),
        (Join-Path $Root "skill\managed-skill-hashes.txt"),
        $false
    )
    [IO.File]::Copy($Uninstaller, (Join-Path $Root "uninstall.exe"), $false)
}

function Start-TestLeaseHolder {
    param(
        [Parameter(Mandatory = $true)][string]$LeasePath,
        [Parameter(Mandatory = $true)][string]$ReadyPath
    )

    $escapedLease = $LeasePath.Replace("'", "''")
    $escapedReady = $ReadyPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
`$lease = [IO.File]::Open('$escapedLease', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
[IO.File]::WriteAllText('$escapedReady', 'ready')
try { Start-Sleep -Seconds 4 } finally { `$lease.Dispose() }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process -FilePath powershell.exe -ArgumentList @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded
    ) -PassThru -WindowStyle Hidden
}

function Invoke-TestQuietUninstall {
    $helper = Join-Path $installRoot "state\installer-helper.exe"
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "Native quiet-uninstall helper is missing: $helper"
    }
    $expected = ('"{0}" quiet-uninstall --install-root "{1}"' -f $helper, $installRoot)
    $actual = [string](Get-ItemProperty -LiteralPath $arpKey).QuietUninstallString
    if ($actual -cne $expected) {
        throw "ARP quiet uninstall command is not exact. Expected '$expected', got '$actual'."
    }
    return Start-TestProcess -FilePath $helper -Arguments @(
        "quiet-uninstall",
        "--install-root", ('"' + $installRoot + '"')
    )
}

function Wait-TestUninstallerIdle {
    param([int]$TimeoutMilliseconds = 30000)

    Wait-TestCondition -TimeoutMilliseconds $TimeoutMilliseconds -Description "uninstaller process tree" -Condition {
        @(Get-Process -Name "uninstall" -ErrorAction SilentlyContinue).Count -eq 0
    }
}

function Remove-TestInstallIfPresent {
    if (-not (Test-Path -LiteralPath $installRoot)) {
        return
    }
    $uninstaller = Join-Path $installRoot "uninstall.exe"
    if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        throw "Cannot safely clean unexpected test install root: $installRoot"
    }
    foreach ($fault in $allowedFaults) {
        [IO.File]::WriteAllText(
            (Join-Path $env:TEMP "herdr-uninstall-fault-$fault.once"),
            "cleanup"
        )
    }
    [void](Start-TestProcess -FilePath $uninstaller -Arguments @("/S"))
    Wait-TestCondition -Description "test install cleanup" -Condition {
        -not (Test-Path -LiteralPath $installRoot)
    }
}

function Assert-TestSkillInstalled {
    $skillText = (New-Object Text.UTF8Encoding($false, $true)).GetString([IO.File]::ReadAllBytes($skillSource))
    $skillValidationText = $skillText.Replace("`r`n", "`n")
    if ($skillValidationText.Contains("`r") -or
        -not $skillValidationText.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Managed skill source must use valid line endings and end with a newline."
    }
    $expectedBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($skillValidationText)
    $expected = [Convert]::ToBase64String($expectedBytes)
    foreach ($candidate in @($skillPath, $claudeSkillPath)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Managed installer did not publish SKILL.md: $candidate"
        }
        $actual = [Convert]::ToBase64String([IO.File]::ReadAllBytes($candidate))
        if ($actual -cne $expected) {
            throw "Managed installer did not publish the canonical SKILL.md: $candidate"
        }
    }
    foreach ($sibling in @(
        (Join-Path $skillRoot "previous-resources\old.txt"),
        (Join-Path $claudeSkillRoot "previous-resources\old.txt")
    )) {
        if ([IO.File]::ReadAllText($sibling) -cne "previous resource") {
            throw "Managed installer removed or changed a foreign skill sibling: $sibling"
        }
    }
}

foreach ($fault in $Faults) {
    if ($allowedFaults -cnotcontains $fault) {
        throw "Unsupported uninstall fault point: $fault"
    }
}
if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
    throw "Project root is missing: $projectRoot"
}
if (Test-Path -LiteralPath $installRoot) {
    throw "Fault test requires no existing Herdr install: $installRoot"
}
if (Test-Path -LiteralPath $arpKey) {
    throw "Fault test requires no existing Herdr ARP registration."
}
if (Test-Path -LiteralPath $skillRoot) {
    throw "Fault test requires no existing cross-agent Herdr skill: $skillRoot"
}
if (Test-Path -LiteralPath $claudeSkillRoot) {
    throw "Fault test requires no existing Claude Herdr skill: $claudeSkillRoot"
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

try {
    foreach ($fault in $Faults) {
        $faultMarker = Join-Path $env:TEMP "herdr-uninstall-fault-$fault.once"
        $installFailure = Join-Path $env:TEMP "herdr-install-failure-$fault.txt"
        if (Test-Path -LiteralPath $faultMarker) {
            Remove-Item -LiteralPath $faultMarker -Force
        }
        if (Test-Path -LiteralPath $installFailure) {
            Remove-Item -LiteralPath $installFailure -Force
        }
        $installer = Join-Path $OutputDir "herdr-installer-fault-$fault.exe"
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force
        }
        New-Item -ItemType Directory -Path (Join-Path $skillRoot "previous-resources") -Force | Out-Null
        [IO.File]::Copy($skillSource, $skillPath, $true)
        [IO.File]::WriteAllText((Join-Path $skillRoot "previous-resources\old.txt"), "previous resource")
        New-Item -ItemType Directory -Path (Join-Path $claudeSkillRoot "previous-resources") -Force | Out-Null
        [IO.File]::Copy($skillSource, $claudeSkillPath, $true)
        [IO.File]::WriteAllText((Join-Path $claudeSkillRoot "previous-resources\old.txt"), "previous resource")

        & $packager `
            -StageDir $StageDir `
            -LauncherExe $LauncherExe `
            -InstallerHelperExe $InstallerHelperExe `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -ProductName $ProductName `
            -OutputPath $installer `
            -TestUninstallFault $fault `
            -TestUserProfileRoot $AgentUserProfileRoot

        $installExitCode = Start-TestProcess -FilePath $installer -Arguments @("/S")
        if ($installExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $installFailure -PathType Leaf) {
                [IO.File]::ReadAllText($installFailure)
            } else {
                "no installer diagnostic was produced"
            }
            throw "Fresh installer for $fault exited with $installExitCode`: $detail"
        }
        try {
            Wait-TestCondition -Description "fresh install for $fault" -Condition {
                (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and
                    (Test-Path -LiteralPath $arpKey)
            }
        } catch {
            throw "Fresh install for $fault did not publish expected state at $installRoot (root=$(Test-Path -LiteralPath $installRoot), active=$(Test-Path -LiteralPath (Join-Path $installRoot 'state\active')), arp=$(Test-Path -LiteralPath $arpKey), exit=$installExitCode)."
        }
        Assert-TestSkillInstalled
        New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $settingsRoot "settings.toml"), "preserve-by-default")

        $uninstaller = Join-Path $installRoot "uninstall.exe"
        $firstQuietExit = Invoke-TestQuietUninstall
        if ($firstQuietExit -eq 0) {
            throw "Quiet uninstall reported success after injected failure $fault."
        }
        Wait-TestCondition -Description "first injected uninstall for $fault" -Condition {
            Test-Path -LiteralPath $faultMarker
        }
        Wait-TestUninstallerIdle
        if (Test-Path -LiteralPath $skillPath) {
            throw "Injected uninstall $fault retained universal SKILL.md."
        }
        if (Test-Path -LiteralPath $claudeSkillPath) {
            throw "Injected uninstall $fault retained Claude SKILL.md."
        }
        if ([IO.File]::ReadAllText((Join-Path $skillRoot "previous-resources\old.txt")) -cne "previous resource" -or
            [IO.File]::ReadAllText((Join-Path $claudeSkillRoot "previous-resources\old.txt")) -cne "previous resource") {
            throw "Injected uninstall $fault removed a foreign skill sibling."
        }
        if ([IO.File]::ReadAllText((Join-Path $settingsRoot "settings.toml")) -cne "preserve-by-default") {
            throw "Injected uninstall $fault did not preserve settings by default."
        }
        if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
            throw "Injected uninstall $fault removed its retry executable."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $installRoot "state\installer-helper.exe") -PathType Leaf)) {
            throw "Injected uninstall $fault removed its native quiet retry helper."
        }

        $retryQuietExit = Invoke-TestQuietUninstall
        if ($retryQuietExit -ne 0) {
            throw "Quiet uninstall retry $fault exited with $retryQuietExit."
        }
        Wait-TestCondition -Description "retry uninstall for $fault" -Condition {
            -not (Test-Path -LiteralPath $installRoot) -and
                -not (Test-Path -LiteralPath $arpKey) -and
                -not (Test-Path -LiteralPath $faultMarker)
        }
        if ([IO.File]::ReadAllText((Join-Path $settingsRoot "settings.toml")) -cne "preserve-by-default") {
            throw "Retry uninstall $fault did not preserve settings by default."
        }
        Remove-Item -LiteralPath $settingsRoot -Recurse -Force
        Write-Host "Uninstall fault retry passed: $fault"
    }

    $modifiedInstaller = Join-Path $OutputDir "herdr-installer-modified-skill-tree.exe"
    if (Test-Path -LiteralPath $modifiedInstaller) {
        Remove-Item -LiteralPath $modifiedInstaller -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $skillRoot "previous-resources") -Force | Out-Null
    [IO.File]::Copy($skillSource, $skillPath, $true)
    [IO.File]::WriteAllText((Join-Path $skillRoot "previous-resources\old.txt"), "previous resource")
    New-Item -ItemType Directory -Path (Join-Path $claudeSkillRoot "previous-resources") -Force | Out-Null
    [IO.File]::Copy($skillSource, $claudeSkillPath, $true)
    [IO.File]::WriteAllText((Join-Path $claudeSkillRoot "previous-resources\old.txt"), "previous resource")
    & $packager `
        -StageDir $StageDir `
        -LauncherExe $LauncherExe `
        -InstallerHelperExe $InstallerHelperExe `
        -BuildId $BuildId `
        -DisplayVersion $DisplayVersion `
        -NumericVersion $NumericVersion `
        -ProductName $ProductName `
        -OutputPath $modifiedInstaller `
        -TestUserProfileRoot $AgentUserProfileRoot
    $modifiedInstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S", "/WINGETjunk")
    if ($modifiedInstallExit -ne 0) {
        throw "Modified-tree installer exited with $modifiedInstallExit."
    }
    Wait-TestCondition -Description "modified-tree install" -Condition {
        (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and
            (Test-Path -LiteralPath $arpKey)
    }
    Assert-TestSkillInstalled
    if (Test-Path -LiteralPath (Join-Path $installRoot "state\package-manager")) {
        throw "Setup accepted /WINGETjunk as package-manager ownership."
    }
    $wingetInstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S", "/WINGET")
    if ($wingetInstallExit -ne 0) {
        throw "Exact /WINGET setup exited with $wingetInstallExit."
    }
    $packageManagerMarker = [IO.File]::ReadAllText((Join-Path $installRoot "state\package-manager")).Replace("`r`n", "`n")
    if ($packageManagerMarker -cne "herdr-package-manager-v1`nmanager=winget`n") {
        throw "Setup did not accept exact /WINGET package-manager ownership."
    }
    [IO.File]::WriteAllText($skillPath, "customized universal skill")
    [IO.File]::WriteAllText($claudeSkillPath, "customized Claude skill")
    New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $settingsRoot "settings.toml"), "remove-explicitly")
    [IO.File]::WriteAllText((Join-Path $skillRoot "user.txt"), "preserve-file")
    New-Item -ItemType Directory -Path (Join-Path $skillRoot "resources") | Out-Null
    [IO.File]::WriteAllText((Join-Path $skillRoot "resources\nested.txt"), "preserve-nested")
    $modifiedUninstaller = Join-Path $installRoot "uninstall.exe"
    $prefixUninstallExit = Start-TestProcess -FilePath $modifiedUninstaller -Arguments @("/S", "/REMOVE_SETTINGSjunk", "/REMOVE_SKILLjunk")
    if ($prefixUninstallExit -ne 0) {
        throw "Prefix-option uninstall exited with $prefixUninstallExit."
    }
    Wait-TestCondition -Description "prefix-option uninstall" -Condition {
        -not (Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $arpKey)
    }
    Wait-TestUninstallerIdle
    if (-not (Test-Path -LiteralPath $settingsRoot) -or -not (Test-Path -LiteralPath $skillPath) -or -not (Test-Path -LiteralPath $claudeSkillPath)) {
        throw "A destructive option prefix was accepted as an exact uninstall flag."
    }
    $reinstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S")
    if ($reinstallExit -ne 0) {
        throw "Reinstall after prefix-option test exited with $reinstallExit."
    }
    Wait-TestCondition -Description "reinstall after prefix-option test" -Condition {
        (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and (Test-Path -LiteralPath $arpKey)
    }
    if ([IO.File]::ReadAllText($skillPath) -cne "customized universal skill" -or
        [IO.File]::ReadAllText($claudeSkillPath) -cne "customized Claude skill") {
        throw "Reinstall after prefix-option test overwrote customized skill content."
    }
    $modifiedUninstaller = Join-Path $installRoot "uninstall.exe"
    $modifiedUninstallExit = Start-TestProcess -FilePath $modifiedUninstaller -Arguments @("/S", "/REMOVE_SETTINGS", "/REMOVE_SKILL")
    if ($modifiedUninstallExit -ne 0) {
        throw "Modified-tree uninstaller exited with $modifiedUninstallExit."
    }
    Wait-TestCondition -Description "modified-tree uninstall" -Condition {
        -not (Test-Path -LiteralPath $installRoot) -and
            -not (Test-Path -LiteralPath $arpKey) -and
            -not (Test-Path -LiteralPath $settingsRoot)
    }
    Wait-TestUninstallerIdle
    if (Test-Path -LiteralPath $skillPath) {
        throw "Sibling-preserving uninstall retained universal SKILL.md."
    }
    if (Test-Path -LiteralPath $claudeSkillPath) {
        throw "Sibling-preserving uninstall retained Claude SKILL.md."
    }
    if ([IO.File]::ReadAllText((Join-Path $skillRoot "user.txt")) -cne "preserve-file") {
        throw "Modified skill tree uninstall removed a user file."
    }
    if ([IO.File]::ReadAllText((Join-Path $skillRoot "resources\nested.txt")) -cne "preserve-nested") {
        throw "Modified skill tree uninstall removed nested user content."
    }
    if ([IO.File]::ReadAllText((Join-Path $claudeSkillRoot "previous-resources\old.txt")) -cne "previous resource") {
        throw "Sibling-preserving uninstall removed Claude skill content."
    }
    if (Test-Path -LiteralPath $settingsRoot) {
        throw "Uninstall ignored /REMOVE_SETTINGS."
    }
    Write-Host "Sibling-preserving skill uninstall passed."

    # Explicit settings cleanup is best effort after application/integration
    # removal. A real running image under .herdr keeps only that residual while
    # setup files, ARP registration, and the installer-owned PATH entry disappear.
    $lockedStateInstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S")
    if ($lockedStateInstallExit -ne 0) {
        throw "Locked-state test install exited with $lockedStateInstallExit."
    }
    Wait-TestCondition -Description "locked-state test install" -Condition {
        (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and (Test-Path -LiteralPath $arpKey)
    }
    New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $settingsRoot "settings.toml"), "preserve-locked-residual")
    $lockedStateExecutable = Join-Path $settingsRoot "locked-state.exe"
    $systemPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    [IO.File]::Copy($systemPowerShell, $lockedStateExecutable, $false)
    $lockedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("Start-Sleep -Seconds 30"))
    $lockedStateProcess = Start-Process -FilePath $lockedStateExecutable -ArgumentList @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $lockedCommand
    ) -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Milliseconds 250
        if ($lockedStateProcess.HasExited) {
            throw "Locked-state process exited before uninstall."
        }
        $lockedStateUninstaller = Join-Path $installRoot "uninstall.exe"
        $lockedStateUninstallExit = Start-TestProcess -FilePath $lockedStateUninstaller -Arguments @("/S", "/REMOVE_SETTINGS")
        if ($lockedStateUninstallExit -ne 0) {
            throw "Locked-state uninstall exited with $lockedStateUninstallExit."
        }
        Wait-TestCondition -Description "locked-state uninstall" -Condition {
            -not (Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $arpKey)
        }
        Wait-TestUninstallerIdle
        if ($lockedStateProcess.HasExited) {
            throw "Locked-state process did not remain active through uninstall."
        }
        if (-not (Test-Path -LiteralPath $settingsRoot -PathType Container) -or
            -not (Test-Path -LiteralPath $lockedStateExecutable -PathType Leaf)) {
            throw "Locked-state uninstall did not preserve its undeletable settings residual."
        }
        Assert-TestUserPathRestored
        Write-Host "Locked settings residual remained nonblocking."
    } finally {
        if (-not $lockedStateProcess.HasExited) {
            $lockedStateProcess.Kill()
            [void]$lockedStateProcess.WaitForExit(5000)
        }
        $lockedStateProcess.Dispose()
        if (Test-Path -LiteralPath $settingsRoot) {
            Remove-Item -LiteralPath $settingsRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $reparseStateInstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S")
    if ($reparseStateInstallExit -ne 0) {
        throw "Reparse-state test install exited with $reparseStateInstallExit."
    }
    Wait-TestCondition -Description "reparse-state test install" -Condition {
        (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and (Test-Path -LiteralPath $arpKey)
    }
    New-Item -ItemType Directory -Path $settingsRoot -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $settingsRoot "settings.toml"), "preserve-reparse-residual")
    $reparseStateTarget = Join-Path $AgentUserProfileRoot "settings-reparse-target"
    New-Item -ItemType Directory -Path $reparseStateTarget | Out-Null
    [IO.File]::WriteAllText((Join-Path $reparseStateTarget "outside.txt"), "preserve-external")
    $reparseStateLink = Join-Path $settingsRoot "external"
    New-Item -ItemType Junction -Path $reparseStateLink -Target $reparseStateTarget | Out-Null
    try {
        $reparseStateUninstaller = Join-Path $installRoot "uninstall.exe"
        $reparseStateUninstallExit = Start-TestProcess -FilePath $reparseStateUninstaller -Arguments @("/S", "/REMOVE_SETTINGS")
        if ($reparseStateUninstallExit -ne 0) {
            throw "Reparse-state uninstall exited with $reparseStateUninstallExit."
        }
        Wait-TestCondition -Description "reparse-state uninstall" -Condition {
            -not (Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $arpKey)
        }
        Wait-TestUninstallerIdle
        if ([IO.File]::ReadAllText((Join-Path $settingsRoot "settings.toml")) -cne "preserve-reparse-residual" -or
            [IO.File]::ReadAllText((Join-Path $reparseStateTarget "outside.txt")) -cne "preserve-external") {
            throw "Reparse-state uninstall changed preserved settings or junction-target content."
        }
        Assert-TestUserPathRestored
        Write-Host "Reparse settings residual remained nonblocking."
    } finally {
        if (Test-Path -LiteralPath $reparseStateLink) {
            [IO.Directory]::Delete($reparseStateLink)
        }
        if (Test-Path -LiteralPath $settingsRoot) {
            Remove-Item -LiteralPath $settingsRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $reparseStateTarget) {
            Remove-Item -LiteralPath $reparseStateTarget -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # A running old runtime keeps activation pending. The installed launcher
    # promotes the new runtime after the lease exits, then the native helper
    # publishes the matching launcher and removes the obsolete runtime.
    $pendingRoot = Join-Path $OutputDir "native-pending-update"
    $oldPackage = Join-Path $pendingRoot "old-package"
    $newPackage = Join-Path $pendingRoot "new-package"
    $newBuildId = "fedcba987654.3210fedcba98"
    $newDisplayVersion = $DisplayVersion.Substring(0, $DisplayVersion.Length - $BuildId.Length) + $newBuildId
    $newLauncher = Join-Path $pendingRoot "new-launcher\app-launcher.exe"
    New-TestIdentityLauncher -Path $newLauncher -Identity $newBuildId
    New-TestHelperPackage -Root $oldPackage -AppLauncher $LauncherExe -Uninstaller $modifiedInstaller
    New-TestHelperPackage -Root $newPackage -AppLauncher $newLauncher -Uninstaller $modifiedInstaller
    $oldInstallExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments @(
        "install",
        "--install-root", $installRoot,
        "--user-profile-root", $AgentUserProfileRoot,
        "--package-root", $oldPackage,
        "--build-id", $BuildId,
        "--display-version", $DisplayVersion,
        "--numeric-version", $NumericVersion,
        "--install-manager", "Direct"
    )
    if ($oldInstallExit -ne 0) {
        throw "Native helper pending-update fixture install exited with $oldInstallExit."
    }
    $repairLease = Join-Path $installRoot "state\leases\$BuildId.lease"
    [IO.File]::WriteAllText($repairLease, "")
    Remove-Item -LiteralPath (Join-Path $installRoot "state\installer-helper.exe") -Force
    $repairInstallExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments @(
        "install",
        "--install-root", $installRoot,
        "--user-profile-root", $AgentUserProfileRoot,
        "--package-root", $oldPackage,
        "--build-id", $BuildId,
        "--display-version", $DisplayVersion,
        "--numeric-version", $NumericVersion,
        "--install-manager", "Direct"
    )
    if ($repairInstallExit -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot "state\installer-helper.exe") -PathType Leaf) -or
        -not (Test-Path -LiteralPath $repairLease -PathType Leaf)) {
        throw "Native setup did not narrowly repair a missing installed helper."
    }
    Write-Host "Native missing-helper repair passed."
    $leaseReady = Join-Path $pendingRoot "lease-ready"
    $leaseHolder = Start-TestLeaseHolder `
        -LeasePath (Join-Path $installRoot "state\leases\$BuildId.lease") `
        -ReadyPath $leaseReady
    try {
        Wait-TestCondition -Description "pending-update lease holder" -Condition {
            Test-Path -LiteralPath $leaseReady -PathType Leaf
        }
        $pendingInstallExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments @(
            "install",
            "--install-root", $installRoot,
            "--user-profile-root", $AgentUserProfileRoot,
            "--package-root", $newPackage,
            "--build-id", $newBuildId,
            "--display-version", $newDisplayVersion,
            "--numeric-version", $NumericVersion,
            "--install-manager", "Direct"
        )
        if ($pendingInstallExit -ne 0) {
            throw "Native helper pending update exited with $pendingInstallExit."
        }
        $activeText = [IO.File]::ReadAllText((Join-Path $installRoot "state\active")).Replace("`r`n", "`n")
        $pendingText = [IO.File]::ReadAllText((Join-Path $installRoot "state\pending")).Replace("`r`n", "`n")
        if ($activeText -cne "herdr-pointer-v1`nbuild_id=$BuildId`n" -or
            $pendingText -cne "herdr-pointer-v1`nbuild_id=$newBuildId`n") {
            throw "Native helper did not preserve active and pending pointer ownership while the old lease was live."
        }
    } finally {
        if (-not $leaseHolder.WaitForExit(15000)) {
            $leaseHolder.Kill()
            [void]$leaseHolder.WaitForExit(5000)
        }
        $leaseHolder.Dispose()
    }
    $launcherExit = Start-TestProcess -FilePath (Join-Path $installRoot "bin\herdr.exe") -Arguments @("--version")
    if ($launcherExit -ne 0) {
        throw "Installed launcher could not activate the pending runtime; exit code $launcherExit."
    }
    $expectedLauncherHash = (Get-FileHash -LiteralPath $newLauncher -Algorithm SHA256).Hash
    Wait-TestCondition -Description "native pending-update maintenance" -Condition {
        $active = Join-Path $installRoot "state\active"
        (Test-Path -LiteralPath $active -PathType Leaf) -and
            ([IO.File]::ReadAllText($active).Replace("`r`n", "`n") -ceq "herdr-pointer-v1`nbuild_id=$newBuildId`n") -and
            -not (Test-Path -LiteralPath (Join-Path $installRoot "state\pending")) -and
            -not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$BuildId")) -and
            ((Get-FileHash -LiteralPath (Join-Path $installRoot "bin\herdr.exe") -Algorithm SHA256).Hash -ceq $expectedLauncherHash)
    }
    $nativeUninstallArguments = @(
        "uninstall",
        "--install-root", $installRoot,
        "--user-profile-root", $AgentUserProfileRoot,
        "--skill-hash-manifest", (Join-Path $newPackage "skill\managed-skill-hashes.txt"),
        "--settings-disposition", "Keep",
        "--skill-disposition", "Auto"
    )
    $malformedPendingLauncher = Join-Path $installRoot "state\launcher.pending-not-a-hash.exe"
    [IO.File]::WriteAllText($malformedPendingLauncher, "preserve")
    $malformedPendingExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments $nativeUninstallArguments
    if ($malformedPendingExit -eq 0 -or
        -not (Test-Path -LiteralPath $malformedPendingLauncher -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot "bin\herdr.exe") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$newBuildId") -PathType Container) -or
        -not (Test-Path -LiteralPath $arpKey) -or
        -not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        throw "Malformed pending-launcher state did not fail closed before uninstall mutation."
    }
    Remove-Item -LiteralPath $malformedPendingLauncher -Force

    $validArpDisplayVersion = [string](Get-ItemProperty -LiteralPath $arpKey).DisplayVersion
    Set-ItemProperty -LiteralPath $arpKey -Name DisplayVersion -Value "$validArpDisplayVersion.extra"
    $malformedArpExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments $nativeUninstallArguments
    if ($malformedArpExit -eq 0 -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot "bin\herdr.exe") -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$newBuildId") -PathType Container) -or
        -not (Test-Path -LiteralPath $arpKey) -or
        -not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        throw "Malformed ARP display identity did not fail closed before uninstall mutation."
    }
    Set-ItemProperty -LiteralPath $arpKey -Name DisplayVersion -Value $validArpDisplayVersion

    $nativeUninstallExit = Start-TestProcess -FilePath $InstallerHelperExe -Arguments $nativeUninstallArguments
    if ($nativeUninstallExit -ne 0) {
        throw "Native helper pending-update fixture uninstall exited with $nativeUninstallExit."
    }
    Wait-TestCondition -Description "native pending-update cleanup" -Condition {
        -not (Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $arpKey)
    }
    Assert-TestUserPathRestored
    Write-Host "Native pending-update activation passed."
} finally {
    Remove-TestInstallIfPresent
    if (Test-Path -LiteralPath $skillRoot) {
        Remove-Item -LiteralPath $skillRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $claudeSkillRoot) {
        Remove-Item -LiteralPath $claudeSkillRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $settingsRoot) {
        Remove-Item -LiteralPath $settingsRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($fault in $allowedFaults) {
        $faultMarker = Join-Path $env:TEMP "herdr-uninstall-fault-$fault.once"
        if (Test-Path -LiteralPath $faultMarker) {
            Remove-Item -LiteralPath $faultMarker -Force -ErrorAction SilentlyContinue
        }
        $installFailure = Join-Path $env:TEMP "herdr-install-failure-$fault.txt"
        if (Test-Path -LiteralPath $installFailure) {
            Remove-Item -LiteralPath $installFailure -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "Windows installer fault matrix passed."
} finally {
    $env:USERPROFILE = $originalUserProfile
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:CLAUDE_CONFIG_DIR = $originalClaudeConfigDir
    try {
        Restore-TestUserPath
    } finally {
        Remove-TestOwnedUserProfile
    }
}
