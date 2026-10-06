<#
.SYNOPSIS
  Removes Start-PowerStubJob and Start-PstbJob, but only if this module created them.

.DESCRIPTION
  Called when the module is removed. A same-named function or alias the user created after
  import is left alone: the function must be the exact script block registered here.
#>

function Unregister-PowerStubJobCommand {
    [CmdletBinding()]
    param()

    $function = Get-Item -LiteralPath 'function:Start-PowerStubJob' -ErrorAction SilentlyContinue
    if ($function -and $Script:JobCommandFunction -and [object]::ReferenceEquals($function.ScriptBlock, $Script:JobCommandFunction)) {
        Remove-Item -LiteralPath 'function:Start-PowerStubJob' -Force
    }
    $Script:JobCommandFunction = $null

    $alias = Get-Alias -Name 'Start-PstbJob' -Scope Global -ErrorAction SilentlyContinue
    if ($Script:JobCommandAlias -and $alias -and $alias.Definition -eq 'Start-PowerStubJob') {
        Remove-Item -LiteralPath 'alias:Start-PstbJob' -Force
    }
    $Script:JobCommandAlias = $false
}
