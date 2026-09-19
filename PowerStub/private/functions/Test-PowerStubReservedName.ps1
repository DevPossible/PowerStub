<#
.SYNOPSIS
  Tests whether a name must not be used for a PowerStub alias.

.DESCRIPTION
  Aliases become global commands, so a name matching a critical system command
  would silently shadow it in every session that loads the module.

.PARAMETER Name
  The alias name to test.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
System.Boolean. True when the name is reserved.
#>


function Test-PowerStubReservedName {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string] $Name
    )

    $reservedNames = @('cd', 'ls', 'dir', 'where', 'git', 'python', 'node', 'npm', 'set', 'del', 'rm', 'cp', 'mv', 'cat', 'echo', 'type', 'cls', 'clear', 'exit', 'push', 'pop')
    return $reservedNames -contains $Name.ToLower()
}
