<#
.SYNOPSIS
  Records the result of an update check for a stub.

.DESCRIPTION
  Writes a temporary file and moves it over the state file in one step, so a reader
  never sees a half-written result. Used by the background check script as well as the
  module, so it must not depend on module state.

.PARAMETER File
  The state file, from Get-PowerStubUpdateCheckFile.

.PARAMETER Path
  The stub folder that was checked.

.PARAMETER Status
  The Get-PowerStubGitInfo status (Ready, NotRepository, FetchFailed, ...) or CheckFailed.

.PARAMETER RepoRoot
  The repository root, when the stub is in a Git repository.

.PARAMETER BehindCount
  Commits on the tracking branch that are not local, when known.
#>

function Write-PowerStubUpdateCheckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [string]$RepoRoot,

        [Nullable[int]]$BehindCount
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $File)) | Out-Null
    $json = [ordered]@{
        Path         = $Path
        LastCheckUtc = [datetime]::UtcNow.ToString('o', [cultureinfo]::InvariantCulture)
        Status       = $Status
        RepoRoot     = if ($RepoRoot) { $RepoRoot } else { $null }
        BehindCount  = $BehindCount
    } | ConvertTo-Json

    $tempFile = "$File.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempFile, $json)
        [IO.File]::Move($tempFile, $File, $true)
    }
    finally {
        if ([IO.File]::Exists($tempFile)) { [IO.File]::Delete($tempFile) }
    }
}
