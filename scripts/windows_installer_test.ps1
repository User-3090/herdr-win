[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $projectRoot "packaging\windows\herdr-installer-helper.ps1"
. $helperPath

function Assert-True {
    param([Parameter(Mandatory = $true)][bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()]$Actual, [AllowNull()]$Expected, [Parameter(Mandatory = $true)][string]$Message)
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $thrown = $false
    try {
        & $Script
    } catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message Unexpected error: $($_.Exception.Message)"
        }
        $thrown = $true
    }
    if (-not $thrown) { throw "$Message Expected an exception matching '$Pattern'." }
}

function Write-TestFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function New-TestStage {
    param([string]$Root, [string]$Name, [string]$PayloadText)
    $stage = Join-Path $Root $Name
    $files = @(
        "herdr.exe",
        "conpty\herdr-conpty.json",
        "conpty\conpty.dll",
        "conpty\x64\OpenConsole.exe",
        "conpty\arm64\OpenConsole.exe",
        "THIRD-PARTY-NOTICES\Microsoft.Windows.Console.ConPTY-LICENSE.txt",
        "THIRD-PARTY-NOTICES\Microsoft.Windows.Console.ConPTY-NOTICE.md"
    )
    foreach ($relative in $files) {
        Write-TestFile -Path (Join-Path $stage $relative) -Text "$PayloadText/$relative"
    }
    return $stage
}

function Invoke-TestInstall {
    param(
        [string]$Root,
        [string]$Stage,
        [string]$Launcher,
        [string]$Uninstaller,
        [string]$BuildId,
        [string]$DisplayVersion,
        [string]$NumericVersion,
        [string]$LegacyReleases,
        [string]$LegacyLock,
        [scriptblock]$ProcessProvider = { @() },
        [long]$ParentPid = 0,
        [int]$LockTimeoutMilliseconds = 3000
    )
    return Invoke-HerdrLifecycleOperation -InstallRoot $Root -TimeoutMilliseconds $LockTimeoutMilliseconds -Operation {
        Install-HerdrLayout `
            -InstallRoot $Root `
            -StageDir $Stage `
            -LauncherPath $Launcher `
            -UninstallerPath $Uninstaller `
            -HelperSourcePath $helperPath `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -LegacyReleasesRoot $LegacyReleases `
            -LegacyInstallLockPath $LegacyLock `
            -ProcessProvider $ProcessProvider `
            -ParentPid $ParentPid `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    }
}

function Invoke-TestUninstall {
    param(
        [string]$Root,
        [scriptblock]$ProcessProvider = { @() },
        [int]$LockTimeoutMilliseconds = 3000
    )
    Invoke-HerdrLifecycleOperation -InstallRoot $Root -TimeoutMilliseconds $LockTimeoutMilliseconds -Operation {
        Invoke-HerdrUninstallLayout `
            -InstallRoot $Root `
            -ProcessProvider $ProcessProvider `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    }
}

function Wait-TestPath {
    param([string]$Path, [int]$TimeoutMilliseconds = 5000)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw "Timed out waiting for test path $Path"
        }
        Start-Sleep -Milliseconds 50
    }
}

function Start-TestSharedFileHolder {
    param([string]$Path, [string]$ReadyPath, [int]$Seconds = 3)
    $escapedPath = $Path.Replace("'", "''")
    $escapedReady = $ReadyPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
`$file = [IO.File]::Open('$escapedPath', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
[IO.File]::WriteAllText('$escapedReady', 'ready')
try { Start-Sleep -Seconds $Seconds } finally { `$file.Dispose() }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded) -PassThru -WindowStyle Hidden
}

function Start-TestLifecycleTransactionOwner {
    param([string]$HelperPath, [string]$InstallRoot, [string]$ReadyPath, [int]$Seconds = 3)
    $escapedHelper = $HelperPath.Replace("'", "''")
    $escapedRoot = $InstallRoot.Replace("'", "''")
    $escapedReady = $ReadyPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
. '$escapedHelper'
Invoke-HerdrLifecycleOperation -InstallRoot '$escapedRoot' -TimeoutMilliseconds 3000 -Operation {
    `$transaction = New-HerdrTransaction -Kind 'fresh' -InstallRoot '$escapedRoot'
    New-Item -ItemType Directory -Path (Join-Path `$transaction.Path 'root') | Out-Null
    Write-HerdrDurableText -Path (Join-Path `$transaction.Path 'root\live.txt') -Text 'live'
    [IO.File]::WriteAllText('$escapedReady', `$transaction.Path)
    Start-Sleep -Seconds $Seconds
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded) -PassThru -WindowStyle Hidden
}

function Complete-TestNsisCleanup {
    param([string]$Root)
    $state = Join-Path $Root "state"
    Remove-Item -LiteralPath (Join-Path $state "uninstall.pending") -Force
    Remove-Item -LiteralPath (Join-Path $state "launcher.lock") -Force
    Remove-Item -LiteralPath (Join-Path $Root "uninstall.exe") -Force
    Remove-Item -LiteralPath (Join-Path $state "installer-helper.ps1") -Force
    Remove-Item -LiteralPath $state -Force
    Remove-Item -LiteralPath $Root -Force
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("hi-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$junctionPath = $null
$childProcesses = New-Object System.Collections.Generic.List[Diagnostics.Process]
$registryPath = "HKCU:\Software\HerdrInstallerTests\$([Guid]::NewGuid().ToString('N'))"
try {
    $id1 = "0123456789ab.cdef01234567"
    $id2 = "fedcba987654.3210fedcba98"
    $display1 = "0.9.0-preview.$id1"
    $display2 = "0.9.1-preview.$id2"
    $numeric1 = "0.9.0.0"
    $numeric2 = "0.9.1.0"
    $launcher1 = Join-Path $tempRoot "launcher-one.exe"
    $launcher2 = Join-Path $tempRoot "launcher-two.exe"
    $uninstaller = Join-Path $tempRoot "uninstall.exe"
    Write-TestFile -Path $launcher1 -Text "launcher-one"
    Write-TestFile -Path $launcher2 -Text "launcher-two"
    Write-TestFile -Path $uninstaller -Text "uninstaller"
    $stage1 = New-TestStage -Root $tempRoot -Name "stage-one" -PayloadText "payload-one"
    $stage2 = New-TestStage -Root $tempRoot -Name "stage-two" -PayloadText "payload-two"
    $legacyReleases = Join-Path $tempRoot "legacy-home\releases"
    $legacyLock = Join-Path $tempRoot "legacy-home\install.lock"
    New-Item -ItemType Directory -Path $legacyReleases -Force | Out-Null

    # A persistent sibling lifecycle lock protects a live transaction from a
    # second real PowerShell process before any recovery/classification runs.
    $concurrencyRoot = Join-Path $tempRoot "concurrent-install"
    $concurrencyReady = Join-Path $tempRoot "concurrency-ready"
    $transactionOwner = Start-TestLifecycleTransactionOwner -HelperPath $helperPath -InstallRoot $concurrencyRoot -ReadyPath $concurrencyReady -Seconds 3
    $childProcesses.Add($transactionOwner)
    Wait-TestPath -Path $concurrencyReady -TimeoutMilliseconds 15000
    $liveTransaction = [IO.File]::ReadAllText($concurrencyReady)
    Assert-HerdrTransaction -Path $liveTransaction -Kind "fresh" -InstallRoot $concurrencyRoot
    Assert-Throws {
        Invoke-HerdrLifecycleOperation -InstallRoot $concurrencyRoot -TimeoutMilliseconds 250 -Operation {
            Remove-HerdrRecoverableInstallTransactions -InstallRoot $concurrencyRoot
        }
    } "Timed out after 250 ms" "A second lifecycle invocation entered while the first owned a live transaction."
    Assert-True (Test-Path -LiteralPath (Join-Path $liveTransaction "root\live.txt")) "Contending lifecycle invocation deleted a live transaction."
    if (-not $transactionOwner.WaitForExit(10000)) { throw "Lifecycle transaction owner did not exit within 10 seconds." }
    if ($transactionOwner.ExitCode -ne 0) { throw "Lifecycle transaction owner exited with $($transactionOwner.ExitCode)." }
    Invoke-HerdrLifecycleOperation -InstallRoot $concurrencyRoot -TimeoutMilliseconds 3000 -Operation {
        Remove-HerdrRecoverableInstallTransactions -InstallRoot $concurrencyRoot
    }
    Assert-True (-not (Test-Path -LiteralPath $liveTransaction)) "Completed lifecycle transaction was not recovered after lock release."
    $persistentLifecycleLock = Get-HerdrLifecycleLockPath -InstallRoot $concurrencyRoot
    Assert-HerdrRegularFile -Path $persistentLifecycleLock
    Assert-Equal (Get-Item -LiteralPath $persistentLifecycleLock).Length ([long]0) "Persistent lifecycle lock is not an empty regular file."

    # Exact record parsing and PATH idempotence remain strict.
    $recordRoot = Join-Path $tempRoot "records"
    New-Item -ItemType Directory -Path $recordRoot | Out-Null
    $pointer = Join-Path $recordRoot "active"
    Write-HerdrDurableText -Path $pointer -Text (Get-HerdrPointerText -BuildId $id1)
    Assert-Equal (Read-HerdrPointer -Path $pointer) $id1 "Exact pointer failed."
    [IO.File]::WriteAllText($pointer, "herdr-pointer-v1`r`nbuild_id=$id1`r`n", $script:Utf8NoBom)
    Assert-Throws { Read-HerdrPointer -Path $pointer } "Invalid Herdr pointer" "CRLF pointer was accepted."
    Assert-Throws {
        Assert-HerdrVersionIdentity -DisplayVersion "0.9.0-$id1" -NumericVersion $numeric1 -BuildId $id1
    } "must be <major>" "Non-preview display identity was accepted."
    Assert-Throws {
        Assert-HerdrVersionIdentity -DisplayVersion $display1 -NumericVersion "0.8.0.0" -BuildId $id1
    } "does not match display version" "Mismatched numeric identity was accepted."
    $binEntry = Join-Path $tempRoot "path-test\bin"
    $pathInput = "C:\Other;;`"$binEntry\`";C:\Keep;$($binEntry.ToUpperInvariant())"
    $pathOnce = Add-HerdrPathEntry -PathValue $pathInput -Entry $binEntry
    Assert-Equal (Add-HerdrPathEntry -PathValue $pathOnce -Entry $binEntry) $pathOnce "PATH insertion was not idempotent."
    Assert-Equal (Remove-HerdrPathEntry -PathValue $pathOnce -Entry $binEntry) "C:\Other;;C:\Keep" "PATH removal changed unrelated entries."

    # A complete fresh tree is built in a sibling transaction and retries clean
    # both complete and partial pre-publication artifacts.
    $installRoot = Join-Path $tempRoot "managed-install"
    $emptyFreshCrash = "$installRoot.installer-fresh.$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $emptyFreshCrash | Out-Null
    $crashFresh = New-HerdrTransaction -Kind "fresh" -InstallRoot $installRoot
    New-HerdrManagedRootTree `
        -Destination (Join-Path $crashFresh.Path "root") `
        -StageDir $stage1 `
        -LauncherPath $launcher1 `
        -UninstallerPath $uninstaller `
        -HelperSourcePath $helperPath `
        -BuildId $id1 `
        -DisplayVersion $display1 `
        -NumericVersion $numeric1
    Remove-Item -LiteralPath (Join-Path $crashFresh.Path "root\runtime\$id1\herdr.exe") -Force
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) "Fresh staging mutated InstallRoot before publication."
    $fresh = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    Assert-Equal $fresh.Status "Activated" "Fresh install did not activate."
    Assert-True (-not (Test-Path -LiteralPath $emptyFreshCrash)) "Empty pre-marker transaction was not recovered."
    Assert-True (-not (Test-Path -LiteralPath $crashFresh.Path)) "Fresh crash transaction was not recovered."
    Assert-HerdrManagedRoot -InstallRoot $installRoot
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $installRoot "bin\managed-install-v1\marker")) "herdr-managed-bin-v1`n" "Managed-bin sentinel is wrong."
    Assert-True (-not (Test-HerdrRecognizedLegacyPayload -Path (Join-Path $installRoot "bin"))) "Old installer could mistake managed bin for legacy payload."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) (Get-HerdrSha256 -Path $launcher1) "Fresh bootstrap differs from launcher input."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "runtime\$id1\herdr-launcher.exe")) (Get-HerdrSha256 -Path $launcher1) "Fresh runtime dispatcher is missing."

    # Runtime and pointer crash artifacts are external and recoverable. A real
    # second PowerShell process holds the old build lease across the upgrade.
    $runtimeCrash = New-HerdrTransaction -Kind "update" -InstallRoot $installRoot
    New-Item -ItemType Directory -Path (Join-Path $runtimeCrash.Path "runtime") | Out-Null
    Write-TestFile -Path (Join-Path $runtimeCrash.Path "runtime\partial") -Text "partial"
    $pointerCrash = New-HerdrTransaction -Kind "update" -InstallRoot $installRoot
    New-Item -ItemType Directory -Path (Join-Path $pointerCrash.Path "metadata") | Out-Null
    Write-TestFile -Path (Join-Path $pointerCrash.Path "metadata\pending") -Text "partial pointer"
    $leasePath = Join-Path $installRoot "state\leases\$id1.lease"
    $leaseReady = Join-Path $tempRoot "lease-ready"
    $leaseProcess = Start-TestSharedFileHolder -Path $leasePath -ReadyPath $leaseReady -Seconds 3
    $childProcesses.Add($leaseProcess)
    Wait-TestPath -Path $leaseReady
    $pending = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    Assert-Equal $pending.Status "Pending" "Second-process lease did not produce pending success."
    Assert-True (-not (Test-Path -LiteralPath $runtimeCrash.Path)) "Runtime crash transaction was not recovered."
    Assert-True (-not (Test-Path -LiteralPath $pointerCrash.Path)) "Pointer crash transaction was not recovered."
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $installRoot "state\active")) $id1 "Busy upgrade changed active."
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $installRoot "state\pending")) $id2 "Busy upgrade did not publish pending."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) (Get-HerdrSha256 -Path $launcher1) "Upgrade replaced immutable bootstrap."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "runtime\$id2\herdr-launcher.exe")) (Get-HerdrSha256 -Path $launcher2) "Upgrade did not carry the new dispatcher."
    if (-not $leaseProcess.WaitForExit(10000)) { throw "Lease holder did not exit within 10 seconds." }
    $activated = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    Assert-Equal $activated.Status "Activated" "Released lease did not activate pending."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "state\pending"))) "Activation retained pending."
    Write-HerdrDurableText -Path (Join-Path $installRoot "state\pending") -Text (Get-HerdrPointerText -BuildId $id1)
    $alreadyActive = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    Assert-Equal $alreadyActive.Status "AlreadyActive" "Same-build reinstall did not report already active."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "state\pending"))) "Same-build reinstall retained an obsolete pending build."

    # Coordination uses bounded FileShare.None probes against a real holder.
    $lockReady = Join-Path $tempRoot "lock-ready"
    $lockProcess = Start-TestSharedFileHolder -Path (Join-Path $installRoot "state\launcher.lock") -ReadyPath $lockReady -Seconds 2
    $childProcesses.Add($lockProcess)
    Wait-TestPath -Path $lockReady
    Assert-Throws {
        Open-HerdrShareModeLock -Path (Join-Path $installRoot "state\launcher.lock") -TimeoutMilliseconds 250
    } "Timed out after 250 ms" "Coordination lock did not use a bounded share-mode deadline."
    if (-not $lockProcess.WaitForExit(10000)) { throw "Coordination holder did not exit within 10 seconds." }

    # Same-build corruption and arbitrary files/directories are rejected and preserved.
    $extraDirectory = Join-Path $installRoot "runtime\$id2\user-empty"
    New-Item -ItemType Directory -Path $extraDirectory | Out-Null
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    } "neither an exact managed nor recognized legacy layout|owned-directory set" "Same-build extra directory was accepted."
    Assert-True (Test-Path -LiteralPath $extraDirectory) "Rejected same-build directory was deleted."
    Remove-Item -LiteralPath $extraDirectory -Force
    $extra = Join-Path $installRoot "runtime\$id2\user-content.txt"
    Write-TestFile -Path $extra -Text "preserve"
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    } "neither an exact managed nor recognized legacy layout|owned-file set" "Same-build extra content was accepted."
    Assert-True (Test-Path -LiteralPath $extra) "Rejected same-build content was deleted."
    Remove-Item -LiteralPath $extra -Force
    $runtimePayload = Join-Path $installRoot "runtime\$id2\herdr.exe"
    $ownedPayloadBytes = [IO.File]::ReadAllBytes((Join-Path $stage2 "herdr.exe"))
    [IO.File]::WriteAllText($runtimePayload, "corrupt", $script:Utf8NoBom)
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    } "neither an exact managed nor recognized legacy layout|hash mismatch" "Same-build hash corruption was accepted."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $runtimePayload) "corrupt" "Rejected corruption was silently repaired or deleted."
    [IO.File]::WriteAllBytes($runtimePayload, $ownedPayloadBytes)
    Assert-HerdrManagedRoot -InstallRoot $installRoot

    # Legacy publication uses the canonical lock, preserves an exact backup and
    # permits only the supplied parent runtime whether Windows reports its
    # visible junction path or its physical release path.
    $legacyTarget = Join-Path $legacyReleases "legacy-release"
    New-Item -ItemType Directory -Path $legacyTarget -Force | Out-Null
    Write-TestFile -Path (Join-Path $legacyTarget "herdr.exe") -Text "legacy"
    $legacyRoot = Join-Path $tempRoot "legacy-visible"
    New-Item -ItemType Directory -Path $legacyRoot | Out-Null
    $junctionPath = Join-Path $legacyRoot "bin"
    New-Item -ItemType Junction -Path $junctionPath -Target $legacyTarget | Out-Null
    $parentProcesses = @([PSCustomObject]@{ ProcessId = 444; ExecutablePath = (Join-Path $junctionPath "herdr.exe"); Name = "herdr.exe" })
    $migrated = Invoke-TestInstall -Root $legacyRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -LegacyReleases $legacyReleases -LegacyLock $legacyLock -ProcessProvider { $parentProcesses } -ParentPid 444
    $junctionPath = $null
    Assert-Equal $migrated.Status "Activated" "Recognized legacy root did not migrate."
    Assert-True (Test-Path -LiteralPath (Join-Path $legacyTarget "herdr.exe")) "Live parent runtime was deleted."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$migrated.LegacyBackup)) "Legacy migration did not preserve a backup."
    Assert-HerdrLegacyRoot -Root $migrated.LegacyBackup -LegacyReleasesRoot $legacyReleases
    Assert-True (Test-Path -LiteralPath $legacyLock) "Canonical legacy install lock was not acquired."

    # An interrupted legacy move is rolled back before a new migration.
    $rollbackRoot = Join-Path $tempRoot "legacy-rollback"
    New-Item -ItemType Directory -Path (Join-Path $rollbackRoot "bin") -Force | Out-Null
    Write-TestFile -Path (Join-Path $rollbackRoot "bin\herdr.exe") -Text "legacy-direct"
    $orphanBackup = "$rollbackRoot.legacy-backup.$([Guid]::NewGuid().ToString('N'))"
    [IO.Directory]::Move($rollbackRoot, $orphanBackup)
    $recovered = Invoke-TestInstall -Root $rollbackRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -LegacyReleases $legacyReleases -LegacyLock $legacyLock
    Assert-Equal $recovered.Status "Activated" "Legacy backup recovery did not finish migration."
    Assert-HerdrManagedRoot -InstallRoot $rollbackRoot

    # ARP stores the truthful display/numeric identity and preserves mismatches.
    Set-HerdrArpRegistration -InstallRoot $installRoot -DisplayVersion $display2 -NumericVersion $numeric2 -RegistryPath $registryPath
    $arp = Get-ItemProperty -LiteralPath $registryPath
    Assert-Equal ([string]$arp.DisplayVersion) $display2 "ARP display version is not truthful."
    Assert-Equal ([int]$arp.VersionMajor) 0 "ARP major version is wrong."
    Set-ItemProperty -LiteralPath $registryPath -Name InstallLocation -Value (Join-Path $tempRoot "someone-else")
    Assert-Throws { Remove-HerdrArpRegistration -InstallRoot $installRoot -RegistryPath $registryPath } "not owned" "Mismatched ARP key was removed."
    Remove-Item -LiteralPath $registryPath -Recurse -Force

    # Any process image under InstallRoot refuses uninstall. Use an actual
    # copied PowerShell executable and let it exit naturally.
    $processRoot = Join-Path $tempRoot "process-busy-install"
    $realLauncher = Join-Path $env:WINDIR "System32\cmd.exe"
    [void](Invoke-TestInstall -Root $processRoot -Stage $stage1 -Launcher $realLauncher -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -LegacyReleases $legacyReleases -LegacyLock $legacyLock)
    $busyProcess = Start-Process -FilePath (Join-Path $processRoot "bin\herdr.exe") -ArgumentList @("/d", "/c", "ping -n 4 127.0.0.1 >nul") -PassThru -WindowStyle Hidden
    $childProcesses.Add($busyProcess)
    Start-Sleep -Milliseconds 200
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -ProcessProvider { Get-HerdrProcessSnapshot } -LockTimeoutMilliseconds 3000
    } "process from the managed Herdr install tree" "Process-tree busy uninstall was accepted."
    Assert-HerdrManagedRoot -InstallRoot $processRoot
    if (-not $busyProcess.WaitForExit(10000)) { throw "Managed process did not exit within 10 seconds." }

    # Crash after uninstall marker/bin move is retryable; exact transaction
    # ownership is validated before deletion and helper remains for NSIS last.
    $stagedMarkerTx = New-HerdrTransaction -Kind "uninstall" -InstallRoot $processRoot
    Copy-HerdrDurableFile -Source (Join-Path $processRoot "state\install.manifest") -Destination (Join-Path $stagedMarkerTx.Path "root.manifest")
    Write-HerdrDurableText -Path (Join-Path $stagedMarkerTx.Path "uninstall.pending") -Text $script:UninstallMarkerText
    $uninstallTx = New-HerdrTransaction -Kind "uninstall" -InstallRoot $processRoot
    Copy-HerdrDurableFile -Source (Join-Path $processRoot "state\install.manifest") -Destination (Join-Path $uninstallTx.Path "root.manifest")
    Write-HerdrDurableText -Path (Join-Path $processRoot "state\uninstall.pending") -Text $script:UninstallMarkerText
    [IO.Directory]::Move((Join-Path $processRoot "bin"), (Join-Path $uninstallTx.Path "bin"))
    Write-HerdrUninstallCleanupManifest -Path $uninstallTx.Path
    Remove-Item -LiteralPath (Join-Path $uninstallTx.Path "bin\herdr.exe") -Force
    $unownedUninstallFile = Join-Path $uninstallTx.Path "unowned.txt"
    Write-TestFile -Path $unownedUninstallFile -Text "preserve"
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    } "unowned file" "Partial uninstall cleanup accepted an unowned survivor."
    Assert-True (Test-Path -LiteralPath $unownedUninstallFile) "Rejected partial-uninstall content was deleted."
    Remove-Item -LiteralPath $unownedUninstallFile -Force
    $unownedUninstallDirectory = Join-Path $uninstallTx.Path "bin\unexpected-empty"
    New-Item -ItemType Directory -Path $unownedUninstallDirectory | Out-Null
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    } "unowned directory" "Partial uninstall cleanup accepted an unowned empty directory."
    Assert-True (Test-Path -LiteralPath $unownedUninstallDirectory) "Rejected partial-uninstall directory was deleted."
    Remove-Item -LiteralPath $unownedUninstallDirectory -Force
    Invoke-TestUninstall -Root $processRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    Assert-HerdrUninstallResidual -InstallRoot $processRoot
    Assert-True (Test-Path -LiteralPath (Join-Path $processRoot "state\installer-helper.ps1")) "Retry helper was removed before NSIS cleanup."
    Complete-TestNsisCleanup -Root $processRoot

    # Active lease refusal preserves the complete primary install.
    $refusalLease = [IO.File]::Open(
        (Join-Path $installRoot "state\leases\$id2.lease"),
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::ReadWrite
    )
    try {
        Assert-Throws { Invoke-TestUninstall -Root $installRoot -ProcessProvider { @() } } "still active" "Lease-active uninstall was accepted."
        Assert-HerdrManagedRoot -InstallRoot $installRoot
    } finally {
        $refusalLease.Dispose()
    }
    Invoke-TestUninstall -Root $installRoot -ProcessProvider { @() }
    Assert-HerdrUninstallResidual -InstallRoot $installRoot
    Complete-TestNsisCleanup -Root $installRoot

    Write-Host "Windows installer PowerShell tests passed."
} finally {
    foreach ($process in $childProcesses) {
        if (-not $process.HasExited) {
            if (-not $process.WaitForExit(10000)) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        }
        $process.Dispose()
    }
    if ($null -ne $junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
        [IO.Directory]::Delete($junctionPath)
    }
    if (Test-Path -LiteralPath $registryPath) {
        Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
