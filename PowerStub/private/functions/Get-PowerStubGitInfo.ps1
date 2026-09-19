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
  If specified, fetches from origin to update remote tracking info before
  calculating ahead/behind counts.

.OUTPUTS
  PSCustomObject with properties:
  - IsRepo: Boolean indicating if path is in a git repo
  - RepoRoot: The root path of the repository
  - RemoteUrl: The URL of the origin remote (if any)
  - CurrentBranch: The current branch name
  - BehindCount: Number of commits behind the remote
  - AheadCount: Number of commits ahead of the remote

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

    $emptyResult = [PSCustomObject]@{
        IsRepo        = $false
        RepoRoot      = $null
        RemoteUrl     = $null
        CurrentBranch = $null
        BehindCount   = 0
        AheadCount    = 0
    }

    # Check if git is available
    if (-not $Script:GitAvailable) {
        return $emptyResult
    }

    # Ensure path exists
    if (-not (Test-Path $Path)) {
        return $emptyResult
    }

    # Use git -C to avoid changing the working directory
    $repoRoot = git -C $Path rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
        return $emptyResult
    }

    # Get remote URL (origin)
    $remoteUrl = git -C $Path config --get remote.origin.url 2>$null

    # Get current branch
    $currentBranch = git -C $Path rev-parse --abbrev-ref HEAD 2>$null

    # Fetch to update remote tracking info (silently)
    # Only fetch if explicitly requested and we have a remote
    if ($Fetch -and $remoteUrl) {
        # A status check must never wait on a credential prompt: fail instead of hanging
        $savedTerminalPrompt = $env:GIT_TERMINAL_PROMPT
        $savedGcmInteractive = $env:GCM_INTERACTIVE
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GCM_INTERACTIVE = 'never'
        try {
            git -C $Path fetch origin --quiet 2>$null
        }
        finally {
            $env:GIT_TERMINAL_PROMPT = $savedTerminalPrompt
            $env:GCM_INTERACTIVE = $savedGcmInteractive
        }
    }

    # Get ahead/behind counts
    $behindCount = 0
    $aheadCount = 0
    if ($remoteUrl -and $currentBranch) {
        $trackingBranch = git -C $Path rev-parse --abbrev-ref "@{upstream}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $trackingBranch) {
            $countOutput = git -C $Path rev-list --left-right --count "$trackingBranch...HEAD" 2>$null
            if ($LASTEXITCODE -eq 0 -and $countOutput) {
                $counts = $countOutput -split '\s+'
                if ($counts.Count -ge 2) {
                    $behindCount = [int]$counts[0]
                    $aheadCount = [int]$counts[1]
                }
            }
        }
    }

    return [PSCustomObject]@{
        IsRepo        = $true
        RepoRoot      = $repoRoot
        RemoteUrl     = $remoteUrl
        CurrentBranch = $currentBranch
        BehindCount   = $behindCount
        AheadCount    = $aheadCount
    }
}
