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
    # Include contextual keywords and future-reserved words, which Get-Command does
    # not report as commands. Keep older PowerShell hosts from persisting aliases that
    # become parser keywords after an upgrade (for example clean, added in 7.3).
    $keywords = @(
        'begin', 'break', 'catch', 'class', 'clean', 'continue', 'data', 'define', 'do',
        'dynamicparam', 'else', 'elseif', 'end', 'enum', 'exit', 'filter', 'finally',
        'for', 'foreach', 'from', 'function', 'hidden', 'if', 'in', 'param', 'process',
        'return', 'static', 'switch', 'throw', 'trap', 'try', 'until', 'using', 'var',
        'while', 'inlinescript', 'parallel', 'sequence', 'workflow', 'configuration',
        'default', 'base'
    )
    return $reservedNames -contains $Name -or $keywords -contains $Name
}
