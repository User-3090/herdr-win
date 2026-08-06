[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("CompleteMaintenance")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot,

    [uint32]$ParentProcessId = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $helper = Join-Path $PSScriptRoot "installer-helper.exe"
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "The native Herdr installer helper is missing: $helper"
    }
    & $helper complete-maintenance `
        --install-root $InstallRoot `
        --parent-process-id ([string]$ParentProcessId)
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("Herdr Win maintenance bridge error: $($_.Exception.Message)")
    exit 1
}
