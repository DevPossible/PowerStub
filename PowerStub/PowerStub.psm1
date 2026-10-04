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

# Setup the main alias only in a free namespace. Config files, including legacy
# settings, are never permission to replace a user's command during module import.
$requestedAlias = Get-PowerStubConfigurationKey 'InvokeAlias'
$alias = $requestedAlias
if ($alias -notmatch '^[a-zA-Z][a-zA-Z0-9_\-]{0,20}$' -or
    (Test-PowerStubReservedName $alias)) {
    Write-Warning "PowerStub: Invalid or reserved InvokeAlias '$requestedAlias'. Trying the default 'pstb'."
    $alias = 'pstb'
}
elseif (Get-PowerStubAliasConflict $alias) {
    Write-Warning "PowerStub: InvokeAlias '$requestedAlias' is already an existing command and was not replaced. Trying the default 'pstb'."
    $alias = 'pstb'
}
if (Get-PowerStubAliasConflict $alias) {
    Write-Warning "PowerStub: InvokeAlias '$alias' is already an existing command and was not replaced. Use Invoke-PowerStubCommand instead."
    $alias = $null
}
if ($alias) {
    Write-Verbose "Creating Invoke-PowerStubCommand alias as: $alias"
    New-Alias $alias Invoke-PowerStubCommand
    Export-ModuleMember -Alias $alias
}

# Tab completion.
#
# Invoke-PowerStubCommand declares no parameters, so that arguments meant for the target are
# never bound to pstb (see the comment in that function). PowerShell therefore has nothing to
# complete from, and Register-ArgumentCompleter cannot fill the gap: it is not consulted for
# a partly typed '-Name' on a function. So completion is supplied by wrapping TabExpansion2,
# the function every host calls for completion.
#
# The wrapper only answers for pstb, Invoke-PowerStubCommand and direct aliases. For every
# other line, and whenever anything goes wrong, it calls the original unchanged.
$Script:InvokeAlias = $alias
$Script:OriginalTabExpansion2 = (Get-Command TabExpansion2 -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
if ($Script:OriginalTabExpansion2) {
    Write-Verbose "Wrapping TabExpansion2 for PowerStub completion"
    Set-Item -Path function:global:TabExpansion2 -Value {
        [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
        [OutputType([System.Management.Automation.CommandCompletion])]
        param(
            [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 0)]
            [AllowEmptyString()]
            [string] $inputScript,

            [Parameter(ParameterSetName = 'ScriptInputSet', Position = 1)]
            [int] $cursorColumn = $inputScript.Length,

            [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 0)]
            [System.Management.Automation.Language.Ast] $ast,

            [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 1)]
            [System.Management.Automation.Language.Token[]] $tokens,

            [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 2)]
            [System.Management.Automation.Language.IScriptPosition] $positionOfCursor,

            [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
            [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
            [Hashtable] $options = $null
        )

        try {
            $text = if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') { $ast.Extent.Text } else { $inputScript }
            $cursor = if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') { $positionOfCursor.Offset } else { $cursorColumn }

            $completion = Get-PowerStubCompletion -InputScript $text -CursorColumn $cursor -Options $options
            if ($completion) {
                return $completion
            }
        }
        catch {
            Write-Debug "PowerStub completion failed, using the default: $_"
        }

        & $Script:OriginalTabExpansion2 @PSBoundParameters
    }
}

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
$Script:RegisteredDirectAliasFunctions = @{}
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
                # Restore only into an unused name. Legacy ForcedDirectAliases entries
                # are not permission to replace another command during startup.
                Register-PowerStubDirectAlias -AliasName $aliasName -Stub $stubName -ErrorAction Stop
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
    # Put the original TabExpansion2 back, unless something else has replaced ours since
    $currentTabExpansion = Get-Command TabExpansion2 -CommandType Function -ErrorAction SilentlyContinue
    if ($Script:OriginalTabExpansion2 -and $currentTabExpansion.ScriptBlock.Module.Name -eq 'PowerStub') {
        Set-Item -Path function:global:TabExpansion2 -Value $Script:OriginalTabExpansion2
    }

    # Only remove the functions this module created, never a same-named command of the user's
    foreach ($aliasName in @($Script:RegisteredDirectAliases)) {
        Unregister-PowerStubDirectAliasFunction $aliasName -ErrorAction SilentlyContinue
    }
}

Write-Verbose "PowerStub module loaded."
