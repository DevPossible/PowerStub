$Script:ModulePath = $PSScriptRoot

Write-Verbose "Initializing PowerStub"

#enable verbose messaging in the psm1 file
if ($MyInvocation.line -match '-verbose') {
    $VerbosePreference = 'continue'
}

#Get all files with functions in them
Write-Verbose 'Finding functions'

$privateFn = Get-ChildItem -Path $PSScriptRoot\private\functions\*.ps1;
$publicFn = Get-ChildItem -Path $PSScriptRoot\public\functions\*.ps1;

#If we are in PowerShell core, load any core specific functions
if ($IsCoreCLR) {
    $pscorePath = Join-Path $PSScriptRoot 'public\functions-pscore'
    if (Test-Path $pscorePath) {
        Write-Verbose 'PowerShell 7 specific commands enabled'
        $publicFn += Get-ChildItem -Path "$pscorePath\*.ps1"
    }
}

# Load all functions using 'dot' import
Write-Verbose 'Dot-sourcing functions'
($publicFn + $privateFn) | ForEach-Object -Process { Write-Verbose $_.FullName; . $_.FullName }

#load the configuration
$Script:PSTBSettings = Get-PowerStubConfigurationDefaults
Import-PowerStubConfiguration

# Check for Git availability and set module-scoped flags
Write-Verbose "Checking Git availability"
$Script:GitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if ($Script:GitAvailable) {
    Write-Verbose "Git is available"
    # GitAvailable is an internal (non-persisted) key: set it in memory only.
    # Module load must never write the config file.
    $Script:PSTBSettings['GitAvailable'] = $true
    # GitEnabled defaults to true if available, but can be overridden by config
    $configEnabled = Get-PowerStubConfigurationKey 'GitEnabled'
    $Script:GitEnabled = if ($null -eq $configEnabled) { $true } else { $configEnabled }
} else {
    Write-Verbose "Git is not available"
    $Script:PSTBSettings['GitAvailable'] = $false
    $Script:GitEnabled = $false
}
Write-Verbose "Git enabled: $Script:GitEnabled"

#export public functions only
[string[]]$exports = @($publicFn | Select-Object -ExpandProperty BaseName)
Write-Verbose "Exporting $($exports.Count) functions"
Export-ModuleMember -Function $exports

# setup and export the main alias
$alias = Get-PowerStubConfigurationKey 'InvokeAlias'
# Validate alias name to prevent shadowing critical system commands
if ($alias -notmatch '^[a-zA-Z][a-zA-Z0-9_\-]{0,20}$' -or (Test-PowerStubReservedName $alias)) {
    Write-Warning "PowerStub: Invalid or reserved InvokeAlias '$alias'. Falling back to 'pstb'."
    $alias = 'pstb'
}
Write-Verbose "Creating Invoke-PowerStubCommand alias as: $alias"
New-Alias $alias Invoke-PowerStubCommand
Export-ModuleMember -Alias $alias

#setup the Invoke-PowerStubCommand argument completer for the STUB parameter
Write-Verbose "Setting up argument completer for Invoke-PowerStubCommand STUB parameter"
$StubCompleter = {
    param($commandName, $parameterName, $stringMatch, $commandAst, $fakeBoundParameters)

    # Virtual verbs (reserved commands)
    $virtualVerbs = @('search', 'help', 'update')

    Sync-PowerStubConfiguration
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    $allOptions = @($virtualVerbs) + @($stubs.Keys)

    if (!$stringMatch) { return $allOptions }

    $PartialMatches = @($allOptions | Where-Object { $_ -like "$stringMatch*" })
    return $PartialMatches
}

# Register for both the function and the alias
Register-ArgumentCompleter -CommandName Invoke-PowerStubCommand -ParameterName Stub -ScriptBlock $StubCompleter
Register-ArgumentCompleter -CommandName $alias -ParameterName Stub -ScriptBlock $StubCompleter

#setup the Invoke-PowerStubCommand argument completer for the COMMAND parameter
Write-Verbose "Setting up argument completer for Invoke-PowerStubCommand COMMAND parameter"
$CommandCompleter = {
    param($commandName, $parameterName, $stringMatch, $commandAst, $fakeBoundParameters)

    $stub = $fakeBoundParameters['Stub']
    if (!$stub) { return @() }

    # Handle virtual verb completions
    if ($stub -eq 'help') {
        # For 'help' verb, the command parameter should show stub names
        Sync-PowerStubConfiguration
        $stubs = Get-PowerStubConfigurationKey 'Stubs'
        $stubNames = @($stubs.Keys)
        if (!$stringMatch) { return $stubNames }
        return @($stubNames | Where-Object { $_ -like "$stringMatch*" })
    }

    if ($stub -eq 'search') {
        # For 'search' verb, no completion (user types query)
        return @()
    }

    if ($stub -eq 'update') {
        # For 'update' verb, the command parameter should show stub names (or empty for all)
        Sync-PowerStubConfiguration
        $stubs = Get-PowerStubConfigurationKey 'Stubs'
        $stubNames = @($stubs.Keys)
        if (!$stringMatch) { return $stubNames }
        return @($stubNames | Where-Object { $_ -like "$stringMatch*" })
    }

    $commands = @(Find-PowerStubCommands $stub)
    if (!$commands) { return @() }

    # Get base names and strip alpha./beta. prefixes for user-friendly completion
    $commandNames = @($commands | ForEach-Object {
        $name = $_.BaseName
        # Strip alpha. or beta. prefix if present
        if ($name -match '^(alpha|beta)\.(.+)$') {
            $Matches[2]
        } else {
            $name
        }
    } | Select-Object -Unique)

    if (!$stringMatch) { return $commandNames }

    $PartialMatches = $commandNames | Where-Object { $_ -like "$stringMatch*" }
    return $PartialMatches
}

# Register for both the function and the alias
Register-ArgumentCompleter -CommandName Invoke-PowerStubCommand -ParameterName Command -ScriptBlock $CommandCompleter
Register-ArgumentCompleter -CommandName $alias -ParameterName Command -ScriptBlock $CommandCompleter

# Ensure PSReadLine Tab completion is properly configured
# PSReadLine is required for interactive tab completion in modern PowerShell terminals
Write-Verbose "Checking PSReadLine Tab completion setup"
$psrlModule = Get-Module PSReadLine
if ($psrlModule) {
    # PSReadLine is loaded - check if Tab is bound to a completion function
    $tabHandler = Get-PSReadLineKeyHandler -Bound -ErrorAction SilentlyContinue | Where-Object { $_.Key -eq 'Tab' }
    if (-not $tabHandler) {
        Write-Verbose "Tab key not bound - setting up Tab completion"
        try {
            Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction Stop
            Write-Verbose "Tab key bound to MenuComplete"
        } catch {
            Write-Warning "PowerStub: Could not configure Tab completion. You may need to add 'Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete' to your profile."
        }
    } else {
        Write-Verbose "Tab key already bound to: $($tabHandler.Function)"
    }
} else {
    # PSReadLine not loaded - this is unusual in interactive sessions
    # Don't warn here as this might be a non-interactive context (tests, scripts, etc.)
    Write-Verbose "PSReadLine not loaded - Tab completion may not work interactively"
}

# NOTE: We intentionally do NOT override TabExpansion2 as it can break tab completion
# for all commands in some environments. The core completion functionality (stub names,
# command names, and dynamic parameters) works via Register-ArgumentCompleter which
# doesn't require TabExpansion2.
#
# Trade-off: When using positional syntax like "pstb DevOps deploy -<Tab>", the
# completions will still include -stub and -command even though they're already bound.
# This is a minor UX issue that's preferable to potentially breaking all tab completion.

# Re-register any saved direct aliases
Write-Verbose "Registering saved direct aliases"
$Script:RegisteredDirectAliases = @()
$directAliases = Get-PowerStubConfigurationKey 'DirectAliases'
if ($directAliases) {
    # Copy keys to array to avoid "Collection was modified" error during enumeration
    $aliasNames = @($directAliases.Keys)
    foreach ($aliasName in $aliasNames) {
        $stubName = $directAliases[$aliasName]
        # Only re-register if the stub still exists
        $stubs = Get-PowerStubConfigurationKey 'Stubs'
        if ($stubs.Keys -contains $stubName) {
            try {
                # No -Force: a name from the config file must never silently replace an existing command
                New-PowerStubDirectAlias -AliasName $aliasName -Stub $stubName -ErrorAction Stop | Out-Null
                Write-Verbose "Registered direct alias '$aliasName' for stub '$stubName'"
            } catch {
                Write-Warning "Could not register direct alias '$aliasName': $_"
            }
        } else {
            Write-Verbose "Skipping alias '$aliasName' - stub '$stubName' no longer exists"
        }
    }
}

# NOTE: Git status checks are NOT performed on module load for performance.
# Use 'pstb update --check' to check for updates manually.

# Cleanup direct aliases on module removal
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    # Only remove the functions this module created, never a same-named command of the user's
    foreach ($aliasName in $Script:RegisteredDirectAliases) {
        # Note: Remove-Item does nothing for a 'function:global:' path; the unqualified path works
        if (Test-Path "function:$aliasName") {
            Remove-Item "function:$aliasName" -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Verbose "PowerStub module loaded."
