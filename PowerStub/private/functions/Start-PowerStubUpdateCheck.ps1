<#
.SYNOPSIS
  Starts a background check of whether a stub's repository is behind its remote, or of
  whether a newer PowerStub release exists.

.DESCRIPTION
  Runs a script from private/scripts (-ScriptName) in a hidden, detached pwsh process
  and returns immediately. A separate process (not a job) is used because pstb often runs in
  short-lived processes, which would take a job down with them.

  Only one check per stub runs at a time: a claim file is created with CreateNew, which
  succeeds in exactly one process. A claim older than 30 minutes belongs to a check that
  died, and is taken over.

  If the process cannot be started, a CheckFailed result is recorded so the next command
  waits for the normal interval instead of trying again straight away.

.PARAMETER StubPath
  The stub folder to check (the module folder for the release check).

.PARAMETER StateFile
  Where the background check records its result.

.PARAMETER ScriptName
  The background script in private/scripts: Update-PowerStubRemoteStatus.ps1 (a stub's
  repository, the default) or Update-PowerStubReleaseStatus.ps1 (PowerStub releases).
#>

function Start-PowerStubUpdateCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StubPath,

        [Parameter(Mandatory = $true)]
        [string]$StateFile,

        [ValidateSet('Update-PowerStubRemoteStatus.ps1', 'Update-PowerStubReleaseStatus.ps1')]
        [string]$ScriptName = 'Update-PowerStubRemoteStatus.ps1'
    )

    $lockFile = "$StateFile.lock"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $StateFile)) | Out-Null
    try {
        [IO.File]::Open($lockFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None).Dispose()
    }
    catch {
        if (-not [IO.File]::Exists($lockFile)) { throw }
        $claimAge = [datetime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($lockFile)
        if ($claimAge.TotalMinutes -lt 30) { return }
        [IO.File]::SetLastWriteTimeUtc($lockFile, [datetime]::UtcNow)
    }

    try {
        $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $script = Join-Path $Script:ModulePath "private/scripts/$ScriptName"
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script,
            '-Path', $StubPath, '-StateFile', $StateFile)

        # On Linux and macOS, setsid detaches the check from the terminal, so closing the
        # terminal does not kill it and ssh cannot prompt on it for a passphrase.
        $setsid = if (-not $IsWindows) { Get-Command setsid -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
        $startInfo = if ($setsid) {
            $arguments = @($pwsh) + $arguments
            [Diagnostics.ProcessStartInfo]::new($setsid.Source)
        }
        else {
            [Diagnostics.ProcessStartInfo]::new($pwsh)
        }
        foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        # Keep the check off the user's console entirely.
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        # Git and Git Credential Manager prompts are disabled by Get-PowerStubGitInfo; this stops ssh's GUI askpass.
        $startInfo.Environment['SSH_ASKPASS_REQUIRE'] = 'never'

        $process = [Diagnostics.Process]::Start($startInfo)
        $process.StandardInput.Close()
        $process.Dispose()
    }
    catch {
        Write-Debug "Could not start the update check for '$StubPath': $_"
        Write-PowerStubUpdateCheckState -File $StateFile -Path $StubPath -Status 'CheckFailed'
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
}
