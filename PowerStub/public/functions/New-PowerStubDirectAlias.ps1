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
    $existingCmd = Get-Command $AliasName -ErrorAction SilentlyContinue
    if ($existingCmd -and -not $Force) {
        throw "A command named '$AliasName' already exists. Use -Force to overwrite."
    }

    # Create the function in global scope using ScriptBlock instead of Invoke-Expression
    # Escape single quotes in stub name to prevent code injection
    $escapedStub = $Stub -replace "'", "''"

    $functionBody = @"
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = `$false, Position = 0)]
        [string]`$Command,

        [Parameter(DontShow = `$true, ValueFromRemainingArguments = `$true)]
        [object[]]`$RemainingArgs
    )

    DynamicParam {
        `$stubName = '$escapedStub'
        `$commandValue = `$PSBoundParameters['Command']

        if (`$commandValue -and (Get-Module PowerStub)) {
            `$module = Get-Module PowerStub
            `$RuntimeParamDic = & `$module { param(`$s, `$c) Get-PowerStubCommandDynamicParams `$s `$c } `$stubName `$commandValue
            return `$RuntimeParamDic
        }

        return New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
    }

    end {
        `$stubName = '$escapedStub'

        if (-not `$Command) {
            # List commands
            `$module = Get-Module PowerStub
            & `$module { param(`$s) Find-PowerStubCommands `$s } `$stubName
            return
        }

        # Get the command object
        `$commandObj = Get-PowerStubCommand `$stubName `$Command
        if (-not `$commandObj) {
            throw "Command '`$stubName : `$Command' not found!"
        }

        `$cmd = `$commandObj.Path
        `$module = Get-Module PowerStub

        # Collect dynamic parameters (bound params that aren't our static or common params)
        `$forwardParams = @{}
        `$skipParams = @('Command', 'RemainingArgs')
        `$commonParamsList = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
            'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer',
            'PipelineVariable', 'ProgressAction', 'WhatIf', 'Confirm')
        foreach (`$key in `$PSBoundParameters.Keys) {
            if (`$key -notin `$skipParams -and `$key -notin `$commonParamsList) {
                `$forwardParams[`$key] = `$PSBoundParameters[`$key]
            }
        }

        Write-Host "Invoking `$cmd"
        & `$module { param(`$c, `$n, `$p) Invoke-CheckedCommandWithParams -command `$c -namedParams `$n -positionalArgs `$p } `$cmd `$forwardParams `$RemainingArgs
    }
"@

    # Create the function via ScriptBlock instead of Invoke-Expression
    $scriptBlock = [scriptblock]::Create($functionBody)
    Set-Item -Path "function:global:$AliasName" -Value $scriptBlock

    # Remember which global functions are ours so module removal only cleans up those
    if ($Script:RegisteredDirectAliases -notcontains $AliasName) {
        $Script:RegisteredDirectAliases += $AliasName
    }

    # Register ArgumentCompleter for -Command parameter
    # Note: Must call Find-PowerStubCommands through the module since it's a private function
    $commandCompleter = {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        $module = Get-Module PowerStub
        if (-not $module) { return @() }

        $commands = @(& $module { param($s) Find-PowerStubCommands $s } $Stub)
        if (-not $commands) { return @() }

        $commandNames = @($commands | ForEach-Object {
            $name = $_.BaseName
            if ($name -match '^(alpha|beta)\.(.+)$') {
                $Matches[2]
            } else {
                $name
            }
        } | Select-Object -Unique)

        if (-not $wordToComplete) { return $commandNames }

        $commandNames | Where-Object { $_ -like "$wordToComplete*" }
    }.GetNewClosure()

    Register-ArgumentCompleter -CommandName $AliasName -ParameterName Command -ScriptBlock $commandCompleter

    # Store in config for re-registration on module load
    $directAliases = Get-PowerStubConfigurationKey 'DirectAliases'
    if (-not $directAliases -or $directAliases[$AliasName] -ne $Stub) {
        # Add only this alias so other sessions' aliases are kept
        Update-PowerStubConfiguration {
            if (-not $Script:PSTBSettings['DirectAliases']) {
                $Script:PSTBSettings['DirectAliases'] = @{}
            }
            $Script:PSTBSettings['DirectAliases'][$AliasName] = $Stub
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
