<#
.SYNOPSIS
  Tells the user when a stub's Git repository is behind its remote.

.DESCRIPTION
  Called each time a stub command runs, so it must stay cheap: it reads one small state
  file and never runs Git itself. When the last result is older than UpdateCheckIntervalHours
  (default 4), a new check is started in the background (Start-PowerStubUpdateCheck); its
  result is shown by the first command that runs after it finishes.

  It does nothing when Git is not installed or is disabled, when UpdateCheckIntervalHours is
  0, when POWERSTUB_NO_UPDATE_CHECK is set, or when nobody is watching (CI, -NonInteractive).
  A stub outside a Git repository records that, and costs one background check per interval.
  Each stub is checked on its own, so stubs with and without repositories can be mixed.

  The message is shown once per repository per session, with Write-Host so it never mixes
  with the command's output and is not affected by $WarningPreference.

.PARAMETER Stub
  The stub name, used in the message.

.PARAMETER StubPath
  The stub's root folder.
#>

function Invoke-PowerStubUpdateCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stub,

        [Parameter(Mandatory = $true)]
        [string]$StubPath
    )

    if (-not $Script:GitAvailable -or -not $Script:GitEnabled) { return }
    if ($env:POWERSTUB_NO_UPDATE_CHECK -and $env:POWERSTUB_NO_UPDATE_CHECK -notin @('0', 'false')) { return }
    $intervalHours = 0.0
    $configured = Get-PowerStubConfigurationKey 'UpdateCheckIntervalHours'
    if (-not [double]::TryParse("$configured", [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$intervalHours) -or
        $intervalHours -le 0) {
        return
    }
    if (-not (Test-PowerStubInteractiveSession)) { return }

    $stateFile = Get-PowerStubUpdateCheckFile -StubPath $StubPath
    $state = Read-PowerStubUpdateCheckState -File $stateFile

    if ($state -and $state.BehindCount -gt 0) {
        $noticeKey = if ($state.RepoRoot) { $state.RepoRoot } else { $StubPath }
        if (-not $Script:UpdateNoticesShown.ContainsKey($noticeKey)) {
            $Script:UpdateNoticesShown[$noticeKey] = $true
            $entry = if ($Script:InvokeAlias) { $Script:InvokeAlias } else { 'Invoke-PowerStubCommand' }
            Write-Host "You do not have the latest version of '$Stub' ($($state.BehindCount) commit(s) behind). Run '$entry update $Stub' to get the latest version." -ForegroundColor Yellow
        }
    }

    if (-not $state -or $state.LastCheckUtc -lt [datetime]::UtcNow.AddHours(-$intervalHours)) {
        Start-PowerStubUpdateCheck -StubPath $StubPath -StateFile $stateFile
    }
}
