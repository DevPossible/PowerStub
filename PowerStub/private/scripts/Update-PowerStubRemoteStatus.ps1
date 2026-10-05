#Requires -Version 7.0
<#
.SYNOPSIS
  Background half of the update check: fetches a stub's repository and records the result.

.DESCRIPTION
  Start-PowerStubUpdateCheck runs this in a hidden, detached pwsh process, so the fetch
  never delays the command the user ran. It loads only the two functions it needs (not the
  module), never prompts for credentials, and writes nothing to the console.
  The claim file (<StateFile>.lock) is always removed, so the next check can run later.

.PARAMETER Path
  The stub folder to check.

.PARAMETER StateFile
  Where to record the result (see Get-PowerStubUpdateCheckFile).
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$StateFile
)

& {
    try {
        . (Join-Path $PSScriptRoot '../functions/Get-PowerStubGitInfo.ps1')
        . (Join-Path $PSScriptRoot '../functions/Write-PowerStubUpdateCheckState.ps1')
        # Get-PowerStubGitInfo checks this module flag; this process was only started when Git is available.
        $Script:GitAvailable = $true

        $gitInfo = Get-PowerStubGitInfo -Path $Path -Fetch
        Write-PowerStubUpdateCheckState -File $StateFile -Path $Path -Status $gitInfo.Status `
            -RepoRoot $gitInfo.RepoRoot -BehindCount $gitInfo.BehindCount
    }
    catch {
        try { Write-PowerStubUpdateCheckState -File $StateFile -Path $Path -Status 'CheckFailed' } catch { }
    }
    finally {
        Remove-Item -LiteralPath "$StateFile.lock" -Force -ErrorAction SilentlyContinue
    }
} *> $null
