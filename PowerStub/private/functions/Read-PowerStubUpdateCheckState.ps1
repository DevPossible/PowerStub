<#
.SYNOPSIS
  Reads the last update check result for a stub.

.PARAMETER File
  The state file, from Get-PowerStubUpdateCheckFile.

.OUTPUTS
  PSCustomObject with Path, LastCheckUtc (UTC DateTime), Status, RepoRoot and BehindCount,
  or $null when there is no usable result. A missing or unreadable file just means the
  stub is due for a check.
#>

function Read-PowerStubUpdateCheckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$File
    )

    if (-not [IO.File]::Exists($File)) { return $null }
    try {
        $state = [IO.File]::ReadAllText($File) | ConvertFrom-Json -ErrorAction Stop
        # ConvertFrom-Json may already have turned the timestamp into a date.
        $lastCheck = $state.LastCheckUtc
        $lastCheckUtc = if ($lastCheck -is [datetimeoffset]) {
            $lastCheck.UtcDateTime
        }
        elseif ($lastCheck -is [datetime]) {
            $lastCheck.ToUniversalTime()
        }
        else {
            [datetime]::Parse([string]$lastCheck, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        }
        $behindCount = $null
        if ($null -ne $state.BehindCount) { $behindCount = [int]$state.BehindCount }

        return [PSCustomObject]@{
            Path         = $state.Path
            LastCheckUtc = $lastCheckUtc
            Status       = $state.Status
            RepoRoot     = $state.RepoRoot
            BehindCount  = $behindCount
        }
    }
    catch {
        Write-Debug "Ignoring unreadable update check state '$File': $_"
        return $null
    }
}
