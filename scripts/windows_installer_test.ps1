[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$helperPath = Join-Path $projectRoot "packaging\windows\herdr-installer-helper.ps1"
$script:TestUninstallRunnerSource = Join-Path $projectRoot "packaging\windows\uninstall-runner.ps1"
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

function New-TestLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    Assert-HerdrBuildId -Value $BuildId
    $sourcePath = "$Path.cs"
    Write-TestFile -Path $sourcePath -Text @"
using System;
using System.Threading;
internal static class Program {
    public static int Main(string[] args) {
        if (args.Length == 1 && String.Equals(args[0], "--herdr-private-launcher-build-id-v1", StringComparison.Ordinal)) {
            Console.Out.WriteLine("$BuildId");
            return 0;
        }
        if (args.Length == 1 && String.Equals(args[0], "--wait", StringComparison.Ordinal)) {
            Thread.Sleep(3000);
            return 0;
        }
        return 64;
    }
}
"@
    $csc = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $csc) {
        throw "The Windows .NET Framework C# compiler is required for launcher lifecycle tests."
    }
    & $csc /nologo /target:exe "/out:$Path" $sourcePath
    if ($LASTEXITCODE -ne 0) {
        throw "Test launcher compilation failed with exit code $LASTEXITCODE."
    }
    Assert-HerdrRegularFile -Path $Path
}

function New-TestStage {
    param([string]$Root, [string]$Name, [string]$PayloadText)
    $stage = Join-Path $Root $Name
    $files = @(
        "herdr.exe",
        "LICENSE.txt",
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
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct",
        [string]$SkillSource = $script:TestSkillSource,
        [string]$SkillHashManifestPath = $script:TestSkillHashManifest,
        [string]$AgentSkillsRoot = $script:TestAgentSkillsRoot,
        [string]$ClaudeSkillsRoot,
        [int]$LockTimeoutMilliseconds = 3000
    )
    return Invoke-HerdrLifecycleOperation -InstallRoot $Root -TimeoutMilliseconds $LockTimeoutMilliseconds -Operation {
        Install-HerdrLayout `
            -InstallRoot $Root `
            -StageDir $Stage `
            -LauncherPath $Launcher `
            -UninstallerPath $Uninstaller `
            -HelperSourcePath $helperPath `
            -UninstallRunnerPath $script:TestUninstallRunnerSource `
            -SkillSourcePath $SkillSource `
            -SkillHashManifestPath $SkillHashManifestPath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -ClaudeSkillsRoot $ClaudeSkillsRoot `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -InstallManager $InstallManager `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    }
}

function Invoke-TestUninstall {
    param(
        [string]$Root,
        [string]$AgentSkillsRoot = $script:TestAgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @(),
        [string]$SkillHashManifestPath = $script:TestSkillHashManifest,
        [ValidateSet("Keep", "Auto", "Remove")][string]$SkillDisposition = "Auto",
        [scriptblock]$ProcessProvider = { @() },
        [int]$LockTimeoutMilliseconds = 3000
    )
    $knownSkillHashes = @(Read-HerdrManagedSkillHashes -Path $SkillHashManifestPath)
    Invoke-HerdrLifecycleOperation -InstallRoot $Root -TimeoutMilliseconds $LockTimeoutMilliseconds -Operation {
        Invoke-HerdrUninstallLayout `
            -InstallRoot $Root `
            -AgentSkillsRoot $AgentSkillsRoot `
            -ClaudeSkillsRoots $ClaudeSkillsRoots `
            -KnownSkillHashes $knownSkillHashes `
            -SkillDisposition $SkillDisposition `
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
    param([string]$Path, [string]$ReadyPath, [int]$Seconds = 3, [ValidateSet("ReadWrite", "None")][string]$ShareMode = "ReadWrite")
    $escapedPath = $Path.Replace("'", "''")
    $escapedReady = $ReadyPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
`$file = [IO.File]::Open('$escapedPath', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::$ShareMode)
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

function Start-TestLifecycleProbe {
    param([string]$HelperPath, [string]$InstallRoot, [string]$ResultPath, [int]$TimeoutMilliseconds = 250)
    $escapedHelper = $HelperPath.Replace("'", "''")
    $escapedRoot = $InstallRoot.Replace("'", "''")
    $escapedResult = $ResultPath.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
. '$escapedHelper'
try {
    Invoke-HerdrLifecycleOperation -InstallRoot '$escapedRoot' -TimeoutMilliseconds $TimeoutMilliseconds -Operation { }
    [IO.File]::WriteAllText('$escapedResult', 'acquired')
} catch {
    [IO.File]::WriteAllText('$escapedResult', ('blocked:' + `$_.Exception.Message))
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    return Start-Process powershell.exe -ArgumentList @("-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", $encoded) -PassThru -WindowStyle Hidden
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("hi-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$faultMarkerPrefix = "hi" + [Guid]::NewGuid().ToString("N").Substring(0, 12)
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$childProcesses = New-Object System.Collections.Generic.List[Diagnostics.Process]
$registryPath = "HKCU:\Software\HerdrInstallerTests\$([Guid]::NewGuid().ToString('N'))"
try {
    $id1 = "0123456789ab.cdef01234567"
    $id2 = "fedcba987654.3210fedcba98"
    $display1 = "0.9.0-preview.$id1"
    $display2 = "0.9.1-preview.$id2"
    $numeric1 = "0.9.0.0"
    $numeric2 = "0.9.1.0"
    $launcher1 = Join-Path $tempRoot "launcher-one\herdr-launcher.exe"
    $launcher2 = Join-Path $tempRoot "launcher-two\herdr-launcher.exe"
    $wrongLauncher = Join-Path $tempRoot "launcher-wrong\herdr-launcher.exe"
    $uninstaller = Join-Path $tempRoot "uninstall.exe"
    New-TestLauncher -Path $launcher1 -BuildId $id1
    New-TestLauncher -Path $launcher2 -BuildId $id2
    New-TestLauncher -Path $wrongLauncher -BuildId $id1
    Write-TestFile -Path $uninstaller -Text "uninstaller"
    $stage1 = New-TestStage -Root $tempRoot -Name "stage-one" -PayloadText "payload-one"
    $stage2 = New-TestStage -Root $tempRoot -Name "stage-two" -PayloadText "payload-two"
    $script:TestSkillSource = Join-Path $tempRoot "skill-one\SKILL.md"
    $skillSource2 = Join-Path $tempRoot "skill-two\SKILL.md"
    $script:TestAgentSkillsRoot = Join-Path $tempRoot ".agents\skills"
    $script:TestClaudeSkillsRoot = Join-Path $tempRoot ".claude\skills"
    Write-TestFile -Path $script:TestSkillSource -Text "---`nname: herdr`ndescription: first`n---`n`n# Herdr one`n"
    Write-TestFile -Path $skillSource2 -Text "---`nname: herdr`ndescription: second`n---`n`n# Herdr two`n"
    $script:TestSkillHashManifest = Join-Path $tempRoot "managed-skill-hashes.txt"
    $testSkillHashes = @(
        (Get-HerdrSha256 -Path $script:TestSkillSource),
        (Get-HerdrSha256 -Path $skillSource2)
    ) | Sort-Object
    Write-TestFile -Path $script:TestSkillHashManifest -Text ("herdr-managed-skill-hashes-v1`n" + ($testSkillHashes -join "`n") + "`n")
    $parsedTestSkillHashes = @(Read-HerdrManagedSkillHashes -Path $script:TestSkillHashManifest -CurrentSkillPath $script:TestSkillSource)
    Assert-Equal $parsedTestSkillHashes.Count 2 "Managed skill hash manifest did not retain both known versions."
    $unsortedSkillHashManifest = Join-Path $tempRoot "unsorted-managed-skill-hashes.txt"
    Write-TestFile -Path $unsortedSkillHashManifest -Text ("herdr-managed-skill-hashes-v1`n" + (@($testSkillHashes[1], $testSkillHashes[0]) -join "`n") + "`n")
    Assert-Throws {
        Read-HerdrManagedSkillHashes -Path $unsortedSkillHashManifest
    } "unique and sorted" "Unsorted managed skill hashes were accepted."
    $missingCurrentSkillHashManifest = Join-Path $tempRoot "missing-current-managed-skill-hashes.txt"
    Write-TestFile -Path $missingCurrentSkillHashManifest -Text "herdr-managed-skill-hashes-v1`n$('0' * 64)`n"
    Assert-Throws {
        Read-HerdrManagedSkillHashes -Path $missingCurrentSkillHashManifest -CurrentSkillPath $script:TestSkillSource
    } "current Herdr agent skill hash is absent" "A manifest without the current skill payload was accepted."
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
    $v1Manifest = Join-Path $recordRoot "install-v1.manifest"
    Write-HerdrDurableText -Path $v1Manifest -Text ("herdr-install-manifest-v1`nbootstrap_sha256=" + (("0" * 64) -join "") + "`ndisplay_version=$display1`nnumeric_version=$numeric1`n")
    $parsedInstallManifest = Read-HerdrInstallManifestFile -Path $v1Manifest
    Assert-True ($null -eq $parsedInstallManifest.PSObject.Properties["SkillSha256"]) "Install manifest retained obsolete skill ownership."
    $crlfSkill = Join-Path $recordRoot "SKILL.md"
    [IO.File]::WriteAllText($crlfSkill, "---`r`nname: herdr`r`ndescription: crlf`r`n---`r`n", $script:Utf8NoBom)
    Assert-Equal (Get-HerdrAgentSkillSha256 -Path $crlfSkill) (Get-HerdrSha256 -Path $crlfSkill) "CRLF Herdr skill was rejected or normalized while hashing."

    # Optional settings cleanup removes only a regular .herdr tree below the
    # selected profile and refuses ambiguous files or reparse-point content.
    $settingsProfile = Join-Path $tempRoot "settings-profile"
    Write-TestFile -Path (Join-Path $settingsProfile ".herdr\sessions\one.json") -Text "session"
    Write-TestFile -Path (Join-Path $settingsProfile ".herdr\config.toml") -Text "settings"
    Remove-HerdrUserSettings -UserProfileRoot $settingsProfile
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $settingsProfile ".herdr"))) "Settings cleanup retained a regular .herdr tree."
    Remove-HerdrUserSettings -UserProfileRoot $settingsProfile

    $settingsFileProfile = Join-Path $tempRoot "settings-file-profile"
    New-Item -ItemType Directory -Path $settingsFileProfile | Out-Null
    $settingsFile = Join-Path $settingsFileProfile ".herdr"
    Write-TestFile -Path $settingsFile -Text "preserve-file"
    Assert-Throws {
        Remove-HerdrUserSettings -UserProfileRoot $settingsFileProfile
    } "regular directory is missing" "Settings cleanup accepted a .herdr file."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $settingsFile) "preserve-file" "Rejected settings file was changed."

    $settingsJunctionProfile = Join-Path $tempRoot "settings-junction-profile"
    $settingsJunctionRoot = Join-Path $settingsJunctionProfile ".herdr"
    $settingsExternal = Join-Path $tempRoot "settings-external"
    Write-TestFile -Path (Join-Path $settingsJunctionRoot "config.toml") -Text "preserve-settings"
    Write-TestFile -Path (Join-Path $settingsExternal "outside.txt") -Text "preserve-external"
    $settingsJunction = Join-Path $settingsJunctionRoot "external"
    New-Item -ItemType Junction -Path $settingsJunction -Target $settingsExternal | Out-Null
    try {
        Assert-Throws {
            Remove-HerdrUserSettings -UserProfileRoot $settingsJunctionProfile
        } "reparse point" "Settings cleanup followed a nested junction."
        Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $settingsJunctionRoot "config.toml")) "preserve-settings" "Rejected settings tree was partially deleted."
        Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $settingsExternal "outside.txt")) "preserve-external" "Settings cleanup changed junction-target content."
    } finally {
        if (Test-Path -LiteralPath $settingsJunction) {
            [IO.Directory]::Delete($settingsJunction)
        }
    }

    # Skill install/update changes only known SKILL.md versions. Unknown copies
    # survive with a warning, while foreign siblings always remain untouched.
    $agentForeign = Join-Path $script:TestAgentSkillsRoot "herdr\user.txt"
    $claudeForeign = Join-Path $script:TestClaudeSkillsRoot "herdr\resources\nested.txt"
    Write-TestFile -Path $agentForeign -Text "preserve-agent"
    Write-TestFile -Path (Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md") -Text "old-agent-skill"
    Write-TestFile -Path $claudeForeign -Text "preserve-claude"
    $preservedUnknownInstall = @(
        Install-HerdrSkillCopies `
            -SourcePath $script:TestSkillSource `
            -AgentSkillsRoot $script:TestAgentSkillsRoot `
            -ClaudeSkillsRoot $script:TestClaudeSkillsRoot `
            -KnownHashes $parsedTestSkillHashes
    )
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md")) "old-agent-skill" "Unknown universal SKILL.md was overwritten."
    Assert-Equal $preservedUnknownInstall.Count 1 "Unknown universal SKILL.md did not produce one preservation warning."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $script:TestClaudeSkillsRoot "herdr\SKILL.md")) (Get-HerdrSha256 -Path $script:TestSkillSource) "Claude skill copy differs from its source."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $agentForeign) "preserve-agent" "Universal skill install removed a foreign sibling."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $claudeForeign) "preserve-claude" "Claude skill install removed a foreign sibling."
    Assert-Equal (Get-HerdrSkillRemovalDefault -KnownHashes $parsedTestSkillHashes -AgentSkillsRoot $script:TestAgentSkillsRoot -ClaudeSkillsRoots @($script:TestClaudeSkillsRoot)) "Keep" "Mixed skill state did not keep interactive removal unchecked."

    [IO.File]::Copy($script:TestSkillSource, (Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md"), $true)
    Assert-Equal (Get-HerdrSkillRemovalDefault -KnownHashes $parsedTestSkillHashes -AgentSkillsRoot $script:TestAgentSkillsRoot -ClaudeSkillsRoots @($script:TestClaudeSkillsRoot)) "Remove" "Known-or-absent skill state did not select interactive removal."
    $knownUpdatePreserved = @(
        Install-HerdrSkillCopies `
            -SourcePath $skillSource2 `
            -AgentSkillsRoot $script:TestAgentSkillsRoot `
            -ClaudeSkillsRoot $script:TestClaudeSkillsRoot `
            -KnownHashes $parsedTestSkillHashes
    )
    Assert-Equal $knownUpdatePreserved.Count 0 "Known skill update reported a customized copy."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md")) (Get-HerdrSha256 -Path $skillSource2) "Known universal SKILL.md was not updated."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $script:TestClaudeSkillsRoot "herdr\SKILL.md")) (Get-HerdrSha256 -Path $skillSource2) "Known Claude SKILL.md was not updated."

    $keptByChoice = @(Remove-HerdrSkillCopies -AgentSkillsRoot $script:TestAgentSkillsRoot -ClaudeSkillsRoots @($script:TestClaudeSkillsRoot) -KnownHashes $parsedTestSkillHashes -Disposition Keep)
    Assert-Equal $keptByChoice.Count 2 "Interactive keep did not preserve both skill copies."
    $automaticRemovalPreserved = @(Remove-HerdrSkillCopies -AgentSkillsRoot $script:TestAgentSkillsRoot -ClaudeSkillsRoots @($script:TestClaudeSkillsRoot) -KnownHashes $parsedTestSkillHashes -Disposition Auto)
    Assert-Equal $automaticRemovalPreserved.Count 0 "Automatic uninstall preserved a known SKILL.md."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md"))) "Automatic uninstall retained a known universal SKILL.md."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $script:TestClaudeSkillsRoot "herdr\SKILL.md"))) "Automatic uninstall retained a known Claude SKILL.md."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $agentForeign) "preserve-agent" "Universal skill uninstall removed a foreign sibling."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $claudeForeign) "preserve-claude" "Claude skill uninstall removed a foreign sibling."

    $unknownAgentSkill = Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md"
    Write-TestFile -Path $unknownAgentSkill -Text "edited-agent-skill"
    $automaticUnknownPreserved = @(Remove-HerdrSkillFile -SkillsRoot $script:TestAgentSkillsRoot -KnownHashes $parsedTestSkillHashes -Disposition Auto)
    Assert-True (Test-Path -LiteralPath $unknownAgentSkill -PathType Leaf) "Automatic uninstall removed an unknown SKILL.md."
    Assert-Equal $automaticUnknownPreserved.Count 1 "Automatic unknown preservation was not reported."
    Remove-HerdrSkillFile -SkillsRoot $script:TestAgentSkillsRoot -KnownHashes $parsedTestSkillHashes -Disposition Remove
    Assert-True (-not (Test-Path -LiteralPath $unknownAgentSkill)) "Explicit skill removal preserved an unknown SKILL.md."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $agentForeign) "preserve-agent" "Explicit skill removal deleted a foreign sibling."

    $emptySkillsRoot = Join-Path $tempRoot "empty-skill-root\skills"
    Install-HerdrSkillFile -SourcePath $script:TestSkillSource -SkillsRoot $emptySkillsRoot -KnownHashes $parsedTestSkillHashes
    Remove-HerdrSkillFile -SkillsRoot $emptySkillsRoot -KnownHashes $parsedTestSkillHashes -Disposition Auto
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $emptySkillsRoot "herdr"))) "Uninstall retained an empty Herdr skill directory."

    $savedClaudeConfig = $env:CLAUDE_CONFIG_DIR
    try {
        $profileRoot = Join-Path $tempRoot "claude-profile"
        $configuredClaudeRoot = Join-Path $tempRoot "configured-claude"
        New-Item -ItemType Directory -Path $profileRoot | Out-Null
        New-Item -ItemType Directory -Path $configuredClaudeRoot | Out-Null
        $env:CLAUDE_CONFIG_DIR = $configuredClaudeRoot
        Assert-True (Test-HerdrClaudeCodeInstalled) "CLAUDE_CONFIG_DIR did not detect Claude Code."
        $claudeRemovalRoots = @(Get-HerdrClaudeSkillsRootsForRemoval -UserProfileRoot $profileRoot)
        Assert-Equal $claudeRemovalRoots.Count 2 "Claude uninstall did not inspect configured and default roots."
        Assert-Equal (Get-HerdrClaudeSkillsRoot -UserProfileRoot $profileRoot -ClaudeConfigRoot "~\custom-claude") (Join-Path $profileRoot "custom-claude\skills") "Claude config tilde did not resolve through the upstream home semantics."
        $env:CLAUDE_CONFIG_DIR = ""
        New-Item -ItemType Directory -Path (Join-Path $profileRoot ".claude") | Out-Null
        Assert-True (Test-HerdrClaudeCodeInstalled -UserProfileRoot $profileRoot) "Existing default Claude config did not detect Claude Code."
    } finally {
        $env:CLAUDE_CONFIG_DIR = $savedClaudeConfig
    }

    # Removal never follows a reparse point in an ancestor.
    $externalAgents = Join-Path $tempRoot "external-agents"
    $externalSkill = Join-Path $externalAgents "skills\herdr\SKILL.md"
    Write-TestFile -Path $externalSkill -Text "---`nname: herdr`n---`nexternal`n"
    $junctionHome = Join-Path $tempRoot "junction-home"
    New-Item -ItemType Directory -Path $junctionHome | Out-Null
    $ancestorJunction = Join-Path $junctionHome ".agents"
    New-Item -ItemType Junction -Path $ancestorJunction -Target $externalAgents | Out-Null
    try {
        [void](Remove-HerdrSkillFile -SkillsRoot (Join-Path $ancestorJunction "skills") -KnownHashes $parsedTestSkillHashes -Disposition Auto)
        Assert-True (Test-Path -LiteralPath $externalSkill) "Agent skill cleanup traversed an ancestor junction."
    } finally {
        if (Test-Path -LiteralPath $ancestorJunction) {
            [IO.Directory]::Delete($ancestorJunction)
        }
    }

    # A reparse-point prior skill fails before publishing any managed root.
    $reparseSkillsRoot = Join-Path $tempRoot "reparse-skills"
    New-Item -ItemType Directory -Path $reparseSkillsRoot | Out-Null
    $reparseTarget = Join-Path $tempRoot "reparse-target"
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    Write-TestFile -Path (Join-Path $reparseTarget "SKILL.md") -Text "old"
    $reparseSkill = Join-Path $reparseSkillsRoot "herdr"
    New-Item -ItemType Junction -Path $reparseSkill -Target $reparseTarget | Out-Null
    $rejectedRoot = Join-Path $tempRoot "reparse-rejected-install"
    try {
        Assert-Throws {
            Invoke-TestInstall -Root $rejectedRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $reparseSkillsRoot
        } "reparse-point directory" "Reparse-point skill rejection did not fail closed."
        Assert-True (-not (Test-Path -LiteralPath $rejectedRoot)) "Rejected skill path changed the managed install root."
        Assert-True (Test-Path -LiteralPath (Join-Path $reparseTarget "SKILL.md")) "Rejected skill path changed its junction target."
    } finally {
        if (Test-Path -LiteralPath $reparseSkill) {
            [IO.Directory]::Delete($reparseSkill)
        }
    }
    # PATH updates preserve the raw registry kind and unrelated bytes. Equivalent
    # user-owned entries are never claimed, and uninstall removes only one exact
    # literal entry that ARP records as installer-owned.
    $binEntry = Join-Path $tempRoot "path-test\bin"
    $pathVariableName = "HERDR_WIN_PATH_TEST_" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $pathVariableRoot = Split-Path -Parent $binEntry
    $oldPathVariable = [Environment]::GetEnvironmentVariable($pathVariableName, "Process")
    $pathRegistrySubKey = "Software\HerdrWinInstallerTests\" + [Guid]::NewGuid().ToString("N")
    try {
        [Environment]::SetEnvironmentVariable($pathVariableName, $pathVariableRoot, "Process")
        $rawVariableEntry = "%$pathVariableName%\bin"
        $variableCurrent = "C:\Other;;$rawVariableEntry;C:\Keep"
        $expandedEquivalent = Resolve-HerdrUserPathUpdate -Current $variableCurrent -Entry $binEntry -RequestedAction Add -ExpandVariables $true -InstallerOwned $false
        Assert-True (-not $expandedEquivalent.Changed) "REG_EXPAND_SZ equivalent PATH entry was rewritten."
        Assert-True (-not $expandedEquivalent.Owned) "Equivalent user PATH entry was claimed as installer-owned."
        Assert-Equal $expandedEquivalent.Value $variableCurrent "Equivalent raw PATH bytes changed."

        $literalVariable = Resolve-HerdrUserPathUpdate -Current $variableCurrent -Entry $binEntry -RequestedAction Add -ExpandVariables $false -InstallerOwned $false
        Assert-True $literalVariable.Changed "REG_SZ variable text was incorrectly expanded."
        Assert-True $literalVariable.Owned "New exact PATH entry was not marked installer-owned."
        Assert-Equal $literalVariable.Value "$binEntry;$variableCurrent" "New managed PATH entry did not preserve existing order and bytes."

        $duplicateCurrent = "$binEntry;C:\Keep;$binEntry"
        $removedExact = Resolve-HerdrUserPathUpdate -Current $duplicateCurrent -Entry $binEntry -RequestedAction Remove -ExpandVariables $false -InstallerOwned $true
        Assert-Equal $removedExact.Value "C:\Keep;$binEntry" "PATH removal did not remove exactly one owned literal entry."
        $unownedRemoval = Resolve-HerdrUserPathUpdate -Current $duplicateCurrent -Entry $binEntry -RequestedAction Remove -ExpandVariables $false -InstallerOwned $false
        Assert-Equal $unownedRemoval.Value $duplicateCurrent "Unowned PATH removal changed user entries."

        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($pathRegistrySubKey)
        try {
            $key.SetValue("Path", $variableCurrent, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } finally {
            $key.Dispose()
        }
        $equivalentRegistryUpdate = Set-HerdrUserPath -BinDir $binEntry -PreviouslyOwned $false -RegistrySubKey $pathRegistrySubKey
        Assert-True (-not $equivalentRegistryUpdate.Changed) "Equivalent registry PATH entry was rewritten."
        Assert-True (-not $equivalentRegistryUpdate.Owned) "Equivalent registry PATH entry was claimed."

        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($pathRegistrySubKey, $true)
        try {
            Assert-Equal $key.GetValueKind("Path") ([Microsoft.Win32.RegistryValueKind]::ExpandString) "PATH registry kind changed."
            Assert-Equal ([string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) $variableCurrent "Raw expanded PATH changed."
            $key.SetValue("Path", "C:\Keep", [Microsoft.Win32.RegistryValueKind]::ExpandString)
        } finally {
            $key.Dispose()
        }
        $addedRegistryPath = Set-HerdrUserPath -BinDir $binEntry -PreviouslyOwned $false -RegistrySubKey $pathRegistrySubKey
        Assert-True ($addedRegistryPath.Changed -and $addedRegistryPath.Owned) "Fresh registry PATH entry was not owned."
        $removedRegistryPath = Remove-HerdrUserPath -BinDir $binEntry -InstallerOwned $true -RegistrySubKey $pathRegistrySubKey
        Assert-True $removedRegistryPath.Changed "Owned registry PATH entry was not removed."
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($pathRegistrySubKey, $false)
        try {
            Assert-Equal $key.GetValueKind("Path") ([Microsoft.Win32.RegistryValueKind]::ExpandString) "PATH registry kind changed after removal."
            Assert-Equal ([string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) "C:\Keep" "Registry PATH removal changed unrelated bytes."
        } finally {
            $key.Dispose()
        }
    } finally {
        [Environment]::SetEnvironmentVariable($pathVariableName, $oldPathVariable, "Process")
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($pathRegistrySubKey, $false)
    }

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
        -UninstallRunnerPath $script:TestUninstallRunnerSource `
        -BuildId $id1 `
        -DisplayVersion $display1 `
        -NumericVersion $numeric1
    Remove-Item -LiteralPath (Join-Path $crashFresh.Path "root\runtime\$id1\herdr.exe") -Force
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) "Fresh staging mutated InstallRoot before publication."
    $fresh = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    Assert-Equal $fresh.Status "Activated" "Fresh install did not activate."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "state\package-manager"))) "Direct setup published package-manager ownership."
    Assert-True (-not (Test-Path -LiteralPath $emptyFreshCrash)) "Empty pre-marker transaction was not recovered."
    Assert-True (-not (Test-Path -LiteralPath $crashFresh.Path)) "Fresh crash transaction was not recovered."
    Assert-HerdrManagedRoot -InstallRoot $installRoot
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $installRoot "bin\managed-install-v1\marker")) "herdr-managed-bin-v1`n" "Managed-bin sentinel is wrong."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) (Get-HerdrSha256 -Path $launcher1) "Fresh launcher differs from its input."
    $installedUninstallRunner = Join-Path $installRoot $script:UninstallRunnerName
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstallRunner) (Get-HerdrSha256 -Path $script:TestUninstallRunnerSource) "Fresh quiet-uninstall runner differs from its input."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$id1\herdr-launcher.exe"))) "Fresh runtime retained a second launcher hop."
    $installedSkill = Join-Path $script:TestAgentSkillsRoot "herdr\SKILL.md"
    Assert-Equal (Get-HerdrSha256 -Path $installedSkill) (Get-HerdrSha256 -Path $script:TestSkillSource) "Fresh install did not publish the canonical cross-agent skill."
    Assert-Equal (Get-HerdrLauncherBuildId -Path $launcher1) $id1 "Launcher build-ID query returned the wrong first build."
    Assert-Equal (Get-HerdrLauncherBuildId -Path $launcher2) $id2 "Launcher build-ID query returned the wrong second build."
    Assert-Throws {
        Set-HerdrPendingLauncher -InstallRoot $installRoot -LauncherPath $wrongLauncher -BuildId $id2
    } "does not match runtime" "Pending launcher accepted a mismatched embedded build ID."
    Assert-True ($null -eq (Get-HerdrPendingLauncher -StateDir (Join-Path $installRoot "state"))) "Rejected launcher left pending state."

    # The current managed layout owns the new runner filename. Missing or changed
    # regular bytes are repaired, while a type collision at that reserved path is
    # preserved and rejected.
    Remove-Item -LiteralPath $installedUninstallRunner -Force
    $missingRunnerRepair = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    Assert-Equal $missingRunnerRepair.Status "AlreadyActive" "Missing current-format uninstall runner was not repaired."
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstallRunner) (Get-HerdrSha256 -Path $script:TestUninstallRunnerSource) "Missing runner repair published the wrong bytes."
    Write-TestFile -Path $installedUninstallRunner -Text "patched development runner"
    $changedRunnerRepair = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    Assert-Equal $changedRunnerRepair.Status "AlreadyActive" "Changed regular current-format uninstall runner was not repaired."
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstallRunner) (Get-HerdrSha256 -Path $script:TestUninstallRunnerSource) "Changed runner repair published the wrong bytes."
    Remove-Item -LiteralPath $installedUninstallRunner -Force
    New-Item -ItemType Directory -Path $installedUninstallRunner | Out-Null
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    } "not compatible.*Uninstall the existing Herdr or Herdr Win entry" "Reserved runner type collision was accepted."
    Assert-True (Test-Path -LiteralPath $installedUninstallRunner -PathType Container) "Rejected runner type collision was changed."
    Remove-Item -LiteralPath $installedUninstallRunner -Force
    [void](Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1)
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstallRunner) (Get-HerdrSha256 -Path $script:TestUninstallRunnerSource) "Runner repair after collision cleanup published the wrong bytes."

    $installedHelper = Join-Path $installRoot "state\installer-helper.ps1"
    $installedUninstaller = Join-Path $installRoot "uninstall.exe"
    Remove-Item -LiteralPath $installedHelper -Force
    Remove-Item -LiteralPath $installedUninstaller -Force
    $missingControlRepair = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    Assert-Equal $missingControlRepair.Status "AlreadyActive" "Missing current-format installer control files were not repaired."
    Assert-Equal (Get-HerdrSha256 -Path $installedHelper) (Get-HerdrSha256 -Path $helperPath) "Missing helper repair published the wrong bytes."
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstaller) (Get-HerdrSha256 -Path $uninstaller) "Missing uninstaller repair published the wrong bytes."
    Write-TestFile -Path $installedHelper -Text "patched development helper"
    Write-TestFile -Path $installedUninstaller -Text "patched development uninstaller"
    $changedControlRepair = Invoke-TestInstall -Root $installRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    Assert-Equal $changedControlRepair.Status "AlreadyActive" "Changed regular current-format installer control files were not repaired."
    Assert-Equal (Get-HerdrSha256 -Path $installedHelper) (Get-HerdrSha256 -Path $helperPath) "Changed helper repair did not restore current bytes."
    Assert-Equal (Get-HerdrSha256 -Path $installedUninstaller) (Get-HerdrSha256 -Path $uninstaller) "Changed uninstaller repair did not restore current bytes."

    # The previous two-hop runtime layout is incompatible and must be rejected
    # before setup mutates the managed root or creates the new package identity.
    $firstRuntime = Join-Path $installRoot "runtime\$id1"
    $legacyRuntimeLauncher = Join-Path $firstRuntime "herdr-launcher.exe"
    Copy-HerdrDurableFile -Source $launcher1 -Destination $legacyRuntimeLauncher
    [IO.File]::WriteAllText((Join-Path $firstRuntime "runtime.manifest"), (Get-HerdrRuntimeManifestText -RuntimeRoot $firstRuntime), $script:Utf8NoBom)
    $launcherBeforeLegacyRejection = Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    } "not compatible.*Uninstall the existing Herdr or Herdr Win entry" "Legacy runtime-local launcher layout was accepted."
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $installRoot "state\active")) $id1 "Legacy layout rejection changed active runtime."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) $launcherBeforeLegacyRejection "Legacy layout rejection changed the installed launcher."
    Assert-True (Test-Path -LiteralPath $legacyRuntimeLauncher) "Legacy layout rejection deleted the old runtime launcher."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$id2"))) "Legacy layout rejection staged the new runtime."
    Remove-Item -LiteralPath $legacyRuntimeLauncher -Force
    [IO.File]::WriteAllText((Join-Path $firstRuntime "runtime.manifest"), (Get-HerdrRuntimeManifestText -RuntimeRoot $firstRuntime), $script:Utf8NoBom)
    Assert-HerdrRuntimeDirectory -Path $firstRuntime -ExpectedBuildId $id1

    # A dead uninstall transaction is recovery evidence, not a permanent setup
    # blocker. This reproduces the observed field state: only the exact managed
    # bin survives while the sibling transaction retains root.manifest.
    $deadUninstallRoot = Join-Path $tempRoot "dead-uninstall-install"
    $deadUninstallSkillsRoot = Join-Path $tempRoot "dead-uninstall-agent-skills"
    [void](Invoke-TestInstall -Root $deadUninstallRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $deadUninstallSkillsRoot)
    $deadUninstallTransaction = New-HerdrTransaction -Kind "uninstall" -InstallRoot $deadUninstallRoot
    Copy-HerdrDurableFile -Source (Join-Path $deadUninstallRoot "state\install.manifest") -Destination (Join-Path $deadUninstallTransaction.Path "root.manifest")
    Remove-Item -LiteralPath (Join-Path $deadUninstallRoot "runtime") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $deadUninstallRoot "state") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $deadUninstallRoot "uninstall.exe") -Force
    $recoveredDeadUninstall = Invoke-TestInstall -Root $deadUninstallRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -AgentSkillsRoot $deadUninstallSkillsRoot
    Assert-Equal $recoveredDeadUninstall.Status "Activated" "Dead uninstall transaction did not recover into a fresh install."
    Assert-True (-not (Test-Path -LiteralPath $deadUninstallTransaction.Path)) "Dead uninstall transaction survived setup recovery."
    Assert-HerdrManagedRoot -InstallRoot $deadUninstallRoot
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $deadUninstallRoot "state\active")) $id2 "Dead uninstall recovery selected the wrong build."

    # Recovery holds the launcher's coordination gate from its final process and
    # lease checks until bin is moved out of the install root. A concurrent
    # launcher owner therefore blocks recovery without losing transaction state.
    $gatedRecoveryRoot = Join-Path $tempRoot "gated-dead-uninstall"
    $gatedRecoverySkillsRoot = Join-Path $tempRoot "gated-dead-uninstall-agent-skills"
    [void](Invoke-TestInstall -Root $gatedRecoveryRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $gatedRecoverySkillsRoot)
    $gatedRecoveryTransaction = New-HerdrTransaction -Kind "uninstall" -InstallRoot $gatedRecoveryRoot
    Copy-HerdrDurableFile -Source (Join-Path $gatedRecoveryRoot "state\install.manifest") -Destination (Join-Path $gatedRecoveryTransaction.Path "root.manifest")
    Remove-Item -LiteralPath (Join-Path $gatedRecoveryRoot "runtime") -Recurse -Force
    $gatedRecoveryReady = Join-Path $tempRoot "gated-dead-uninstall-ready"
    $gatedRecoveryOwner = Start-TestSharedFileHolder -Path (Join-Path $gatedRecoveryRoot "state\launcher.lock") -ReadyPath $gatedRecoveryReady -Seconds 2 -ShareMode None
    $childProcesses.Add($gatedRecoveryOwner)
    Wait-TestPath -Path $gatedRecoveryReady
    Assert-Throws {
        Invoke-TestInstall -Root $gatedRecoveryRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -AgentSkillsRoot $gatedRecoverySkillsRoot -LockTimeoutMilliseconds 250
    } "Timed out after 250 ms.*launcher.lock" "Dead uninstall recovery entered while a launcher owned its coordination gate."
    Assert-True (Test-Path -LiteralPath $gatedRecoveryTransaction.Path) "Blocked recovery deleted its transaction."
    Assert-True (Test-Path -LiteralPath (Join-Path $gatedRecoveryRoot "bin\herdr.exe")) "Blocked recovery removed its launcher."
    if (-not $gatedRecoveryOwner.WaitForExit(10000)) { throw "Gated recovery owner did not exit within 10 seconds." }
    $recoveredGatedUninstall = Invoke-TestInstall -Root $gatedRecoveryRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -AgentSkillsRoot $gatedRecoverySkillsRoot
    Assert-Equal $recoveredGatedUninstall.Status "Activated" "Gated dead uninstall did not recover after launcher coordination released."
    Assert-HerdrManagedRoot -InstallRoot $gatedRecoveryRoot

    # A transaction that died before changing a complete managed root is simply
    # discarded; setup must preserve the installation and follow normal update.
    $preMutationTransaction = New-HerdrTransaction -Kind "uninstall" -InstallRoot $deadUninstallRoot
    Copy-HerdrDurableFile -Source (Join-Path $deadUninstallRoot "state\install.manifest") -Destination (Join-Path $preMutationTransaction.Path "root.manifest")
    $recoveredPreMutation = Invoke-TestInstall -Root $deadUninstallRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -AgentSkillsRoot $deadUninstallSkillsRoot
    Assert-Equal $recoveredPreMutation.Status "AlreadyActive" "Pre-mutation uninstall transaction changed normal setup behavior."
    Assert-True (-not (Test-Path -LiteralPath $preMutationTransaction.Path)) "Pre-mutation uninstall transaction survived setup recovery."
    Assert-HerdrManagedRoot -InstallRoot $deadUninstallRoot

    # An exact residual left by an older interrupted uninstaller remains
    # resumable by setup even though current helpers finalize it under the lock.
    $uninstallResidualRoot = Join-Path $tempRoot "uninstall-residual-install"
    $uninstallResidualSkillsRoot = Join-Path $tempRoot "uninstall-residual-agent-skills"
    [void](Invoke-TestInstall -Root $uninstallResidualRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $uninstallResidualSkillsRoot)
    Write-HerdrDurableText -Path (Join-Path $uninstallResidualRoot "state\uninstall.pending") -Text $script:UninstallMarkerText
    Remove-Item -LiteralPath (Join-Path $uninstallResidualRoot "bin") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $uninstallResidualRoot "runtime") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $uninstallResidualRoot "state\active") -Force
    Remove-Item -LiteralPath (Join-Path $uninstallResidualRoot "state\install.manifest") -Force
    Remove-Item -LiteralPath (Join-Path $uninstallResidualRoot "state\leases") -Force
    Assert-HerdrUninstallResidual -InstallRoot $uninstallResidualRoot
    $recoveredResidual = Invoke-TestInstall -Root $uninstallResidualRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -AgentSkillsRoot $uninstallResidualSkillsRoot
    Assert-Equal $recoveredResidual.Status "Activated" "Exact uninstall residual did not recover into a fresh install."
    Assert-HerdrManagedRoot -InstallRoot $uninstallResidualRoot

    # Final cleanup fault points now live in the embedded helper, inside the
    # lifecycle lock. Every exact partial residual keeps its retry executable and
    # a second pass completes idempotently.
    foreach ($fault in @(
        "after-uninstall-pending",
        "after-launcher-lock",
        "after-installer-helper",
        "after-state-directory",
        "before-uninstaller",
        "after-uninstaller",
        "after-uninstall-runner"
    )) {
        Remove-HerdrUninstallFaultMarker -Fault $fault -MarkerPrefix $faultMarkerPrefix
        $faultRoot = Join-Path $tempRoot "fault-$fault"
        Write-TestFile -Path (Join-Path $faultRoot "state\installer-helper.ps1") -Text "helper"
        Write-TestFile -Path (Join-Path $faultRoot "state\launcher.lock") -Text ""
        Write-HerdrDurableText -Path (Join-Path $faultRoot "state\uninstall.pending") -Text $script:UninstallMarkerText
        Write-TestFile -Path (Join-Path $faultRoot "uninstall.exe") -Text "uninstaller"
        Write-TestFile -Path (Join-Path $faultRoot $script:UninstallRunnerName) -Text "runner"
        Assert-Throws {
            Remove-HerdrUninstallResidual -InstallRoot $faultRoot -UninstallFault $fault -UninstallFaultMarkerPrefix $faultMarkerPrefix
        } "Injected uninstall cleanup fault" "Helper cleanup fault '$fault' did not interrupt its first pass."
        Assert-True (Test-Path -LiteralPath (Join-Path $faultRoot "uninstall.exe")) "Helper cleanup fault '$fault' removed its retry executable."
        Assert-True (Test-Path -LiteralPath (Join-Path $faultRoot $script:UninstallRunnerName)) "Helper cleanup fault '$fault' removed its retry runner."
        Remove-HerdrUninstallResidual -InstallRoot $faultRoot -UninstallFault $fault -UninstallFaultMarkerPrefix $faultMarkerPrefix
        Assert-True (-not (Test-Path -LiteralPath $faultRoot)) "Helper cleanup fault '$fault' was not retryable."
        Remove-HerdrUninstallFaultMarker -Fault $fault -MarkerPrefix $faultMarkerPrefix
    }

    # The same dead-transaction recovery is shared by uninstall. With no running
    # managed process, a partial current install is removed instead of wedging the
    # uninstaller on its own abandoned transaction.
    $deadUninstallRemovalRoot = Join-Path $tempRoot "dead-uninstall-removal"
    $deadUninstallRemovalSkillsRoot = Join-Path $tempRoot "dead-uninstall-removal-agent-skills"
    [void](Invoke-TestInstall -Root $deadUninstallRemovalRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $deadUninstallRemovalSkillsRoot)
    $deadUninstallRemovalTransaction = New-HerdrTransaction -Kind "uninstall" -InstallRoot $deadUninstallRemovalRoot
    Copy-HerdrDurableFile -Source (Join-Path $deadUninstallRemovalRoot "state\install.manifest") -Destination (Join-Path $deadUninstallRemovalTransaction.Path "root.manifest")
    Remove-Item -LiteralPath (Join-Path $deadUninstallRemovalRoot "runtime") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $deadUninstallRemovalRoot "state") -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $deadUninstallRemovalRoot "uninstall.exe") -Force
    Invoke-TestUninstall -Root $deadUninstallRemovalRoot -AgentSkillsRoot $deadUninstallRemovalSkillsRoot -ProcessProvider { @() }
    Assert-True (-not (Test-Path -LiteralPath $deadUninstallRemovalRoot)) "Uninstall did not remove its dead-transaction partial root."
    Assert-True (-not (Test-Path -LiteralPath $deadUninstallRemovalTransaction.Path)) "Uninstall retained its dead transaction."

    # Filesystem finalization occurs inside the outer lifecycle operation. Even
    # after the root is gone, another setup cannot publish a new generation until
    # the uninstall owner releases the persistent sibling lock.
    $lockedFinalizationRoot = Join-Path $tempRoot "locked-finalization-install"
    $lockedFinalizationSkillsRoot = Join-Path $tempRoot "locked-finalization-agent-skills"
    [void](Invoke-TestInstall -Root $lockedFinalizationRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $lockedFinalizationSkillsRoot)
    $knownFinalizationSkillHashes = @(Read-HerdrManagedSkillHashes -Path $script:TestSkillHashManifest)
    $finalizationProbeResult = Join-Path $tempRoot "locked-finalization-probe"
    Invoke-HerdrLifecycleOperation -InstallRoot $lockedFinalizationRoot -TimeoutMilliseconds 3000 -Operation {
        [void](Invoke-HerdrUninstallLayout `
            -InstallRoot $lockedFinalizationRoot `
            -AgentSkillsRoot $lockedFinalizationSkillsRoot `
            -KnownSkillHashes $knownFinalizationSkillHashes `
            -SkillDisposition Auto `
            -ProcessProvider { @() } `
            -LockTimeoutMilliseconds 3000)
        Assert-True (-not (Test-Path -LiteralPath $lockedFinalizationRoot)) "Uninstall returned before filesystem finalization."
        $finalizationProbe = Start-TestLifecycleProbe -HelperPath $helperPath -InstallRoot $lockedFinalizationRoot -ResultPath $finalizationProbeResult
        $childProcesses.Add($finalizationProbe)
        if (-not $finalizationProbe.WaitForExit(10000)) { throw "Lifecycle finalization probe did not exit within 10 seconds." }
        Assert-True (Test-Path -LiteralPath $finalizationProbeResult) "Lifecycle finalization probe produced no result."
        Assert-True ((Read-HerdrStrictUtf8 -Path $finalizationProbeResult) -match '^blocked:Timed out after 250 ms') "Lifecycle lock released before uninstall finalization returned."
    }
    Invoke-HerdrLifecycleOperation -InstallRoot $lockedFinalizationRoot -TimeoutMilliseconds 3000 -Operation { }

    # Managed updates replace known historical SKILL.md copies while preserving
    # customized copies and foreign siblings.
    Write-TestFile -Path (Join-Path $script:TestAgentSkillsRoot "herdr\obsolete.txt") -Text "old-version"
    New-Item -ItemType Directory -Path (Join-Path $script:TestAgentSkillsRoot "herdr\obsolete-resources") | Out-Null
    Write-TestFile -Path (Join-Path $script:TestAgentSkillsRoot "herdr\obsolete-resources\old.txt") -Text "old-resource"
    $script:TestSkillSource = $skillSource2

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
    $leaseProcess = Start-TestSharedFileHolder -Path $leasePath -ReadyPath $leaseReady -Seconds 10
    $childProcesses.Add($leaseProcess)
    Wait-TestPath -Path $leaseReady
    $pending = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    Assert-Equal $pending.Status "Pending" "Second-process lease did not produce pending success."
    Assert-True (-not (Test-Path -LiteralPath $runtimeCrash.Path)) "Runtime crash transaction was not recovered."
    Assert-True (-not (Test-Path -LiteralPath $pointerCrash.Path)) "Pointer crash transaction was not recovered."
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $installRoot "state\active")) $id1 "Busy upgrade changed active."
    Assert-Equal (Read-HerdrPointer -Path (Join-Path $installRoot "state\pending")) $id2 "Busy upgrade did not publish pending."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) (Get-HerdrSha256 -Path $launcher1) "Busy upgrade replaced the active launcher."
    $pendingLauncher = Get-HerdrPendingLauncher -StateDir (Join-Path $installRoot "state")
    Assert-True ($null -ne $pendingLauncher) "Busy upgrade did not stage the new launcher."
    Assert-Equal $pendingLauncher.Sha256 (Get-HerdrSha256 -Path $launcher2) "Pending launcher hash is wrong."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$id2\herdr-launcher.exe"))) "Upgrade retained a runtime-local launcher."
    Assert-Equal (Get-HerdrSha256 -Path $installedSkill) (Get-HerdrSha256 -Path $skillSource2) "Managed update did not replace the Herdr skill."
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $script:TestAgentSkillsRoot "herdr\obsolete.txt")) "old-version" "Managed update removed a foreign skill sibling."
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $script:TestAgentSkillsRoot "herdr\obsolete-resources\old.txt")) "old-resource" "Managed update removed a foreign nested skill sibling."
    Write-TestFile -Path $installedSkill -Text "modified-after-update"
    $repairedSkill = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    Assert-Equal $repairedSkill.Status "Pending" "Customized-skill preservation changed the busy managed update outcome."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $installedSkill) "modified-after-update" "Managed reinstall overwrote a customized skill."
    Assert-Equal @($repairedSkill.PreservedSkillPaths).Count 1 "Managed reinstall did not report its preserved customized skill."
    if (-not $leaseProcess.WaitForExit(15000)) { throw "Lease holder did not exit within 15 seconds." }
    $activated = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    Assert-Equal $activated.Status "Activated" "Released lease did not activate pending."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "state\pending"))) "Activation retained pending."
    Assert-Equal (Get-HerdrSha256 -Path (Join-Path $installRoot "bin\herdr.exe")) (Get-HerdrSha256 -Path $launcher2) "Idle activation did not update the launcher."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "runtime\$id1"))) "Idle activation retained an obsolete runtime."
    Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $installRoot "runtime") -Directory).Count 1 "Runtime pruning did not reach a single active build."
    Write-HerdrDurableText -Path (Join-Path $installRoot "state\pending") -Text (Get-HerdrPointerText -BuildId $id2)
    $alreadyActive = Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
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
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    } "not compatible with this setup|owned-directory set" "Same-build extra directory was accepted."
    Assert-True (Test-Path -LiteralPath $extraDirectory) "Rejected same-build directory was deleted."
    Remove-Item -LiteralPath $extraDirectory -Force
    $extra = Join-Path $installRoot "runtime\$id2\user-content.txt"
    Write-TestFile -Path $extra -Text "preserve"
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    } "not compatible with this setup|owned-file set" "Same-build extra content was accepted."
    Assert-True (Test-Path -LiteralPath $extra) "Rejected same-build content was deleted."
    Remove-Item -LiteralPath $extra -Force
    $runtimePayload = Join-Path $installRoot "runtime\$id2\herdr.exe"
    $ownedPayloadBytes = [IO.File]::ReadAllBytes((Join-Path $stage2 "herdr.exe"))
    [IO.File]::WriteAllText($runtimePayload, "corrupt", $script:Utf8NoBom)
    Assert-Throws {
        Invoke-TestInstall -Root $installRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2
    } "not compatible with this setup|hash mismatch" "Same-build hash corruption was accepted."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $runtimePayload) "corrupt" "Rejected corruption was silently repaired or deleted."
    [IO.File]::WriteAllBytes($runtimePayload, $ownedPayloadBytes)
    Assert-HerdrManagedRoot -InstallRoot $installRoot

    # WinGet owns only installations carrying its exact setup marker. A later
    # direct setup preserves that ownership, malformed markers fail closed, and
    # uninstall removes the marker with the managed state root.
    $wingetRoot = Join-Path $tempRoot "winget-install"
    $wingetSkillsRoot = Join-Path $tempRoot "winget-agent-skills"
    [void](Invoke-TestInstall -Root $wingetRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -InstallManager WinGet -AgentSkillsRoot $wingetSkillsRoot)
    $wingetMarker = Join-Path $wingetRoot "state\package-manager"
    Assert-Equal (Read-HerdrStrictUtf8 -Path $wingetMarker) $script:PackageManagerMarkerText "WinGet setup did not publish its exact package-manager marker."
    [void](Invoke-TestInstall -Root $wingetRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -InstallManager Direct -AgentSkillsRoot $wingetSkillsRoot)
    Assert-Equal (Read-HerdrStrictUtf8 -Path $wingetMarker) $script:PackageManagerMarkerText "Direct setup removed WinGet ownership from an existing package-managed install."
    $wingetRetry = Invoke-TestInstall -Root $wingetRoot -Stage $stage2 -Launcher $launcher2 -Uninstaller $uninstaller -BuildId $id2 -DisplayVersion $display2 -NumericVersion $numeric2 -InstallManager WinGet -AgentSkillsRoot $wingetSkillsRoot
    Assert-Equal $wingetRetry.Status "AlreadyActive" "Repeated WinGet setup was not idempotent."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $wingetMarker) $script:PackageManagerMarkerText "Repeated WinGet setup changed its package-manager marker."
    Write-TestFile -Path $wingetMarker -Text "invalid"
    Assert-Throws { Assert-HerdrManagedRoot -InstallRoot $wingetRoot } "package-manager marker is invalid" "Malformed package-manager ownership was accepted."
    Write-TestFile -Path $wingetMarker -Text $script:PackageManagerMarkerText
    Invoke-TestUninstall -Root $wingetRoot -AgentSkillsRoot $wingetSkillsRoot -ProcessProvider { @() }
    Assert-True (-not (Test-Path -LiteralPath $wingetRoot)) "WinGet-owned managed root survived uninstall."

    # Setup preserves and rejects every non-current layout. The user must remove
    # an earlier installation before retrying the current setup.
    $incompatibleRoot = Join-Path $tempRoot "incompatible-install"
    Write-TestFile -Path (Join-Path $incompatibleRoot "bin\herdr.exe") -Text "preserve"
    Assert-Throws {
        Invoke-TestInstall -Root $incompatibleRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
    } "not compatible with this setup.*Uninstall the existing Herdr or Herdr Win entry" "An incompatible install root was accepted."
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $incompatibleRoot "bin\herdr.exe")) "preserve" "Rejected incompatible content was changed."

    # A junction at the fixed install root is rejected before transaction repair,
    # setup publication, or uninstall cleanup can mutate its target.
    $reparseInstallTarget = Join-Path $tempRoot "reparse-install-target"
    New-Item -ItemType Directory -Path $reparseInstallTarget | Out-Null
    Write-TestFile -Path (Join-Path $reparseInstallTarget "preserve.txt") -Text "preserve"
    $reparseInstallRoot = Join-Path $tempRoot "reparse-install-root"
    New-Item -ItemType Junction -Path $reparseInstallRoot -Target $reparseInstallTarget | Out-Null
    try {
        Assert-Throws {
            Invoke-TestInstall -Root $reparseInstallRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1
        } "reparse-point directory" "Setup followed a reparse-point install root."
        Assert-Throws {
            Invoke-TestUninstall -Root $reparseInstallRoot -ProcessProvider { @() }
        } "reparse-point directory" "Uninstall followed a reparse-point install root."
        Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $reparseInstallTarget "preserve.txt")) "preserve" "Rejected install-root junction changed its target."
    } finally {
        if (Test-Path -LiteralPath $reparseInstallRoot) {
            [IO.Directory]::Delete($reparseInstallRoot)
        }
    }

    # ARP stores the truthful display/numeric identity and preserves mismatches.
    Set-HerdrArpRegistration -InstallRoot $installRoot -DisplayVersion $display2 -NumericVersion $numeric2 -PathAdded $true -RegistryPath $registryPath
    $arp = Get-ItemProperty -LiteralPath $registryPath
    Assert-Equal ([string]$arp.DisplayName) $script:ProductName "ARP package identity is not the configured distribution name."
    Assert-Equal ([string]$arp.DisplayVersion) $display2 "ARP display version is not truthful."
    Assert-Equal ([int]$arp.VersionMajor) 0 "ARP major version is wrong."
    Assert-Equal ([string]$arp.QuietUninstallString) (Get-HerdrQuietUninstallString -InstallRoot $installRoot) "ARP quiet uninstall does not propagate terminal status through the runner."
    Assert-True (Get-HerdrArpPathOwnership -InstallRoot $installRoot -RegistryPath $registryPath) "ARP did not retain exact PATH ownership."
    Set-ItemProperty -LiteralPath $registryPath -Name QuietUninstallString -Value ('"' + (Join-Path $installRoot "uninstall.exe") + '" /S')
    Assert-Throws {
        Assert-HerdrArpOwnership -InstallRoot $installRoot -RegistryPath $registryPath
    } "not owned" "Legacy quiet uninstall registration was accepted outside setup adoption."
    Assert-HerdrArpOwnership -InstallRoot $installRoot -RegistryPath $registryPath -AllowLegacyQuietUninstall
    Assert-True (Get-HerdrArpPathOwnership -InstallRoot $installRoot -RegistryPath $registryPath -AllowLegacyQuietUninstall) "Setup-scoped legacy registration lost PATH ownership."
    Set-HerdrArpRegistration -InstallRoot $installRoot -DisplayVersion $display2 -NumericVersion $numeric2 -PathAdded $true -RegistryPath $registryPath -AllowLegacyQuietUninstall
    Assert-Equal ([string](Get-ItemProperty -LiteralPath $registryPath).QuietUninstallString) (Get-HerdrQuietUninstallString -InstallRoot $installRoot) "Setup adoption did not immediately rewrite legacy quiet uninstall registration."
    New-ItemProperty -LiteralPath $registryPath -Name UnknownValue -Value "preserve" -PropertyType String | Out-Null
    Assert-Throws { Assert-HerdrArpOwnership -InstallRoot $installRoot -RegistryPath $registryPath } "unknown or incomplete" "Unknown ARP state was accepted."
    Remove-ItemProperty -LiteralPath $registryPath -Name UnknownValue
    New-Item -Path (Join-Path $registryPath "UnknownSubkey") | Out-Null
    Assert-Throws { Assert-HerdrArpOwnership -InstallRoot $installRoot -RegistryPath $registryPath } "unknown or incomplete" "Unknown ARP subkey was accepted."
    Remove-Item -LiteralPath (Join-Path $registryPath "UnknownSubkey") -Force
    Remove-ItemProperty -LiteralPath $registryPath -Name PathAdded
    Assert-True (-not (Get-HerdrArpPathOwnership -InstallRoot $installRoot -RegistryPath $registryPath)) "Missing legacy PATH ownership was claimed."
    New-ItemProperty -LiteralPath $registryPath -Name PathAdded -Value "1" -PropertyType String | Out-Null
    Assert-Throws { Get-HerdrArpPathOwnership -InstallRoot $installRoot -RegistryPath $registryPath } "must be REG_DWORD" "REG_SZ PATH ownership was accepted."
    Remove-ItemProperty -LiteralPath $registryPath -Name PathAdded
    New-ItemProperty -LiteralPath $registryPath -Name PathAdded -Value ([long]1) -PropertyType QWord | Out-Null
    Assert-Throws { Get-HerdrArpPathOwnership -InstallRoot $installRoot -RegistryPath $registryPath } "must be REG_DWORD" "REG_QWORD PATH ownership was accepted."
    Remove-ItemProperty -LiteralPath $registryPath -Name PathAdded
    Set-ItemProperty -LiteralPath $registryPath -Name InstallLocation -Value (Join-Path $tempRoot "someone-else")
    Assert-Throws { Remove-HerdrArpRegistration -InstallRoot $installRoot -RegistryPath $registryPath } "not owned" "Mismatched ARP key was removed."
    Remove-Item -LiteralPath $registryPath -Recurse -Force

    # Any process image under InstallRoot refuses uninstall. Use an actual
    # copied PowerShell executable and let it exit naturally.
    $processRoot = Join-Path $tempRoot "process-busy-install"
    $processAgentSkillsRoot = Join-Path $tempRoot "process-agent-skills"
    $realLauncher = $launcher1
    [void](Invoke-TestInstall -Root $processRoot -Stage $stage1 -Launcher $realLauncher -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $processAgentSkillsRoot)
    $busyProcess = Start-Process -FilePath (Join-Path $processRoot "bin\herdr.exe") -ArgumentList @("--wait") -PassThru -WindowStyle Hidden
    $childProcesses.Add($busyProcess)
    Start-Sleep -Milliseconds 200
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -AgentSkillsRoot $processAgentSkillsRoot -ProcessProvider { Get-HerdrProcessSnapshot } -LockTimeoutMilliseconds 3000
    } "process from the managed Herdr install tree" "Process-tree busy uninstall was accepted."
    Assert-HerdrManagedRoot -InstallRoot $processRoot
    if (-not $busyProcess.WaitForExit(10000)) { throw "Managed process did not exit within 10 seconds." }

    # Automatic direct removal preserves unknown SKILL.md content; explicit
    # removal deletes that exact file while preserving siblings.
    $processSkillRoot = Join-Path $processAgentSkillsRoot "herdr"
    $processSkill = Join-Path $processSkillRoot "SKILL.md"
    Write-TestFile -Path $processSkill -Text "user-edited-skill"
    $processSkillSibling = Join-Path $processSkillRoot "user.txt"
    Write-TestFile -Path $processSkillSibling -Text "preserve"
    $directUnknownPreserved = @(Remove-HerdrSkillFile -SkillsRoot $processAgentSkillsRoot -KnownHashes $parsedTestSkillHashes -Disposition Auto)
    Assert-True (Test-Path -LiteralPath $processSkill -PathType Leaf) "Automatic direct removal deleted an edited SKILL.md."
    Assert-Equal $directUnknownPreserved.Count 1 "Automatic direct removal did not report an edited SKILL.md."
    Remove-HerdrSkillFile -SkillsRoot $processAgentSkillsRoot -KnownHashes $parsedTestSkillHashes -Disposition Remove
    Assert-True (-not (Test-Path -LiteralPath $processSkill)) "Explicit direct removal preserved an edited SKILL.md."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $processSkillSibling) "preserve" "Direct removal deleted a foreign sibling."
    Remove-Item -LiteralPath $processSkillSibling -Force
    Install-HerdrSkillFile -SourcePath $script:TestSkillSource -SkillsRoot $processAgentSkillsRoot -KnownHashes $parsedTestSkillHashes

    # An unchanged but temporarily locked owned skill keeps uninstall retryable
    # and preserves the install manifest until cleanup can succeed.
    $lockedSkill = $processSkill
    $lockedSkillReady = Join-Path $tempRoot "locked-skill-ready"
    $lockedSkillProcess = Start-TestSharedFileHolder -Path $lockedSkill -ReadyPath $lockedSkillReady -Seconds 2 -ShareMode None
    $childProcesses.Add($lockedSkillProcess)
    Wait-TestPath -Path $lockedSkillReady
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -AgentSkillsRoot $processAgentSkillsRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    } "being used|cannot access|access to the path" "Locked owned skill did not keep uninstall retryable."
    Assert-True (Test-Path -LiteralPath (Join-Path $processRoot "state\install.manifest")) "Failed skill cleanup removed uninstall ownership state."
    if (-not $lockedSkillProcess.WaitForExit(10000)) { throw "Locked skill holder did not exit within 10 seconds." }

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
        Invoke-TestUninstall -Root $processRoot -AgentSkillsRoot $processAgentSkillsRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    } "unowned file" "Partial uninstall cleanup accepted an unowned survivor."
    Assert-True (Test-Path -LiteralPath $unownedUninstallFile) "Rejected partial-uninstall content was deleted."
    Remove-Item -LiteralPath $unownedUninstallFile -Force
    $unownedUninstallDirectory = Join-Path $uninstallTx.Path "bin\unexpected-empty"
    New-Item -ItemType Directory -Path $unownedUninstallDirectory | Out-Null
    Assert-Throws {
        Invoke-TestUninstall -Root $processRoot -AgentSkillsRoot $processAgentSkillsRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    } "unowned directory" "Partial uninstall cleanup accepted an unowned empty directory."
    Assert-True (Test-Path -LiteralPath $unownedUninstallDirectory) "Rejected partial-uninstall directory was deleted."
    Remove-Item -LiteralPath $unownedUninstallDirectory -Force
    Invoke-TestUninstall -Root $processRoot -AgentSkillsRoot $processAgentSkillsRoot -ProcessProvider { @() } -LockTimeoutMilliseconds 3000
    Assert-True (-not (Test-Path -LiteralPath $processRoot)) "Dead uninstall recovery retained its partial managed root."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $processAgentSkillsRoot "herdr"))) "Uninstall retained its unchanged owned Herdr skill."

    # Explicit removal deletes an unknown SKILL.md while preserving extra files
    # and nested directories.
    $extraTreeRoot = Join-Path $tempRoot "extra-tree-install"
    $extraTreeSkillsRoot = Join-Path $tempRoot "extra-tree-agent-skills"
    [void](Invoke-TestInstall -Root $extraTreeRoot -Stage $stage1 -Launcher $launcher1 -Uninstaller $uninstaller -BuildId $id1 -DisplayVersion $display1 -NumericVersion $numeric1 -AgentSkillsRoot $extraTreeSkillsRoot)
    $extraTreeSkillRoot = Join-Path $extraTreeSkillsRoot "herdr"
    $extraTreeSkill = Join-Path $extraTreeSkillRoot "SKILL.md"
    Write-TestFile -Path (Join-Path $extraTreeSkillRoot "user.txt") -Text "preserve-file"
    Write-TestFile -Path (Join-Path $extraTreeSkillRoot "resources\nested.txt") -Text "preserve-nested"
    Write-TestFile -Path $extraTreeSkill -Text "customized-extra-tree-skill"
    Invoke-TestUninstall -Root $extraTreeRoot -AgentSkillsRoot $extraTreeSkillsRoot -SkillDisposition Remove -ProcessProvider { @() }
    Assert-True (-not (Test-Path -LiteralPath $extraTreeRoot)) "Extra-tree uninstall returned before removing its install root."
    Assert-True (-not (Test-Path -LiteralPath $extraTreeSkill)) "Extra-tree uninstall preserved SKILL.md."
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $extraTreeSkillRoot "user.txt")) "preserve-file" "Extra-tree uninstall removed a user file."
    Assert-Equal (Read-HerdrStrictUtf8 -Path (Join-Path $extraTreeSkillRoot "resources\nested.txt")) "preserve-nested" "Extra-tree uninstall removed nested user content."

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
    Write-TestFile -Path $installedSkill -Text "user-modified-skill"
    $finalPreservedSkills = @(Invoke-TestUninstall -Root $installRoot -ProcessProvider { @() })
    Assert-True (-not (Test-Path -LiteralPath $installRoot)) "Final uninstall returned before removing its install root."
    Assert-Equal $finalPreservedSkills.Count 1 "Automatic uninstall did not report one modified Herdr skill."
    Assert-True (Test-Path -LiteralPath $installedSkill -PathType Leaf) "Uninstall removed a modified Herdr skill."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $installedSkill) "user-modified-skill" "Automatic uninstall changed a modified Herdr skill."
    Assert-Equal (Read-HerdrStrictUtf8 -Path $agentForeign) "preserve-agent" "Uninstall removed a foreign skill sibling."

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
    if (Test-Path -LiteralPath $registryPath) {
        Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($fault in @("after-uninstall-pending", "after-launcher-lock", "after-installer-helper", "after-state-directory", "before-uninstaller", "after-uninstaller", "after-uninstall-runner")) {
        Remove-HerdrUninstallFaultMarker -Fault $fault -MarkerPrefix $faultMarkerPrefix
    }
}
