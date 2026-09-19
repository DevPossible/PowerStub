<#
.SYNOPSIS
  Gets the command names to offer when completing a stub's command.

.DESCRIPTION
  Returns the visible commands of a stub with any alpha./beta. prefix removed, because
  users always type the unprefixed name.

.PARAMETER Stub
  The name of the stub.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
System.String. The command names, without duplicates.
#>


function Get-PowerStubCompletionCommandName {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory)]
        [string] $Stub
    )

    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not $stubs -or -not $stubs.ContainsKey($Stub)) { return }

    @(Find-PowerStubCommands $Stub 3>$null) |
        ForEach-Object { $_.BaseName -replace '^(alpha|beta)\.', '' } |
        Select-Object -Unique
}
