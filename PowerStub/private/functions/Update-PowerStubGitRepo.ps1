<#
.SYNOPSIS
  Updates a Git repository by pulling latest changes.

.DESCRIPTION
  Performs a git pull on the specified repository path using git -C to
  avoid changing the current working directory.

.PARAMETER Path
  The path to the Git repository to update.

.OUTPUTS
  PSCustomObject with update status information.

.EXAMPLE
  Update-PowerStubGitRepo -Path "C:\MyRepo"
#>

function Update-PowerStubGitRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Check if git is available and enabled
    if (-not $Script:GitAvailable) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Git is not available"
            Path    = $Path
        }
    }

    if (-not $Script:GitEnabled) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Git integration is disabled"
            Path    = $Path
        }
    }

    # Get git info for the path
    $gitInfo = Get-PowerStubGitInfo -Path $Path
    if (-not $gitInfo.IsRepo) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Path is not a Git repository"
            Path    = $Path
        }
    }

    if (-not $gitInfo.RemoteUrl) {
        return [PSCustomObject]@{
            Success = $false
            Message = "No remote configured for repository"
            Path    = $Path
        }
    }

    # Perform git pull using -C to avoid changing directory
    # The output is captured, so a terminal credential prompt would be invisible and hang:
    # make git fail with a clear error instead. Credential manager dialogs still work.
    $savedTerminalPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    try {
        $pullOutput = git -C $gitInfo.RepoRoot pull 2>&1
        $pullSuccess = $LASTEXITCODE -eq 0
    }
    finally {
        $env:GIT_TERMINAL_PROMPT = $savedTerminalPrompt
    }

    return [PSCustomObject]@{
        Success = $pullSuccess
        Message = if ($pullSuccess) { "Repository updated successfully" } else { "Failed to update: $pullOutput" }
        Path    = $gitInfo.RepoRoot
        Output  = $pullOutput
    }
}
