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
    Overwrites the alias if it already exists.

.EXAMPLE
    New-PowerStubDirectAlias -AliasName dv -Stub DevOps

    Creates an alias 'dv' for the DevOps stub. Now you can run:
        dv deploy -Environment prod
    Instead of:
        pstb DevOps deploy -Environment prod

.EXAMPLE
    New-PowerStubDirectAlias -AliasName dv -Stub DevOps -Force

    Overwrites an existing 'dv' alias.

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

    # Check if function already exists
    $wasOurAlias = $Script:RegisteredDirectAliases -contains $AliasName
    $existingCmd = Get-Command $AliasName -ErrorAction SilentlyContinue
    if ($existingCmd -and -not $Force) {
        throw "A command named '$AliasName' already exists. Use -Force to overwrite."
    }

    # Create the function in global scope using ScriptBlock instead of Invoke-Expression
    # Escape single quotes in stub name to prevent code injection
    $escapedStub = $Stub -replace "'", "''"

    # A simple function with no parameters, for the same reason as Invoke-PowerStubCommand:
    # nothing meant for the target may be bound here. @args forwards every argument untouched.
    $functionBody = @"
    if (`$args.Count -eq 0) {
        # List commands
        & (Get-Module PowerStub) { param(`$s) Find-PowerStubCommands `$s } '$escapedStub'
        return
    }

    # Every simple-function boundary must link the target's failure status to its caller.
    # Preserve @args (including its parameter-name markers) in a local variable because
    # a scriptblock's own `$args would refer to that scriptblock's arguments instead.
    `$targetArgs = `$args
    `$pipeline = { Invoke-PowerStubCommand '$escapedStub' @targetArgs }.GetSteppablePipeline(`$MyInvocation.CommandOrigin)
    try {
        `$pipeline.Begin(`$false, `$ExecutionContext)
        `$pipeline.Process()
        `$pipeline.End()
    }
    finally {
        `$pipeline.Dispose()
    }
"@

    # Create the function via ScriptBlock instead of Invoke-Expression
    $scriptBlock = [scriptblock]::Create($functionBody)
    Set-Item -Path "function:global:$AliasName" -Value $scriptBlock

    # Remember which global functions are ours so module removal only cleans up those
    if ($Script:RegisteredDirectAliases -notcontains $AliasName) {
        $Script:RegisteredDirectAliases += $AliasName
    }

    # Tab completion for the alias comes from the module's TabExpansion2 wrapper,
    # which recognizes every name in $Script:RegisteredDirectAliases.

    # Store in config for re-registration on module load.
    # If -Force was used to take a name that belongs to another command (for example a
    # 'devops.bat' on the PATH), remember that consent: module load re-creates such an alias,
    # but never lets a name that merely appears in the config file shadow a command.
    $shadowsOtherCommand = $Force -and $existingCmd -and -not $wasOurAlias
    $directAliases = Get-PowerStubConfigurationKey 'DirectAliases'
    $forcedAliases = @(Get-PowerStubConfigurationKey 'ForcedDirectAliases')
    $needsSave = -not $directAliases -or $directAliases[$AliasName] -ne $Stub -or
        ($shadowsOtherCommand -and $forcedAliases -notcontains $AliasName)
    if ($needsSave) {
        # Add only this alias so other sessions' aliases are kept
        Update-PowerStubConfiguration {
            if (-not $Script:PSTBSettings['DirectAliases']) {
                $Script:PSTBSettings['DirectAliases'] = @{}
            }
            $Script:PSTBSettings['DirectAliases'][$AliasName] = $Stub

            if ($shadowsOtherCommand) {
                $forced = @($Script:PSTBSettings['ForcedDirectAliases']) | Where-Object { $_ }
                if ($forced -notcontains $AliasName) {
                    $Script:PSTBSettings['ForcedDirectAliases'] = @($forced) + $AliasName
                }
            }
        }
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
