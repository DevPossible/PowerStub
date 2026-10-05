<#
.SYNOPSIS
  Forgets the update check results for a repository.

.DESCRIPTION
  Called after 'pstb update' pulls a repository, so the "not the latest version" message
  stops straight away instead of when the next check runs. Every stub in the repository
  is cleared, not just the one that was updated.

.PARAMETER RepoRoot
  The repository root, as Git reports it.
#>

function Clear-PowerStubUpdateCheckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $folder = Join-Path (Split-Path -Parent (Get-PowerStubConfigurationKey 'ConfigFile')) 'update-check'
    if (-not [IO.Directory]::Exists($folder)) { return }

    foreach ($file in [IO.Directory]::GetFiles($folder, '*.json')) {
        $state = Read-PowerStubUpdateCheckState -File $file
        if ($state -and $state.RepoRoot -eq $RepoRoot) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    if ($Script:UpdateNoticesShown) {
        $Script:UpdateNoticesShown.Remove($RepoRoot)
    }
}
