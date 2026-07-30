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
$script:InstallManifestHeader = "herdr-install-manifest-v2"
$script:AgentSkillTransactionMarkerName = ".herdr-agent-skill-transaction"
$script:AgentSkillTransactionMarkerNewName = ".herdr-agent-skill-transaction.new"
$script:AgentSkillPhaseStaged = ".herdr-agent-skill-staged"
$script:AgentSkillPhasePublishing = ".herdr-agent-skill-publishing"
$script:AgentSkillPhasePublished = ".herdr-agent-skill-published"
$script:AgentSkillPhaseCompleting = ".herdr-agent-skill-completing"
$script:AgentSkillPhaseRollingBack = ".herdr-agent-skill-rolling-back"
$script:AgentSkillRemovalOwnerName = ".herdr-agent-skill-removal"
$script:AgentSkillRemovalCandidateName = "owned-SKILL.md"
$script:AgentSkillRemovalCleanupPattern = '^\.herdr-installer-skill-cleanup\.([0-9a-f]{32})$'
$script:ManagedBinMarkerText = "herdr-managed-bin-v1`n"
$script:UninstallMarkerText = "herdr-uninstall-v1`n"
$script:TransactionMarkerName = ".herdr-installer-transaction"
$script:ArpKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$script:ProductName"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

if ($null -eq ("Herdr.Installer.PinnedSkillFile" -as [type])) {
    $pinnedSkillFileSource = @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Herdr.Installer
{
    public sealed class PinnedSkillFile : IDisposable
    {
        private const uint DeleteAccess = 0x00010000;
        private const uint FileReadData = 0x00000001;
        private const uint FileReadAttributes = 0x00000080;
        private const uint OpenExisting = 3;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileRenameInfo = 3;
        private const int FileDispositionInfo = 4;

        private SafeFileHandle handle;
        private bool disposed;

        private PinnedSkillFile(SafeFileHandle handle, string sha256Hex)
        {
            this.handle = handle;
            this.Sha256Hex = sha256Hex;
        }

        public string Sha256Hex { get; private set; }

        public static PinnedSkillFile Open(string path)
        {
            if (String.IsNullOrWhiteSpace(path))
            {
                throw new ArgumentException("A skill file path is required.", "path");
            }
            SafeFileHandle file = CreateFileW(
                Path.GetFullPath(path),
                DeleteAccess | FileReadData | FileReadAttributes,
                0,
                IntPtr.Zero,
                OpenExisting,
                FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (file.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                file.Dispose();
                throw new Win32Exception(error, "Could not pin detached SKILL.md");
            }
            try
            {
                BY_HANDLE_FILE_INFORMATION information;
                if (!GetFileInformationByHandle(file, out information))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not inspect detached SKILL.md");
                }
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
                {
                    throw new InvalidDataException("Detached SKILL.md is a reparse point.");
                }
                if ((information.FileAttributes & FileAttributeDirectory) != 0)
                {
                    throw new InvalidDataException("Detached SKILL.md is a directory.");
                }
                if (information.NumberOfLinks != 1)
                {
                    throw new InvalidDataException("Detached SKILL.md must have exactly one hard link.");
                }
                string hash = HashSameHandle(file);
                PinnedSkillFile result = new PinnedSkillFile(file, hash);
                file = null;
                return result;
            }
            finally
            {
                if (file != null)
                {
                    file.Dispose();
                }
            }
        }

        public void DeleteByHandle()
        {
            if (this.disposed)
            {
                throw new ObjectDisposedException("PinnedSkillFile");
            }
            FILE_DISPOSITION_INFO disposition = new FILE_DISPOSITION_INFO();
            disposition.DeleteFile = 1;
            if (!SetFileInformationByHandle(
                    this.handle,
                    FileDispositionInfo,
                    ref disposition,
                    1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not delete pinned detached SKILL.md");
            }
            this.handle.Dispose();
            this.handle = null;
            this.disposed = true;
            GC.SuppressFinalize(this);
        }

        public void MoveTo(string destinationPath)
        {
            if (this.disposed)
            {
                throw new ObjectDisposedException("PinnedSkillFile");
            }
            string destination = Path.GetFullPath(destinationPath);
            byte[] name = Encoding.Unicode.GetBytes(destination);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            int bufferSize = checked(nameOffset + name.Length + 2);
            IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
            try
            {
                for (int index = 0; index < bufferSize; index++)
                {
                    Marshal.WriteByte(buffer, index, 0);
                }
                Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                Marshal.Copy(name, 0, new IntPtr(buffer.ToInt64() + nameOffset), name.Length);
                if (!SetFileInformationByHandleBuffer(
                        this.handle,
                        FileRenameInfo,
                        buffer,
                        bufferSize))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not isolate pinned detached SKILL.md");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public void Dispose()
        {
            if (this.handle != null)
            {
                this.handle.Dispose();
                this.handle = null;
            }
            this.disposed = true;
            GC.SuppressFinalize(this);
        }

        private static string HashSameHandle(SafeFileHandle file)
        {
            bool addedReference = false;
            file.DangerousAddRef(ref addedReference);
            try
            {
#pragma warning disable 618
                using (FileStream stream = new FileStream(
                    file.DangerousGetHandle(),
                    FileAccess.Read,
                    false,
                    65536,
                    false))
#pragma warning restore 618
                using (SHA256 sha256 = SHA256.Create())
                {
                    byte[] hash = sha256.ComputeHash(stream);
                    char[] text = new char[hash.Length * 2];
                    const string alphabet = "0123456789abcdef";
                    for (int index = 0; index < hash.Length; index++)
                    {
                        text[index * 2] = alphabet[hash[index] >> 4];
                        text[index * 2 + 1] = alphabet[hash[index] & 0x0f];
                    }
                    return new string(text);
                }
            }
            finally
            {
                if (addedReference)
                {
                    file.DangerousRelease();
                }
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public FILETIME CreationTime;
            public FILETIME LastAccessTime;
            public FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct FILE_DISPOSITION_INFO
        {
            public byte DeleteFile;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            int informationClass,
            ref FILE_DISPOSITION_INFO information,
            int bufferSize);

        [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileInformationByHandleBuffer(
            SafeFileHandle file,
            int informationClass,
            IntPtr information,
            int bufferSize);
    }
}
'@
    if ($PSVersionTable.PSEdition -ceq "Desktop") {
        Add-Type `
            -TypeDefinition $pinnedSkillFileSource `
            -ReferencedAssemblies @([ComponentModel.Win32Exception].Assembly.Location)
    } else {
        Add-Type -TypeDefinition $pinnedSkillFileSource
    }
}

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

function Get-HerdrAgentSkillsRoot {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw "USERPROFILE is not set; the cross-agent skill directory cannot be located."
    }
    $userProfile = Get-HerdrFullPath -Path $env:USERPROFILE
    Assert-HerdrRegularDirectory -Path $userProfile
    $skillsRoot = [IO.Path]::GetFullPath((Join-Path $userProfile ".agents\skills")).TrimEnd('\')
    if (-not (Test-HerdrPathWithin -Path $skillsRoot -Root $userProfile)) {
        throw "Cross-agent skill directory escaped USERPROFILE: $skillsRoot"
    }
    return $skillsRoot
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

function Initialize-HerdrAgentSkillsRoot {
    param([Parameter(Mandatory = $true)][string]$AgentSkillsRoot)

    $AgentSkillsRoot = Get-HerdrFullPath -Path $AgentSkillsRoot
    $parent = Split-Path -Parent $AgentSkillsRoot
    $grandparent = Split-Path -Parent $parent
    Assert-HerdrRegularDirectory -Path $grandparent
    if (Test-Path -LiteralPath $AgentSkillsRoot) {
        Assert-HerdrRegularDirectory -Path $parent
        Assert-HerdrRegularDirectory -Path $AgentSkillsRoot
        return $AgentSkillsRoot
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $parent
    New-Item -ItemType Directory -Path $AgentSkillsRoot | Out-Null
    Assert-HerdrRegularDirectory -Path $AgentSkillsRoot
    return $AgentSkillsRoot
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

function Move-HerdrAgentSkillPath {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-HerdrReplaceableAgentSkillPath -Path $Source
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.PSIsContainer) {
        [IO.Directory]::Move($Source, $Destination)
    } else {
        [IO.File]::Move($Source, $Destination)
    }
}

function Get-HerdrAgentSkillLockPath {
    param([Parameter(Mandatory = $true)][string]$AgentSkillsRoot)

    $root = Get-HerdrFullPath -Path $AgentSkillsRoot
    return Join-Path (Split-Path -Parent $root) ".herdr-agent-skill-installer.lock"
}

function Assert-HerdrAgentSkillTransactionPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot
    )

    $root = Get-HerdrFullPath -Path $AgentSkillsRoot
    $fullPath = Get-HerdrFullPath -Path $Path
    $name = Split-Path -Leaf $fullPath
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $fullPath)).Equals($root, [StringComparison]::OrdinalIgnoreCase)) -or
        $name -cnotmatch '^\.herdr-installer-skill\.[0-9a-f]{32}$') {
        throw "Refusing an unrecognized Herdr agent skill transaction: $Path"
    }
    Assert-HerdrRegularDirectory -Path $fullPath
    return $fullPath
}

function Get-HerdrAgentSkillTransactionMarkerText {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$SkillSha256,
        [Parameter(Mandatory = $true)][bool]$HadPrevious
    )

    if ($DisplayVersion -cnotmatch '^[0-9A-Za-z._+\-]+$' -or $SkillSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid Herdr agent skill transaction identity."
    }
    $rootHash = Get-HerdrTextSha256 -Text ((Get-HerdrFullPath -Path $InstallRoot).ToLowerInvariant())
    $hadPreviousValue = if ($HadPrevious) { "1" } else { "0" }
    return "herdr-agent-skill-transaction-v2`ninstall_root_sha256=$rootHash`ndisplay_version=$DisplayVersion`nskill_sha256=$SkillSha256`nhad_previous=$hadPreviousValue`n"
}

function Test-HerdrExactAgentSkill {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    try {
        Assert-HerdrRegularDirectory -Path $Path
        $entries = @(Get-ChildItem -LiteralPath $Path -Force)
        return $entries.Count -eq 1 -and $entries[0].Name -ceq "SKILL.md" -and -not $entries[0].PSIsContainer -and
            -not ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            (Get-HerdrSha256 -Path (Join-Path $Path "SKILL.md")) -ceq $ExpectedSha256
    } catch {
        return $false
    }
}

function Assert-HerdrAgentSkillTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $Path = Assert-HerdrAgentSkillTransactionPath -Path $Path -AgentSkillsRoot $AgentSkillsRoot
    $entries = @(Get-ChildItem -LiteralPath $Path -Force)
    foreach ($entry in $entries) {
        if ($entry.Name -cnotin @(
            $script:AgentSkillTransactionMarkerName,
            $script:AgentSkillPhaseStaged,
            $script:AgentSkillPhasePublishing,
            $script:AgentSkillPhasePublished,
            $script:AgentSkillPhaseCompleting,
            $script:AgentSkillPhaseRollingBack,
            $script:AgentSkillRemovalOwnerName,
            $script:AgentSkillRemovalCandidateName,
            "new",
            "previous",
            "discard",
            "discard-new"
        )) {
            throw "Herdr agent skill transaction contains unexpected content: $($entry.FullName)"
        }
    }
    $marker = Join-Path $Path $script:AgentSkillTransactionMarkerName
    $text = Read-HerdrStrictUtf8 -Path $marker
    $match = [regex]::Match(
        $text,
        '\Aherdr-agent-skill-transaction-v2\ninstall_root_sha256=([0-9a-f]{64})\ndisplay_version=([0-9A-Za-z._+\-]+)\nskill_sha256=([0-9a-f]{64})\nhad_previous=([01])\n\z'
    )
    $expectedRootHash = Get-HerdrTextSha256 -Text ((Get-HerdrFullPath -Path $InstallRoot).ToLowerInvariant())
    if (-not $match.Success -or $match.Groups[1].Value -cne $expectedRootHash) {
        throw "Herdr agent skill transaction marker is invalid: $Path"
    }
    $phaseNames = @(
        $script:AgentSkillPhaseStaged,
        $script:AgentSkillPhasePublishing,
        $script:AgentSkillPhasePublished,
        $script:AgentSkillPhaseCompleting,
        $script:AgentSkillPhaseRollingBack
    )
    $phases = @($entries | Where-Object { $phaseNames -ccontains $_.Name })
    if ($phases.Count -ne 1 -or $phases[0].PSIsContainer -or
        ($phases[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or $phases[0].Length -ne 0) {
        throw "Herdr agent skill transaction has an invalid phase owner: $Path"
    }
    $removalOwners = @($entries | Where-Object { $_.Name -ceq $script:AgentSkillRemovalOwnerName })
    if ($removalOwners.Count -gt 1 -or
        ($removalOwners.Count -eq 1 -and ($removalOwners[0].PSIsContainer -or
            ($removalOwners[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $removalOwners[0].Length -ne 0))) {
        throw "Herdr agent skill transaction has an invalid removal owner: $Path"
    }
    $operation = if ($removalOwners.Count -eq 1) { "Removal" } else { "Install" }
    $new = Join-Path $Path "new"
    if ($operation -ceq "Removal") {
        if ($phases[0].Name -cnotin @(
            $script:AgentSkillPhaseStaged,
            $script:AgentSkillPhasePublishing,
            $script:AgentSkillPhaseCompleting
        )) {
            throw "Herdr agent skill removal transaction has an invalid phase: $Path"
        }
        foreach ($forbidden in @("new", "discard", "discard-new")) {
            if (Test-Path -LiteralPath (Join-Path $Path $forbidden)) {
                throw "Herdr agent skill removal transaction contains install-only content: $Path"
            }
        }
        $previous = Join-Path $Path "previous"
        if (Test-Path -LiteralPath $previous) {
            Assert-HerdrRegularDirectory -Path $previous
        }
        $candidate = Join-Path $Path $script:AgentSkillRemovalCandidateName
        if (Test-Path -LiteralPath $candidate) {
            Assert-HerdrRegularFile -Path $candidate
        }
    } else {
        if (Test-Path -LiteralPath (Join-Path $Path $script:AgentSkillRemovalCandidateName)) {
            throw "Herdr agent skill install transaction contains a removal candidate: $Path"
        }
        if (Test-Path -LiteralPath $new) {
            if ($phases[0].Name -ceq $script:AgentSkillPhaseRollingBack) {
                Assert-HerdrRegularDirectory -Path $new
                $partialEntries = @(Get-ChildItem -LiteralPath $new -Force)
                if ($partialEntries.Count -gt 1 -or
                    ($partialEntries.Count -eq 1 -and ($partialEntries[0].Name -cne "SKILL.md" -or
                        $partialEntries[0].PSIsContainer -or
                        ($partialEntries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)))) {
                    throw "Herdr agent skill rollback has invalid staged cleanup content: $Path"
                }
            } elseif (-not (Test-HerdrExactAgentSkill -Path $new -ExpectedSha256 $match.Groups[3].Value)) {
                throw "Herdr agent skill transaction has an invalid staged skill: $Path"
            }
        }
        foreach ($name in @("previous", "discard", "discard-new")) {
            $owned = Join-Path $Path $name
            if (Test-Path -LiteralPath $owned) {
                Assert-HerdrReplaceableAgentSkillPath -Path $owned
            }
        }
    }
    return [PSCustomObject]@{
        Path = $Path
        DisplayVersion = $match.Groups[2].Value
        SkillSha256 = $match.Groups[3].Value
        HadPrevious = $match.Groups[4].Value -ceq "1"
        Phase = $phases[0].Name
        Operation = $operation
    }
}

function Test-HerdrAgentSkillTransactionCommitted {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $manifestPath = Join-Path $InstallRoot "state\install.manifest"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $manifest = Read-HerdrInstallManifestFile -Path $manifestPath
    return $manifest.DisplayVersion -ceq $Transaction.DisplayVersion -and
        $manifest.SkillSha256 -ceq $Transaction.SkillSha256
}

function Complete-HerdrAgentSkillTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [switch]$RequireExactTarget
    )

    $transaction = Assert-HerdrAgentSkillTransaction -Path $Path -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Install") {
        throw "A Herdr agent skill removal transaction cannot use install completion."
    }
    if ($transaction.Phase -cne $script:AgentSkillPhasePublished -and
        $transaction.Phase -cne $script:AgentSkillPhaseCompleting) {
        throw "Cannot complete a Herdr agent skill transaction before publication."
    }
    if (-not (Test-HerdrAgentSkillTransactionCommitted -Transaction $transaction -InstallRoot $InstallRoot)) {
        throw "Cannot complete a Herdr agent skill transaction before its install manifest commit."
    }
    if ($RequireExactTarget -and
        -not (Test-HerdrExactAgentSkill -Path (Join-Path $AgentSkillsRoot "herdr") -ExpectedSha256 $transaction.SkillSha256)) {
        throw "Published Herdr agent skill changed before installer completion."
    }
    $phase = Join-Path $Path $transaction.Phase
    if ($transaction.Phase -ceq $script:AgentSkillPhasePublished) {
        $completing = Join-Path $Path $script:AgentSkillPhaseCompleting
        [IO.File]::Move($phase, $completing)
        $phase = $completing
    }
    foreach ($name in @("new", "previous", "discard", "discard-new")) {
        $owned = Join-Path $Path $name
        if (Test-Path -LiteralPath $owned) {
            Remove-HerdrReplaceableAgentSkillPath -Path $owned
        }
    }
    Remove-Item -LiteralPath (Join-Path $Path $script:AgentSkillTransactionMarkerName) -Force
    Remove-Item -LiteralPath $phase -Force
    Remove-Item -LiteralPath $Path -Force
}

function Undo-HerdrAgentSkillTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $transaction = Assert-HerdrAgentSkillTransaction -Path $Path -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Install") {
        throw "A Herdr agent skill removal transaction cannot use install rollback."
    }
    if ($transaction.Phase -ceq $script:AgentSkillPhaseCompleting) {
        throw "A completing Herdr agent skill transaction cannot be rolled back."
    }
    $originalPhase = $transaction.Phase
    $phase = Join-Path $Path $originalPhase
    if ($originalPhase -cne $script:AgentSkillPhaseRollingBack) {
        $rollingBack = Join-Path $Path $script:AgentSkillPhaseRollingBack
        [IO.File]::Move($phase, $rollingBack)
        $phase = $rollingBack
    }
    $target = Join-Path $AgentSkillsRoot "herdr"
    $new = Join-Path $Path "new"
    $previous = Join-Path $Path "previous"
    $discard = Join-Path $Path "discard"
    $discardNew = Join-Path $Path "discard-new"

    if ($originalPhase -cne $script:AgentSkillPhaseStaged) {
        if ($transaction.HadPrevious) {
            if (Test-Path -LiteralPath $previous) {
                if (Test-Path -LiteralPath $target) {
                    if (-not (Test-HerdrExactAgentSkill -Path $target -ExpectedSha256 $transaction.SkillSha256)) {
                        throw "A changed Herdr agent skill blocks safe transaction rollback."
                    }
                    Move-HerdrAgentSkillPath -Source $target -Destination $discard
                }
                Move-HerdrAgentSkillPath -Source $previous -Destination $target
            } elseif ((Test-Path -LiteralPath $discard) -and -not (Test-Path -LiteralPath $target)) {
                throw "Herdr agent skill rollback lost its previous target."
            }
        } elseif (-not (Test-Path -LiteralPath $new) -and (Test-Path -LiteralPath $target)) {
            if (-not (Test-HerdrExactAgentSkill -Path $target -ExpectedSha256 $transaction.SkillSha256)) {
                throw "A changed Herdr agent skill blocks safe transaction rollback."
            }
            Move-HerdrAgentSkillPath -Source $target -Destination $discard
        }
    }
    if (Test-Path -LiteralPath $new) {
        if (Test-Path -LiteralPath $discardNew) {
            throw "Herdr agent skill rollback has duplicate staged cleanup owners."
        }
        Move-HerdrAgentSkillPath -Source $new -Destination $discardNew
    }
    foreach ($owned in @($previous, $discard, $discardNew)) {
        if (Test-Path -LiteralPath $owned) {
            Remove-HerdrReplaceableAgentSkillPath -Path $owned
        }
    }
    Remove-Item -LiteralPath (Join-Path $Path $script:AgentSkillTransactionMarkerName) -Force
    Remove-Item -LiteralPath $phase -Force
    Remove-Item -LiteralPath $Path -Force
}

function Restore-HerdrAgentSkillTransactions {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $cleanupPaths = @(Get-ChildItem -LiteralPath $AgentSkillsRoot -Force | Where-Object {
        $_.Name -cmatch $script:AgentSkillRemovalCleanupPattern
    })
    foreach ($cleanupPath in $cleanupPaths) {
        Remove-HerdrAgentSkillRemovalCleanupPath `
            -Path $cleanupPath.FullName `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
    }
    $transactions = @(Get-ChildItem -LiteralPath $AgentSkillsRoot -Force -Directory | Where-Object {
        $_.Name -cmatch '^\.herdr-installer-skill\.[0-9a-f]{32}$'
    })
    if ($transactions.Count -gt 1) {
        throw "Multiple interrupted Herdr agent skill transactions require manual review."
    }
    foreach ($transactionPath in $transactions) {
        $transactionFullPath = Assert-HerdrAgentSkillTransactionPath `
            -Path $transactionPath.FullName `
            -AgentSkillsRoot $AgentSkillsRoot
        $marker = Join-Path $transactionFullPath $script:AgentSkillTransactionMarkerName
        if (-not (Test-Path -LiteralPath $marker)) {
            $entries = @(Get-ChildItem -LiteralPath $transactionFullPath -Force)
            if ($entries.Count -eq 0) {
                Remove-Item -LiteralPath $transactionFullPath -Force
                continue
            }
            $entryNames = @($entries | ForEach-Object { $_.Name })
            $creationNames = @(
                "new",
                $script:AgentSkillRemovalOwnerName,
                $script:AgentSkillPhaseStaged,
                $script:AgentSkillTransactionMarkerNewName
            )
            $cleanupNames = @($script:AgentSkillPhaseCompleting, $script:AgentSkillPhaseRollingBack)
            $isCreation = @($entryNames | Where-Object { $creationNames -cnotcontains $_ }).Count -eq 0
            $isCleanup = $entryNames.Count -eq 1 -and $cleanupNames -ccontains $entryNames[0]
            if (-not $isCreation -and -not $isCleanup) {
                throw "Markerless Herdr agent skill transaction contains unexpected content: $transactionFullPath"
            }
            foreach ($entry in $entries) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "Markerless Herdr agent skill transaction contains a reparse point: $($entry.FullName)"
                }
                if ($entry.Name -ceq "new") {
                    Assert-HerdrRegularDirectory -Path $entry.FullName
                    $stagedEntries = @(Get-ChildItem -LiteralPath $entry.FullName -Force)
                    if ($stagedEntries.Count -gt 1 -or
                        ($stagedEntries.Count -eq 1 -and ($stagedEntries[0].Name -cne "SKILL.md" -or
                            $stagedEntries[0].PSIsContainer -or
                            ($stagedEntries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)))) {
                        throw "Markerless Herdr agent skill staging contains unexpected content: $($entry.FullName)"
                    }
                } elseif ($entry.Name -ceq $script:AgentSkillTransactionMarkerNewName) {
                    Assert-HerdrRegularFile -Path $entry.FullName
                } elseif ($entry.PSIsContainer -or $entry.Length -ne 0) {
                    throw "Markerless Herdr agent skill transaction file is invalid: $($entry.FullName)"
                }
            }
            Remove-HerdrReplaceableAgentSkillPath -Path $transactionFullPath
            if (-not (Test-Path -LiteralPath $transactionFullPath)) {
                continue
            }
            throw "Markerless Herdr agent skill transaction cleanup did not reach terminal state: $transactionFullPath"
        }
        $transaction = Assert-HerdrAgentSkillTransaction `
            -Path $transactionFullPath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
        if ($transaction.Operation -ceq "Removal") {
            Restore-HerdrAgentSkillRemovalTransaction `
                -Path $transaction.Path `
                -AgentSkillsRoot $AgentSkillsRoot `
                -InstallRoot $InstallRoot
        } elseif (($transaction.Phase -ceq $script:AgentSkillPhasePublished -or
                $transaction.Phase -ceq $script:AgentSkillPhaseCompleting) -and
            (Test-HerdrAgentSkillTransactionCommitted -Transaction $transaction -InstallRoot $InstallRoot)) {
            Complete-HerdrAgentSkillTransaction -Path $transaction.Path -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
        } elseif ($transaction.Phase -ceq $script:AgentSkillPhaseCompleting) {
            throw "A completing Herdr agent skill transaction lost its install manifest commit."
        } else {
            Undo-HerdrAgentSkillTransaction -Path $transaction.Path -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
        }
    }
}

function New-HerdrAgentSkillTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion
    )

    $expectedHash = Get-HerdrAgentSkillSha256 -Path $SourcePath
    $target = Join-Path $AgentSkillsRoot "herdr"
    Assert-HerdrReplaceableAgentSkillPath -Path $target
    $hadPrevious = Test-Path -LiteralPath $target
    $transaction = Join-Path $AgentSkillsRoot (".herdr-installer-skill." + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $transaction | Out-Null
    $staged = Join-Path $transaction "new"
    New-Item -ItemType Directory -Path $staged | Out-Null
    Copy-HerdrDurableFile -Source $SourcePath -Destination (Join-Path $staged "SKILL.md")
    if ((Get-HerdrAgentSkillSha256 -Path (Join-Path $staged "SKILL.md")) -cne $expectedHash) {
        throw "Staged Herdr agent skill differs from its embedded source."
    }
    Write-HerdrDurableBytes -Path (Join-Path $transaction $script:AgentSkillPhaseStaged) -Bytes ([byte[]]@())
    $markerNew = Join-Path $transaction $script:AgentSkillTransactionMarkerNewName
    Write-HerdrDurableText -Path $markerNew -Text (
        Get-HerdrAgentSkillTransactionMarkerText `
            -InstallRoot $InstallRoot `
            -DisplayVersion $DisplayVersion `
            -SkillSha256 $expectedHash `
            -HadPrevious $hadPrevious
    )
    [IO.File]::Move($markerNew, (Join-Path $transaction $script:AgentSkillTransactionMarkerName))
    return Assert-HerdrAgentSkillTransaction -Path $transaction -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
}

function Publish-HerdrAgentSkillTransaction {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $state = Assert-HerdrAgentSkillTransaction `
        -Path $Transaction.Path `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($state.Phase -cne $script:AgentSkillPhaseStaged) {
        throw "Herdr agent skill transaction is not in its staged phase."
    }
    $staged = Join-Path $state.Path "new"
    if (-not (Test-HerdrExactAgentSkill -Path $staged -ExpectedSha256 $state.SkillSha256)) {
        throw "Herdr agent skill transaction does not contain its exact staged skill."
    }
    $target = Join-Path $AgentSkillsRoot "herdr"
    Assert-HerdrReplaceableAgentSkillPath -Path $target
    if ($state.HadPrevious -cne (Test-Path -LiteralPath $target)) {
        throw "Herdr agent skill target changed after transaction staging."
    }
    $publishing = Join-Path $state.Path $script:AgentSkillPhasePublishing
    [IO.File]::Move((Join-Path $state.Path $script:AgentSkillPhaseStaged), $publishing)
    $previous = Join-Path $state.Path "previous"
    if ($state.HadPrevious) {
        Move-HerdrAgentSkillPath -Source $target -Destination $previous
    }
    [IO.Directory]::Move($staged, $target)
    [IO.File]::Move($publishing, (Join-Path $state.Path $script:AgentSkillPhasePublished))
    if (-not (Test-HerdrExactAgentSkill -Path $target -ExpectedSha256 $state.SkillSha256)) {
        throw "Published Herdr agent skill does not exactly match its embedded source."
    }
}

function Get-HerdrAgentSkillRemovalCleanupPath {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot
    )

    $root = Get-HerdrFullPath -Path $AgentSkillsRoot
    $transaction = Get-HerdrFullPath -Path $TransactionPath
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $transaction)).Equals($root, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Herdr agent skill removal transaction escaped its skills root: $TransactionPath"
    }
    $match = [regex]::Match((Split-Path -Leaf $transaction), '^\.herdr-installer-skill\.([0-9a-f]{32})$')
    if (-not $match.Success) {
        throw "Herdr agent skill removal transaction name is invalid: $TransactionPath"
    }
    return Join-Path $root (".herdr-installer-skill-cleanup." + $match.Groups[1].Value)
}

function Remove-HerdrAgentSkillRemovalCleanupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $root = Get-HerdrFullPath -Path $AgentSkillsRoot
    $cleanup = Get-HerdrFullPath -Path $Path
    if (-not ([IO.Path]::GetFullPath((Split-Path -Parent $cleanup)).Equals($root, [StringComparison]::OrdinalIgnoreCase)) -or
        (Split-Path -Leaf $cleanup) -cnotmatch $script:AgentSkillRemovalCleanupPattern) {
        throw "Refusing an unrecognized Herdr agent skill removal cleanup path: $Path"
    }
    Assert-HerdrRegularDirectory -Path $cleanup
    $entries = @(Get-ChildItem -LiteralPath $cleanup -Force)
    $phaseNames = @(
        $script:AgentSkillPhaseStaged,
        $script:AgentSkillPhasePublishing,
        $script:AgentSkillPhaseCompleting
    )
    foreach ($entry in $entries) {
        if ($entry.Name -cnotin @(
            $script:AgentSkillTransactionMarkerName,
            $script:AgentSkillRemovalOwnerName
        ) -and $phaseNames -cnotcontains $entry.Name) {
            throw "Herdr agent skill removal cleanup contains unexpected content: $($entry.FullName)"
        }
        if ($entry.Name -ceq $script:AgentSkillTransactionMarkerName) {
            $text = Read-HerdrStrictUtf8 -Path $entry.FullName
            $match = [regex]::Match(
                $text,
                '\Aherdr-agent-skill-transaction-v2\ninstall_root_sha256=([0-9a-f]{64})\ndisplay_version=([0-9A-Za-z._+\-]+)\nskill_sha256=([0-9a-f]{64})\nhad_previous=1\n\z'
            )
            $expectedRootHash = Get-HerdrTextSha256 -Text ((Get-HerdrFullPath -Path $InstallRoot).ToLowerInvariant())
            if (-not $match.Success -or $match.Groups[1].Value -cne $expectedRootHash) {
                throw "Herdr agent skill removal cleanup marker is invalid: $($entry.FullName)"
            }
        } elseif ($entry.PSIsContainer -or
            ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entry.Length -ne 0) {
            throw "Herdr agent skill removal cleanup owner is invalid: $($entry.FullName)"
        }
    }
    if (@($entries | Where-Object { $phaseNames -ccontains $_.Name }).Count -gt 1) {
        throw "Herdr agent skill removal cleanup has multiple phase owners: $cleanup"
    }
    foreach ($entry in $entries) {
        Remove-Item -LiteralPath $entry.FullName -Force
    }
    if (@(Get-ChildItem -LiteralPath $cleanup -Force).Count -ne 0) {
        throw "Herdr agent skill removal cleanup did not reach an empty terminal state: $cleanup"
    }
    Remove-Item -LiteralPath $cleanup -Force
}

function Remove-HerdrAgentSkillRemovalTransactionOwner {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $state = Assert-HerdrAgentSkillTransaction `
        -Path $Transaction.Path `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($state.Operation -cne "Removal") {
        throw "An install transaction cannot use removal cleanup."
    }
    foreach ($name in @("previous", $script:AgentSkillRemovalCandidateName)) {
        if (Test-Path -LiteralPath (Join-Path $state.Path $name)) {
            throw "Herdr agent skill removal cleanup still owns detached content: $($state.Path)"
        }
    }
    $cleanup = Get-HerdrAgentSkillRemovalCleanupPath `
        -TransactionPath $state.Path `
        -AgentSkillsRoot $AgentSkillsRoot
    if (Test-Path -LiteralPath $cleanup) {
        throw "Herdr agent skill removal cleanup path already exists: $cleanup"
    }
    [IO.Directory]::Move($state.Path, $cleanup)
    Remove-HerdrAgentSkillRemovalCleanupPath `
        -Path $cleanup `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
}

function Move-HerdrAgentSkillRemovalCandidateBack {
    param([Parameter(Mandatory = $true)][object]$Transaction)

    $candidate = Join-Path $Transaction.Path $script:AgentSkillRemovalCandidateName
    if (-not (Test-Path -LiteralPath $candidate)) {
        return
    }
    Assert-HerdrRegularFile -Path $candidate
    $previous = Join-Path $Transaction.Path "previous"
    if (-not (Test-Path -LiteralPath $previous)) {
        New-Item -ItemType Directory -Path $previous | Out-Null
    }
    Assert-HerdrRegularDirectory -Path $previous
    $skill = Join-Path $previous "SKILL.md"
    if (Test-Path -LiteralPath $skill) {
        throw "Detached Herdr agent skill already contains SKILL.md; the isolated removal candidate is preserved."
    }
    [IO.File]::Move($candidate, $skill)
}

function Undo-HerdrAgentSkillRemovalTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $transaction = Assert-HerdrAgentSkillTransaction `
        -Path $Path `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Removal" -or $transaction.Phase -ceq $script:AgentSkillPhaseCompleting) {
        throw "Only an uncommitted Herdr agent skill removal can be restored."
    }
    Move-HerdrAgentSkillRemovalCandidateBack -Transaction $transaction
    $previous = Join-Path $transaction.Path "previous"
    if (Test-Path -LiteralPath $previous) {
        $target = Join-Path $AgentSkillsRoot "herdr"
        if (Test-Path -LiteralPath $target) {
            throw "A concurrent Herdr agent skill replacement blocks restoration; detached content remains at $previous"
        }
        Assert-HerdrRegularDirectory -Path $previous
        [IO.Directory]::Move($previous, $target)
    }
    Remove-HerdrAgentSkillRemovalTransactionOwner `
        -Transaction $transaction `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
}

function Remove-HerdrPinnedAgentSkillCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $candidate = Join-Path $Transaction.Path $script:AgentSkillRemovalCandidateName
    $pinned = [Herdr.Installer.PinnedSkillFile]::Open($candidate)
    if ($pinned.Sha256Hex -cne $ExpectedSha256) {
        $actual = $pinned.Sha256Hex
        $pinned.Dispose()
        throw "Detached Herdr agent skill changed before deletion (expected $ExpectedSha256, found $actual); it is preserved."
    }
    try {
        $pinned.DeleteByHandle()
    } finally {
        $pinned.Dispose()
    }
}

function Restore-HerdrAgentSkillRemovalTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot
    )

    $transaction = Assert-HerdrAgentSkillTransaction `
        -Path $Path `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Removal") {
        throw "An install transaction cannot use removal recovery."
    }
    if ($transaction.Phase -cne $script:AgentSkillPhaseCompleting) {
        Undo-HerdrAgentSkillRemovalTransaction `
            -Path $transaction.Path `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
        return
    }
    if (Test-Path -LiteralPath (Join-Path $transaction.Path "previous")) {
        throw "Committed Herdr agent skill removal retained unexpected detached directory content."
    }
    if (Test-Path -LiteralPath (Join-Path $transaction.Path $script:AgentSkillRemovalCandidateName)) {
        Remove-HerdrPinnedAgentSkillCandidate `
            -Transaction $transaction `
            -ExpectedSha256 $transaction.SkillSha256
    }
    Remove-HerdrAgentSkillRemovalTransactionOwner `
        -Transaction $transaction `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
}

function Start-HerdrInstalledAgentSkillRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $target = Join-Path $AgentSkillsRoot "herdr"
    if (-not (Test-Path -LiteralPath $target)) {
        return $null
    }
    $transactionPath = Join-Path $AgentSkillsRoot (".herdr-installer-skill." + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $transactionPath | Out-Null
    Write-HerdrDurableBytes -Path (Join-Path $transactionPath $script:AgentSkillRemovalOwnerName) -Bytes ([byte[]]@())
    Write-HerdrDurableBytes -Path (Join-Path $transactionPath $script:AgentSkillPhaseStaged) -Bytes ([byte[]]@())
    $markerNew = Join-Path $transactionPath $script:AgentSkillTransactionMarkerNewName
    Write-HerdrDurableText -Path $markerNew -Text (
        Get-HerdrAgentSkillTransactionMarkerText `
            -InstallRoot $InstallRoot `
            -DisplayVersion $DisplayVersion `
            -SkillSha256 $ExpectedSha256 `
            -HadPrevious $true
    )
    [IO.File]::Move($markerNew, (Join-Path $transactionPath $script:AgentSkillTransactionMarkerName))
    $transaction = Assert-HerdrAgentSkillTransaction `
        -Path $transactionPath `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Removal") {
        throw "Herdr agent skill removal transaction lost its operation owner."
    }
    $publishing = Join-Path $transactionPath $script:AgentSkillPhasePublishing
    [IO.File]::Move((Join-Path $transactionPath $script:AgentSkillPhaseStaged), $publishing)
    try {
        Move-HerdrAgentSkillPath -Source $target -Destination (Join-Path $transactionPath "previous")
    } catch {
        $moveError = $_.Exception
        Undo-HerdrAgentSkillRemovalTransaction `
            -Path $transactionPath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
        throw $moveError
    }
    return $transactionPath
}

function Publish-HerdrAgentSkillRemovalCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $transaction = Assert-HerdrAgentSkillTransaction `
        -Path $TransactionPath `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Removal" -or
        $transaction.Phase -cne $script:AgentSkillPhasePublishing -or
        -not $transaction.HadPrevious -or
        $transaction.SkillSha256 -cne $ExpectedSha256) {
        throw "Herdr agent skill removal transaction identity changed before candidate publication."
    }
    $previous = Join-Path $transaction.Path "previous"
    $entries = @(Get-ChildItem -LiteralPath $previous -Force)
    if ($entries.Count -ne 1 -or $entries[0].Name -cne "SKILL.md" -or
        $entries[0].PSIsContainer -or ($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Undo-HerdrAgentSkillRemovalTransaction `
            -Path $transaction.Path `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
        return $null
    }
    $candidate = Join-Path $transaction.Path $script:AgentSkillRemovalCandidateName
    $pinned = $null
    try {
        $pinned = [Herdr.Installer.PinnedSkillFile]::Open($entries[0].FullName)
        if ($pinned.Sha256Hex -cne $ExpectedSha256) {
            $pinned.Dispose()
            $pinned = $null
            Undo-HerdrAgentSkillRemovalTransaction `
                -Path $transaction.Path `
                -AgentSkillsRoot $AgentSkillsRoot `
                -InstallRoot $InstallRoot
            return $null
        }
        $pinned.MoveTo($candidate)
        $result = [PSCustomObject]@{
            TransactionPath = $transaction.Path
            Pinned = $pinned
        }
        $pinned = $null
        return $result
    } catch {
        if ($null -ne $pinned) {
            $pinned.Dispose()
            $pinned = $null
        }
        Undo-HerdrAgentSkillRemovalTransaction `
            -Path $transaction.Path `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot
        throw
    }
}

function Commit-HerdrAgentSkillRemovalCandidate {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $transaction = Assert-HerdrAgentSkillTransaction `
        -Path $Candidate.TransactionPath `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    if ($transaction.Operation -cne "Removal" -or
        $transaction.Phase -cne $script:AgentSkillPhasePublishing -or
        -not $transaction.HadPrevious -or
        $transaction.SkillSha256 -cne $ExpectedSha256) {
        throw "Herdr agent skill removal transaction identity changed before candidate commit."
    }
    $previous = Join-Path $transaction.Path "previous"
    $pinned = $Candidate.Pinned
    if ($null -eq $pinned -or $pinned.Sha256Hex -cne $ExpectedSha256) {
        throw "Pinned Herdr agent skill removal candidate identity changed before commit."
    }
    try {
        try {
            [IO.Directory]::Delete($previous)
        } catch {
            $pinned.Dispose()
            $pinned = $null
            Move-HerdrAgentSkillRemovalCandidateBack -Transaction $transaction
            Undo-HerdrAgentSkillRemovalTransaction `
                -Path $transaction.Path `
                -AgentSkillsRoot $AgentSkillsRoot `
                -InstallRoot $InstallRoot
            return $false
        }
        $completing = Join-Path $transaction.Path $script:AgentSkillPhaseCompleting
        [IO.File]::Move((Join-Path $transaction.Path $script:AgentSkillPhasePublishing), $completing)
        $pinned.DeleteByHandle()
        $pinned = $null
    } finally {
        if ($null -ne $pinned) {
            $pinned.Dispose()
        }
    }
    $completed = Assert-HerdrAgentSkillTransaction `
        -Path $transaction.Path `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    Remove-HerdrAgentSkillRemovalTransactionOwner `
        -Transaction $completed `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot
    return $true
}

function Complete-HerdrInstalledAgentSkillRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $candidate = Publish-HerdrAgentSkillRemovalCandidate `
        -TransactionPath $TransactionPath `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot `
        -ExpectedSha256 $ExpectedSha256
    if ($null -eq $candidate) {
        return $false
    }
    return Commit-HerdrAgentSkillRemovalCandidate `
        -Candidate $candidate `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot `
        -ExpectedSha256 $ExpectedSha256
}

function Remove-HerdrInstalledAgentSkill {
    param(
        [Parameter(Mandatory = $true)][string]$AgentSkillsRoot,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if ($ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid owned Herdr agent skill hash."
    }
    if (-not (Test-Path -LiteralPath $AgentSkillsRoot -PathType Container)) {
        return
    }
    $AgentSkillsRoot = Get-HerdrFullPath -Path $AgentSkillsRoot
    $parent = Split-Path -Parent $AgentSkillsRoot
    $grandparent = Split-Path -Parent $parent
    foreach ($component in @($grandparent, $parent, $AgentSkillsRoot)) {
        if (Test-HerdrReparsePoint -Path $component) {
            return
        }
        Assert-HerdrRegularDirectory -Path $component
    }
    $target = Join-Path $AgentSkillsRoot "herdr"
    if (-not (Test-Path -LiteralPath $target -PathType Container) -or (Test-HerdrReparsePoint -Path $target)) {
        return
    }
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return
            }
            if ($entry.PSIsContainer) {
                $pending.Push($entry.FullName)
            }
        }
    }
    $transactionPath = Start-HerdrInstalledAgentSkillRemoval `
        -AgentSkillsRoot $AgentSkillsRoot `
        -InstallRoot $InstallRoot `
        -DisplayVersion $DisplayVersion `
        -ExpectedSha256 $ExpectedSha256
    if ($null -ne $transactionPath) {
        [void](Complete-HerdrInstalledAgentSkillRemoval `
            -TransactionPath $transactionPath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot `
            -ExpectedSha256 $ExpectedSha256)
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
        [Parameter(Mandatory = $true)][string]$SkillSha256,
        [Parameter(Mandatory = $true)][string]$DisplayVersion,
        [Parameter(Mandatory = $true)][string]$NumericVersion
    )

    if ($SkillSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid Herdr agent skill SHA-256 for the install manifest."
    }
    return "$script:InstallManifestHeader`nbootstrap_sha256=$(Get-HerdrSha256 -Path $BootstrapPath)`nskill_sha256=$SkillSha256`ndisplay_version=$DisplayVersion`nnumeric_version=$NumericVersion`n"
}

function Read-HerdrInstallManifestFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $path = $Path
    $text = Read-HerdrStrictUtf8 -Path $path
    $match = [regex]::Match(
        $text,
        '\Aherdr-install-manifest-v2\nbootstrap_sha256=([0-9a-f]{64})\nskill_sha256=([0-9a-f]{64})\ndisplay_version=([0-9A-Za-z._+\-]+)\nnumeric_version=([0-9]{1,5}(?:\.[0-9]{1,5}){3})\n\z'
    )
    $skillSha256 = $null
    if ($match.Success) {
        $bootstrapSha256 = $match.Groups[1].Value
        $skillSha256 = $match.Groups[2].Value
        $manifestDisplayVersion = $match.Groups[3].Value
        $manifestNumericVersion = $match.Groups[4].Value
    } else {
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
    }
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
        SkillSha256 = $skillSha256
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
        [Parameter(Mandatory = $true)][string]$SkillSha256,
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
            -SkillSha256 $SkillSha256 `
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
        [Parameter(Mandatory = $true)][string]$SkillSha256,
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
                    -SkillSha256 $SkillSha256 `
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
    $AgentSkillsRoot = Initialize-HerdrAgentSkillsRoot -AgentSkillsRoot $AgentSkillsRoot
    $skillLock = Open-HerdrShareModeLock `
        -Path (Get-HerdrAgentSkillLockPath -AgentSkillsRoot $AgentSkillsRoot) `
        -TimeoutMilliseconds $LockTimeoutMilliseconds
    $skillTransaction = $null
    try {
        Restore-HerdrAgentSkillTransactions -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
        $skillTransaction = New-HerdrAgentSkillTransaction `
            -SourcePath $SkillSourcePath `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot `
            -DisplayVersion $DisplayVersion
        $skillSha256 = $skillTransaction.SkillSha256
        Publish-HerdrAgentSkillTransaction `
            -Transaction $skillTransaction `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot

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
                -SkillSha256 $skillSha256 `
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
                    -SkillSha256 $skillSha256 `
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
        Complete-HerdrAgentSkillTransaction `
            -Path $skillTransaction.Path `
            -AgentSkillsRoot $AgentSkillsRoot `
            -InstallRoot $InstallRoot `
            -RequireExactTarget
        return $result
    } catch {
        if ($null -ne $skillTransaction -and (Test-Path -LiteralPath $skillTransaction.Path)) {
            Restore-HerdrAgentSkillTransactions -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
        }
        throw
    } finally {
        $skillLock.Dispose()
    }
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
        $result = Install-HerdrLayout `
            -InstallRoot $InstallRoot `
            -StageDir $StageDir `
            -LauncherPath $LauncherPath `
            -UninstallerPath $UninstallerPath `
            -HelperSourcePath $HelperSourcePath `
            -SkillSourcePath $SkillSourcePath `
            -AgentSkillsRoot (Get-HerdrAgentSkillsRoot) `
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
        [int]$LockTimeoutMilliseconds = 30000,
        [scriptblock]$ProcessProvider = { Get-HerdrProcessSnapshot }
    )

    $InstallRoot = Get-HerdrFullPath -Path $InstallRoot
    $skillLock = $null
    if (Test-Path -LiteralPath $AgentSkillsRoot -PathType Container) {
        $AgentSkillsRoot = Initialize-HerdrAgentSkillsRoot -AgentSkillsRoot $AgentSkillsRoot
        $skillLock = Open-HerdrShareModeLock `
            -Path (Get-HerdrAgentSkillLockPath -AgentSkillsRoot $AgentSkillsRoot) `
            -TimeoutMilliseconds $LockTimeoutMilliseconds
    }
    try {
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

            if ($null -ne $skillLock) {
                Restore-HerdrAgentSkillTransactions -AgentSkillsRoot $AgentSkillsRoot -InstallRoot $InstallRoot
            }
            $installManifestPath = Join-Path $stateDir "install.manifest"
            if ($null -ne $skillLock -and (Test-Path -LiteralPath $installManifestPath)) {
                $installManifest = Read-HerdrInstallManifestFile -Path $installManifestPath
                if ($null -ne $installManifest.SkillSha256) {
                    Remove-HerdrInstalledAgentSkill `
                        -AgentSkillsRoot $AgentSkillsRoot `
                        -InstallRoot $InstallRoot `
                        -DisplayVersion $installManifest.DisplayVersion `
                        -ExpectedSha256 $installManifest.SkillSha256
                }
            }

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
    } finally {
        if ($null -ne $skillLock) {
            $skillLock.Dispose()
        }
    }
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
        Invoke-HerdrUninstallLayout -InstallRoot $InstallRoot -AgentSkillsRoot (Get-HerdrAgentSkillsRoot)
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
