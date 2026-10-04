<#
.SYNOPSIS
  Finds an existing command that a case-insensitive PowerShell alias would shadow.
#>
function Get-PowerStubAliasConflict {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # This discovery API searches the live namespace without auto-importing modules.
    # Get-Command (even -ListImported) can otherwise auto-import an installed older
    # PowerStub while the current module is still initializing its own main alias.
    $command = $ExecutionContext.InvokeCommand.GetCommands(
        $Name, [System.Management.Automation.CommandTypes]::All, $false) |
        Select-Object -First 1
    if ($command) { return $command }

    # On Unix native lookup is case-sensitive, but function and alias names are not.
    # For example a new PWSH function would still hide the existing pwsh executable.
    $nativeTypes = [System.Management.Automation.CommandTypes]::Application -bor
        [System.Management.Automation.CommandTypes]::ExternalScript
    $ExecutionContext.InvokeCommand.GetCommands('*', $nativeTypes, $true) |
        Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
}
