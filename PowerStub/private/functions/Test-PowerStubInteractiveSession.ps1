<#
.SYNOPSIS
  Tests whether a person is likely to see messages from this session.

.DESCRIPTION
  The update check only helps someone who can act on it. CI jobs, services and processes
  started with -NonInteractive neither fetch nor show the message.

.OUTPUTS
  Boolean.
#>

function Test-PowerStubInteractiveSession {
    [CmdletBinding()]
    param()

    if (-not [Environment]::UserInteractive) { return $false }
    # GitLab, GitHub and most CI systems set CI; Azure Pipelines sets TF_BUILD.
    if ($env:CI -or $env:TF_BUILD) { return $false }
    # pwsh accepts any unambiguous prefix of -NonInteractive, down to -noni.
    foreach ($argument in [Environment]::GetCommandLineArgs()) {
        if ($argument -match '^-{1,2}noni') { return $false }
    }
    return $true
}
