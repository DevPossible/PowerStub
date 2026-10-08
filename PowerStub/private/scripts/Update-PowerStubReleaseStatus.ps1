#Requires -Version 7.0
<#
.SYNOPSIS
  Background half of the release check: asks the PowerShell Gallery for the latest PowerStub
  release and records it.

.DESCRIPTION
  Start-PowerStubUpdateCheck runs this in a hidden, detached pwsh process, so the request
  never delays the command the user ran. It loads only the function it needs (not the
  module) and writes nothing to the console. Prereleases are ignored.
  The claim file (<StateFile>.lock) is always removed, so the next check can run later.

.PARAMETER Path
  The installed module folder, recorded with the result.

.PARAMETER StateFile
  Where to record the result (see Invoke-PowerStubReleaseCheck).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$StateFile
)

& {
    try {
        . (Join-Path $PSScriptRoot '../functions/Write-PowerStubUpdateCheckState.ps1')

        $uri = "https://www.powershellgallery.com/api/v2/FindPackagesById()?id='PowerStub'&`$filter=IsLatestVersion"
        $entry = @(Invoke-RestMethod -Uri $uri -TimeoutSec 30 -ErrorAction Stop)[0]
        $latest = [version]$entry.properties.Version
        Write-PowerStubUpdateCheckState -File $StateFile -Path $Path -Status 'Ready' -LatestVersion $latest.ToString()
    }
    catch {
        try { Write-PowerStubUpdateCheckState -File $StateFile -Path $Path -Status 'CheckFailed' } catch { }
    }
    finally {
        Remove-Item -LiteralPath "$StateFile.lock" -Force -ErrorAction SilentlyContinue
    }
} *> $null
