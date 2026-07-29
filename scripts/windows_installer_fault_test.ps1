[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [Parameter(Mandatory = $true)][string]$BuildId,
    [Parameter(Mandatory = $true)][string]$DisplayVersion,
    [Parameter(Mandatory = $true)][string]$NumericVersion,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$AgentUserProfileRoot,
    [string[]]$Faults = @(
        "after-uninstall-pending",
        "after-launcher-lock",
        "after-installer-helper",
        "after-state-directory",
        "before-uninstaller"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$packager = Join-Path $PSScriptRoot "package_windows_installer.ps1"
$originalUserProfile = $env:USERPROFILE
$originalLocalAppData = $env:LOCALAPPDATA
$ownsAgentUserProfile = [string]::IsNullOrWhiteSpace($AgentUserProfileRoot)
if ($ownsAgentUserProfile) {
    $AgentUserProfileRoot = Join-Path ([IO.Path]::GetTempPath()) ("hs-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $AgentUserProfileRoot | Out-Null
} elseif (-not (Test-Path -LiteralPath $AgentUserProfileRoot -PathType Container)) {
    throw "AgentUserProfileRoot must be an existing test-owned directory: $AgentUserProfileRoot"
}
$env:USERPROFILE = [IO.Path]::GetFullPath($AgentUserProfileRoot)
$env:LOCALAPPDATA = Join-Path $env:USERPROFILE "AppData\Local"
if (-not (Test-Path -LiteralPath $env:LOCALAPPDATA)) {
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
}
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\Herdr"
$arpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Herdr"
$skillSource = Join-Path $projectRoot "SKILL.md"
$skillRoot = Join-Path $env:USERPROFILE ".agents\skills\herdr"
$skillPath = Join-Path $skillRoot "SKILL.md"
$allowedFaults = @(
    "after-uninstall-pending",
    "after-launcher-lock",
    "after-installer-helper",
    "after-state-directory",
    "before-uninstaller"
)

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
    $entries = @(Get-ChildItem -LiteralPath $skillRoot -Force)
    if ($entries.Count -ne 1 -or $entries[0].Name -cne "SKILL.md" -or $entries[0].PSIsContainer) {
        throw "Managed installer did not replace the complete previous Herdr skill directory."
    }
    $expected = [Convert]::ToBase64String([IO.File]::ReadAllBytes($skillSource))
    $actual = [Convert]::ToBase64String([IO.File]::ReadAllBytes($skillPath))
    if ($actual -cne $expected) {
        throw "Managed installer did not publish the canonical root SKILL.md."
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
$skillsRoot = Split-Path -Parent $skillRoot
if (Test-Path -LiteralPath $skillsRoot -PathType Container) {
    $interruptedSkills = @(Get-ChildItem -LiteralPath $skillsRoot -Force -Directory | Where-Object {
        $_.Name -cmatch '^\.herdr-installer-skill\.[0-9a-f]{32}$'
    })
    if ($interruptedSkills.Count -ne 0) {
        throw "Fault test requires no interrupted Herdr agent skill transaction."
    }
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
        [IO.File]::WriteAllText($skillPath, "previous skill")
        [IO.File]::WriteAllText((Join-Path $skillRoot "previous-resources\old.txt"), "previous resource")

        & $packager `
            -StageDir $StageDir `
            -LauncherExe $LauncherExe `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -OutputPath $installer `
            -TestUninstallFault $fault

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

        $uninstaller = Join-Path $installRoot "uninstall.exe"
        [void](Start-TestProcess -FilePath $uninstaller -Arguments @("/S"))
        Wait-TestCondition -Description "first injected uninstall for $fault" -Condition {
            Test-Path -LiteralPath $faultMarker
        }
        Wait-TestUninstallerIdle
        if (Test-Path -LiteralPath $skillRoot) {
            throw "Injected uninstall $fault retained the unchanged owned Herdr skill."
        }
        if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
            throw "Injected uninstall $fault removed its retry executable."
        }

        [void](Start-TestProcess -FilePath $uninstaller -Arguments @("/S"))
        Wait-TestCondition -Description "retry uninstall for $fault" -Condition {
            -not (Test-Path -LiteralPath $installRoot) -and
                -not (Test-Path -LiteralPath $arpKey) -and
                -not (Test-Path -LiteralPath $faultMarker)
        }
        Write-Host "Uninstall fault retry passed: $fault"
    }

    $modifiedInstaller = Join-Path $OutputDir "herdr-installer-modified-skill-tree.exe"
    if (Test-Path -LiteralPath $modifiedInstaller) {
        Remove-Item -LiteralPath $modifiedInstaller -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $skillRoot "previous-resources") -Force | Out-Null
    [IO.File]::WriteAllText($skillPath, "previous skill")
    [IO.File]::WriteAllText((Join-Path $skillRoot "previous-resources\old.txt"), "previous resource")
    & $packager `
        -StageDir $StageDir `
        -LauncherExe $LauncherExe `
        -BuildId $BuildId `
        -DisplayVersion $DisplayVersion `
        -NumericVersion $NumericVersion `
        -OutputPath $modifiedInstaller
    $modifiedInstallExit = Start-TestProcess -FilePath $modifiedInstaller -Arguments @("/S")
    if ($modifiedInstallExit -ne 0) {
        throw "Modified-tree installer exited with $modifiedInstallExit."
    }
    Wait-TestCondition -Description "modified-tree install" -Condition {
        (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and
            (Test-Path -LiteralPath $arpKey)
    }
    Assert-TestSkillInstalled
    [IO.File]::WriteAllText((Join-Path $skillRoot "user.txt"), "preserve-file")
    New-Item -ItemType Directory -Path (Join-Path $skillRoot "resources") | Out-Null
    [IO.File]::WriteAllText((Join-Path $skillRoot "resources\nested.txt"), "preserve-nested")
    $modifiedUninstaller = Join-Path $installRoot "uninstall.exe"
    $modifiedUninstallExit = Start-TestProcess -FilePath $modifiedUninstaller -Arguments @("/S")
    if ($modifiedUninstallExit -ne 0) {
        throw "Modified-tree uninstaller exited with $modifiedUninstallExit."
    }
    Wait-TestCondition -Description "modified-tree uninstall" -Condition {
        -not (Test-Path -LiteralPath $installRoot) -and -not (Test-Path -LiteralPath $arpKey)
    }
    Wait-TestUninstallerIdle
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        throw "Modified skill tree uninstall removed SKILL.md."
    }
    if ([IO.File]::ReadAllText((Join-Path $skillRoot "user.txt")) -cne "preserve-file") {
        throw "Modified skill tree uninstall removed a user file."
    }
    if ([IO.File]::ReadAllText((Join-Path $skillRoot "resources\nested.txt")) -cne "preserve-nested") {
        throw "Modified skill tree uninstall removed nested user content."
    }
    Write-Host "Modified skill tree uninstall passed."
} finally {
    Remove-TestInstallIfPresent
    if (Test-Path -LiteralPath $skillRoot) {
        Remove-Item -LiteralPath $skillRoot -Recurse -Force -ErrorAction SilentlyContinue
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
    $env:USERPROFILE = $originalUserProfile
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($ownsAgentUserProfile -and (Test-Path -LiteralPath $AgentUserProfileRoot)) {
        Remove-Item -LiteralPath $AgentUserProfileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Windows installer fault matrix passed."
