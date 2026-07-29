[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StageDir,
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [Parameter(Mandatory = $true)][string]$BuildId,
    [Parameter(Mandatory = $true)][string]$DisplayVersion,
    [Parameter(Mandatory = $true)][string]$NumericVersion,
    [Parameter(Mandatory = $true)][string]$OutputDir,
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
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\Herdr"
$arpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Herdr"
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
    Start-TestProcess -FilePath $uninstaller -Arguments @("/S")
    Wait-TestCondition -Description "test install cleanup" -Condition {
        -not (Test-Path -LiteralPath $installRoot)
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
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

try {
    foreach ($fault in $Faults) {
        $faultMarker = Join-Path $env:TEMP "herdr-uninstall-fault-$fault.once"
        if (Test-Path -LiteralPath $faultMarker) {
            Remove-Item -LiteralPath $faultMarker -Force
        }
        $installer = Join-Path $OutputDir "herdr-installer-fault-$fault.exe"
        if (Test-Path -LiteralPath $installer) {
            Remove-Item -LiteralPath $installer -Force
        }

        & $packager `
            -StageDir $StageDir `
            -LauncherExe $LauncherExe `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -OutputPath $installer `
            -TestUninstallFault $fault

        Start-TestProcess -FilePath $installer -Arguments @("/S")
        Wait-TestCondition -Description "fresh install for $fault" -Condition {
            (Test-Path -LiteralPath (Join-Path $installRoot "state\active")) -and
                (Test-Path -LiteralPath $arpKey)
        }

        $uninstaller = Join-Path $installRoot "uninstall.exe"
        Start-TestProcess -FilePath $uninstaller -Arguments @("/S")
        Wait-TestCondition -Description "first injected uninstall for $fault" -Condition {
            Test-Path -LiteralPath $faultMarker
        }
        Wait-TestUninstallerIdle
        if (-not (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
            throw "Injected uninstall $fault removed its retry executable."
        }

        Start-TestProcess -FilePath $uninstaller -Arguments @("/S")
        Wait-TestCondition -Description "retry uninstall for $fault" -Condition {
            -not (Test-Path -LiteralPath $installRoot) -and
                -not (Test-Path -LiteralPath $arpKey) -and
                -not (Test-Path -LiteralPath $faultMarker)
        }
        Write-Host "Uninstall fault retry passed: $fault"
    }
} finally {
    Remove-TestInstallIfPresent
    foreach ($fault in $allowedFaults) {
        $faultMarker = Join-Path $env:TEMP "herdr-uninstall-fault-$fault.once"
        if (Test-Path -LiteralPath $faultMarker) {
            Remove-Item -LiteralPath $faultMarker -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "Windows installer fault matrix passed."
