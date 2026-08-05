[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Uninstaller,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$temporaryUninstaller = $null
$process = $null
$exitCode = 1
try {
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    if ($InstallRoot.Equals([IO.Path]::GetPathRoot($InstallRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to run quiet uninstall from a volume root."
    }
    $installRootItem = Get-Item -LiteralPath $InstallRoot -Force
    if ($installRootItem -isnot [IO.DirectoryInfo] -or
        ($installRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Quiet uninstall requires a regular non-reparse install root."
    }
    $Uninstaller = [IO.Path]::GetFullPath($Uninstaller)
    $expectedUninstaller = Join-Path $InstallRoot "uninstall.exe"
    if (-not $Uninstaller.Equals($expectedUninstaller, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Quiet uninstall received an unexpected uninstaller path."
    }
    $uninstallerItem = Get-Item -LiteralPath $Uninstaller -Force
    if ($uninstallerItem -isnot [IO.FileInfo] -or
        ($uninstallerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $uninstallerItem.Length -le 0) {
        throw "Quiet uninstall requires a nonempty regular non-reparse uninstaller."
    }

    $temporaryUninstaller = Join-Path ([IO.Path]::GetTempPath()) ("herdr-uninstall-" + [Guid]::NewGuid().ToString("N") + ".exe")
    [IO.File]::Copy($Uninstaller, $temporaryUninstaller, $false)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $temporaryUninstaller
    $startInfo.Arguments = "/S _?=$InstallRoot"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start the copied Herdr uninstaller."
    }
    if (-not $process.WaitForExit(180000)) {
        try {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        } catch {}
        throw "Herdr quiet uninstall exceeded its 180 second deadline."
    }
    $exitCode = $process.ExitCode
} catch {
    [Console]::Error.WriteLine("Herdr quiet uninstall error: $($_.Exception.Message)")
} finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
    if ($null -ne $temporaryUninstaller -and (Test-Path -LiteralPath $temporaryUninstaller)) {
        Remove-Item -LiteralPath $temporaryUninstaller -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
