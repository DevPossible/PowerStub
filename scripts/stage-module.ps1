<#
.SYNOPSIS
    Creates a clean, version-stamped PowerStub package directory without publishing.
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)]
    [string]$DestinationPath,
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$source = Join-Path $RepositoryRoot 'PowerStub'
if ((Split-Path $DestinationPath -Leaf) -ne 'PowerStub') {
    throw 'The staging directory must be named PowerStub.'
}
if (Test-Path -LiteralPath $DestinationPath) {
    if (@(Get-ChildItem -LiteralPath $DestinationPath -Force).Count -gt 0) {
        throw 'The staging directory must be empty, to prevent stale files shipping.'
    }
}
foreach ($required in @('PowerStub/PowerStub.psd1', 'LICENSE.txt', 'README.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $required) -PathType Leaf)) {
        throw "Missing package input: $required"
    }
}
New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
Get-ChildItem -LiteralPath $source -Force |
    Where-Object { $_.Name -notlike '*.pssproj' -and $_.Name -notin @('.gitignore', 'PowerStub.json') } |
    Copy-Item -Destination $DestinationPath -Recurse -Force
foreach ($file in @('LICENSE.txt', 'README.md')) {
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $file) -Destination $DestinationPath
}
$manifestPath = Join-Path $DestinationPath 'PowerStub.psd1'
Update-ModuleManifest -Path $manifestPath -ModuleVersion $Version `
    -LicenseUri "https://github.com/DevPossible/power-stub/blob/v$Version/LICENSE.txt"
$manifest = Test-ModuleManifest -Path $manifestPath
if ($manifest.Version.ToString() -ne $Version) { throw 'Staged module version does not match the release.' }
Write-Host "Staged PowerStub $Version at $DestinationPath"
