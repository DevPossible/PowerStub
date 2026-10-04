<#
.SYNOPSIS
  Gets Git repository information for a given path.

.DESCRIPTION
  Checks if a path is part of a Git repository and returns repository details
  including the remote URL and status information. Uses git -C to avoid
  changing the current working directory.

.PARAMETER Path
  The path to check for Git repository information.

.PARAMETER Fetch
  If specified, fetches the tracking remote before calculating ahead/behind
  counts. A failed fetch makes the status unavailable, rather than using stale counts.

.OUTPUTS
  PSCustomObject with properties:
  - IsRepo: Boolean indicating if path is in a git repo
  - RepoRoot: The root path of the repository
  - RemoteUrl: The tracking remote URL, or origin URL when no upstream is configured
  - CurrentBranch: The current branch name
  - TrackingBranch: The upstream branch (if any)
  - BehindCount / AheadCount: Commit counts, or null when status is unavailable
  - Status: Ready, NotRepository, NoRemote, NoUpstream, FetchFailed or StatusFailed
  - StatusMessage: Explanation when status is unavailable

.EXAMPLE
  Get-PowerStubGitInfo -Path "C:\MyRepo"
#>

function Get-PowerStubGitInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter()]
        [switch]$Fetch
    )

    $result = [PSCustomObject]@{
        IsRepo         = $false
        RepoRoot       = $null
        RemoteUrl      = $null
        CurrentBranch  = $null
        TrackingBranch = $null
        BehindCount    = $null
        AheadCount     = $null
        Status         = 'NotRepository'
        StatusMessage  = 'Path is not a Git repository'
    }

    if (-not $Script:GitAvailable -or -not (Test-Path -LiteralPath $Path)) {
        return $result
    }

    # Handle expected native failures ourselves, regardless of the caller's preference.
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $repoRoot = git -C $Path rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
            return $result
        }
        $result.IsRepo = $true
        $result.RepoRoot = $repoRoot
        $result.Status = 'StatusFailed'
        $result.StatusMessage = 'Unable to determine repository status'

        $currentBranch = git -C $Path rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $currentBranch) { return $result }
        $result.CurrentBranch = $currentBranch

        $trackingRemote = git -C $Path config --get "branch.$currentBranch.remote" 2>$null
        if ($LASTEXITCODE -gt 1) { return $result }
        $trackingRef = git -C $Path config --get "branch.$currentBranch.merge" 2>$null
        if ($LASTEXITCODE -gt 1) { return $result }
        $remoteName = if ($trackingRemote) { $trackingRemote } else { 'origin' }
        if ($remoteName -eq '.') {
            # Git also allows an upstream in this same repository.
            $result.RemoteUrl = '.'
        }
        else {
            $remoteUrl = git -C $Path config --get "remote.$remoteName.url" 2>$null
            if ($LASTEXITCODE -gt 1) { return $result }
            $result.RemoteUrl = $remoteUrl
        }
        if (-not $result.RemoteUrl) {
            $result.Status = 'NoRemote'
            $result.StatusMessage = "No remote configured for repository ('$remoteName')"
            return $result
        }
        if (-not $trackingRemote -or -not $trackingRef -or $currentBranch -eq 'HEAD') {
            $result.Status = 'NoUpstream'
            $result.StatusMessage = 'No tracking branch configured for the current branch'
            return $result
        }

        if ($Fetch) {
            # A status check must never wait on a credential prompt.
            $savedTerminalPrompt = $env:GIT_TERMINAL_PROMPT
            $savedGcmInteractive = $env:GCM_INTERACTIVE
            $env:GIT_TERMINAL_PROMPT = '0'
            $env:GCM_INTERACTIVE = 'never'
            $fetchSucceeded = $false
            try {
                git -C $Path fetch $remoteName --quiet 2>$null
                $fetchSucceeded = $LASTEXITCODE -eq 0
            }
            catch {
                $fetchSucceeded = $false
            }
            finally {
                $env:GIT_TERMINAL_PROMPT = $savedTerminalPrompt
                $env:GCM_INTERACTIVE = $savedGcmInteractive
            }
            if (-not $fetchSucceeded) {
                $result.Status = 'FetchFailed'
                $result.StatusMessage = 'Fetch failed; remote status could not be checked'
                return $result
            }
        }

        $trackingBranch = git -C $Path rev-parse --abbrev-ref '@{upstream}' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $trackingBranch) { return $result }
        $result.TrackingBranch = $trackingBranch
        $countOutput = git -C $Path rev-list --left-right --count "$trackingBranch...HEAD" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $countOutput) { return $result }
        $counts = "$countOutput".Trim() -split '\s+'
        $behindCount = 0
        $aheadCount = 0
        if ($counts.Count -ne 2 -or
            -not [int]::TryParse($counts[0], [ref]$behindCount) -or $behindCount -lt 0 -or
            -not [int]::TryParse($counts[1], [ref]$aheadCount) -or $aheadCount -lt 0) {
            return $result
        }
        $result.BehindCount = $behindCount
        $result.AheadCount = $aheadCount
        $result.Status = 'Ready'
        $result.StatusMessage = $null
    }
    catch {
        $result.Status = 'StatusFailed'
        $result.StatusMessage = "Unable to determine repository status: $($_.Exception.Message)"
    }
    return $result
}
