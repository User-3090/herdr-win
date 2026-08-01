[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall")]
    [string]$Action,

    [string]$InstallRoot,
    [string]$StageDir,
    [string]$LauncherPath,
    [string]$UninstallerPath,
    [string]$HelperSourcePath,
    [string]$SkillSourcePath,
    [string]$ProductName = "Herdr",
    [string]$BuildId,
    [string]$DisplayVersion,
    [string]$NumericVersion,
    [ValidateSet("Keep", "Remove")]
    [string]$SettingsDisposition = "Keep",
    [long]$ParentPid = 0,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:ProductNamePattern = '^[A-Za-z0-9](?:[A-Za-z0-9 ._-]{0,62}[A-Za-z0-9_-])?$'
if ($ProductName -cnotmatch $script:ProductNamePattern) {
    throw "Invalid product name '$ProductName'."
}
$script:ProductName = $ProductName
$script:BuildIdPattern = '^[0-9a-f]{12}\.[0-9a-f]{12}$'
$script:DisplayVersionPattern = '^((?:0|[1-9][0-9]{0,4}))\.((?:0|[1-9][0-9]{0,4}))\.((?:0|[1-9][0-9]{0,4}))-preview\.([0-9a-f]{12}\.[0-9a-f]{12})$'
$script:NumericVersionPattern = '^([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})\.([0-9]{1,5})$'
$script:PointerPattern = '\Aherdr-pointer-v1\nbuild_id=([0-9a-f]{12}\.[0-9a-f]{12})\n\z'
$script:RuntimePattern = '\Aherdr-runtime-v1\nbuild_id=([0-9a-f]{12}\.[0-9a-f]{12})\n\z'
$script:LeasePattern = '^([0-9a-f]{12}\.[0-9a-f]{12})\.lease$'
$script:RuntimeManifestHeader = "herdr-runtime-manifest-v1"
$script:InstallManifestHeader = "herdr-install-manifest-v1"
$script:ManagedBinMarkerText = "herdr-managed-bin-v1`n"
$script:UninstallMarkerText = "herdr-uninstall-v1`n"
$script:TransactionMarkerName = ".herdr-installer-transaction"
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

function Install-HerdrSkillFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$SkillsRoot
    )

    $expectedHash = Get-HerdrAgentSkillSha256 -Path $SourcePath
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
    }
    [IO.File]::Copy($SourcePath, $destination, $true)
    if ((Get-HerdrAgentSkillSha256 -Path $destination) -cne $expectedHash) {
        throw "Installed Herdr SKILL.md differs from its embedded source: $destination"
    }
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
        [string]$ClaudeSkillsRoot
    )

    Install-HerdrSkillFile -SourcePath $SourcePath -SkillsRoot $AgentSkillsRoot
    if (-not [string]::IsNullOrWhiteSpace($ClaudeSkillsRoot) -and
        -not $ClaudeSkillsRoot.Equals($AgentSkillsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Install-HerdrSkillFile -SourcePath $SourcePath -SkillsRoot $ClaudeSkillsRoot
    }
}

function Remove-HerdrSkillFile {
    param([Parameter(Mandatory = $true)][string]$SkillsRoot)

    if (-not (Test-Path -LiteralPath $SkillsRoot -PathType Container)) {
        return
    }
    $SkillsRoot = Get-HerdrFullPath -Path $SkillsRoot
    $parent = Split-Path -Parent $SkillsRoot
    $grandparent = Split-Path -Parent $parent
    foreach ($component in @($grandparent, $parent, $SkillsRoot)) {
        if (-not (Test-Path -LiteralPath $component -PathType Container) -or
            (Test-HerdrReparsePoint -Path $component)) {
            return
        }
    }
    $target = Join-Path $SkillsRoot "herdr"
    if (-not (Test-Path -LiteralPath $target -PathType Container) -or
        (Test-HerdrReparsePoint -Path $target)) {
        return
    }
    $skill = Join-Path $target "SKILL.md"
    if (Test-Path -LiteralPath $skill) {
        if (-not (Test-Path -LiteralPath $skill -PathType Leaf) -or
            (Test-HerdrReparsePoint -Path $skill)) {
            return
        }
        Remove-Item -LiteralPath $skill -Force
    }
    if (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) {
        Remove-Item -LiteralPath $target -Force
    }
}

function Remove-HerdrSkillCopies {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @()
    )

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @($AgentSkillsRoot) + @($ClaudeSkillsRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and $seen.Add([IO.Path]::GetFullPath($root))) {
            Remove-HerdrSkillFile -SkillsRoot $root
        }
    }
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
    Assert-HerdrRegularFile -Path (Join-Path $Path "herdr-launcher.exe")
    $manifest = Read-HerdrRuntimeManifest -RuntimeRoot $Path
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
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    if (Test-Path -LiteralPath $Destination) {
        throw "Runtime staging destination already exists: $Destination"
    }
    Copy-HerdrDurableTree -SourceRoot $StageDir -DestinationRoot $Destination
    Copy-HerdrDurableFile -Source $LauncherPath -Destination (Join-Path $Destination "herdr-launcher.exe")
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

    return "$script:InstallManifestHeader`nbootstrap_sha256=$(Get-HerdrSha256 -Path $BootstrapPath)`ndisplay_version=$DisplayVersion`nnumeric_version=$NumericVersion`n"
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

function Assert-HerdrManagedRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Assert-HerdrRegularDirectory -Path $InstallRoot
    $rootNames = @(Get-ChildItem -LiteralPath $InstallRoot -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object @("bin", "runtime", "state", "uninstall.exe") $rootNames -CaseSensitive).Count -ne 0) {
        throw "Managed Herdr root has an unrecognized owned layout: $InstallRoot"
    }
    Assert-HerdrRegularFile -Path (Join-Path $InstallRoot "uninstall.exe")
    $stateDir = Join-Path $InstallRoot "state"
    Assert-HerdrRegularDirectory -Path $stateDir
    $allowedState = @("active", "pending", "leases", "launcher.lock", "installer-helper.ps1", "install.manifest")
    foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -Force)) {
        if ($allowedState -cnotcontains $entry.Name -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in managed Herdr state: $($entry.FullName)"
        }
    }
    foreach ($required in @("active", "leases", "launcher.lock", "installer-helper.ps1", "install.manifest")) {
        if (-not (Test-Path -LiteralPath (Join-Path $stateDir $required))) {
            throw "Managed Herdr state is missing $required."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $stateDir "uninstall.pending")) {
        throw "Managed Herdr uninstall is incomplete; rerun uninstall before installing."
    }
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "launcher.lock")
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "installer-helper.ps1")
    Assert-HerdrLeasesDirectory -LeasesDir (Join-Path $stateDir "leases")
    $installManifest = Read-HerdrInstallManifest -StateDir $stateDir
    Assert-HerdrManagedBin -BinDir (Join-Path $InstallRoot "bin") -ExpectedBootstrapSha256 $installManifest.BootstrapSha256

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
    $allowedRoot = @("bin", "runtime", "state", "uninstall.exe")
    foreach ($entry in @(Get-ChildItem -LiteralPath $InstallRoot -Force)) {
        if ($allowedRoot -cnotcontains $entry.Name -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unrecognized content in uninstall-retry root: $($entry.FullName)"
        }
    }
    Assert-HerdrRegularFile -Path (Join-Path $InstallRoot "uninstall.exe")
    $stateDir = Join-Path $InstallRoot "state"
    Assert-HerdrRegularDirectory -Path $stateDir
    foreach ($required in @("installer-helper.ps1", "launcher.lock", "uninstall.pending")) {
        Assert-HerdrRegularFile -Path (Join-Path $stateDir $required)
    }
    if ((Read-HerdrStrictUtf8 -Path (Join-Path $stateDir "uninstall.pending")) -cne $script:UninstallMarkerText) {
        throw "Invalid Herdr uninstall retry marker."
    }
    $allowedState = @("active", "pending", "leases", "launcher.lock", "installer-helper.ps1", "install.manifest", "uninstall.pending")
    foreach ($entry in @(Get-ChildItem -LiteralPath $stateDir -Force)) {
        if ($allowedState -cnotcontains $entry.Name -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
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
    if (Test-Path -LiteralPath (Join-Path $InstallRoot "bin")) {
        if ($null -eq $installManifest) {
            throw "Cannot validate remaining managed bin without install.manifest."
        }
        Assert-HerdrManagedBin -BinDir (Join-Path $InstallRoot "bin") -ExpectedBootstrapSha256 $installManifest.BootstrapSha256
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

    $rootNames = @(Get-ChildItem -LiteralPath $InstallRoot -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object @("state", "uninstall.exe") $rootNames -CaseSensitive).Count -ne 0) {
        throw "Uninstall residual root contains unexpected content."
    }
    $stateDir = Join-Path $InstallRoot "state"
    $stateNames = @(Get-ChildItem -LiteralPath $stateDir -Force | ForEach-Object { $_.Name })
    if (@(Compare-Object @("installer-helper.ps1", "launcher.lock", "uninstall.pending") $stateNames -CaseSensitive).Count -ne 0) {
        throw "Uninstall residual state contains unexpected content."
    }
    Assert-HerdrRegularFile -Path (Join-Path $InstallRoot "uninstall.exe")
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "installer-helper.ps1")
    Assert-HerdrRegularFile -Path (Join-Path $stateDir "launcher.lock")
    if ((Read-HerdrStrictUtf8 -Path (Join-Path $stateDir "uninstall.pending")) -cne $script:UninstallMarkerText) {
        throw "Uninstall residual marker is invalid."
    }
}

function Get-HerdrTransactionMarkerText {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update", "uninstall")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $rootHash = Get-HerdrTextSha256 -Text ((Get-HerdrFullPath -Path $InstallRoot).ToLowerInvariant())
    return "herdr-installer-transaction-v1`nkind=$Kind`ninstall_root_sha256=$rootHash`n"
}

function New-HerdrTransaction {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update", "uninstall")][string]$Kind,
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
    Write-HerdrDurableText -Path (Join-Path $path $script:TransactionMarkerName) -Text (
        Get-HerdrTransactionMarkerText -Kind $Kind -InstallRoot $InstallRoot
    )
    return [PSCustomObject]@{ Kind = $Kind; Path = $path }
}

function Assert-HerdrTransaction {
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
        throw "Refusing an unrecognized Herdr installer transaction path: $Path"
    }
    [void](Get-HerdrSafeTreeEntries -Root $Path)
    $marker = Join-Path $Path $script:TransactionMarkerName
    if ((Read-HerdrStrictUtf8 -Path $marker) -cne (Get-HerdrTransactionMarkerText -Kind $Kind -InstallRoot $InstallRoot)) {
        throw "Herdr installer transaction marker is invalid: $Path"
    }
}

function Get-HerdrTransactions {
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

function Remove-HerdrTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrTransaction -Path $Path -Kind $Kind -InstallRoot $InstallRoot
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($entry.Name -ceq $script:TransactionMarkerName) {
            continue
        }
        if ($Kind -eq "fresh") {
            if ($entry.Name -cne "root" -or -not $entry.PSIsContainer) {
                throw "Fresh installer transaction contains unexpected content: $($entry.FullName)"
            }
            continue
        }
        if ($entry.Name -in @("runtime", "metadata")) {
            if (-not $entry.PSIsContainer) {
                throw "Update installer transaction path is not a directory: $($entry.FullName)"
            }
            continue
        }
        if ($entry.PSIsContainer -or
            $entry.Name -cnotmatch '^(?:active|pending|installer-helper\.ps1|uninstall\.exe|install\.manifest)\.backup\.[0-9a-f]{32}$') {
            throw "Update installer transaction contains unexpected content: $($entry.FullName)"
        }
    }
    $marker = Join-Path $Path $script:TransactionMarkerName
    Assert-HerdrRegularFile -Path $marker
    $files = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object {
        -not $_.PSIsContainer -and $_.FullName -ine $marker
    } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($file in $files) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    $directories = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
    Remove-Item -LiteralPath $marker -Force
    Remove-Item -LiteralPath $Path -Force
}

function Remove-HerdrEmptyTransactionShell {
    param([string]$Path, [AllowEmptyCollection()][object[]]$Entries)
    if ($Entries.Count -ne 0 -and
        ($Entries.Count -ne 1 -or $Entries[0].Name -cne $script:TransactionMarkerName -or $Entries[0].PSIsContainer)) {
        return $false
    }
    if ($Entries.Count -eq 1) { Remove-Item -LiteralPath $Entries[0].FullName -Force }
    Remove-Item -LiteralPath $Path -Force
    return $true
}

function Remove-HerdrRecoverableTransactionPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("fresh", "update")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrRegularDirectory -Path $Path
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if (Remove-HerdrEmptyTransactionShell -Path $Path -Entries $entries) {
        return
    }
    Remove-HerdrTransaction -Path $Path -Kind $Kind -InstallRoot $InstallRoot
}

function Remove-HerdrRecoverableInstallTransactions {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    foreach ($kind in @("fresh", "update")) {
        foreach ($path in @(Get-HerdrTransactions -InstallRoot $InstallRoot -Kind $kind)) {
            Remove-HerdrRecoverableTransactionPath -Path $path -Kind $kind -InstallRoot $InstallRoot
        }
    }
}

function Assert-HerdrUninstallTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrTransaction -Path $Path -Kind "uninstall" -InstallRoot $InstallRoot
    $allowed = @($script:TransactionMarkerName, "root.manifest", "uninstall.pending", "bin", "runtime")
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($allowed -cnotcontains $entry.Name) {
            throw "Uninstall transaction contains unexpected content: $($entry.FullName)"
        }
    }
    $manifestPath = Join-Path $Path "root.manifest"
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Read-HerdrInstallManifestFile -Path $manifestPath
    }
    $pendingPath = Join-Path $Path "uninstall.pending"
    if (Test-Path -LiteralPath $pendingPath) {
        if ((Read-HerdrStrictUtf8 -Path $pendingPath) -cne $script:UninstallMarkerText) {
            throw "Uninstall transaction contains an invalid staged retry marker."
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Path "bin")) {
        if ($null -eq $manifest) {
            throw "Uninstall transaction cannot validate bin without root.manifest."
        }
        Assert-HerdrManagedBin -BinDir (Join-Path $Path "bin") -ExpectedBootstrapSha256 $manifest.BootstrapSha256
    }
    if (Test-Path -LiteralPath (Join-Path $Path "runtime")) {
        Assert-HerdrRegularDirectory -Path (Join-Path $Path "runtime")
        foreach ($runtime in @(Get-ChildItem -LiteralPath (Join-Path $Path "runtime") -Force)) {
            if (-not $runtime.PSIsContainer -or $runtime.Name -cnotmatch $script:BuildIdPattern) {
                throw "Uninstall transaction contains an unrecognized runtime."
            }
            Assert-HerdrRuntimeDirectory -Path $runtime.FullName -ExpectedBuildId $runtime.Name
        }
    }
}

function Remove-HerdrUninstallTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrUninstallTransaction -Path $Path -InstallRoot $InstallRoot
    Write-HerdrUninstallCleanupManifest -Path $Path
    Remove-HerdrUninstallTransactionOwnedFiles -Path $Path -InstallRoot $InstallRoot
}

function Write-HerdrUninstallCleanupManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $manifestPath = Join-Path $Path "cleanup.manifest"
    if (Test-Path -LiteralPath $manifestPath) {
        return
    }
    $temporary = Join-Path $Path "cleanup.manifest.new"
    if (Test-Path -LiteralPath $temporary) {
        Assert-HerdrRegularFile -Path $temporary
        Remove-Item -LiteralPath $temporary -Force
    }
    $relativePaths = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object {
        -not $_.PSIsContainer -and $_.Name -notin @("cleanup.manifest", "cleanup.manifest.new")
    } | ForEach-Object { (Get-HerdrRelativePath -Root $Path -Path $_.FullName).Replace('\', '/') })
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append("herdr-uninstall-owned-v1`n")
    foreach ($relative in $relativePaths) {
        $hash = Get-HerdrSha256 -Path (Join-Path $Path $relative.Replace('/', '\'))
        [void]$builder.Append($hash).Append("  ").Append($relative).Append("`n")
    }
    Write-HerdrDurableText -Path $temporary -Text $builder.ToString()
    [IO.File]::Move($temporary, $manifestPath)
}

function Read-HerdrUninstallCleanupManifest {
    param([Parameter(Mandatory = $true)][string]$Path)

    $manifestPath = Join-Path $Path "cleanup.manifest"
    $text = Read-HerdrStrictUtf8 -Path $manifestPath
    if (-not $text.StartsWith("herdr-uninstall-owned-v1`n", [StringComparison]::Ordinal) -or
        -not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "Invalid uninstall cleanup ownership manifest: $manifestPath"
    }
    $lines = $text.Substring(0, $text.Length - 1).Split("`n")
    $entries = [ordered]@{}
    $previous = $null
    if ($lines.Count -gt 1) {
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            $match = [regex]::Match($line, '^([0-9a-f]{64})  ([0-9A-Za-z._/-]+)$')
            if (-not $match.Success) {
                throw "Invalid uninstall cleanup ownership entry: $manifestPath"
            }
            $relative = $match.Groups[2].Value
            if ($relative.Contains("../") -or $relative -in @("cleanup.manifest", "cleanup.manifest.new")) {
                throw "Unsafe uninstall cleanup ownership path: $relative"
            }
            if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous, $relative) -ge 0) {
                throw "Uninstall cleanup ownership paths are not strictly sorted."
            }
            $entries[$relative] = $match.Groups[1].Value
            $previous = $relative
        }
    }
    return ,$entries
}

function Assert-HerdrPartialUninstallTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrTransaction -Path $Path -Kind "uninstall" -InstallRoot $InstallRoot
    $ownership = Read-HerdrUninstallCleanupManifest -Path $Path
    foreach ($entry in @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { -not $_.PSIsContainer })) {
        $relative = (Get-HerdrRelativePath -Root $Path -Path $entry.FullName).Replace('\', '/')
        if ($relative -ceq "cleanup.manifest") {
            continue
        }
        if (-not $ownership.Contains($relative)) {
            throw "Partial uninstall transaction contains unowned file $relative."
        }
        if ((Get-HerdrSha256 -Path $entry.FullName) -cne [string]$ownership[$relative]) {
            throw "Partial uninstall transaction hash mismatch for $relative."
        }
    }
    $ownedDirectories = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::Ordinal)
    foreach ($relative in $ownership.Keys) {
        $parent = [IO.Path]::GetDirectoryName($relative.Replace('/', '\'))
        while (-not [string]::IsNullOrEmpty($parent)) {
            $ownedDirectories[$parent.Replace('\', '/')] = $true
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }
    foreach ($directory in @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { $_.PSIsContainer })) {
        $relative = (Get-HerdrRelativePath -Root $Path -Path $directory.FullName).Replace('\', '/')
        if (-not $ownedDirectories.ContainsKey($relative)) {
            throw "Partial uninstall transaction contains unowned directory $relative."
        }
    }
    $allowedTop = @($script:TransactionMarkerName, "root.manifest", "uninstall.pending", "cleanup.manifest", "bin", "runtime")
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force)) {
        if ($allowedTop -cnotcontains $entry.Name) {
            throw "Partial uninstall transaction contains unexpected path $($entry.FullName)."
        }
    }
}

function Remove-HerdrUninstallTransactionOwnedFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrPartialUninstallTransaction -Path $Path -InstallRoot $InstallRoot
    $markerPath = Join-Path $Path $script:TransactionMarkerName
    $manifestPath = Join-Path $Path "cleanup.manifest"
    $files = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object {
        -not $_.PSIsContainer -and $_.FullName -ine $markerPath -and $_.FullName -ine $manifestPath
    } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($file in $files) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    $directories = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { $_.PSIsContainer } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        Remove-Item -LiteralPath $directory.FullName -Force
    }
    Remove-Item -LiteralPath $manifestPath -Force
    Remove-Item -LiteralPath $markerPath -Force
    Remove-Item -LiteralPath $Path -Force
}

function Remove-HerdrRecoverableUninstallTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    Assert-HerdrRegularDirectory -Path $Path
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    if (Remove-HerdrEmptyTransactionShell -Path $Path -Entries $entries) {
        return
    }
    $cleanupNew = Join-Path $Path "cleanup.manifest.new"
    if (Test-Path -LiteralPath $cleanupNew) {
        Assert-HerdrRegularFile -Path $cleanupNew
        Remove-Item -LiteralPath $cleanupNew -Force
    }
    if (Test-Path -LiteralPath (Join-Path $Path "cleanup.manifest")) {
        Remove-HerdrUninstallTransactionOwnedFiles -Path $Path -InstallRoot $InstallRoot
    } else {
        Remove-HerdrUninstallTransaction -Path $Path -InstallRoot $InstallRoot
    }
}

function Get-HerdrLegacyPayloadFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    $files = @(Get-HerdrSafeTreeEntries -Root $Path | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        (Get-HerdrRelativePath -Root $Path -Path $_.FullName).Replace('\', '/')
    })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    return $files
}

function Test-HerdrRecognizedLegacyPayload {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $actual = @(Get-HerdrLegacyPayloadFiles -Path $Path)
    } catch {
        return $false
    }
    $single = @("herdr.exe")
    $conpty = @(
        "THIRD-PARTY-NOTICES/Microsoft.Windows.Console.ConPTY-LICENSE.txt",
        "THIRD-PARTY-NOTICES/Microsoft.Windows.Console.ConPTY-NOTICE.md",
        "conpty/arm64/OpenConsole.exe",
        "conpty/conpty.dll",
        "conpty/herdr-conpty.json",
        "conpty/x64/OpenConsole.exe",
        "herdr.exe"
    )
    [Array]::Sort($conpty, [StringComparer]::Ordinal)
    return (@(Compare-Object $actual $single -CaseSensitive).Count -eq 0) -or
        (@(Compare-Object $actual $conpty -CaseSensitive).Count -eq 0)
}

function Get-HerdrJunctionTarget {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.LinkType -ne "Junction") {
        throw "Only a recognized legacy Herdr junction can be migrated: $Path"
    }
    $targets = @($item.Target)
    if ($targets.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$targets[0])) {
        throw "Legacy Herdr junction has an ambiguous target: $Path"
    }
    $target = [string]$targets[0]
    if (-not [IO.Path]::IsPathRooted($target)) {
        $target = Join-Path (Split-Path -Parent $Path) $target
    }
    return [IO.Path]::GetFullPath($target).TrimEnd('\')
}

function Assert-HerdrRecognizedLegacyEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot
    )

    if (Test-HerdrReparsePoint -Path $Path) {
        $target = Get-HerdrJunctionTarget -Path $Path
        if (-not (Test-HerdrPathWithin -Path $target -Root $LegacyReleasesRoot) -or
            -not (Test-HerdrRecognizedLegacyPayload -Path $target)) {
            throw "Legacy Herdr junction target is not an exact owned release: $Path"
        }
        return
    }
    if (-not (Test-HerdrRecognizedLegacyPayload -Path $Path)) {
        throw "Legacy Herdr directory has an unrecognized layout: $Path"
    }
}

function Assert-HerdrLegacyRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot
    )

    Assert-HerdrRegularDirectory -Path $Root
    $entries = @(Get-ChildItem -LiteralPath $Root -Force)
    foreach ($entry in $entries) {
        if (($entry.Name -cne "bin" -and $entry.Name -cnotmatch '^bin\.legacy\.[0-9a-f]{32}$') -or -not $entry.PSIsContainer) {
            throw "Refusing ambiguous legacy Herdr root content: $($entry.FullName)"
        }
        Assert-HerdrRecognizedLegacyEntry -Path $entry.FullName -LegacyReleasesRoot $LegacyReleasesRoot
    }
    if (@($entries | Where-Object { $_.Name -ceq "bin" }).Count -ne 1) {
        throw "Legacy Herdr root does not contain exactly one bin entry."
    }
}

function Get-HerdrRootKind {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot
    )

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
            Assert-HerdrLegacyRoot -Root $InstallRoot -LegacyReleasesRoot $LegacyReleasesRoot
            return "Legacy"
        } catch {
            throw "Herdr install root is neither an exact managed nor recognized legacy layout: $InstallRoot"
        }
    }
}

function Get-HerdrLegacyBackups {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $parent = Split-Path -Parent $InstallRoot
    if (-not (Test-Path -LiteralPath $parent)) {
        return @()
    }
    Assert-HerdrRegularDirectory -Path $parent
    $leaf = [regex]::Escape((Split-Path -Leaf $InstallRoot))
    return @(Get-ChildItem -LiteralPath $parent -Force -Directory | Where-Object {
        $_.Name -cmatch "^$leaf\.legacy-backup\.[0-9a-f]{32}$"
    } | ForEach-Object { $_.FullName })
}

function Get-HerdrLegacyReleasesRoot {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw "USERPROFILE is not set; legacy Herdr ownership cannot be checked safely."
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".herdr\packages\standalone\releases")).TrimEnd('\')
}

function Get-HerdrLegacyInstallLockPath {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw "USERPROFILE is not set; legacy Herdr install lock cannot be located."
    }
    return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".herdr\packages\standalone\install.lock"))
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

function Test-HerdrLegacyProcessBusy {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Processes,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot,
        [long]$ParentPid = 0
    )

    foreach ($process in $Processes) {
        $path = [string]$process.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if ($ParentPid -gt 0 -and [long]$process.ProcessId -eq $ParentPid) {
            continue
        }
        if (Test-HerdrPathWithin -Path $path -Root $InstallRoot) {
            return $true
        }
        if (Test-HerdrPathWithin -Path $path -Root $LegacyReleasesRoot) {
            return $true
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

function Remove-HerdrStaleLeases {
    param([Parameter(Mandatory = $true)][object]$LeaseStatus)

    if (@($LeaseStatus.Active).Count -gt 0 -or @($LeaseStatus.Ambiguous).Count -gt 0) {
        throw "Cannot remove Herdr leases while an active or ambiguous lease exists."
    }
    foreach ($path in @($LeaseStatus.Stale)) {
        Remove-Item -LiteralPath $path -Force
    }
}

function New-HerdrManagedRootTree {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion
    )

    New-Item -ItemType Directory -Path (Join-Path $Destination "bin\managed-install-v1") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Destination "runtime") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Destination "state\leases") -Force | Out-Null
    Copy-HerdrDurableFile -Source $LauncherPath -Destination (Join-Path $Destination "bin\herdr.exe")
    Write-HerdrDurableText -Path (Join-Path $Destination "bin\managed-install-v1\marker") -Text $script:ManagedBinMarkerText
    New-HerdrRuntimeTree -Destination (Join-Path $Destination "runtime\$BuildId") -StageDir $StageDir -LauncherPath $LauncherPath -BuildId $BuildId
    Write-HerdrDurableBytes -Path (Join-Path $Destination "state\launcher.lock") -Bytes ([byte[]]@())
    Write-HerdrDurableText -Path (Join-Path $Destination "state\active") -Text (Get-HerdrPointerText -BuildId $BuildId)
    Copy-HerdrDurableFile -Source $HelperSourcePath -Destination (Join-Path $Destination "state\installer-helper.ps1")
    Copy-HerdrDurableFile -Source $UninstallerPath -Destination (Join-Path $Destination "uninstall.exe")
    Write-HerdrDurableText -Path (Join-Path $Destination "state\install.manifest") -Text (
        Get-HerdrInstallManifestText `
            -BootstrapPath (Join-Path $Destination "bin\herdr.exe") `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion
    )
    Assert-HerdrManagedRoot -InstallRoot $Destination
}

function Restore-HerdrLegacyBackupIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot,
        [string]$LegacyInstallLockPath = (Get-HerdrLegacyInstallLockPath),
        [int]$LockTimeoutMilliseconds = 30000
    )

    if (Test-Path -LiteralPath $InstallRoot) {
        return
    }
    $backups = @(Get-HerdrLegacyBackups -InstallRoot $InstallRoot)
    if ($backups.Count -eq 0) {
        return
    }
    if ($backups.Count -ne 1) {
        throw "Multiple legacy Herdr backups exist while the visible root is absent; refusing ambiguous recovery."
    }
    Assert-HerdrLegacyRoot -Root $backups[0] -LegacyReleasesRoot $LegacyReleasesRoot
    $legacyLock = Open-HerdrShareModeLock -Path $LegacyInstallLockPath -TimeoutMilliseconds $LockTimeoutMilliseconds
    try {
        if (-not (Test-Path -LiteralPath $InstallRoot)) {
            [IO.Directory]::Move($backups[0], $InstallRoot)
        }
    } finally {
        $legacyLock.Dispose()
    }
}

function Publish-HerdrFreshTransaction {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot,
        [string]$LegacyInstallLockPath = (Get-HerdrLegacyInstallLockPath),
        [ValidateSet("New", "Legacy")][string]$RootKind,
        [long]$ParentPid = 0,
        [int]$LockTimeoutMilliseconds = 30000,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    $stagedRoot = Join-Path $Transaction.Path "root"
    Assert-HerdrManagedRoot -InstallRoot $stagedRoot
    if ($RootKind -eq "New") {
        if (Test-Path -LiteralPath $InstallRoot) {
            throw "Herdr install root appeared before fresh publication."
        }
        [IO.Directory]::Move($stagedRoot, $InstallRoot)
        return $null
    }

    $legacyLock = Open-HerdrShareModeLock -Path $LegacyInstallLockPath -TimeoutMilliseconds $LockTimeoutMilliseconds
    $backup = $null
    try {
        Assert-HerdrLegacyRoot -Root $InstallRoot -LegacyReleasesRoot $LegacyReleasesRoot
        $processes = @(& $ProcessProvider)
        if (Test-HerdrLegacyProcessBusy -Processes $processes -InstallRoot $InstallRoot -LegacyReleasesRoot $LegacyReleasesRoot -ParentPid $ParentPid) {
            throw "A legacy Herdr process is still active; close it before migration."
        }
        $backup = "$InstallRoot.legacy-backup.$([Guid]::NewGuid().ToString('N'))"
        [IO.Directory]::Move($InstallRoot, $backup)
        try {
            [IO.Directory]::Move($stagedRoot, $InstallRoot)
        } catch {
            if (-not (Test-Path -LiteralPath $InstallRoot) -and (Test-Path -LiteralPath $backup)) {
                [IO.Directory]::Move($backup, $InstallRoot)
            }
            throw
        }
        return $backup
    } finally {
        $legacyLock.Dispose()
    }
}

function Install-HerdrManagedUpgrade {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [int]$LockTimeoutMilliseconds = 30000
    )

    # Inactive runtimes remain until uninstall. The coordination gate closes the
    # new-launch race, but CIM omits inaccessible ExecutablePath values, so this
    # helper cannot prove the required no-process condition without ambiguity.
    $transaction = New-HerdrTransaction -Kind "update" -InstallRoot $InstallRoot
    try {
        $stagedRuntime = Join-Path $transaction.Path "runtime"
        New-HerdrRuntimeTree -Destination $stagedRuntime -StageDir $StageDir -LauncherPath $LauncherPath -BuildId $BuildId
        $metadata = Join-Path $transaction.Path "metadata"
        New-Item -ItemType Directory -Path $metadata | Out-Null
        Copy-HerdrDurableFile -Source $HelperSourcePath -Destination (Join-Path $metadata "installer-helper.ps1")
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

            Publish-HerdrStagedFile -Source (Join-Path $metadata "installer-helper.ps1") -Destination (Join-Path $stateDir "installer-helper.ps1") -BackupDir $transaction.Path
            Publish-HerdrStagedFile -Source (Join-Path $metadata "uninstall.exe") -Destination (Join-Path $InstallRoot "uninstall.exe") -BackupDir $transaction.Path

            $activePath = Join-Path $stateDir "active"
            $activeBuild = Read-HerdrPointer -Path $activePath
            $pendingPath = Join-Path $stateDir "pending"
            if ($activeBuild -ceq $BuildId) {
                if (Test-Path -LiteralPath $pendingPath) {
                    Remove-Item -LiteralPath $pendingPath -Force
                }
                Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $transaction.Path
                return [PSCustomObject]@{ Status = "AlreadyActive"; BuildId = $BuildId }
            }
            Publish-HerdrStagedFile -Source (Join-Path $metadata "pending") -Destination $pendingPath -BackupDir $transaction.Path
            $leaseStatus = Get-HerdrLeaseStatus -LeasesDir (Join-Path $stateDir "leases")
            if (@($leaseStatus.Active).Count -gt 0 -or @($leaseStatus.Ambiguous).Count -gt 0) {
                Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $transaction.Path
                return [PSCustomObject]@{ Status = "Pending"; BuildId = $BuildId }
            }
            Remove-HerdrStaleLeases -LeaseStatus $leaseStatus
            $activeBackup = Join-Path $transaction.Path ("active.backup." + [Guid]::NewGuid().ToString("N"))
            [IO.File]::Replace($pendingPath, $activePath, $activeBackup)
            Remove-Item -LiteralPath $activeBackup -Force
            if ((Read-HerdrPointer -Path $activePath) -cne $BuildId -or (Test-Path -LiteralPath $pendingPath)) {
                throw "Atomic pending activation did not publish the expected active pointer."
            }
            Publish-HerdrStagedFile -Source (Join-Path $metadata "install.manifest") -Destination (Join-Path $stateDir "install.manifest") -BackupDir $transaction.Path
            return [PSCustomObject]@{ Status = "Activated"; BuildId = $BuildId }
        } finally {
            $coordination.Dispose()
        }
    } finally {
        if (Test-Path -LiteralPath $transaction.Path) {
            Remove-HerdrTransaction -Path $transaction.Path -Kind "update" -InstallRoot $InstallRoot
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
        [Parameter(Mandatory = $true)][string]$SkillSourcePath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string]$ClaudeSkillsRoot,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [Parameter(Mandatory = $true)][string]$LegacyReleasesRoot,
        [string]$LegacyInstallLockPath = (Get-HerdrLegacyInstallLockPath),
        [long]$ParentPid = 0,
        [int]$LockTimeoutMilliseconds = 30000,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    Assert-HerdrVersionIdentity -DisplayVersion $DisplayVersion -NumericVersion $NumericVersion -BuildId $BuildId
    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $StageDir = Get-HerdrFullPath -Path $StageDir
    Assert-HerdrRegularDirectory -Path $StageDir
    Assert-HerdrRegularFile -Path $LauncherPath
    Assert-HerdrRegularFile -Path $UninstallerPath
    Assert-HerdrRegularFile -Path $HelperSourcePath
    [void](Get-HerdrAgentSkillSha256 -Path $SkillSourcePath)
    Assert-HerdrSkillTarget -SkillsRoot $AgentSkillsRoot
    if (-not [string]::IsNullOrWhiteSpace($ClaudeSkillsRoot) -and
        -not $ClaudeSkillsRoot.Equals($AgentSkillsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Assert-HerdrSkillTarget -SkillsRoot $ClaudeSkillsRoot
    }

    Restore-HerdrLegacyBackupIfNeeded -InstallRoot $InstallRoot -LegacyReleasesRoot $LegacyReleasesRoot -LegacyInstallLockPath $LegacyInstallLockPath -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    Remove-HerdrRecoverableInstallTransactions -InstallRoot $InstallRoot
    if (@(Get-HerdrTransactions -InstallRoot $InstallRoot -Kind "uninstall").Count -gt 0) {
        throw "A previous Herdr uninstall transaction is incomplete; rerun uninstall before installing."
    }
    $rootKind = Get-HerdrRootKind -InstallRoot $InstallRoot -LegacyReleasesRoot $LegacyReleasesRoot
    if ($rootKind -eq "UninstallRetry") {
        throw "A previous Herdr uninstall is incomplete; rerun uninstall before installing."
    }
    if ($rootKind -eq "Managed") {
        $result = Install-HerdrManagedUpgrade `
            -InstallRoot $InstallRoot `
            -StageDir $StageDir `
            -LauncherPath $LauncherPath `
            -UninstallerPath $UninstallerPath `
            -HelperSourcePath $HelperSourcePath `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -LockTimeoutMilliseconds $LockTimeoutMilliseconds
    } else {
        $transaction = New-HerdrTransaction -Kind "fresh" -InstallRoot $InstallRoot
        try {
            $stagedRoot = Join-Path $transaction.Path "root"
            New-HerdrManagedRootTree `
                -Destination $stagedRoot `
                -StageDir $StageDir `
                -LauncherPath $LauncherPath `
                -UninstallerPath $UninstallerPath `
                -HelperSourcePath $HelperSourcePath `
                -BuildId $BuildId `
                -DisplayVersion $DisplayVersion `
                -NumericVersion $NumericVersion
            $legacyBackup = Publish-HerdrFreshTransaction `
                -Transaction $transaction `
                -InstallRoot $InstallRoot `
                -LegacyReleasesRoot $LegacyReleasesRoot `
                -LegacyInstallLockPath $LegacyInstallLockPath `
                -RootKind $rootKind `
                -ParentPid $ParentPid `
                -LockTimeoutMilliseconds $LockTimeoutMilliseconds `
                -ProcessProvider $ProcessProvider
            $result = [PSCustomObject]@{ Status = "Activated"; BuildId = $BuildId; LegacyBackup = $legacyBackup }
        } finally {
            if (Test-Path -LiteralPath $transaction.Path) {
                Remove-HerdrTransaction -Path $transaction.Path -Kind "fresh" -InstallRoot $InstallRoot
            }
        }
    }
    Install-HerdrSkillCopies -SourcePath $SkillSourcePath -AgentSkillsRoot $AgentSkillsRoot -ClaudeSkillsRoot $ClaudeSkillsRoot
    return $result
}

function Get-HerdrComparablePathEntry {
    param([AllowNull()][string]$Entry)

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return $null
    }
    $candidate = $Entry.Trim()
    if ($candidate.Length -ge 2 -and $candidate[0] -eq '"' -and $candidate[$candidate.Length - 1] -eq '"') {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }
    $candidate = [Environment]::ExpandEnvironmentVariables($candidate)
    try {
        return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
    } catch {
        return $candidate.TrimEnd('\')
    }
}

function Test-HerdrPathEntryEqual {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)

    $leftComparable = Get-HerdrComparablePathEntry -Entry $Left
    $rightComparable = Get-HerdrComparablePathEntry -Entry $Right
    return $null -ne $leftComparable -and $null -ne $rightComparable -and
        $leftComparable.Equals($rightComparable, [StringComparison]::OrdinalIgnoreCase)
}

function Add-HerdrPathEntry {
    param([AllowNull()][string]$PathValue, [Parameter(Mandatory = $true)][string]$Entry)

    $segments = if ($null -eq $PathValue) { @() } else { @($PathValue.Split([char[]]@(';'), [StringSplitOptions]::None)) }
    $result = New-Object System.Collections.Generic.List[string]
    $result.Add($Entry)
    foreach ($segment in $segments) {
        if (-not (Test-HerdrPathEntryEqual -Left $segment -Right $Entry)) {
            $result.Add($segment)
        }
    }
    return $result.ToArray() -join ';'
}

function Remove-HerdrPathEntry {
    param([AllowNull()][string]$PathValue, [Parameter(Mandatory = $true)][string]$Entry)

    if ($null -eq $PathValue) {
        return $null
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($segment in @($PathValue.Split([char[]]@(';'), [StringSplitOptions]::None))) {
        if (-not (Test-HerdrPathEntryEqual -Left $segment -Right $Entry)) {
            $result.Add($segment)
        }
    }
    return $result.ToArray() -join ';'
}

function Set-HerdrUserPath {
    param([Parameter(Mandatory = $true)][string]$BinDir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $updated = Add-HerdrPathEntry -PathValue $current -Entry $BinDir
    if ($updated -cne $current) {
        [Environment]::SetEnvironmentVariable("Path", $updated, "User")
    }
}

function Remove-HerdrUserPath {
    param([Parameter(Mandatory = $true)][string]$BinDir)

    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $updated = Remove-HerdrPathEntry -PathValue $current -Entry $BinDir
    if ($updated -cne $current) {
        [Environment]::SetEnvironmentVariable("Path", $updated, "User")
    }
}

function Assert-HerdrArpOwnership {
    param([Parameter(Mandatory = $true)][string]$InstallRoot, [string]$RegistryPath = $script:ArpKey)

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        return
    }
    $registeredRoot = [string](Get-ItemProperty -LiteralPath $RegistryPath).InstallLocation
    if ([string]::IsNullOrWhiteSpace($registeredRoot) -or -not (Test-HerdrPathEntryEqual -Left $registeredRoot -Right $InstallRoot)) {
        throw "Refusing to modify an ARP registration not owned by this Herdr install."
    }
}

function Set-HerdrArpRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [string]$RegistryPath = $script:ArpKey
    )

    Assert-HerdrArpOwnership -InstallRoot $InstallRoot -RegistryPath $RegistryPath
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
        QuietUninstallString = ('"' + $uninstaller + '" /S')
    }
    foreach ($name in $values.Keys) {
        New-ItemProperty -LiteralPath $RegistryPath -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $RegistryPath -Name "VersionMajor" -Value ([int]$numeric[0]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "VersionMinor" -Value ([int]$numeric[1]) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $RegistryPath -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
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
        [Parameter(Mandatory = $true)][string]$StageDir,
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$UninstallerPath,
        [Parameter(Mandatory = $true)][string]$HelperSourcePath,
        [Parameter(Mandatory = $true)][string]$SkillSourcePath,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion,
        [long]$ParentPid = 0,
        [int]$LifecycleLockTimeoutMilliseconds = 30000
    )

    if ($ParentPid -lt 0 -or $ParentPid -gt [uint32]::MaxValue) {
        throw "PARENT_PID must be a valid 32-bit process ID."
    }
    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    return Invoke-HerdrLifecycleOperation -InstallRoot $InstallRoot -TimeoutMilliseconds $LifecycleLockTimeoutMilliseconds -Operation {
        Assert-HerdrArpOwnership -InstallRoot $InstallRoot
        $agentSkillsRoot = Get-HerdrAgentSkillsRoot
        $claudeSkillsRoot = if (Test-HerdrClaudeCodeInstalled) { Get-HerdrClaudeSkillsRoot } else { $null }
        $result = Install-HerdrLayout `
            -InstallRoot $InstallRoot `
            -StageDir $StageDir `
            -LauncherPath $LauncherPath `
            -UninstallerPath $UninstallerPath `
            -HelperSourcePath $HelperSourcePath `
            -SkillSourcePath $SkillSourcePath `
            -AgentSkillsRoot $agentSkillsRoot `
            -ClaudeSkillsRoot $claudeSkillsRoot `
            -BuildId $BuildId `
            -DisplayVersion $DisplayVersion `
            -NumericVersion $NumericVersion `
            -LegacyReleasesRoot (Get-HerdrLegacyReleasesRoot) `
            -ParentPid $ParentPid
        Set-HerdrUserPath -BinDir (Join-Path $InstallRoot "bin")
        Set-HerdrArpRegistration -InstallRoot $InstallRoot -DisplayVersion $DisplayVersion -NumericVersion $NumericVersion
        return $result
    }
}

function Invoke-HerdrUninstallLayout {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [string[]]$ClaudeSkillsRoots = @(),
        [int]$LockTimeoutMilliseconds = 30000,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    Remove-HerdrRecoverableInstallTransactions -InstallRoot $InstallRoot
    $legacyRoot = Get-HerdrLegacyReleasesRoot
    $rootKind = Get-HerdrRootKind -InstallRoot $InstallRoot -LegacyReleasesRoot $legacyRoot
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
        $uninstallTransactions = @(Get-HerdrTransactions -InstallRoot $InstallRoot -Kind "uninstall")
        $processRoots = @($InstallRoot) + $uninstallTransactions
        $processes = @(& $ProcessProvider)
        if (Test-HerdrProcessWithinRoots -Processes $processes -Roots $processRoots) {
            throw "A process from the managed Herdr install tree is still active."
        }
        foreach ($path in $uninstallTransactions) {
            Remove-HerdrRecoverableUninstallTransaction -Path $path -InstallRoot $InstallRoot
        }

        Remove-HerdrSkillCopies -AgentSkillsRoot $AgentSkillsRoot -ClaudeSkillsRoots $ClaudeSkillsRoots
        $installManifestPath = Join-Path $stateDir "install.manifest"

        $transaction = New-HerdrTransaction -Kind "uninstall" -InstallRoot $InstallRoot
        if (Test-Path -LiteralPath $installManifestPath) {
            Copy-HerdrDurableFile -Source $installManifestPath -Destination (Join-Path $transaction.Path "root.manifest")
        }
        if (-not (Test-Path -LiteralPath (Join-Path $stateDir "uninstall.pending"))) {
            Write-HerdrDurableText -Path (Join-Path $transaction.Path "uninstall.pending") -Text $script:UninstallMarkerText
            Publish-HerdrStagedFile `
                -Source (Join-Path $transaction.Path "uninstall.pending") `
                -Destination (Join-Path $stateDir "uninstall.pending") `
                -BackupDir $transaction.Path
        }
        if (Test-Path -LiteralPath (Join-Path $InstallRoot "bin")) {
            [IO.Directory]::Move((Join-Path $InstallRoot "bin"), (Join-Path $transaction.Path "bin"))
        }
        if (Test-Path -LiteralPath (Join-Path $InstallRoot "runtime")) {
            [IO.Directory]::Move((Join-Path $InstallRoot "runtime"), (Join-Path $transaction.Path "runtime"))
        }
        Assert-HerdrUninstallTransaction -Path $transaction.Path -InstallRoot $InstallRoot
        Remove-HerdrUninstallTransaction -Path $transaction.Path -InstallRoot $InstallRoot

        Remove-HerdrStaleLeases -LeaseStatus $leaseStatus
        foreach ($name in @("active", "pending", "install.manifest")) {
            $path = Join-Path $stateDir $name
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        $leasesDir = Join-Path $stateDir "leases"
        if (Test-Path -LiteralPath $leasesDir) {
            Remove-Item -LiteralPath $leasesDir -Force
        }
    } finally {
        $coordination.Dispose()
    }
    Assert-HerdrUninstallResidual -InstallRoot $InstallRoot
}

function Invoke-HerdrUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [ValidateSet("Keep", "Remove")][string]$SettingsDisposition = "Keep",
        [string]$UserProfileRoot = $env:USERPROFILE,
        [int]$LifecycleLockTimeoutMilliseconds = 30000
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    Invoke-HerdrLifecycleOperation -InstallRoot $InstallRoot -TimeoutMilliseconds $LifecycleLockTimeoutMilliseconds -Operation {
        Assert-HerdrArpOwnership -InstallRoot $InstallRoot
        Invoke-HerdrUninstallLayout `
            -InstallRoot $InstallRoot `
            -AgentSkillsRoot (Get-HerdrAgentSkillsRoot) `
            -ClaudeSkillsRoots (Get-HerdrClaudeSkillsRootsForRemoval)
        Remove-HerdrUserPath -BinDir (Join-Path $InstallRoot "bin")
        Remove-HerdrArpRegistration -InstallRoot $InstallRoot
        if ($SettingsDisposition -ceq "Remove") {
            Remove-HerdrUserSettings -UserProfileRoot $UserProfileRoot
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Action) {
            "Install" {
                $result = Invoke-HerdrInstall `
                    -InstallRoot $InstallRoot `
                    -StageDir $StageDir `
                    -LauncherPath $LauncherPath `
                    -UninstallerPath $UninstallerPath `
                    -HelperSourcePath $HelperSourcePath `
                    -SkillSourcePath $SkillSourcePath `
                    -BuildId $BuildId `
                    -DisplayVersion $DisplayVersion `
                    -NumericVersion $NumericVersion `
                    -ParentPid $ParentPid
                if ($result.Status -ceq "Pending") {
                    [Console]::Out.WriteLine("$script:ProductName $($result.BuildId): Pending; staged until old sessions exit.")
                } else {
                    [Console]::Out.WriteLine("$script:ProductName $($result.BuildId): $($result.Status)")
                }
            }
            "Uninstall" {
                Invoke-HerdrUninstall -InstallRoot $InstallRoot -SettingsDisposition $SettingsDisposition
                [Console]::Out.WriteLine("$script:ProductName uninstall cleanup is ready.")
            }
            default {
                throw "Action must be Install or Uninstall."
            }
        }
        exit 0
    } catch {
        [Console]::Error.WriteLine("$script:ProductName installer error: $($_.Exception.Message)")
        exit 1
    }
}
