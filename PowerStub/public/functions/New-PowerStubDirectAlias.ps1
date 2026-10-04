<#
.SYNOPSIS
    Creates a direct alias for a PowerStub stub.

.DESCRIPTION
    Creates a PowerShell function that acts as a shortcut for a specific stub.
    Instead of typing 'pstb DevOps <command>', you can use a shorter alias like 'dv <command>'.

    The alias supports full tab completion for both command names and command parameters.

.PARAMETER AliasName
    The name of the alias to create (e.g., 'dv' for DevOps).

.PARAMETER Stub
    The name of the stub to create an alias for.

.PARAMETER Force
    Retained for command-line compatibility. Existing commands or saved aliases are
    always rejected, including when -Force is specified.

.EXAMPLE
    New-PowerStubDirectAlias -AliasName dv -Stub DevOps

    Creates an alias 'dv' for the DevOps stub. Now you can run:
        dv deploy -Environment prod
    Instead of:
        pstb DevOps deploy -Environment prod

.EXAMPLE
    New-PowerStubDirectAlias -AliasName dv2 -Stub DevOps

    Creates a second shortcut with a distinct, unused name.

.OUTPUTS
    PSCustomObject with alias information and usage instructions.
#>

function New-PowerStubDirectAlias {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]*$')]
        [string]$AliasName,

        [Parameter(Mandatory = $true)]
        [string]$Stub,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    if (Test-PowerStubReservedName $AliasName) {
        throw "'$AliasName' is a reserved name and cannot be used as a direct alias."
    }

    Sync-PowerStubConfiguration

    # Verify stub exists
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not ($stubs.Keys -contains $Stub)) {
        throw "Stub '$Stub' not found. Register it first with New-PowerStub."
    }

    # Public add never refreshes, retargets, or replaces a duplicate, including our
    # own persisted proxy. Startup uses the private session-only registration path.
    $directAliases = Get-PowerStubConfigurationKey 'DirectAliases'
    if (($directAliases -and $directAliases.ContainsKey($AliasName)) -or
        (Get-PowerStubAliasConflict $AliasName)) {
        throw "A command or saved direct alias named '$AliasName' already exists. Choose a different alias name."
    }

    Register-PowerStubDirectAlias -AliasName $AliasName -Stub $Stub
    try {
        # Recheck under the lock: another session may have added this name after Sync.
        Update-PowerStubConfiguration {
            if (-not $Script:PSTBSettings['DirectAliases']) {
                $Script:PSTBSettings['DirectAliases'] = @{}
            }
            if ($Script:PSTBSettings['DirectAliases'].ContainsKey($AliasName)) {
                throw "A saved direct alias named '$AliasName' already exists. Choose a different alias name."
            }
            $Script:PSTBSettings['DirectAliases'][$AliasName] = $Stub
        }
    }
    catch {
        # A failed add must not leave an unsaved global function behind.
        Unregister-PowerStubDirectAliasFunction $AliasName
        throw
    }

    # Return info object
    $stubConfig = $stubs[$Stub]
    $stubPath = Get-PowerStubPath -StubConfig $stubConfig
    [PSCustomObject]@{
        AliasName = $AliasName
        Stub      = $Stub
        StubPath  = $stubPath
        Usage     = @"
Alias '$AliasName' created for stub '$Stub'.

Usage:
    $AliasName                         # List available commands
    $AliasName <command>               # Run a command
    $AliasName <command> <Tab>         # Tab complete command names
    $AliasName <command> -<Tab>        # Tab complete command parameters

To make persistent, add to your `$PROFILE:
    Import-Module PowerStub

The alias is automatically recreated when the PowerStub module loads.
"@
    }
}
