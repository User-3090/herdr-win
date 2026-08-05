[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall", "GetSkillRemovalDefault", "CompleteMaintenance")]
    [string]$Action,

    [string]$InstallRoot,
    [string]$UserProfileRoot = $env:USERPROFILE,
    [string]$StageDir,
    [string]$LauncherPath,
    [string]$UninstallerPath,
    [string]$HelperSourcePath,
    [string]$SkillSourcePath,
    [string]$SkillHashManifestPath,
    [string]$ProductName = "Herdr",
    [string]$PackageRoot,
    [string]$BuildId,
    [string]$DisplayVersion,
    [string]$NumericVersion,
    [ValidateSet("Direct", "WinGet")]
    [string]$InstallManager = "Direct",
    [ValidateSet("Keep", "Remove")]
    [string]$SettingsDisposition = "Keep",
    [ValidateSet("Keep", "Auto", "Remove")]
    [string]$SkillDisposition = "Auto",

    [uint32]$ParentProcessId = 0,
    [ValidateSet(
        "",
        "after-uninstall-pending",
        "after-launcher-lock",
        "after-installer-helper",
        "after-state-directory",
        "before-uninstaller",
        "after-uninstaller",
        "after-uninstall-runner"
    )]
    [string]$UninstallFault = "",
    [string]$UninstallFaultMarkerPrefix = "herdr"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProductNamePattern = '^[A-Za-z0-9](?:[A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?$'
if ($ProductName -cnotmatch $script:ProductNamePattern) {
    throw "Invalid product name '$ProductName'."
}
$script:ProductName = $ProductName
if ($UninstallFaultMarkerPrefix -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$') {
    throw "Invalid uninstall fault marker prefix '$UninstallFaultMarkerPrefix'."
}
$script:BuildIdPattern = '^[0-9a-f]{12}\.[0-9a-f]{12}$'
$script:DisplayVersionPattern = '^((?:0|[1-9][0-9]{0,4}))\.((?:0|[1-9][0-9]{0,4}))\.((?:0|[1-9][0-9]{0,4}))-preview\.([0-9a-f]{12}\.[0-9a-f]{12})$'
$script:NumericVersionPattern = '^([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$'
$script:PointerPattern = '\Aherdr-pointer-v1\nbuild_id=([0-9a-f]{12}\.[0-9a-f]{12})\n\z'
$script:RuntimePattern = '\Aherdr-runtime-v1\nbuild_id=([0-9a-f]{12}\.[0-9a-f]{12})\n\z'
$script:LeasePattern = '^([0-9a-f]{12}\.[0-9a-f]{12})\.lease$'
$script:PendingLauncherPattern = '^launcher\.pending-([0-9a-f]{64})\.exe$'
$script:LauncherReplacementName = "herdr.exe.new"
$script:LauncherBuildIdArgument = "--herdr-private-launcher-build-id-v1"
$script:RuntimeManifestHeader = "herdr-runtime-manifest-v1"
$script:InstallManifestHeader = "herdr-install-manifest-v1"
$script:ManagedSkillHashesHeader = "herdr-managed-skill-hashes-v1"
$script:ManagedBinMarkerText = "herdr-managed-bin-v1`n"
$script:PackageManagerMarkerText = "herdr-package-manager-v1`nmanager=winget`n"
$script:UninstallMarkerText = "herdr-uninstall-v1`n"
$script:UninstallRunnerName = "uninstall-runner.ps1"
$script:ArpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$script:ProductName"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Assert-HerdrBuildId {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cnotmatch $script:BuildIdPattern) {
        throw "Invalid Herdr build ID '$Value'. Expected 12 lowercase hex characters, a dot, and 12 lowercase hex characters."
    }
}

function Assert-HerdrVersionIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    Assert-HerdrBuildId -Value $BuildId
    $displayMatch = [regex]::Match($DisplayVersion, $script:DisplayVersionPattern)
    if (-not $displayMatch.Success -or $displayMatch.Groups[4].Value -cne $BuildId) {
        throw "Display version '$DisplayVersion' must be <major>.<minor>.<patch>-preview.$BuildId."
    }
    $match = [regex]::Match($NumericVersion, $script:NumericVersionPattern)
    if (-not $match.Success) {
        throw "Numeric version '$NumericVersion' must contain four dot-separated 0-65535 components."
    }
    for ($index = 1; $index -le 4; $index++) {
        if ([int]$match.Groups[$index].Value -gt 65535) {
            throw "Numeric version '$NumericVersion' contains a component greater than 65535."
        }
    }
    for ($index = 1; $index -le 3; $index++) {
        if ([int]$displayMatch.Groups[$index].Value -ne [int]$match.Groups[$index].Value) {
            throw "Numeric version '$NumericVersion' does not match display version '$DisplayVersion'."
        }
    }
}

function Get-HerdrFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "A required filesystem path is empty."
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a volume root as a Herdr install path: $fullPath"
    }
    return $fullPath.TrimEnd('\')
}

function Test-HerdrPathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    try {
        $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-HerdrReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Assert-HerdrRegularFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required regular file is missing: $Path"
    }
    if (Test-HerdrReparsePoint -Path $Path) {
        throw "Refusing a reparse-point file: $Path"
    }
}

function Assert-HerdrRegularDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Required regular directory is missing: $Path"
    }
    if (Test-HerdrReparsePoint -Path $Path) {
        throw "Refusing a reparse-point directory: $Path"
    }
}

function Get-HerdrSafeTreeEntries {
    param([Parameter(Mandatory = $true)][string]$Root)

    Assert-HerdrRegularDirectory -Path $Root
    $pending = New-Object System.Collections.Generic.Stack[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a reparse point inside managed content: $($entry.FullName)"
            }
            $entries.Add($entry)
            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
            }
        }
    }
    return $entries.ToArray()
}

function Get-HerdrRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escaped its expected root: $fullPath"
    }
    return $fullPath.Substring($fullRoot.Length + 1)
}

function ConvertTo-HerdrUtf8Bytes {
    param([Parameter(Mandatory = $true)][string]$Text)

    return $script:Utf8NoBom.GetBytes($Text)
}

function Read-HerdrStrictUtf8 {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-HerdrRegularFile -Path $Path
    return $script:Utf8NoBom.GetString([IO.File]::ReadAllBytes($Path))
}

function Get-HerdrSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-HerdrRegularFile -Path $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-HerdrAgentSkillSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = (Read-HerdrStrictUtf8 -Path $Path).Replace("`r`n", "`n")
    if ($text.Contains("`r")) {
        throw "Herdr agent skill contains an unsupported carriage return: $Path"
    }
    $lines = @($text -split "`n")
    if ($lines.Count -lt 4 -or $lines[0] -cne "---") {
        throw "Herdr agent skill lacks YAML frontmatter: $Path"
    }
    $frontmatterEnd = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -ceq "---") {
            $frontmatterEnd = $index
            break
        }
    }
    if ($frontmatterEnd -lt 2 -or @($lines[1..($frontmatterEnd - 1)] | Where-Object { $_ -ceq "name: herdr" }).Count -ne 1) {
        throw "Herdr agent skill frontmatter must contain exactly one 'name: herdr' entry: $Path"
    }
    return Get-HerdrSha256 -Path $Path
}

function Read-HerdrManagedSkillHashes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$CurrentSkillPath
    )

    $text = Read-HerdrStrictUtf8 -Path $Path
    if ($text.Contains("`r") -or -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Herdr managed skill hash manifest must use LF line endings and end with a newline: $Path"
    }
    $lines = @($text.Substring(0, $text.Length - 1) -split "`n")
    if ($lines.Count -lt 2 -or $lines[0] -cne $script:ManagedSkillHashesHeader) {
        throw "Invalid Herdr managed skill hash manifest header: $Path"
    }
    $hashes = New-Object System.Collections.Generic.List[string]
    $previous = $null
    foreach ($hash in @($lines[1..($lines.Count - 1)])) {
        if ($hash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Invalid SHA-256 entry in Herdr managed skill hash manifest: $Path"
        }
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous, $hash) -ge 0) {
            throw "Herdr managed skill hashes must be unique and sorted: $Path"
        }
        $hashes.Add($hash)
        $previous = $hash
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentSkillPath)) {
        $currentHash = Get-HerdrAgentSkillSha256 -Path $CurrentSkillPath
        if ($hashes -cnotcontains $currentHash) {
            throw "Current Herdr agent skill hash is absent from its managed hash manifest: $CurrentSkillPath"
        }
    }
    return $hashes.ToArray()
}

function Get-HerdrUserProfileRoot {
    param([string]$UserProfileRoot = $env:USERPROFILE)

    if ([string]::IsNullOrWhiteSpace($UserProfileRoot)) {
        throw "USERPROFILE is not set; agent skill directories cannot be located."
    }
    $root = Get-HerdrFullPath -Path $UserProfileRoot
    Assert-HerdrRegularDirectory -Path $root
    return $root
}

function Get-HerdrAgentSkillsRoot {
    param([string]$UserProfileRoot = $env:USERPROFILE)

    $userProfile = Get-HerdrUserProfileRoot -UserProfileRoot $UserProfileRoot
    return [IO.Path]::GetFullPath((Join-Path $userProfile ".agents\skills")).TrimEnd('\')
}

function Get-HerdrClaudeSkillsRoot {
    param(
        [string]$UserProfileRoot = $env:USERPROFILE,
        [string]$ClaudeConfigRoot = $env:CLAUDE_CONFIG_DIR
    )

    $userProfile = Get-HerdrUserProfileRoot -UserProfileRoot $UserProfileRoot
    if ([string]::IsNullOrWhiteSpace($ClaudeConfigRoot)) {
        $ClaudeConfigRoot = Join-Path $userProfile ".claude"
    } elseif ($ClaudeConfigRoot -ceq "~") {
        $ClaudeConfigRoot = $userProfile
    } elseif ($ClaudeConfigRoot.StartsWith("~\") -or $ClaudeConfigRoot.StartsWith("~/")) {
        $ClaudeConfigRoot = Join-Path $userProfile $ClaudeConfigRoot.Substring(2)
    }
    $ClaudeConfigRoot = Get-HerdrFullPath -Path $ClaudeConfigRoot
    return [IO.Path]::GetFullPath((Join-Path $ClaudeConfigRoot "skills")).TrimEnd('\')
}

function Test-HerdrClaudeCodeInstalled {
    param([string]$UserProfileRoot = $env:USERPROFILE)

    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
        return $true
    }
    $defaultConfigRoot = Split-Path -Parent (Get-HerdrClaudeSkillsRoot -UserProfileRoot $UserProfileRoot -ClaudeConfigRoot "")
    if (Test-Path -LiteralPath $defaultConfigRoot -PathType Container) {
        return $true
    }
    return $null -ne (Get-Command "claude" -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-HerdrClaudeSkillsRootsForRemoval {
    param([string]$UserProfileRoot = $env:USERPROFILE)

    $roots = New-Object System.Collections.Generic.List[string]
    $defaultRoot = Get-HerdrClaudeSkillsRoot -UserProfileRoot $UserProfileRoot -ClaudeConfigRoot ""
    $roots.Add($defaultRoot)
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
        $configured = Get-HerdrClaudeSkillsRoot -UserProfileRoot $UserProfileRoot -ClaudeConfigRoot $env:CLAUDE_CONFIG_DIR
        if (-not $configured.Equals($defaultRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $roots.Add($configured)
        }
    }
    return $roots.ToArray()
}

function Get-HerdrTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash((ConvertTo-HerdrUtf8Bytes -Text $Text)))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Write-HerdrDurableBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )

    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        65536,
        [IO.FileOptions]::WriteThrough
    )
    try {
        if ($Bytes.Length -gt 0) {
            $stream.Write($Bytes, 0, $Bytes.Length)
        }
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
}

function Write-HerdrDurableText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    Write-HerdrDurableBytes -Path $Path -Bytes (ConvertTo-HerdrUtf8Bytes -Text $Text)
}

function Copy-HerdrDurableFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-HerdrRegularFile -Path $Source
    $sourceStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $destinationStream = $null
    try {
        $destinationStream = New-Object IO.FileStream(
            $Destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            1048576,
            [IO.FileOptions]::WriteThrough
        )
        $buffer = New-Object byte[] 1048576
        while (($count = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $destinationStream.Write($buffer, 0, $count)
        }
        $destinationStream.Flush($true)
    } finally {
        if ($null -ne $destinationStream) {
            $destinationStream.Dispose()
        }
        $sourceStream.Dispose()
    }
}

function Copy-HerdrDurableTree {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )

    $entries = @(Get-HerdrSafeTreeEntries -Root $SourceRoot)
    New-Item -ItemType Directory -Path $DestinationRoot | Out-Null
    foreach ($directory in @($entries | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length })) {
        $relative = Get-HerdrRelativePath -Root $SourceRoot -Path $directory.FullName
        New-Item -ItemType Directory -Path (Join-Path $DestinationRoot $relative) | Out-Null
    }
    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)) {
        $relative = Get-HerdrRelativePath -Root $SourceRoot -Path $file.FullName
        Copy-HerdrDurableFile -Source $file.FullName -Destination (Join-Path $DestinationRoot $relative)
    }
}

function Initialize-HerdrSkillsRoot {
    param([Parameter(Mandatory = $true)][string]$SkillsRoot)

    $SkillsRoot = Get-HerdrFullPath -Path $SkillsRoot
    $parent = Split-Path -Parent $SkillsRoot
    $grandparent = Split-Path -Parent $parent
    Assert-HerdrRegularDirectory -Path $grandparent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $parent
    if (-not (Test-Path -LiteralPath $SkillsRoot)) {
        New-Item -ItemType Directory -Path $SkillsRoot | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $SkillsRoot
    return $SkillsRoot
}

function Assert-HerdrReplaceableAgentSkillPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to replace a reparse-point Herdr agent skill: $Path"
    }
    if ($item.PSIsContainer) {
        [void](Get-HerdrSafeTreeEntries -Root $Path)
    } else {
        Assert-HerdrRegularFile -Path $Path
    }
}

function Remove-HerdrReplaceableAgentSkillPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-HerdrReplaceableAgentSkillPath -Path $Path
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Force
        return
    }
    $entries = @(Get-HerdrSafeTreeEntries -Root $Path)
    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer })) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    foreach ($directory in @($entries | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
    Remove-Item -LiteralPath $Path -Force
}

function Remove-HerdrValidatedDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entries = @(Get-HerdrSafeTreeEntries -Root $Path)
    foreach ($file in @($entries | Where-Object { -not $_.PSIsContainer })) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    foreach ($directory in @($entries | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
    Remove-Item -LiteralPath $Path -Force
}

function Remove-HerdrUserSettings {
    param([Parameter(Mandatory = $true)][string]$UserProfileRoot)

    $profileRoot = Get-HerdrFullPath -Path $UserProfileRoot
    Assert-HerdrRegularDirectory -Path $profileRoot
    $settingsRoot = [IO.Path]::GetFullPath((Join-Path $profileRoot ".herdr")).TrimEnd('\')
    if (-not (Test-HerdrPathWithin -Path $settingsRoot -Root $profileRoot)) {
        throw "Herdr settings directory escaped the current user profile: $settingsRoot"
    }
    if (-not (Test-Path -LiteralPath $settingsRoot)) {
        return
    }
    Assert-HerdrRegularDirectory -Path $settingsRoot
    Remove-HerdrReplaceableAgentSkillPath -Path $settingsRoot
    if (Test-Path -LiteralPath $settingsRoot) {
        throw "Herdr settings cleanup did not reach terminal state: $settingsRoot"
    }
}

function Get-HerdrSkillFileState {
    param(
        [Parameter(Mandatory = $true)][string]$SkillsRoot,
        [Parameter(Mandatory = $true)][string[]]$KnownHashes
    )

    $SkillsRoot = Get-HerdrFullPath -Path $SkillsRoot
    $target = Join-Path $SkillsRoot "herdr"
    $skill = Join-Path $target "SKILL.md"
    $parent = Split-Path -Parent $SkillsRoot
    $grandparent = Split-Path -Parent $parent
    foreach ($component in @($grandparent, $parent, $SkillsRoot, $target)) {
        if (-not (Test-Path -LiteralPath $component)) {
            return [PSCustomObject]@{ State = "Absent"; Path = $skill }
        }
        if (-not (Test-Path -LiteralPath $component -PathType Container) -or
            (Test-HerdrReparsePoint -Path $component)) {
            return [PSCustomObject]@{ State = "Unsafe"; Path = $skill }
        }
    }
    if (-not (Test-Path -LiteralPath $skill)) {
        return [PSCustomObject]@{ State = "Absent"; Path = $skill }
    }
    if (-not (Test-Path -LiteralPath $skill -PathType Leaf) -or
        (Test-HerdrReparsePoint -Path $skill)) {
        return [PSCustomObject]@{ State = "Unsafe"; Path = $skill }
    }
    $hash = Get-HerdrSha256 -Path $skill
    $state = if ($KnownHashes -ccontains $hash) { "Known" } else { "Unknown" }
    return [PSCustomObject]@{ State = $state; Path = $skill; Sha256 = $hash }
}

function Install-HerdrSkillFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SkillsRoot,
        [Parameter(Mandatory = $true)][string[]]$KnownHashes
    )

    $expectedHash = Get-HerdrAgentSkillSha256 -Path $SourcePath
    if ($KnownHashes -cnotcontains $expectedHash) {
        throw "Embedded Herdr agent skill is absent from its managed hash manifest: $SourcePath"
    }
    Assert-HerdrSkillTarget -SkillsRoot $SkillsRoot
    $SkillsRoot = Get-HerdrFullPath -Path $SkillsRoot
    $target = Join-Path $SkillsRoot "herdr"
    if (Test-Path -LiteralPath $target) {
        Assert-HerdrRegularDirectory -Path $target
    } else {
        New-Item -ItemType Directory -Path $target | Out-Null
    }
    $destination = Join-Path $target "SKILL.md"
    if (Test-Path -LiteralPath $destination) {
        Assert-HerdrRegularFile -Path $destination
        if ($KnownHashes -cnotcontains (Get-HerdrSha256 -Path $destination)) {
            return $destination
        }
    }
    [IO.File]::Copy($SourcePath, $destination, $true)
    if ((Get-HerdrAgentSkillSha256 -Path $destination) -cne $expectedHash) {
        throw "Installed Herdr SKILL.md differs from its embedded source: $destination"
    }
    return $null
}

function Assert-HerdrSkillTarget {
    param([Parameter(Mandatory = $true)][string]$SkillsRoot)

    $SkillsRoot = Initialize-HerdrSkillsRoot -SkillsRoot $SkillsRoot
    $target = Join-Path $SkillsRoot "herdr"
    if (Test-Path -LiteralPath $target) {
        Assert-HerdrRegularDirectory -Path $target
        $destination = Join-Path $target "SKILL.md"
        if (Test-Path -LiteralPath $destination) {
            Assert-HerdrRegularFile -Path $destination
        }
    }
}

function Install-HerdrSkillCopies {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string]$ClaudeSkillsRoot,
        [Parameter(Mandatory = $true)][string[]]$KnownHashes
    )

    $preserved = New-Object System.Collections.Generic.List[string]
    $agentResult = Install-HerdrSkillFile -SourcePath $SourcePath -SkillsRoot $AgentSkillsRoot -KnownHashes $KnownHashes
    if (-not [string]::IsNullOrWhiteSpace($agentResult)) {
        $preserved.Add($agentResult)
    }
    if (-not [string]::IsNullOrWhiteSpace($ClaudeSkillsRoot) -and
        -not $ClaudeSkillsRoot.Equals($AgentSkillsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $claudeResult = Install-HerdrSkillFile -SourcePath $SourcePath -SkillsRoot $ClaudeSkillsRoot -KnownHashes $KnownHashes
        if (-not [string]::IsNullOrWhiteSpace($claudeResult)) {
            $preserved.Add($claudeResult)
        }
    }
    return $preserved.ToArray()
}

function Remove-HerdrSkillFile {
    param(
        [Parameter(Mandatory = $true)][string]$SkillsRoot,
        [Parameter(Mandatory = $true)][string[]]$KnownHashes,
        [Parameter(Mandatory = $true)][ValidateSet("Keep", "Auto", "Remove")][string]$Disposition
    )

    $state = Get-HerdrSkillFileState -SkillsRoot $SkillsRoot -KnownHashes $KnownHashes
    if ($state.State -ceq "Absent") {
        return $null
    }
    if ($state.State -ceq "Unsafe" -or $Disposition -ceq "Keep") {
        return $state.Path
    }
    Assert-HerdrRegularFile -Path $state.Path
    $isKnown = $KnownHashes -ccontains (Get-HerdrSha256 -Path $state.Path)
    if (-not $isKnown -and $Disposition -cne "Remove") {
        return $state.Path
    }
    Remove-Item -LiteralPath $state.Path -Force
    $target = Split-Path -Parent $state.Path
    if (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) {
        Remove-Item -LiteralPath $target -Force
    }
    return $null
}

function Remove-HerdrSkillCopies {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @(),
        [Parameter(Mandatory = $true)][string[]]$KnownHashes,
        [Parameter(Mandatory = $true)][ValidateSet("Keep", "Auto", "Remove")][string]$Disposition
    )

    $preserved = New-Object System.Collections.Generic.List[string]
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($AgentSkillsRoot) + @($ClaudeSkillsRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and $seen.Add([IO.Path]::GetFullPath($root))) {
            $result = Remove-HerdrSkillFile -SkillsRoot $root -KnownHashes $KnownHashes -Disposition $Disposition
            if (-not [string]::IsNullOrWhiteSpace($result)) {
                $preserved.Add($result)
            }
        }
    }
    return $preserved.ToArray()
}

function Remove-HerdrSkillCopiesBestEffort {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @(),
        [Parameter(Mandatory = $true)][string[]]$KnownHashes,
        [Parameter(Mandatory = $true)][ValidateSet("Keep", "Auto", "Remove")][string]$Disposition
    )

    try {
        return @(
            Remove-HerdrSkillCopies `
                -AgentSkillsRoot $AgentSkillsRoot `
                -ClaudeSkillsRoots $ClaudeSkillsRoots `
                -KnownHashes $KnownHashes `
                -Disposition $Disposition
        )
    } catch {
        [Console]::Out.WriteLine(
            "Warning: Herdr skill cleanup was incomplete and the residual was preserved. $($_.Exception.Message)"
        )
        return @()
    }
}

function Get-HerdrSkillRemovalDefault {
    param(
        [Parameter(Mandatory = $true)][string[]]$KnownHashes,
        [string]$AgentSkillsRoot = (Get-HerdrAgentSkillsRoot),
        [string[]]$ClaudeSkillsRoots = @(Get-HerdrClaudeSkillsRootsForRemoval)
    )

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($AgentSkillsRoot) + @($ClaudeSkillsRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and $seen.Add([IO.Path]::GetFullPath($root))) {
            $state = Get-HerdrSkillFileState -SkillsRoot $root -KnownHashes $KnownHashes
            if ($state.State -cne "Absent" -and $state.State -cne "Known") {
                return "Keep"
            }
        }
    }
    return "Remove"
}

function Publish-HerdrStagedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$BackupDir
    )

    Assert-HerdrRegularFile -Path $Source
    Assert-HerdrRegularDirectory -Path $BackupDir
    if (Test-Path -LiteralPath $Destination) {
        Assert-HerdrRegularFile -Path $Destination
    }
    $backup = Join-Path $BackupDir (([IO.Path]::GetFileName($Destination)) + ".backup." + [Guid]::NewGuid().ToString("N"))
    if (Test-Path -LiteralPath $Destination) {
        [IO.File]::Replace($Source, $Destination, $backup)
        Remove-Item -LiteralPath $backup -Force
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Get-HerdrPointerText {
    param([Parameter(Mandatory = $true)][string]$BuildId)

    Assert-HerdrBuildId -Value $BuildId
    return "herdr-pointer-v1`nbuild_id=$BuildId`n"
}

function Get-HerdrRuntimeReadyText {
    param([Parameter(Mandatory = $true)][string]$BuildId)

    Assert-HerdrBuildId -Value $BuildId
    return "herdr-runtime-v1`nbuild_id=$BuildId`n"
}

function Read-HerdrPointer {
    param([Parameter(Mandatory = $true)][string]$Path)

    $match = [regex]::Match((Read-HerdrStrictUtf8 -Path $Path), $script:PointerPattern)
    if (-not $match.Success) {
        throw "Invalid Herdr pointer file: $Path"
    }
    return $match.Groups[1].Value
}

function Read-HerdrRuntimeReady {
    param([Parameter(Mandatory = $true)][string]$Path)

    $match = [regex]::Match((Read-HerdrStrictUtf8 -Path $Path), $script:RuntimePattern)
    if (-not $match.Success) {
        throw "Invalid Herdr runtime marker: $Path"
    }
    return $match.Groups[1].Value
}

function Get-HerdrRuntimeManifestText {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $relativePaths = @(
        Get-HerdrSafeTreeEntries -Root $RuntimeRoot |
            Where-Object { -not $_.PSIsContainer -and $_.Name -cne "runtime.manifest" } |
            ForEach-Object { (Get-HerdrRelativePath -Root $RuntimeRoot -Path $_.FullName).Replace('\', '/') }
    )
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append($script:RuntimeManifestHeader).Append("`n")
    foreach ($relative in $relativePaths) {
        if ($relative -cnotmatch '^[0-9A-Za-z._/-]+$' -or $relative.StartsWith("/", [StringComparison]::Ordinal) -or $relative.Contains("../")) {
            throw "Runtime manifest cannot represent path '$relative'."
        }
        $hash = Get-HerdrSha256 -Path (Join-Path $RuntimeRoot $relative.Replace('/', '\'))
        [void]$builder.Append($hash).Append("  ").Append($relative).Append("`n")
    }
    return $builder.ToString()
}

function Read-HerdrRuntimeManifest {
    param([Parameter(Mandatory = $true)][string]$RuntimeRoot)

    $path = Join-Path $RuntimeRoot "runtime.manifest"
    $text = Read-HerdrStrictUtf8 -Path $path
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Runtime ownership manifest lacks its final newline: $path"
    }
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
    if ($lines.Count -lt 2 -or $lines[0] -cne $script:RuntimeManifestHeader) {
        throw "Invalid runtime ownership manifest header: $path"
    }
    $entries = [ordered]@{}
    $previous = $null
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $match = [regex]::Match($line, '^([0-9a-f]{64})  ([0-9A-Za-z._/-]+)$')
        if (-not $match.Success) {
            throw "Invalid runtime ownership manifest entry in $path."
        }
        $relative = $match.Groups[2].Value
        if ($relative.StartsWith("/", [StringComparison]::Ordinal) -or $relative.Contains("../") -or $relative -ceq "runtime.manifest") {
            throw "Unsafe runtime ownership path '$relative' in $path."
        }
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous, $relative) -ge 0) {
            throw "Runtime ownership manifest paths are not strictly ordinal-sorted: $path"
        }
        $entries[$relative] = $match.Groups[1].Value
        $previous = $relative
    }
    return ,$entries
}

function Assert-HerdrRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedBuildId
    )

    Assert-HerdrBuildId -Value $ExpectedBuildId
    $tree = @(Get-HerdrSafeTreeEntries -Root $Path)
    $actualBuildId = Read-HerdrRuntimeReady -Path (Join-Path $Path "runtime.ready")
    if ($actualBuildId -cne $ExpectedBuildId) {
        throw "Runtime marker build ID '$actualBuildId' does not match directory '$ExpectedBuildId'."
    }
    Assert-HerdrRegularFile -Path (Join-Path $Path "herdr.exe")
    $manifest = Read-HerdrRuntimeManifest -RuntimeRoot $Path
    foreach ($relative in $manifest.Keys) {
        if ([IO.Path]::GetFileName([string]$relative) -ceq "herdr-launcher.exe") {
            throw "Runtime contains the obsolete launcher hop and must be uninstalled first: $Path"
        }
    }
    $actualFiles = @($tree | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        (Get-HerdrRelativePath -Root $Path -Path $_.FullName).Replace('\', '/')
    })
    [Array]::Sort($actualFiles, [StringComparer]::Ordinal)
    $expectedFiles = @($manifest.Keys) + "runtime.manifest"
    [Array]::Sort($expectedFiles, [StringComparer]::Ordinal)
    if (@(Compare-Object $expectedFiles $actualFiles -CaseSensitive).Count -ne 0) {
        throw "Runtime owned-file set differs from its manifest: $Path"
    }
    $actualDirectories = @($tree | Where-Object { $_.PSIsContainer } | ForEach-Object {
        (Get-HerdrRelativePath -Root $Path -Path $_.FullName).Replace('\', '/')
    })
    [Array]::Sort($actualDirectories, [StringComparer]::Ordinal)
    $expectedDirectorySet = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
    foreach ($relative in $manifest.Keys) {
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', '\'))
        while (-not [string]::IsNullOrEmpty($parent)) {
            $normalizedParent = $parent.Replace('\', '/')
            $expectedDirectorySet[$normalizedParent] = $true
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }
    $expectedDirectories = @($expectedDirectorySet.Keys)
    [Array]::Sort($expectedDirectories, [StringComparer]::Ordinal)
    if (@(Compare-Object $expectedDirectories $actualDirectories -CaseSensitive).Count -ne 0) {
        throw "Runtime owned-directory set differs from its manifest-derived layout: $Path"
    }
    foreach ($relative in $manifest.Keys) {
        $actualHash = Get-HerdrSha256 -Path (Join-Path $Path $relative.Replace('/', '\'))
        if ($actualHash -cne [string]$manifest[$relative]) {
            throw "Runtime owned-file hash mismatch for $relative in $Path"
        }
    }
}

function New-HerdrRuntimeTree {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    if (Test-Path -LiteralPath $Destination) {
        throw "Runtime staging destination already exists: $Destination"
    }
    Copy-HerdrDurableTree -SourceRoot $StageDir -DestinationRoot $Destination
    Write-HerdrDurableText -Path (Join-Path $Destination "runtime.ready") -Text (Get-HerdrRuntimeReadyText -BuildId $BuildId)
    Write-HerdrDurableText -Path (Join-Path $Destination "runtime.manifest") -Text (Get-HerdrRuntimeManifestText -RuntimeRoot $Destination)
    Assert-HerdrRuntimeDirectory -Path $Destination -ExpectedBuildId $BuildId
}

function Assert-HerdrSameRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Existing,
        [Parameter(Mandatory = $true)][string]$Staged,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    Assert-HerdrRuntimeDirectory -Path $Existing -ExpectedBuildId $BuildId
    Assert-HerdrRuntimeDirectory -Path $Staged -ExpectedBuildId $BuildId
    $existingManifest = [IO.File]::ReadAllBytes((Join-Path $Existing "runtime.manifest"))
    $stagedManifest = [IO.File]::ReadAllBytes((Join-Path $Staged "runtime.manifest"))
    if ([Convert]::ToBase64String($existingManifest) -cne [Convert]::ToBase64String($stagedManifest)) {
        throw "Existing runtime $BuildId does not exactly match the staged owned payload."
    }
}

function Get-HerdrInstallManifestText {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapPath,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion
    )

    return Get-HerdrInstallManifestTextForHash `
        -BootstrapSha256 (Get-HerdrSha256 -Path $BootstrapPath) `
        -DisplayVersion $DisplayVersion `
        -NumericVersion $NumericVersion
}

function Get-HerdrInstallManifestTextForHash {
    param(
        [Parameter(Mandatory = $true)][string]$BootstrapSha256,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion
    )

    if ($BootstrapSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid managed launcher SHA-256 '$BootstrapSha256'."
    }
    return "$script:InstallManifestHeader`nbootstrap_sha256=$BootstrapSha256`ndisplay_version=$DisplayVersion`nnumeric_version=$NumericVersion`n"
}

function Read-HerdrInstallManifestFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $path = $Path
    $text = Read-HerdrStrictUtf8 -Path $path
    $match = [regex]::Match(
        $text,
        '\Aherdr-install-manifest-v1\nbootstrap_sha256=([0-9a-f]{64})\ndisplay_version=([0-9A-Za-z._+\-]+)\nnumeric_version=([0-9]{1,5}(?:\.[0-9]{1,5}){3})\n\z'
    )
    if (-not $match.Success) {
        throw "Invalid managed install ownership manifest: $path"
    }
    $bootstrapSha256 = $match.Groups[1].Value
    $manifestDisplayVersion = $match.Groups[2].Value
    $manifestNumericVersion = $match.Groups[3].Value
    if ($manifestDisplayVersion.Length -lt 25) {
        throw "Managed install display version does not contain a build ID: $path"
    }
    $manifestBuildId = $manifestDisplayVersion.Substring($manifestDisplayVersion.Length - 25)
    Assert-HerdrVersionIdentity `
        -DisplayVersion $manifestDisplayVersion `
        -NumericVersion $manifestNumericVersion `
        -BuildId $manifestBuildId
    return [PSCustomObject]@{
        BootstrapSha256 = $bootstrapSha256
        DisplayVersion = $manifestDisplayVersion
        NumericVersion = $manifestNumericVersion
    }
}

function Read-HerdrInstallManifest {
    param([Parameter(Mandatory = $true)][string]$StateDir)

    return Read-HerdrInstallManifestFile -Path (Join-Path $StateDir "install.manifest")
}

function Get-HerdrLauncherBuildId {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMilliseconds = 30000
    )

    Assert-HerdrRegularFile -Path $Path
    if ($TimeoutMilliseconds -lt 1 -or $TimeoutMilliseconds -gt 120000) {
        throw "Launcher build-ID timeout must be between 1 and 120000 milliseconds."
    }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.Arguments = $script:LauncherBuildIdArgument
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Could not start the managed launcher build-ID query: $Path"
        }
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "Managed launcher build-ID query exceeded $TimeoutMilliseconds ms: $Path"
        }
        [void]$process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $errorOutput.Length -ne 0) {
            throw "Managed launcher build-ID query failed for $Path (exit $($process.ExitCode)): $errorOutput"
        }
        if ($output.EndsWith("`r`n", [StringComparison]::Ordinal)) {
            $output = $output.Substring(0, $output.Length - 2)
        } elseif ($output.EndsWith("`n", [StringComparison]::Ordinal)) {
            $output = $output.Substring(0, $output.Length - 1)
        }
        Assert-HerdrBuildId -Value $output
        return $output
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-HerdrPendingLauncher {
    param([Parameter(Mandatory = $true)][string]$StateDir)

    Assert-HerdrRegularDirectory -Path $StateDir
    $matches = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $StateDir -Force)) {
        $match = [regex]::Match($entry.Name, $script:PendingLauncherPattern)
        if (-not $match.Success) {
            continue
        }
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Pending managed launcher is not a regular file: $($entry.FullName)"
        }
        $matches += [PSCustomObject]@{
            Path = $entry.FullName
            Sha256 = $match.Groups[1].Value
        }
    }
    if ($matches.Count -gt 1) {
        throw "Managed Herdr state contains more than one pending launcher."
    }
    if ($matches.Count -eq 0) {
        return $null
    }
    Assert-HerdrRegularFile -Path $matches[0].Path
    if ((Get-HerdrSha256 -Path $matches[0].Path) -cne $matches[0].Sha256) {
        throw "Pending managed launcher hash does not match its filename: $($matches[0].Path)"
    }
    return $matches[0]
}

function Set-HerdrPendingLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    Assert-HerdrRegularFile -Path $LauncherPath
    Assert-HerdrBuildId -Value $BuildId
    $launcherBuildId = Get-HerdrLauncherBuildId -Path $LauncherPath
    if ($launcherBuildId -cne $BuildId) {
        throw "Managed launcher build ID '$launcherBuildId' does not match runtime '$BuildId': $LauncherPath"
    }
    $stateDir = Join-Path $InstallRoot "state"
    $manifest = Read-HerdrInstallManifest -StateDir $stateDir
    $installed = Join-Path $InstallRoot "bin\herdr.exe"
    Assert-HerdrManagedBin -BinDir (Join-Path $InstallRoot "bin") -ExpectedBootstrapSha256 $manifest.BootstrapSha256
    $pendingSha256 = Get-HerdrSha256 -Path $LauncherPath
    $existing = Get-HerdrPendingLauncher -StateDir $stateDir
    if ($null -ne $existing -and $existing.Sha256 -cne $pendingSha256) {
        Remove-Item -LiteralPath $existing.Path -Force
        $existing = $null
    }
    if ($pendingSha256 -ceq (Get-HerdrSha256 -Path $installed)) {
        if ($null -ne $existing) {
            Remove-Item -LiteralPath $existing.Path -Force
        }
        return $null
    }
    if ($null -eq $existing) {
        $destination = Join-Path $stateDir "launcher.pending-$pendingSha256.exe"
        Copy-HerdrDurableFile -Source $LauncherPath -Destination $destination
        $existing = Get-HerdrPendingLauncher -StateDir $stateDir
    }
    return $existing
}

function Set-HerdrInstallManifestBootstrapHash {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$BootstrapSha256
    )

    $stateDir = Join-Path $InstallRoot "state"
    $current = Read-HerdrInstallManifest -StateDir $stateDir
    $staging = New-HerdrStagingDirectory -Kind "update" -InstallRoot $InstallRoot
    try {
        $metadata = Join-Path $staging.Path "metadata"
        New-Item -ItemType Directory -Path $metadata | Out-Null
        Write-HerdrDurableText -Path (Join-Path $metadata "install.manifest") -Text (
            Get-HerdrInstallManifestTextForHash `
                -BootstrapSha256 $BootstrapSha256 `
                -DisplayVersion $current.DisplayVersion `
                -NumericVersion $current.NumericVersion
        )
        Publish-HerdrStagedFile `
            -Source (Join-Path $metadata "install.manifest") `
            -Destination (Join-Path $stateDir "install.manifest") `
            -BackupDir $staging.Path
    } finally {
        if (Test-Path -LiteralPath $staging.Path) {
            Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
        }
    }
}

function Repair-HerdrLauncherPublication {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        return
    }
    Assert-HerdrRegularDirectory -Path $InstallRoot
    $stateDir = Join-Path $InstallRoot "state"
    $manifest = Read-HerdrInstallManifest -StateDir $stateDir
    $launcher = Join-Path $InstallRoot "bin\herdr.exe"
    Assert-HerdrRegularFile -Path $launcher
    $pending = Get-HerdrPendingLauncher -StateDir $stateDir
    $replacement = Join-Path $InstallRoot "bin\$script:LauncherReplacementName"
    if (Test-Path -LiteralPath $replacement) {
        Assert-HerdrRegularFile -Path $replacement
        if ($null -eq $pending -or (Get-HerdrSha256 -Path $replacement) -cne $pending.Sha256) {
            throw "Unrecognized managed launcher replacement file: $replacement"
        }
        Remove-Item -LiteralPath $replacement -Force
    }

    $installedSha256 = Get-HerdrSha256 -Path $launcher
    if ($installedSha256 -ceq $manifest.BootstrapSha256) {
        if ($null -ne $pending -and $pending.Sha256 -ceq $installedSha256) {
            Remove-Item -LiteralPath $pending.Path -Force
        }
        return
    }
    if ($null -eq $pending -or $installedSha256 -cne $pending.Sha256) {
        throw "Managed launcher hash matches neither the install manifest nor a validated pending launcher: $launcher"
    }
    $activeBuildId = Read-HerdrPointer -Path (Join-Path $stateDir "active")
    $pendingBuildId = Get-HerdrLauncherBuildId -Path $pending.Path
    if ($pendingBuildId -cne $activeBuildId) {
        throw "Pending managed launcher build ID '$pendingBuildId' does not match active runtime '$activeBuildId'."
    }
    Set-HerdrInstallManifestBootstrapHash -InstallRoot $InstallRoot -BootstrapSha256 $installedSha256
    Remove-Item -LiteralPath $pending.Path -Force
}

function Assert-HerdrManagedBin {
    param(
        [Parameter(Mandatory = $true)][string]$BinDir,
        [Parameter(Mandatory = $true)][string]$ExpectedBootstrapSha256
    )

    Assert-HerdrRegularDirectory -Path $BinDir
    $entries = @(Get-ChildItem -LiteralPath $BinDir -Force)
    $names = @($entries | ForEach-Object { $_.Name })
    if (@(Compare-Object @("herdr.exe", "managed-install-v1") $names -CaseSensitive).Count -ne 0) {
        throw "Managed Herdr bin directory has an unrecognized layout: $BinDir"
    }
    $bootstrap = Join-Path $BinDir "herdr.exe"
    Assert-HerdrRegularFile -Path $bootstrap
    if ((Get-HerdrSha256 -Path $bootstrap) -cne $ExpectedBootstrapSha256) {
        throw "Managed Herdr bootstrap hash does not match its install manifest: $bootstrap"
    }
    $sentinel = Join-Path $BinDir "managed-install-v1"
    Assert-HerdrRegularDirectory -Path $sentinel
    $sentinelEntries = @(Get-ChildItem -LiteralPath $sentinel -Force)
    if ($sentinelEntries.Count -ne 1 -or $sentinelEntries[0].Name -cne "marker" -or $sentinelEntries[0].PSIsContainer) {
        throw "Managed-bin sentinel has an unrecognized layout: $sentinel"
    }
    if ((Read-HerdrStrictUtf8 -Path (Join-Path $sentinel "marker")) -cne $script:ManagedBinMarkerText) {
        throw "Managed-bin sentinel marker is invalid: $sentinel"
    }
}

function Assert-HerdrLeasesDirectory {
    param([Parameter(Mandatory = $true)][string]$LeasesDir)

    Assert-HerdrRegularDirectory -Path $LeasesDir
    foreach ($lease in @(Get-ChildItem -LiteralPath $LeasesDir -Force)) {
        if ($lease.PSIsContainer -or
            ($lease.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $lease.Name -cnotmatch $script:LeasePattern) {
            throw "Unrecognized content in the Herdr leases directory: $($lease.FullName)"
        }
    }
}

function Assert-HerdrPackageManagerMarker {
    param([Parameter(Mandatory = $true)][string]$StateDir)

    $marker = Join-Path $StateDir "package-manager"
    if (-not (Test-Path -LiteralPath $marker)) {
        return
    }
    Assert-HerdrRegularFile -Path $marker
    if ((Read-HerdrStrictUtf8 -Path $marker) -cne $script:PackageManagerMarkerText) {
        throw "Managed Herdr package-manager marker is invalid: $marker"
    }
}

function Set-HerdrPackageManagerMarker {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct"
    )

    $marker = Join-Path $StateDir "package-manager"
    if (Test-Path -LiteralPath $marker) {
        Assert-HerdrPackageManagerMarker -StateDir $StateDir
        return
    }
    if ($InstallManager -ceq "WinGet") {
        Write-HerdrDurableText -Path $marker -Text $script:PackageManagerMarkerText
    }
}

function Assert-HerdrManagedRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Assert-HerdrRegularDirectory -Path $InstallRoot
    $allowedRoot = @("bin", "runtime", "state", "uninstall.exe", $script:UninstallRunnerName)
    foreach ($entry in @(Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        if ($allowedRoot -cnotcontains $entry.Name -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (($entry.Name -in @("bin", "runtime", "state")) -ne $entry.PSIsContainer)) {
            throw "Managed Herdr root has an unrecognized owned layout: $($entry.FullName)"
        }
    }
    foreach ($required in @("bin", "runtime", "state")) {
        if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $required))) {
            throw "Managed Herdr root is missing $required."
        }
    }
    $uninstaller = Join-Path $InstallRoot "uninstall.exe"
    if (Test-Path -LiteralPath $uninstaller) {
        Assert-HerdrRegularFile -Path $uninstaller
    }
    $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
    if (Test-Path -LiteralPath $uninstallRunner) {
        Assert-HerdrRegularFile -Path $uninstallRunner
    }
    $stateDir = Join-Path $InstallRoot "state"
    Assert-HerdrRegularDirectory -Path $stateDir
    $allowedState = @("active", "pending", "leases", "launcher.lock", "installer-helper.ps1", "install.manifest", "package-manager")
    foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -Force)) {
        $pendingLauncher = [regex]::IsMatch($entry.Name, $script:PendingLauncherPattern)
        if (($allowedState -cnotcontains $entry.Name -and -not $pendingLauncher) -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in managed Herdr state: $($entry.FullName)"
        }
    }
    foreach ($required in @("active", "leases", "launcher.lock", "install.manifest")) {
        if (-not (Test-Path -LiteralPath (Join-Path $stateDir $required))) {
            throw "Managed Herdr state is missing $required."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $stateDir "uninstall.pending")) {
        throw "Managed Herdr uninstall is incomplete; rerun uninstall before installing."
    }
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "launcher.lock")
    $installerHelper = Join-Path $stateDir "installer-helper.ps1"
    if (Test-Path -LiteralPath $installerHelper) {
        Assert-HerdrRegularFile -Path $installerHelper
    }
    Assert-HerdrLeasesDirectory -LeasesDir (Join-Path $stateDir "leases")
    $installManifest = Read-HerdrInstallManifest -StateDir $stateDir
    Assert-HerdrPackageManagerMarker -StateDir $stateDir
    Assert-HerdrManagedBin -BinDir (Join-Path $InstallRoot "bin") -ExpectedBootstrapSha256 $installManifest.BootstrapSha256
    [void](Get-HerdrPendingLauncher -StateDir $stateDir)

    $runtimeRoot = Join-Path $InstallRoot "runtime"
    Assert-HerdrRegularDirectory -Path $runtimeRoot
    foreach ($runtime in @(Get-ChildItem -LiteralPath $runtimeRoot -Force)) {
        if (-not $runtime.PSIsContainer -or $runtime.Name -cnotmatch $script:BuildIdPattern -or
            ($runtime.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in the Herdr runtime root: $($runtime.FullName)"
        }
        Assert-HerdrRuntimeDirectory -Path $runtime.FullName -ExpectedBuildId $runtime.Name
    }
    $activeBuild = Read-HerdrPointer -Path (Join-Path $stateDir "active")
    Assert-HerdrRuntimeDirectory -Path (Join-Path $runtimeRoot $activeBuild) -ExpectedBuildId $activeBuild
    $pendingPath = Join-Path $stateDir "pending"
    if (Test-Path -LiteralPath $pendingPath) {
        $pendingBuild = Read-HerdrPointer -Path $pendingPath
        Assert-HerdrRuntimeDirectory -Path (Join-Path $runtimeRoot $pendingBuild) -ExpectedBuildId $pendingBuild
    }
}

function Assert-HerdrUninstallRetryRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Assert-HerdrRegularDirectory -Path $InstallRoot
    $allowedRoot = @("bin", "runtime", "state", "uninstall.exe", $script:UninstallRunnerName)
    foreach ($entry in @(Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        if ($allowedRoot -cnotcontains $entry.Name -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in uninstall-retry root: $($entry.FullName)"
        }
    }
    Assert-HerdrRegularFile -Path (Join-Path $InstallRoot "uninstall.exe")
    $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
    if (Test-Path -LiteralPath $uninstallRunner) {
        Assert-HerdrRegularFile -Path $uninstallRunner
    }
    $stateDir = Join-Path $InstallRoot "state"
    Assert-HerdrRegularDirectory -Path $stateDir
    foreach ($required in @("installer-helper.ps1", "launcher.lock", "uninstall.pending")) {
        Assert-HerdrRegularFile -Path (Join-Path $stateDir $required)
    }
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "uninstall.pending")
    $allowedState = @("active", "pending", "leases", "launcher.lock", "installer-helper.ps1", "install.manifest", "package-manager", "uninstall.pending")
    foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -Force)) {
        $pendingLauncher = [regex]::IsMatch($entry.Name, $script:PendingLauncherPattern)
        if (($allowedState -cnotcontains $entry.Name -and -not $pendingLauncher) -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in uninstall-retry state: $($entry.FullName)"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $stateDir "leases")) {
        Assert-HerdrLeasesDirectory -LeasesDir (Join-Path $stateDir "leases")
    }
    $installManifest = if (Test-Path -LiteralPath (Join-Path $stateDir "install.manifest")) {
        Read-HerdrInstallManifest -StateDir $stateDir
    } else {
        $null
    }
    Assert-HerdrPackageManagerMarker -StateDir $stateDir
    if (Test-Path -LiteralPath (Join-Path $InstallRoot "bin")) {
        if ($null -eq $installManifest) {
            throw "Cannot validate remaining managed bin without install.manifest."
        }
        Assert-HerdrManagedBin -BinDir (Join-Path $InstallRoot "bin") -ExpectedBootstrapSha256 $installManifest.BootstrapSha256
    }
    if (Test-Path -LiteralPath $stateDir) {
        [void](Get-HerdrPendingLauncher -StateDir $stateDir)
    }
    if (Test-Path -LiteralPath (Join-Path $InstallRoot "runtime")) {
        Assert-HerdrRegularDirectory -Path (Join-Path $InstallRoot "runtime")
        foreach ($runtime in @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot "runtime") -Force)) {
            if (-not $runtime.PSIsContainer -or $runtime.Name -cnotmatch $script:BuildIdPattern) {
                throw "Unrecognized remaining runtime during uninstall: $($runtime.FullName)"
            }
            Assert-HerdrRuntimeDirectory -Path $runtime.FullName -ExpectedBuildId $runtime.Name
        }
    }
    foreach ($pointerName in @("active", "pending")) {
        $pointer = Join-Path $stateDir $pointerName
        if (Test-Path -LiteralPath $pointer) {
            [void](Read-HerdrPointer -Path $pointer)
        }
    }
}

function Assert-HerdrUninstallResidual {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    foreach ($entry in @(Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        if ($entry.Name -cnotin @("state", "uninstall.exe", $script:UninstallRunnerName) -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (($entry.Name -ceq "state") -ne $entry.PSIsContainer)) {
            throw "Uninstall residual root contains unexpected content."
        }
    }
    $stateDir = Join-Path $InstallRoot "state"
    $stateNames = @(Get-ChildItem -LiteralPath $stateDir -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object @("installer-helper.ps1", "launcher.lock", "uninstall.pending") $stateNames -CaseSensitive).Count -ne 0) {
        throw "Uninstall residual state contains unexpected content."
    }
    Assert-HerdrRegularFile -Path (Join-Path $InstallRoot "uninstall.exe")
    $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
    if (Test-Path -LiteralPath $uninstallRunner) {
        Assert-HerdrRegularFile -Path $uninstallRunner
    }
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "installer-helper.ps1")
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "launcher.lock")
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "uninstall.pending")
}

function Assert-HerdrUninstallCleanupRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Assert-HerdrRegularDirectory -Path $InstallRoot
    foreach ($entry in @(Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        if ($entry.Name -cnotin @("state", "uninstall.exe", $script:UninstallRunnerName) -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Uninstall cleanup root contains unexpected content: $($entry.FullName)"
        }
        if (($entry.Name -ceq "state") -ne $entry.PSIsContainer) {
            throw "Uninstall cleanup root entry has the wrong type: $($entry.FullName)"
        }
    }

    $uninstaller = Join-Path $InstallRoot "uninstall.exe"
    if (Test-Path -LiteralPath $uninstaller) {
        Assert-HerdrRegularFile -Path $uninstaller
    }
    $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
    if (Test-Path -LiteralPath $uninstallRunner) {
        Assert-HerdrRegularFile -Path $uninstallRunner
    }
    $stateDir = Join-Path $InstallRoot "state"
    if (-not (Test-Path -LiteralPath $stateDir)) {
        return
    }
    Assert-HerdrRegularDirectory -Path $stateDir
    foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -Force)) {
        if ($entry.Name -cnotin @("installer-helper.ps1", "launcher.lock", "uninstall.pending") -or
            $entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Uninstall cleanup state contains unexpected content: $($entry.FullName)"
        }
        Assert-HerdrRegularFile -Path $entry.FullName
    }
    $pending = Join-Path $stateDir "uninstall.pending"
    if (Test-Path -LiteralPath $pending) {
        Assert-HerdrRegularFile -Path $pending
    }
}

function Get-HerdrUninstallFaultMarkerPath {
    param(
        [Parameter(Mandatory = $true)][string]$Point,
        [Parameter(Mandatory = $true)][string]$MarkerPrefix
    )

    return Join-Path ([IO.Path]::GetTempPath()) "$MarkerPrefix-uninstall-fault-$Point.once"
}

function Invoke-HerdrUninstallFault {
    param(
        [Parameter(Mandatory = $true)][string]$Point,
        [string]$Fault = "",
        [string]$MarkerPrefix = "herdr"
    )

    if ($Fault -cne $Point) {
        return
    }
    $marker = Get-HerdrUninstallFaultMarkerPath -Point $Point -MarkerPrefix $MarkerPrefix
    if (Test-Path -LiteralPath $marker) {
        Assert-HerdrRegularFile -Path $marker
        return
    }
    Write-HerdrDurableBytes -Path $marker -Bytes ([byte[]]@())
    throw "Injected uninstall cleanup fault after $Point."
}

function Remove-HerdrUninstallFaultMarker {
    param([string]$Fault = "", [string]$MarkerPrefix = "herdr")

    if ([string]::IsNullOrEmpty($Fault)) {
        return
    }
    $marker = Get-HerdrUninstallFaultMarkerPath -Point $Fault -MarkerPrefix $MarkerPrefix
    if (Test-Path -LiteralPath $marker) {
        Assert-HerdrRegularFile -Path $marker
        Remove-Item -LiteralPath $marker -Force
    }
}

function Remove-HerdrTerminalUninstallFiles {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$UninstallFault = "",
        [string]$UninstallFaultMarkerPrefix = "herdr"
    )

    Assert-HerdrUninstallCleanupRoot -InstallRoot $InstallRoot
    $retryFiles = @()
    foreach ($name in @("uninstall.exe", $script:UninstallRunnerName)) {
        $path = Join-Path $InstallRoot $name
        if (Test-Path -LiteralPath $path) {
            Assert-HerdrRegularFile -Path $path
            $retryFiles += [PSCustomObject]@{
                Path = $path
                Bytes = [IO.File]::ReadAllBytes($path)
                Sha256 = Get-HerdrSha256 -Path $path
            }
        }
    }

    try {
        Invoke-HerdrUninstallFault -Point "before-uninstaller" -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix
        $uninstaller = Join-Path $InstallRoot "uninstall.exe"
        if (Test-Path -LiteralPath $uninstaller) {
            Remove-Item -LiteralPath $uninstaller -Force
        }
        Invoke-HerdrUninstallFault -Point "after-uninstaller" -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix

        $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
        if (Test-Path -LiteralPath $uninstallRunner) {
            Remove-Item -LiteralPath $uninstallRunner -Force
        }
        Invoke-HerdrUninstallFault -Point "after-uninstall-runner" -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix
        Remove-Item -LiteralPath $InstallRoot -Force
    } catch {
        $terminalFailure = $_
        try {
            if (Test-Path -LiteralPath $InstallRoot) {
                Assert-HerdrRegularDirectory -Path $InstallRoot
                foreach ($record in $retryFiles) {
                    if (Test-Path -LiteralPath $record.Path) {
                        Assert-HerdrRegularFile -Path $record.Path
                        if ((Get-HerdrSha256 -Path $record.Path) -cne $record.Sha256) {
                            throw "Refusing to overwrite changed uninstall retry state: $($record.Path)"
                        }
                    } else {
                        Write-HerdrDurableBytes -Path $record.Path -Bytes $record.Bytes
                    }
                    if ((Get-HerdrSha256 -Path $record.Path) -cne $record.Sha256) {
                        throw "Restored uninstall retry state does not match its actual pre-cleanup bytes: $($record.Path)"
                    }
                }
            }
        } catch {
            throw "Terminal uninstall cleanup failed ($($terminalFailure.Exception.Message)) and retry-file restoration also failed: $($_.Exception.Message)"
        }
        throw $terminalFailure
    }
}

function Remove-HerdrUninstallResidual {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$UninstallFault = "",
        [string]$UninstallFaultMarkerPrefix = "herdr"
    )

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        return
    }
    Assert-HerdrUninstallCleanupRoot -InstallRoot $InstallRoot
    $stateDir = Join-Path $InstallRoot "state"
    if (Test-Path -LiteralPath $stateDir) {
        foreach ($entry in @(
            [PSCustomObject]@{ Name = "uninstall.pending"; Fault = "after-uninstall-pending" },
            [PSCustomObject]@{ Name = "launcher.lock"; Fault = "after-launcher-lock" },
            [PSCustomObject]@{ Name = "installer-helper.ps1"; Fault = "after-installer-helper" }
        )) {
            $path = Join-Path $stateDir $entry.Name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
            Invoke-HerdrUninstallFault -Point $entry.Fault -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix
        }
        Remove-Item -LiteralPath $stateDir -Force
        Invoke-HerdrUninstallFault -Point "after-state-directory" -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix
    }
    Remove-HerdrTerminalUninstallFiles `
        -InstallRoot $InstallRoot `
        -UninstallFault $UninstallFault `
        -UninstallFaultMarkerPrefix $UninstallFaultMarkerPrefix
}

function New-HerdrStagingDirectory {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $parent = Split-Path -Parent $InstallRoot
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $parent
    $leaf = Split-Path -Leaf $InstallRoot
    $path = Join-Path $parent ("$leaf.installer-$Kind." + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return [PSCustomObject]@{ Kind = $Kind; Path = $path }
}

function Assert-HerdrStagingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update", "uninstall")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $expectedParent = Split-Path -Parent $InstallRoot
    $leaf = [regex]::Escape((Split-Path -Leaf $InstallRoot))
    $name = Split-Path -Leaf $Path
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $Path)).Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase)) -or
        $name -cnotmatch "^$leaf\.installer-$Kind\.[0-9a-f]{32}$") {
        throw "Refusing an unrecognized Herdr installer staging path: $Path"
    }
    Assert-HerdrRegularDirectory -Path $Path
    [void](Get-HerdrSafeTreeEntries -Root $Path)
}

function Get-HerdrStagingDirectories {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update", "uninstall")][string]$Kind
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $parent = Split-Path -Parent $InstallRoot
    $leaf = [regex]::Escape((Split-Path -Leaf $InstallRoot))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $parent -Force -Directory | Where-Object {
        $_.Name -cmatch "^$leaf\.installer-$Kind\.[0-9a-f]{32}$"
    } | ForEach-Object { $_.FullName })
}

function Remove-HerdrStagingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update", "uninstall")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [switch]$BestEffort
    )

    try {
        Assert-HerdrStagingDirectory -Path $Path -Kind $Kind -InstallRoot $InstallRoot
        $files = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object {
            -not $_.PSIsContainer
        } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($file in $files) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
        $directories = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($directory in $directories) {
            Remove-Item -LiteralPath $directory.FullName -Force
        }
        Remove-Item -LiteralPath $Path -Force
    } catch {
        if (-not $BestEffort) {
            throw
        }
        [Console]::Out.WriteLine(
            "Warning: Private installer staging was preserved and will not change the requested result: $Path. $($_.Exception.Message)"
        )
    }
}

function Remove-HerdrStaleStagingDirectories {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    foreach ($kind in @("fresh", "update", "uninstall")) {
        foreach ($path in @(Get-HerdrStagingDirectories -InstallRoot $InstallRoot -Kind $kind)) {
            Remove-HerdrStagingDirectory -Path $path -Kind $kind -InstallRoot $InstallRoot -BestEffort
        }
    }
}

function Test-HerdrLegacyLauncherHop {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $runtimeRoot = Join-Path $InstallRoot "runtime"
    if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container) -or
        (Get-Item -LiteralPath $runtimeRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $false
    }
    foreach ($runtime in @(Get-ChildItem -LiteralPath $runtimeRoot -Force -Directory)) {
        if (-not ($runtime.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            (Test-Path -LiteralPath (Join-Path $runtime.FullName "herdr-launcher.exe"))) {
            return $true
        }
    }
    return $false
}

function Get-HerdrRootKind {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        return "New"
    }
    if (Test-Path -LiteralPath (Join-Path $InstallRoot "state\uninstall.pending")) {
        Assert-HerdrUninstallRetryRoot -InstallRoot $InstallRoot
        return "UninstallRetry"
    }
    try {
        Assert-HerdrManagedRoot -InstallRoot $InstallRoot
        return "Managed"
    } catch {
        try {
            Assert-HerdrUninstallCleanupRoot -InstallRoot $InstallRoot
            return "UninstallResidual"
        } catch {
            throw "The existing Herdr installation is not compatible with this setup. Uninstall the existing Herdr or Herdr Win entry from Windows Installed Apps, then run setup again. Setup preserved: $InstallRoot"
        }
    }
}

function Get-HerdrLifecycleLockPath {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $parent = Split-Path -Parent $InstallRoot
    $leaf = Split-Path -Leaf $InstallRoot
    $path = [IO.Path]::GetFullPath((Join-Path $parent "$leaf.installer-lifecycle.lock"))
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $path)).Equals($parent, [StringComparison]::OrdinalIgnoreCase)) -or
        (Split-Path -Leaf $path) -cne "$leaf.installer-lifecycle.lock") {
        throw "Could not derive the fixed Herdr lifecycle lock beside $InstallRoot."
    }
    return $path
}

function Open-HerdrShareModeLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMilliseconds = 30000
    )

    if ($TimeoutMilliseconds -lt 1 -or $TimeoutMilliseconds -gt 120000) {
        throw "Lock timeout must be between 1 and 120000 milliseconds."
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $parent
    if (Test-Path -LiteralPath $Path) {
        Assert-HerdrRegularFile -Path $Path
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            if (Test-HerdrReparsePoint -Path $Path) {
                $stream.Dispose()
                throw "Refusing a reparse-point lock file: $Path"
            }
            return $stream
        } catch [IO.IOException] {
            if ($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw "Timed out after $TimeoutMilliseconds ms acquiring Herdr lock $Path"
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Invoke-HerdrLifecycleOperation {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [int]$TimeoutMilliseconds = 30000
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $lockPath = Get-HerdrLifecycleLockPath -InstallRoot $InstallRoot
    if (Test-Path -LiteralPath $lockPath) {
        Assert-HerdrRegularFile -Path $lockPath
        if ((Get-Item -LiteralPath $lockPath -Force).Length -ne 0) {
            throw "Persistent Herdr lifecycle lock contains unexpected data: $lockPath"
        }
    }
    # This zero-byte sibling file is the permanent rendezvous owner across
    # missing, replaced, and partially uninstalled InstallRoot generations.
    # Never delete it: every new installer/uninstaller must lock the same path.
    $lifecycleLock = Open-HerdrShareModeLock -Path $lockPath -TimeoutMilliseconds $TimeoutMilliseconds
    try {
        if ($lifecycleLock.Length -ne 0) {
            throw "Persistent Herdr lifecycle lock contains unexpected data: $lockPath"
        }
        return & $Operation
    } finally {
        $lifecycleLock.Dispose()
    }
}

function Get-HerdrProcessSnapshot {
    try {
        return @(Get-CimInstance -ClassName Win32_Process -Filter "ExecutablePath IS NOT NULL" -OperationTimeoutSec 5 -ErrorAction Stop |
            Select-Object ProcessId, ExecutablePath, Name)
    } catch {
        throw "Could not inspect running processes safely: $($_.Exception.Message)"
    }
}

function Test-HerdrProcessWithinRoots {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Roots
    )

    foreach ($process in $Processes) {
        $path = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        foreach ($root in $Roots) {
            if (Test-HerdrPathWithin -Path $path -Root $root) {
                return $true
            }
        }
    }
    return $false
}

function Get-HerdrLeaseStatus {
    param([Parameter(Mandatory = $true)][string]$LeasesDir)

    Assert-HerdrLeasesDirectory -LeasesDir $LeasesDir
    $active = New-Object System.Collections.Generic.List[string]
    $stale = New-Object System.Collections.Generic.List[string]
    $ambiguous = New-Object System.Collections.Generic.List[string]
    foreach ($lease in @(Get-ChildItem -LiteralPath $LeasesDir -Force)) {
        $probe = $null
        try {
            $probe = [IO.File]::Open($lease.FullName, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stale.Add($lease.FullName)
        } catch [UnauthorizedAccessException] {
            $ambiguous.Add($lease.FullName)
        } catch [IO.IOException] {
            $active.Add($lease.FullName)
        } finally {
            if ($null -ne $probe) {
                $probe.Dispose()
            }
        }
    }
    return [PSCustomObject]@{
        Active = $active.ToArray()
        Stale = $stale.ToArray()
        Ambiguous = $ambiguous.ToArray()
    }
}

function Remove-HerdrCurrentRootForConvergence {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [int]$LockTimeoutMilliseconds = 30000,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        return
    }
    Assert-HerdrRegularDirectory -Path $InstallRoot
    [void](Get-HerdrSafeTreeEntries -Root $InstallRoot)

    $stateDir = Join-Path $InstallRoot "state"
    $coordination = $null
    if (Test-Path -LiteralPath $stateDir) {
        Assert-HerdrRegularDirectory -Path $stateDir
        $coordination = Open-HerdrShareModeLock `
            -Path (Join-Path $stateDir "launcher.lock") `
            -TimeoutMilliseconds $LockTimeoutMilliseconds
    }
    try {
        [void](Get-HerdrSafeTreeEntries -Root $InstallRoot)
        $leasesDir = Join-Path $stateDir "leases"
        if (Test-Path -LiteralPath $leasesDir) {
            $leaseStatus = Get-HerdrLeaseStatus -LeasesDir $leasesDir
            if (@($leaseStatus.Active).Count -gt 0 -or @($leaseStatus.Ambiguous).Count -gt 0) {
                throw "Herdr is still active. Close all managed sessions before continuing."
            }
        }
        $processes = @(& $ProcessProvider)
        if (Test-HerdrProcessWithinRoots -Processes $processes -Roots @($InstallRoot)) {
            throw "A process from the managed Herdr install tree is still active."
        }
        foreach ($name in @("bin", "runtime")) {
            $path = Join-Path $InstallRoot $name
            if (Test-Path -LiteralPath $path) {
                Remove-HerdrValidatedDirectory -Path $path
            }
        }
    } finally {
        if ($null -ne $coordination) {
            $coordination.Dispose()
        }
    }
    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-HerdrValidatedDirectory -Path $InstallRoot
    }
}

function Remove-HerdrStaleLeases {
    param([Parameter(Mandatory = $true)][object]$LeaseStatus)

    if (@($LeaseStatus.Active).Count -gt 0 -or @($LeaseStatus.Ambiguous).Count -gt 0) {
        throw "Cannot remove Herdr leases while an active or ambiguous lease exists."
    }
    foreach ($path in @($LeaseStatus.Stale)) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Remove-HerdrRuntimeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    Assert-HerdrRuntimeDirectory -Path $Path -ExpectedBuildId $BuildId
    $staging = New-HerdrStagingDirectory -Kind "update" -InstallRoot $InstallRoot
    $moved = $false
    try {
        [IO.Directory]::Move($Path, (Join-Path $staging.Path "runtime"))
        $moved = $true
        Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
    } finally {
        if (-not $moved -and (Test-Path -LiteralPath $staging.Path)) {
            Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
        }
    }
}

function Remove-HerdrInactiveRuntimes {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [AllowEmptyCollection()][object[]]$Processes = @()
    )

    $stateDir = Join-Path $InstallRoot "state"
    $runtimeRoot = Join-Path $InstallRoot "runtime"
    $protected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$protected.Add((Read-HerdrPointer -Path (Join-Path $stateDir "active")))
    $pendingPointer = Join-Path $stateDir "pending"
    if (Test-Path -LiteralPath $pendingPointer) {
        [void]$protected.Add((Read-HerdrPointer -Path $pendingPointer))
    }

    foreach ($runtime in @(Get-ChildItem -LiteralPath $runtimeRoot -Force -Directory)) {
        if ($protected.Contains($runtime.Name)) {
            continue
        }
        Assert-HerdrRuntimeDirectory -Path $runtime.FullName -ExpectedBuildId $runtime.Name
        if (Test-HerdrProcessWithinRoots -Processes $Processes -Roots @($runtime.FullName)) {
            continue
        }
        $leasePath = Join-Path $stateDir "leases\$($runtime.Name).lease"
        $leaseProbe = $null
        if (Test-Path -LiteralPath $leasePath) {
            Assert-HerdrRegularFile -Path $leasePath
            try {
                $leaseProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            } catch [UnauthorizedAccessException] {
                continue
            } catch [IO.IOException] {
                continue
            }
        }
        if ($null -ne $leaseProbe) {
            $leaseProbe.Dispose()
        }
        Remove-HerdrRuntimeDirectory -InstallRoot $InstallRoot -Path $runtime.FullName -BuildId $runtime.Name
        if (Test-Path -LiteralPath $leasePath) {
            Remove-Item -LiteralPath $leasePath -Force
        }
    }
}

function Complete-HerdrLauncherUpdateLocked {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
    $stateDir = Join-Path $InstallRoot "state"
    $pending = Get-HerdrPendingLauncher -StateDir $stateDir
    if ($null -eq $pending) {
        return $false
    }
    $leaseStatus = Get-HerdrLeaseStatus -LeasesDir (Join-Path $stateDir "leases")
    if (@($leaseStatus.Active).Count -gt 0 -or @($leaseStatus.Ambiguous).Count -gt 0) {
        return $false
    }
    $activeBuildId = Read-HerdrPointer -Path (Join-Path $stateDir "active")
    $pendingBuildId = Get-HerdrLauncherBuildId -Path $pending.Path
    if ($pendingBuildId -cne $activeBuildId) {
        throw "Pending managed launcher build ID '$pendingBuildId' does not match active runtime '$activeBuildId'."
    }

    $launcher = Join-Path $InstallRoot "bin\herdr.exe"
    $replacement = Join-Path $InstallRoot "bin\$script:LauncherReplacementName"
    if (Test-Path -LiteralPath $replacement) {
        Assert-HerdrRegularFile -Path $replacement
        Remove-Item -LiteralPath $replacement -Force
    }
    Copy-HerdrDurableFile -Source $pending.Path -Destination $replacement
    $staging = New-HerdrStagingDirectory -Kind "update" -InstallRoot $InstallRoot
    $backup = Join-Path $staging.Path ("launcher.backup." + [Guid]::NewGuid().ToString("N"))
    try {
        [IO.File]::Replace($replacement, $launcher, $backup)
    } catch [IO.IOException] {
        if (Test-Path -LiteralPath $replacement) {
            Remove-Item -LiteralPath $replacement -Force
        }
        Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
        return $false
    }
    Remove-Item -LiteralPath $backup -Force
    Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
    if ((Get-HerdrSha256 -Path $launcher) -cne $pending.Sha256) {
        throw "Published managed launcher does not match its staged SHA-256: $launcher"
    }
    Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
    return $true
}

function Invoke-HerdrMaintenanceLocked {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
    Assert-HerdrManagedRoot -InstallRoot $InstallRoot
    $processes = @(Get-HerdrProcessSnapshot)
    Remove-HerdrInactiveRuntimes -InstallRoot $InstallRoot -Processes $processes
    $launcherUpdated = Complete-HerdrLauncherUpdateLocked -InstallRoot $InstallRoot
    Assert-HerdrManagedRoot -InstallRoot $InstallRoot
    return [PSCustomObject]@{ LauncherUpdated = $launcherUpdated }
}

function Wait-HerdrParentProcessExit {
    param(
        [uint32]$ProcessId,
        [int]$TimeoutMilliseconds = 30000
    )

    if ($ProcessId -eq 0) {
        return $true
    }
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    } catch {
        return $true
    }
    try {
        return $process.WaitForExit($TimeoutMilliseconds)
    } finally {
        $process.Dispose()
    }
}

function Invoke-HerdrCompleteMaintenance {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [uint32]$ParentProcessId = 0,
        [int]$LifecycleLockTimeoutMilliseconds = 30000
    )

    if (-not (Wait-HerdrParentProcessExit -ProcessId $ParentProcessId)) {
        return [PSCustomObject]@{ Status = "Deferred"; LauncherUpdated = $false }
    }
    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    return Invoke-HerdrLifecycleOperation -InstallRoot $InstallRoot -TimeoutMilliseconds $LifecycleLockTimeoutMilliseconds -Operation {
        if (-not (Test-Path -LiteralPath $InstallRoot)) {
            return [PSCustomObject]@{ Status = "Missing"; LauncherUpdated = $false }
        }
        Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
        Remove-HerdrStaleStagingDirectories -InstallRoot $InstallRoot
        if ((Get-HerdrRootKind -InstallRoot $InstallRoot) -ne "Managed") {
            return [PSCustomObject]@{ Status = "Deferred"; LauncherUpdated = $false }
        }
        $coordination = Open-HerdrShareModeLock -Path (Join-Path $InstallRoot "state\launcher.lock") -TimeoutMilliseconds 30000
        try {
            $result = Invoke-HerdrMaintenanceLocked -InstallRoot $InstallRoot
            return [PSCustomObject]@{ Status = "Complete"; LauncherUpdated = $result.LauncherUpdated }
        } finally {
            $coordination.Dispose()
        }
    }
}

function New-HerdrManagedRootTree {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$UninstallRunnerPath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct"
    )

    New-Item -ItemType Directory -Path (Join-Path $Destination "bin\managed-install-v1") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Destination "runtime") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Destination "state\leases") -Force | Out-Null
    Copy-HerdrDurableFile -Source $LauncherPath -Destination (Join-Path $Destination "bin\herdr.exe")
    Write-HerdrDurableText -Path (Join-Path $Destination "bin\managed-install-v1\marker") -Text $script:ManagedBinMarkerText
    New-HerdrRuntimeTree -Destination (Join-Path $Destination "runtime\$BuildId") -StageDir $StageDir -BuildId $BuildId
    Write-HerdrDurableBytes -Path (Join-Path $Destination "state\launcher.lock") -Bytes ([byte[]]@())
    Write-HerdrDurableText -Path (Join-Path $Destination "state\active") -Text (Get-HerdrPointerText -BuildId $BuildId)
    Copy-HerdrDurableFile -Source $HelperSourcePath -Destination (Join-Path $Destination "state\installer-helper.ps1")
    Copy-HerdrDurableFile -Source $UninstallRunnerPath -Destination (Join-Path $Destination $script:UninstallRunnerName)
    Copy-HerdrDurableFile -Source $UninstallerPath -Destination (Join-Path $Destination "uninstall.exe")
    Write-HerdrDurableText -Path (Join-Path $Destination "state\install.manifest") -Text (
        Get-HerdrInstallManifestText `
            -BootstrapPath (Join-Path $Destination "bin\herdr.exe") `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion
    )
    Set-HerdrPackageManagerMarker -StateDir (Join-Path $Destination "state") -InstallManager $InstallManager
    Assert-HerdrManagedRoot -InstallRoot $Destination
}

function Publish-HerdrFreshStaging {
    param(
        [Parameter(Mandatory = $true)][object]$Staging,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $stagedRoot = Join-Path $Staging.Path "root"
    Assert-HerdrManagedRoot -InstallRoot $stagedRoot
    if (Test-Path -LiteralPath $InstallRoot) {
        throw "Herdr install root appeared before fresh publication."
    }
    [IO.Directory]::Move($stagedRoot, $InstallRoot)
}

function Install-HerdrManagedUpgrade {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$UninstallRunnerPath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct",
        [int]$LockTimeoutMilliseconds = 30000
    )

    $staging = New-HerdrStagingDirectory -Kind "update" -InstallRoot $InstallRoot
    try {
        $stagedRuntime = Join-Path $staging.Path "runtime"
        New-HerdrRuntimeTree -Destination $stagedRuntime -StageDir $StageDir -BuildId $BuildId
        $metadata = Join-Path $staging.Path "metadata"
        New-Item -ItemType Directory -Path $metadata | Out-Null
        Copy-HerdrDurableFile -Source $HelperSourcePath -Destination (Join-Path $metadata "installer-helper.ps1")
        Copy-HerdrDurableFile -Source $UninstallRunnerPath -Destination (Join-Path $metadata $script:UninstallRunnerName)
        Copy-HerdrDurableFile -Source $UninstallerPath -Destination (Join-Path $metadata "uninstall.exe")
        Write-HerdrDurableText -Path (Join-Path $metadata "pending") -Text (Get-HerdrPointerText -BuildId $BuildId)

        $stateDir = Join-Path $InstallRoot "state"
        $coordination = Open-HerdrShareModeLock -Path (Join-Path $stateDir "launcher.lock") -TimeoutMilliseconds $LockTimeoutMilliseconds
        try {
            Assert-HerdrManagedRoot -InstallRoot $InstallRoot
            Write-HerdrDurableText -Path (Join-Path $metadata "install.manifest") -Text (
                Get-HerdrInstallManifestText `
                    -BootstrapPath (Join-Path $InstallRoot "bin\herdr.exe") `
                    -DisplayVersion $DisplayVersion `
                    -NumericVersion $NumericVersion
            )
            $runtimeDestination = Join-Path $InstallRoot "runtime\$BuildId"
            if (Test-Path -LiteralPath $runtimeDestination) {
                Assert-HerdrSameRuntime -Existing $runtimeDestination -Staged $stagedRuntime -BuildId $BuildId
                Remove-Item -LiteralPath $stagedRuntime -Recurse -Force
            } else {
                [IO.Directory]::Move($stagedRuntime, $runtimeDestination)
            }

            Publish-HerdrStagedFile -Source (Join-Path $metadata "installer-helper.ps1") -Destination (Join-Path $stateDir "installer-helper.ps1") -BackupDir $staging.Path
            Publish-HerdrStagedFile -Source (Join-Path $metadata $script:UninstallRunnerName) -Destination (Join-Path $InstallRoot $script:UninstallRunnerName) -BackupDir $staging.Path
            Publish-HerdrStagedFile -Source (Join-Path $metadata "uninstall.exe") -Destination (Join-Path $InstallRoot "uninstall.exe") -BackupDir $staging.Path
            [void](Set-HerdrPendingLauncher -InstallRoot $InstallRoot -LauncherPath $LauncherPath -BuildId $BuildId)

            $activePath = Join-Path $stateDir "active"
            $activeBuild = Read-HerdrPointer -Path $activePath
            $pendingPath = Join-Path $stateDir "pending"
            if ($activeBuild -ceq $BuildId) {
                if (Test-Path -LiteralPath $pendingPath) {
                    Remove-Item -LiteralPath $pendingPath -Force
                }
                Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $staging.Path
                [void](Invoke-HerdrMaintenanceLocked -InstallRoot $InstallRoot)
                Set-HerdrPackageManagerMarker -StateDir $stateDir -InstallManager $InstallManager
                return [PSCustomObject]@{ Status = "AlreadyActive"; BuildId = $BuildId }
            }
            Publish-HerdrStagedFile -Source (Join-Path $metadata "pending") -Destination $pendingPath -BackupDir $staging.Path
            $leaseStatus = Get-HerdrLeaseStatus -LeasesDir (Join-Path $stateDir "leases")
            if (@($leaseStatus.Active).Count -gt 0 -or @($leaseStatus.Ambiguous).Count -gt 0) {
                Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $staging.Path
                [void](Invoke-HerdrMaintenanceLocked -InstallRoot $InstallRoot)
                Set-HerdrPackageManagerMarker -StateDir $stateDir -InstallManager $InstallManager
                return [PSCustomObject]@{ Status = "Pending"; BuildId = $BuildId }
            }
            Remove-HerdrStaleLeases -LeaseStatus $leaseStatus
            $activeBackup = Join-Path $staging.Path ("active.backup." + [Guid]::NewGuid().ToString("N"))
            [IO.File]::Replace($pendingPath, $activePath, $activeBackup)
            Remove-Item -LiteralPath $activeBackup -Force
            if ((Read-HerdrPointer -Path $activePath) -cne $BuildId -or (Test-Path -LiteralPath $pendingPath)) {
                throw "Atomic pending activation did not publish the expected active pointer."
            }
            Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $staging.Path
            [void](Invoke-HerdrMaintenanceLocked -InstallRoot $InstallRoot)
            Set-HerdrPackageManagerMarker -StateDir $stateDir -InstallManager $InstallManager
            return [PSCustomObject]@{ Status = "Activated"; BuildId = $BuildId }
        } finally {
            $coordination.Dispose()
        }
    } finally {
        if (Test-Path -LiteralPath $staging.Path) {
            Remove-HerdrStagingDirectory -Path $staging.Path -Kind "update" -InstallRoot $InstallRoot -BestEffort
        }
    }
}

function Install-HerdrLayout {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$UninstallRunnerPath,
        [Parameter(Mandatory = $true)][string]$SkillSourcePath,
        [Parameter(Mandatory = $true)][string]$SkillHashManifestPath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string]$ClaudeSkillsRoot,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct",
        [int]$LockTimeoutMilliseconds = 30000,
        [bool]$AllowCurrentRootConvergence = $false,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    Assert-HerdrVersionIdentity -DisplayVersion $DisplayVersion -NumericVersion $NumericVersion -BuildId $BuildId
    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    if (Test-Path -LiteralPath $InstallRoot) {
        Assert-HerdrRegularDirectory -Path $InstallRoot
    }
    $StageDir = Get-HerdrFullPath -Path $StageDir
    Assert-HerdrRegularDirectory -Path $StageDir
    Assert-HerdrRegularFile -Path $LauncherPath
    $launcherBuildId = Get-HerdrLauncherBuildId -Path $LauncherPath
    if ($launcherBuildId -cne $BuildId) {
        throw "Managed launcher build ID '$launcherBuildId' does not match runtime '$BuildId': $LauncherPath"
    }
    Assert-HerdrRegularFile -Path $UninstallerPath
    Assert-HerdrRegularFile -Path $HelperSourcePath
    Assert-HerdrRegularFile -Path $UninstallRunnerPath
    $knownSkillHashes = @(Read-HerdrManagedSkillHashes -Path $SkillHashManifestPath -CurrentSkillPath $SkillSourcePath)
    Assert-HerdrSkillTarget -SkillsRoot $AgentSkillsRoot
    if (-not [string]::IsNullOrWhiteSpace($ClaudeSkillsRoot) -and
        -not $ClaudeSkillsRoot.Equals($AgentSkillsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Assert-HerdrSkillTarget -SkillsRoot $ClaudeSkillsRoot
    }

    $effectiveInstallManager = $InstallManager
    $packageManagerMarker = Join-Path $InstallRoot "state\package-manager"
    if (Test-Path -LiteralPath $packageManagerMarker) {
        try {
            Assert-HerdrPackageManagerMarker -StateDir (Split-Path -Parent $packageManagerMarker)
            $effectiveInstallManager = "WinGet"
        } catch {
            # Normal layout validation or direct convergence owns malformed
            # current-root state. Preserve only positively validated WinGet
            # ownership across a direct rebuild.
        }
    }

    Remove-HerdrStaleStagingDirectories -InstallRoot $InstallRoot

    if (Test-HerdrLegacyLauncherHop -InstallRoot $InstallRoot) {
        throw "The existing Herdr installation is not compatible with this setup. Uninstall the existing Herdr or Herdr Win entry from Windows Installed Apps, then run setup again. Setup preserved: $InstallRoot"
    }

    try {
        if ((Test-Path -LiteralPath (Join-Path $InstallRoot "state\install.manifest")) -and
            (Test-Path -LiteralPath (Join-Path $InstallRoot "bin\herdr.exe"))) {
            Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
        }
        $rootKind = Get-HerdrRootKind -InstallRoot $InstallRoot
    } catch {
        if (-not $AllowCurrentRootConvergence) {
            throw
        }
        [Console]::Out.WriteLine(
            "Warning: The registered current Herdr root could not use normal repair and will be rebuilt directly. $($_.Exception.Message)"
        )
        Remove-HerdrCurrentRootForConvergence `
            -InstallRoot $InstallRoot `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds `
            -ProcessProvider $ProcessProvider
        $rootKind = "New"
    }
    if ($rootKind -eq "UninstallRetry") {
        $recoveryClaudeRoots = if ([string]::IsNullOrWhiteSpace($ClaudeSkillsRoot)) { @() } else { @($ClaudeSkillsRoot) }
        [void](Invoke-HerdrUninstallLayout `
            -InstallRoot $InstallRoot `
            -AgentSkillsRoot $AgentSkillsRoot `
            -ClaudeSkillsRoots $recoveryClaudeRoots `
            -KnownSkillHashes $knownSkillHashes `
            -SkillDisposition Keep `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds `
            -AllowCurrentRootConvergence $true `
            -ProcessProvider $ProcessProvider)
        $rootKind = "New"
    } elseif ($rootKind -eq "UninstallResidual") {
        Remove-HerdrUninstallResidual -InstallRoot $InstallRoot
        $rootKind = "New"
    }
    if ($rootKind -eq "Managed") {
        $result = Install-HerdrManagedUpgrade `
            -InstallRoot $InstallRoot `
            -StageDir $StageDir `
            -LauncherPath $LauncherPath `
            -UninstallerPath $UninstallerPath `
            -HelperSourcePath $HelperSourcePath `
            -UninstallRunnerPath $UninstallRunnerPath `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -InstallManager $effectiveInstallManager `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    } else {
        $staging = New-HerdrStagingDirectory -Kind "fresh" -InstallRoot $InstallRoot
        try {
            $stagedRoot = Join-Path $staging.Path "root"
            New-HerdrManagedRootTree `
                -Destination $stagedRoot `
                -StageDir $StageDir `
                -LauncherPath $LauncherPath `
                -UninstallerPath $UninstallerPath `
                -HelperSourcePath $HelperSourcePath `
                -UninstallRunnerPath $UninstallRunnerPath `
                -BuildId $BuildId `
                -DisplayVersion $DisplayVersion `
                -NumericVersion $NumericVersion `
                -InstallManager $effectiveInstallManager
            Publish-HerdrFreshStaging `
                -Staging $staging `
                -InstallRoot $InstallRoot
            $result = [PSCustomObject]@{ Status = "Activated"; BuildId = $BuildId }
        } finally {
            if (Test-Path -LiteralPath $staging.Path) {
                Remove-HerdrStagingDirectory -Path $staging.Path -Kind "fresh" -InstallRoot $InstallRoot -BestEffort
            }
        }
    }
    $preservedSkillPaths = @(
        Install-HerdrSkillCopies `
            -SourcePath $SkillSourcePath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -ClaudeSkillsRoot $ClaudeSkillsRoot `
            -KnownHashes $knownSkillHashes
    )
    return [PSCustomObject]@{
        Status = $result.Status
        BuildId = $result.BuildId
        PreservedSkillPaths = $preservedSkillPaths
    }
}

function Get-HerdrComparablePathEntry {
    param([AllowNull()][string]$Entry, [bool]$ExpandVariables = $true)

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return $null
    }
    $candidate = $Entry.Trim()
    if ($candidate.Length -ge 2 -and $candidate[0] -eq '"' -and $candidate[$candidate.Length - 1] -eq '"') {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    if ($ExpandVariables) {
        $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    }
    try {
        return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
    } catch {
        return $candidate.TrimEnd('\')
    }
}

function Test-HerdrPathEntryEqual {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right, [bool]$ExpandVariables = $true)

    $leftComparable = Get-HerdrComparablePathEntry -Entry $Left -ExpandVariables $ExpandVariables
    $rightComparable = Get-HerdrComparablePathEntry -Entry $Right -ExpandVariables $ExpandVariables
    return $null -ne $leftComparable -and $null -ne $rightComparable -and
        $leftComparable.Equals($rightComparable, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-HerdrUserPathUpdate {
    param(
        [AllowEmptyString()][string]$Current,
        [Parameter(Mandatory = $true)][string]$Entry,
        [Parameter(Mandatory = $true)][ValidateSet("Add", "Remove")][string]$RequestedAction,
        [bool]$ExpandVariables,
        [bool]$InstallerOwned
    )

    $segments = @($Current.Split([char[]]@(';'), [StringSplitOptions]::None))
    if ($RequestedAction -ceq "Add") {
        $equivalent = @($segments | Where-Object {
            Test-HerdrPathEntryEqual -Left $_ -Right $Entry -ExpandVariables $ExpandVariables
        })
        if ($equivalent.Count -gt 0) {
            $exactExists = @($segments | Where-Object { [string]$_ -ceq $Entry }).Count -gt 0
            return [PSCustomObject]@{
                Changed = $false
                Value = $Current
                Owned = $InstallerOwned -and $exactExists
            }
        }
        $updated = if ([string]::IsNullOrEmpty($Current)) { $Entry } else { "$Entry;$Current" }
        return [PSCustomObject]@{ Changed = $true; Value = $updated; Owned = $true }
    }

    if (-not $InstallerOwned) {
        return [PSCustomObject]@{ Changed = $false; Value = $Current; Owned = $false }
    }
    $removeIndex = -1
    for ($index = 0; $index -lt $segments.Count; $index += 1) {
        if ([string]$segments[$index] -ceq $Entry) {
            $removeIndex = $index
            break
        }
    }
    if ($removeIndex -lt 0) {
        return [PSCustomObject]@{ Changed = $false; Value = $Current; Owned = $false }
    }
    $kept = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $segments.Count; $index += 1) {
        if ($index -ne $removeIndex) {
            [void]$kept.Add([string]$segments[$index])
        }
    }
    return [PSCustomObject]@{
        Changed = $true
        Value = [string]::Join(';', [string[]]$kept)
        Owned = $false
    }
}

function Update-HerdrUserPath {
    param(
        [Parameter(Mandatory = $true)][string]$BinDir,
        [Parameter(Mandatory = $true)][ValidateSet("Add", "Remove")][string]$RequestedAction,
        [bool]$InstallerOwned,
        [string]$RegistrySubKey = "Environment"
    )

    if ($RequestedAction -ceq "Remove" -and -not $InstallerOwned) {
        return [PSCustomObject]@{ Changed = $false; Owned = $false }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey, $true)
    if ($null -eq $key -and $RequestedAction -ceq "Remove") {
        return [PSCustomObject]@{ Changed = $false; Owned = $false }
    }
    if ($null -eq $key) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($RegistrySubKey)
    }
    if ($null -eq $key) {
        throw "Could not open the current-user Environment registry key."
    }
    try {
        $hasPath = @($key.GetValueNames()) -contains "Path"
        if (-not $hasPath -and $RequestedAction -ceq "Remove") {
            return [PSCustomObject]@{ Changed = $false; Owned = $false }
        }
        $kind = if ($hasPath) {
            $key.GetValueKind("Path")
        } else {
            [Microsoft.Win32.RegistryValueKind]::ExpandString
        }
        if ($kind -ne [Microsoft.Win32.RegistryValueKind]::String -and
            $kind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
            throw "The current-user Path has unsupported registry kind '$kind'."
        }
        $current = if ($hasPath) {
            [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        } else {
            ""
        }
        $update = Resolve-HerdrUserPathUpdate `
            -Current $current `
            -Entry $BinDir `
            -RequestedAction $RequestedAction `
            -ExpandVariables ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) `
            -InstallerOwned $InstallerOwned
        if ([bool]$update.Changed) {
            $key.SetValue("Path", [string]$update.Value, $kind)
        }
        return [PSCustomObject]@{ Changed = [bool]$update.Changed; Owned = [bool]$update.Owned }
    } finally {
        $key.Dispose()
    }
}

function Set-HerdrUserPath {
    param(
        [Parameter(Mandatory = $true)][string]$BinDir,
        [bool]$PreviouslyOwned = $false,
        [string]$RegistrySubKey = "Environment"
    )

    return Update-HerdrUserPath -BinDir $BinDir -RequestedAction Add -InstallerOwned $PreviouslyOwned -RegistrySubKey $RegistrySubKey
}

function Remove-HerdrUserPath {
    param(
        [Parameter(Mandatory = $true)][string]$BinDir,
        [bool]$InstallerOwned,
        [string]$RegistrySubKey = "Environment"
    )

    return Update-HerdrUserPath -BinDir $BinDir -RequestedAction Remove -InstallerOwned $InstallerOwned -RegistrySubKey $RegistrySubKey
}

function Get-HerdrQuietUninstallString {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $powerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $runner = Join-Path $InstallRoot $script:UninstallRunnerName
    $uninstaller = Join-Path $InstallRoot "uninstall.exe"
    return ('"{0}" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}" -Uninstaller "{2}" -InstallRoot "{3}"' -f $powerShell, $runner, $uninstaller, $InstallRoot)
}

function Get-HerdrArpValue {
    param(
        [Parameter(Mandatory = $true)]$Registration,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Microsoft.Win32.RegistryValueKind]$Kind
    )

    if (@($Registration.GetValueNames()) -cnotcontains $Name) {
        throw "The Herdr ARP registration is missing $Name."
    }
    if ($Registration.GetValueKind($Name) -ne $Kind) {
        $kindName = if ($Kind -eq [Microsoft.Win32.RegistryValueKind]::DWord) { "REG_DWORD" } else { "REG_SZ" }
        throw "The Herdr ARP $Name value must be $kindName."
    }
    return $Registration.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
}

function Assert-HerdrArpOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$RegistryPath = $script:ArpKey,
        [switch]$AllowLegacyQuietUninstall
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return
    }
    $registration = Get-Item -LiteralPath $RegistryPath
    try {
        $requiredNames = @(
            "DisplayName", "DisplayVersion", "Publisher", "InstallLocation", "DisplayIcon",
            "UninstallString", "QuietUninstallString", "VersionMajor", "VersionMinor", "NoModify", "NoRepair"
        )
        $actualNames = [string]::Join("`n", @($registration.GetValueNames() | Sort-Object))
        $withoutPath = [string]::Join("`n", @($requiredNames | Sort-Object))
        $withPath = [string]::Join("`n", @($requiredNames + "PathAdded" | Sort-Object))
        if (($actualNames -cne $withoutPath -and $actualNames -cne $withPath) -or $registration.GetSubKeyNames().Count -ne 0) {
            throw "The Herdr ARP registration contains unknown or incomplete state."
        }

        $displayName = [string](Get-HerdrArpValue -Registration $registration -Name "DisplayName" -Kind String)
        $displayVersion = [string](Get-HerdrArpValue -Registration $registration -Name "DisplayVersion" -Kind String)
        $publisher = [string](Get-HerdrArpValue -Registration $registration -Name "Publisher" -Kind String)
        $registeredRoot = [string](Get-HerdrArpValue -Registration $registration -Name "InstallLocation" -Kind String)
        $displayIcon = [string](Get-HerdrArpValue -Registration $registration -Name "DisplayIcon" -Kind String)
        $uninstallString = [string](Get-HerdrArpValue -Registration $registration -Name "UninstallString" -Kind String)
        $quietUninstallString = [string](Get-HerdrArpValue -Registration $registration -Name "QuietUninstallString" -Kind String)
        $versionMajor = [int](Get-HerdrArpValue -Registration $registration -Name "VersionMajor" -Kind DWord)
        $versionMinor = [int](Get-HerdrArpValue -Registration $registration -Name "VersionMinor" -Kind DWord)
        $noModify = [int](Get-HerdrArpValue -Registration $registration -Name "NoModify" -Kind DWord)
        $noRepair = [int](Get-HerdrArpValue -Registration $registration -Name "NoRepair" -Kind DWord)
        if (@($registration.GetValueNames()) -ccontains "PathAdded") {
            $pathAdded = [int](Get-HerdrArpValue -Registration $registration -Name "PathAdded" -Kind DWord)
            if ($pathAdded -notin @(0, 1)) {
                throw "The Herdr ARP PathAdded ownership value is invalid."
            }
        }

        $uninstaller = Join-Path $InstallRoot "uninstall.exe"
        $launcher = Join-Path $InstallRoot "bin\herdr.exe"
        $legacyQuietUninstallString = '"' + $uninstaller + '" /S'
        $quietUninstallOwned = $quietUninstallString -ceq (Get-HerdrQuietUninstallString -InstallRoot $InstallRoot) -or
            ($AllowLegacyQuietUninstall -and $quietUninstallString -ceq $legacyQuietUninstallString)
        $displayMatch = [regex]::Match($displayVersion, $script:DisplayVersionPattern)
        if ($displayName -cne $script:ProductName -or
            $publisher -cne "herdr-win" -or
            -not (Test-HerdrPathEntryEqual -Left $registeredRoot -Right $InstallRoot) -or
            $displayIcon -cne "$launcher,0" -or
            $uninstallString -cne ('"' + $uninstaller + '"') -or
            -not $quietUninstallOwned -or
            -not $displayMatch.Success -or
            $versionMajor -ne [int]$displayMatch.Groups[1].Value -or
            $versionMinor -ne [int]$displayMatch.Groups[2].Value -or
            $noModify -ne 1 -or $noRepair -ne 1) {
            throw "Refusing to modify an ARP registration not owned by this Herdr install."
        }
    } finally {
        $registration.Dispose()
    }
}

function Test-HerdrLegacyQuietUninstallRegistration {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$RegistryPath = $script:ArpKey)

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $false
    }
    $registration = Get-Item -LiteralPath $RegistryPath
    try {
        $uninstaller = Join-Path $InstallRoot "uninstall.exe"
        $quietUninstallString = [string]$registration.GetValue(
            "QuietUninstallString",
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        return $quietUninstallString -ceq ('"' + $uninstaller + '" /S')
    } finally {
        $registration.Dispose()
    }
}

function Get-HerdrArpPathOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$RegistryPath = $script:ArpKey,
        [switch]$AllowLegacyQuietUninstall
    )

    Assert-HerdrArpOwnership `
        -InstallRoot $InstallRoot `
        -RegistryPath $RegistryPath `
        -AllowLegacyQuietUninstall:$AllowLegacyQuietUninstall
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return $false
    }
    $registration = Get-Item -LiteralPath $RegistryPath
    try {
        if (@($registration.GetValueNames()) -notcontains "PathAdded") {
            return $false
        }
        if ($registration.GetValueKind("PathAdded") -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            throw "The Herdr ARP PathAdded ownership value must be REG_DWORD."
        }
        $value = [int]$registration.GetValue("PathAdded")
        if ($value -ne 0 -and $value -ne 1) {
            throw "The Herdr ARP PathAdded ownership value is invalid."
        }
        return $value -eq 1
    } finally {
        $registration.Dispose()
    }
}

function Set-HerdrArpRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [bool]$PathAdded,
        [string]$RegistryPath = $script:ArpKey,
        [switch]$AllowLegacyQuietUninstall
    )

    Assert-HerdrArpOwnership `
        -InstallRoot $InstallRoot `
        -RegistryPath $RegistryPath `
        -AllowLegacyQuietUninstall:$AllowLegacyQuietUninstall
    $uninstallRunner = Join-Path $InstallRoot $script:UninstallRunnerName
    Assert-HerdrRegularFile -Path $uninstallRunner
    New-Item -Path $RegistryPath -Force | Out-Null
    $uninstaller = Join-Path $InstallRoot "uninstall.exe"
    $launcher = Join-Path $InstallRoot "bin\herdr.exe"
    $numeric = $NumericVersion.Split('.')
    $values = @{
        DisplayName = $script:ProductName
        DisplayVersion = $DisplayVersion
        Publisher = "herdr-win"
        InstallLocation = $InstallRoot
        DisplayIcon = "$launcher,0"
        UninstallString = ('"' + $uninstaller + '"')
        QuietUninstallString = Get-HerdrQuietUninstallString -InstallRoot $InstallRoot
    }
    foreach ($name in $values.Keys) {
        New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $RegistryPath -Name "VersionMajor" -Value ([int]$numeric[0]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "VersionMinor" -Value ([int]$numeric[1]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "PathAdded" -Value ([int]$PathAdded) -PropertyType DWord -Force | Out-Null
    Assert-HerdrArpOwnership -InstallRoot $InstallRoot -RegistryPath $RegistryPath
}

function Remove-HerdrArpRegistration {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$RegistryPath = $script:ArpKey)

    Assert-HerdrArpOwnership -InstallRoot $InstallRoot -RegistryPath $RegistryPath
    if (Test-Path -LiteralPath $RegistryPath) {
        Remove-Item -LiteralPath $RegistryPath -Recurse -Force
    }
}

function Invoke-HerdrInstall {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$UserProfileRoot,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$UninstallRunnerPath,
        [Parameter(Mandatory = $true)][string]$SkillSourcePath,
        [Parameter(Mandatory = $true)][string]$SkillHashManifestPath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [ValidateSet("Direct", "WinGet")][string]$InstallManager = "Direct",
        [int]$LifecycleLockTimeoutMilliseconds = 30000
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $userProfile = Get-HerdrUserProfileRoot -UserProfileRoot $UserProfileRoot
    return Invoke-HerdrLifecycleOperation -InstallRoot $InstallRoot -TimeoutMilliseconds $LifecycleLockTimeoutMilliseconds -Operation {
        Assert-HerdrArpOwnership -InstallRoot $InstallRoot -AllowLegacyQuietUninstall
        $allowCurrentRootConvergence = Test-Path -LiteralPath $script:ArpKey
        $legacyQuietUninstall = Test-HerdrLegacyQuietUninstallRegistration -InstallRoot $InstallRoot
        $previousPathOwnership = Get-HerdrArpPathOwnership -InstallRoot $InstallRoot -AllowLegacyQuietUninstall
        $agentSkillsRoot = Get-HerdrAgentSkillsRoot -UserProfileRoot $userProfile
        $claudeSkillsRoot = if (Test-HerdrClaudeCodeInstalled -UserProfileRoot $userProfile) {
            Get-HerdrClaudeSkillsRoot -UserProfileRoot $userProfile
        } else {
            $null
        }
        $result = Install-HerdrLayout `
            -InstallRoot $InstallRoot `
            -StageDir $StageDir `
            -LauncherPath $LauncherPath `
            -UninstallerPath $UninstallerPath `
            -HelperSourcePath $HelperSourcePath `
            -UninstallRunnerPath $UninstallRunnerPath `
            -SkillSourcePath $SkillSourcePath `
            -SkillHashManifestPath $SkillHashManifestPath `
            -AgentSkillsRoot $agentSkillsRoot `
            -ClaudeSkillsRoot $claudeSkillsRoot `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -InstallManager $InstallManager `
            -AllowCurrentRootConvergence $allowCurrentRootConvergence
        if ($legacyQuietUninstall) {
            Set-HerdrArpRegistration `
                -InstallRoot $InstallRoot `
                -DisplayVersion $DisplayVersion `
                -NumericVersion $NumericVersion `
                -PathAdded $previousPathOwnership `
                -AllowLegacyQuietUninstall
        }
        $pathUpdate = Set-HerdrUserPath -BinDir (Join-Path $InstallRoot "bin") -PreviouslyOwned $previousPathOwnership
        Set-HerdrArpRegistration `
            -InstallRoot $InstallRoot `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -PathAdded ([bool]$pathUpdate.Owned)
        return $result
    }
}

function Invoke-HerdrUninstallLayout {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @(),
        [Parameter(Mandatory = $true)][string[]]$KnownSkillHashes,
        [Parameter(Mandatory = $true)][ValidateSet("Keep", "Auto", "Remove")][string]$SkillDisposition,
        [int]$LockTimeoutMilliseconds = 30000,
        [bool]$AllowCurrentRootConvergence = $false,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot },
        [string]$UninstallFault = "",
        [string]$UninstallFaultMarkerPrefix = "herdr"
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    if (Test-Path -LiteralPath $InstallRoot) {
        Assert-HerdrRegularDirectory -Path $InstallRoot
    }
    Remove-HerdrStaleStagingDirectories -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        return @(
            Remove-HerdrSkillCopiesBestEffort `
                -AgentSkillsRoot $AgentSkillsRoot `
                -ClaudeSkillsRoots $ClaudeSkillsRoots `
                -KnownHashes $KnownSkillHashes `
                -Disposition $SkillDisposition
        )
    }
    try {
        if ((Test-Path -LiteralPath (Join-Path $InstallRoot "state\install.manifest")) -and
            (Test-Path -LiteralPath (Join-Path $InstallRoot "bin\herdr.exe"))) {
            Repair-HerdrLauncherPublication -InstallRoot $InstallRoot
        }
        $rootKind = Get-HerdrRootKind -InstallRoot $InstallRoot
    } catch {
        if (-not $AllowCurrentRootConvergence) {
            throw
        }
        [Console]::Out.WriteLine(
            "Warning: The registered current Herdr root could not use normal uninstall recovery and will be removed directly. $($_.Exception.Message)"
        )
        Remove-HerdrCurrentRootForConvergence `
            -InstallRoot $InstallRoot `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds `
            -ProcessProvider $ProcessProvider
        $preservedSkillPaths = @(
            Remove-HerdrSkillCopiesBestEffort `
                -AgentSkillsRoot $AgentSkillsRoot `
                -ClaudeSkillsRoots $ClaudeSkillsRoots `
                -KnownHashes $KnownSkillHashes `
                -Disposition $SkillDisposition
        )
        return $preservedSkillPaths
    }
    if ($rootKind -eq "UninstallResidual") {
        $preservedSkillPaths = @(
            Remove-HerdrSkillCopiesBestEffort `
                -AgentSkillsRoot $AgentSkillsRoot `
                -ClaudeSkillsRoots $ClaudeSkillsRoots `
                -KnownHashes $KnownSkillHashes `
                -Disposition $SkillDisposition
        )
        Remove-HerdrUninstallResidual `
            -InstallRoot $InstallRoot `
            -UninstallFault $UninstallFault `
            -UninstallFaultMarkerPrefix $UninstallFaultMarkerPrefix
        return $preservedSkillPaths
    }
    if ($rootKind -ne "Managed" -and $rootKind -ne "UninstallRetry") {
        throw "Only an exact managed Herdr root can be uninstalled."
    }
    $stateDir = Join-Path $InstallRoot "state"
    $coordination = Open-HerdrShareModeLock -Path (Join-Path $stateDir "launcher.lock") -TimeoutMilliseconds $LockTimeoutMilliseconds
    try {
        if (Test-Path -LiteralPath (Join-Path $stateDir "uninstall.pending")) {
            Assert-HerdrUninstallRetryRoot -InstallRoot $InstallRoot
        } else {
            Assert-HerdrManagedRoot -InstallRoot $InstallRoot
        }
        $leaseStatus = if (Test-Path -LiteralPath (Join-Path $stateDir "leases")) {
            Get-HerdrLeaseStatus -LeasesDir (Join-Path $stateDir "leases")
        } else {
            [PSCustomObject]@{ Active = @(); Stale = @(); Ambiguous = @() }
        }
        if (@($leaseStatus.Active).Count -gt 0 -or @($leaseStatus.Ambiguous).Count -gt 0) {
            throw "Herdr is still active. Close all managed sessions before uninstalling."
        }
        $processes = @(& $ProcessProvider)
        if (Test-HerdrProcessWithinRoots -Processes $processes -Roots @($InstallRoot)) {
            throw "A process from the managed Herdr install tree is still active."
        }

        $preservedSkillPaths = @(
            Remove-HerdrSkillCopiesBestEffort `
                -AgentSkillsRoot $AgentSkillsRoot `
                -ClaudeSkillsRoots $ClaudeSkillsRoots `
                -KnownHashes $KnownSkillHashes `
                -Disposition $SkillDisposition
        )
        $uninstallPending = Join-Path $stateDir "uninstall.pending"
        if (-not (Test-Path -LiteralPath $uninstallPending)) {
            Write-HerdrDurableText -Path $uninstallPending -Text $script:UninstallMarkerText
        } else {
            Assert-HerdrRegularFile -Path $uninstallPending
        }
        foreach ($name in @("bin", "runtime")) {
            $path = Join-Path $InstallRoot $name
            if (Test-Path -LiteralPath $path) {
                Remove-HerdrValidatedDirectory -Path $path
            }
        }
        $pendingLauncher = Get-HerdrPendingLauncher -StateDir $stateDir
        if ($null -ne $pendingLauncher) {
            Remove-Item -LiteralPath $pendingLauncher.Path -Force
        }
        foreach ($name in @("active", "pending", "install.manifest", "package-manager")) {
            $path = Join-Path $stateDir $name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        $leasesDir = Join-Path $stateDir "leases"
        if (Test-Path -LiteralPath $leasesDir) {
            Remove-HerdrValidatedDirectory -Path $leasesDir
        }
    } finally {
        $coordination.Dispose()
    }
    Assert-HerdrUninstallResidual -InstallRoot $InstallRoot
    Remove-HerdrUninstallResidual `
        -InstallRoot $InstallRoot `
        -UninstallFault $UninstallFault `
        -UninstallFaultMarkerPrefix $UninstallFaultMarkerPrefix
    return $preservedSkillPaths
}

function Invoke-HerdrUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [ValidateSet("Keep", "Remove")][string]$SettingsDisposition = "Keep",
        [Parameter(Mandatory = $true)][string]$SkillHashManifestPath,
        [ValidateSet("Keep", "Auto", "Remove")][string]$SkillDisposition = "Auto",
        [string]$UserProfileRoot = $env:USERPROFILE,
        [int]$LifecycleLockTimeoutMilliseconds = 30000,
        [string]$UninstallFault = "",
        [string]$UninstallFaultMarkerPrefix = "herdr"
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $userProfile = Get-HerdrUserProfileRoot -UserProfileRoot $UserProfileRoot
    $knownSkillHashes = @(Read-HerdrManagedSkillHashes -Path $SkillHashManifestPath)
    return Invoke-HerdrLifecycleOperation -InstallRoot $InstallRoot -TimeoutMilliseconds $LifecycleLockTimeoutMilliseconds -Operation {
        Assert-HerdrArpOwnership -InstallRoot $InstallRoot
        $allowCurrentRootConvergence = Test-Path -LiteralPath $script:ArpKey
        $pathOwned = Get-HerdrArpPathOwnership -InstallRoot $InstallRoot
        $preservedSkillPaths = @(
            Invoke-HerdrUninstallLayout `
                -InstallRoot $InstallRoot `
                -AgentSkillsRoot (Get-HerdrAgentSkillsRoot -UserProfileRoot $userProfile) `
                -ClaudeSkillsRoots (Get-HerdrClaudeSkillsRootsForRemoval -UserProfileRoot $userProfile) `
                -KnownSkillHashes $knownSkillHashes `
                -SkillDisposition $SkillDisposition `
                -AllowCurrentRootConvergence $allowCurrentRootConvergence `
                -UninstallFault $UninstallFault `
                -UninstallFaultMarkerPrefix $UninstallFaultMarkerPrefix
        )
        [void](Remove-HerdrUserPath -BinDir (Join-Path $InstallRoot "bin") -InstallerOwned $pathOwned)
        Remove-HerdrArpRegistration -InstallRoot $InstallRoot
        if ($SettingsDisposition -ceq "Remove") {
            try {
                Remove-HerdrUserSettings -UserProfileRoot $userProfile
            } catch {
                [Console]::Out.WriteLine(
                    "Warning: Selected Herdr settings cleanup was incomplete; locked or unsafe settings were preserved. $($_.Exception.Message)"
                )
            }
        }
        Remove-HerdrUninstallFaultMarker -Fault $UninstallFault -MarkerPrefix $UninstallFaultMarkerPrefix
        return $preservedSkillPaths
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Action) {
            "Install" {
                if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
                    throw "PackageRoot is required for Install."
                }
                $PackageRoot = Get-HerdrFullPath -Path $PackageRoot
                $StageDir = Join-Path $PackageRoot "payload"
                $LauncherPath = Join-Path $PackageRoot "app-launcher.exe"
                $UninstallerPath = Join-Path $PackageRoot "uninstall.exe"
                $HelperSourcePath = Join-Path $PackageRoot "installer-helper.ps1"
                $UninstallRunnerPath = Join-Path $PackageRoot $script:UninstallRunnerName
                $SkillSourcePath = Join-Path $PackageRoot "skill\SKILL.md"
                $SkillHashManifestPath = Join-Path $PackageRoot "skill\managed-skill-hashes.txt"
                $result = Invoke-HerdrInstall `
                    -InstallRoot $InstallRoot `
                    -UserProfileRoot $UserProfileRoot `
                    -StageDir $StageDir `
                    -LauncherPath $LauncherPath `
                    -UninstallerPath $UninstallerPath `
                    -HelperSourcePath $HelperSourcePath `
                    -UninstallRunnerPath $UninstallRunnerPath `
                    -SkillSourcePath $SkillSourcePath `
                    -SkillHashManifestPath $SkillHashManifestPath `
                    -BuildId $BuildId `
                    -DisplayVersion $DisplayVersion `
                    -NumericVersion $NumericVersion `
                    -InstallManager $InstallManager
                if ($result.Status -ceq "Pending") {
                    [Console]::Out.WriteLine("$script:ProductName $($result.BuildId): Pending; staged until old sessions exit.")
                } else {
                    [Console]::Out.WriteLine("$script:ProductName $($result.BuildId): $($result.Status)")
                }
                foreach ($path in @($result.PreservedSkillPaths)) {
                    [Console]::Out.WriteLine("Warning: Existing customized Herdr skill was preserved: $path")
                }
            }
            "Uninstall" {
                $preservedSkillPaths = @(
                    Invoke-HerdrUninstall `
                        -InstallRoot $InstallRoot `
                        -UserProfileRoot $UserProfileRoot `
                        -SettingsDisposition $SettingsDisposition `
                        -SkillHashManifestPath $SkillHashManifestPath `
                        -SkillDisposition $SkillDisposition `
                        -UninstallFault $UninstallFault `
                        -UninstallFaultMarkerPrefix $UninstallFaultMarkerPrefix
                )
                [Console]::Out.WriteLine("$script:ProductName uninstall cleanup is ready.")
                foreach ($path in $preservedSkillPaths) {
                    [Console]::Out.WriteLine("Preserved Herdr skill: $path")
                }
            }
            "GetSkillRemovalDefault" {
                $knownSkillHashes = @(Read-HerdrManagedSkillHashes -Path $SkillHashManifestPath)
                $userProfile = Get-HerdrUserProfileRoot -UserProfileRoot $UserProfileRoot
                [Console]::Out.Write((Get-HerdrSkillRemovalDefault `
                    -KnownHashes $knownSkillHashes `
                    -AgentSkillsRoot (Get-HerdrAgentSkillsRoot -UserProfileRoot $userProfile) `
                    -ClaudeSkillsRoots (Get-HerdrClaudeSkillsRootsForRemoval -UserProfileRoot $userProfile)))
            }
            "CompleteMaintenance" {
                $result = Invoke-HerdrCompleteMaintenance `
                    -InstallRoot $InstallRoot `
                    -ParentProcessId $ParentProcessId
                [Console]::Out.WriteLine("$script:ProductName maintenance: $($result.Status)")
            }
            default {
                throw "Action must be Install, Uninstall, GetSkillRemovalDefault, or CompleteMaintenance."
            }
        }
        exit 0
    } catch {
        [Console]::Error.WriteLine("$script:ProductName installer error: $($_.Exception.Message)")
        exit 1
    }
}
