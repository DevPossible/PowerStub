<#
.SYNOPSIS
  Tells the user when a newer PowerStub release is on the PowerShell Gallery.

.DESCRIPTION
  The module's counterpart of Invoke-PowerStubUpdateCheck, called each time a stub command
  runs, so it must stay cheap: it reads one small state file and never contacts the Gallery
  itself. When the last result is older than ReleaseCheckIntervalHours (default 24), a new
  check is started in the background (Start-PowerStubUpdateCheck with
  Update-PowerStubReleaseStatus.ps1); its result is shown by the first command that runs
  after it finishes.

  Only a copy installed from a gallery is checked (it carries PSGetModuleInfo.xml): a
  development checkout's manifest version is a baseline, not a release, and could not be
  updated with Update-Module anyway.

  It does nothing when ReleaseCheckIntervalHours is 0, when POWERSTUB_NO_UPDATE_CHECK is set,
  or when nobody is watching (CI, -NonInteractive). Git is not needed.

  The message is shown once per session, with Write-Host so it never mixes with the
  command's output and is not affected by $WarningPreference.
#>

function Invoke-PowerStubReleaseCheck {
    [CmdletBinding()]
    param()

    if ($env:POWERSTUB_NO_UPDATE_CHECK -and $env:POWERSTUB_NO_UPDATE_CHECK -notin @('0', 'false')) { return }
    $intervalHours = 0.0
    $configured = Get-PowerStubConfigurationKey 'ReleaseCheckIntervalHours'
    if (-not [double]::TryParse("$configured", [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$intervalHours) -or
        $intervalHours -le 0) {
        return
    }
    if (-not [IO.File]::Exists((Join-Path $Script:ModulePath 'PSGetModuleInfo.xml'))) { return }
    if (-not (Test-PowerStubInteractiveSession)) { return }

    $stateFile = Join-Path (Split-Path -Parent (Get-PowerStubConfigurationKey 'ConfigFile')) 'update-check/powerstub-release.json'
    $state = Read-PowerStubUpdateCheckState -File $stateFile

    $installed = $MyInvocation.MyCommand.Module.Version
    $latest = $null
    if ($state -and [version]::TryParse("$($state.LatestVersion)", [ref]$latest) -and $latest -gt $installed) {
        if (-not $Script:UpdateNoticesShown.ContainsKey('PowerStub release')) {
            $Script:UpdateNoticesShown['PowerStub release'] = $true
            Write-Host "A newer version of PowerStub is available ($latest, you have $installed). Run 'Update-Module PowerStub' to install it." -ForegroundColor Yellow
        }
    }

    if (-not $state -or $state.LastCheckUtc -lt [datetime]::UtcNow.AddHours(-$intervalHours)) {
        Start-PowerStubUpdateCheck -StubPath $Script:ModulePath -StateFile $stateFile -ScriptName 'Update-PowerStubReleaseStatus.ps1'
    }
}
