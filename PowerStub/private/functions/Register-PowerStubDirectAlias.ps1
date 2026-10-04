<#
.SYNOPSIS
  Registers a saved direct proxy in this session without rewriting configuration.
.DESCRIPTION
  Used by module startup and the public add command. Never replaces an existing
  command, even if a legacy configuration recorded ForcedDirectAliases consent.
#>
function Register-PowerStubDirectAlias {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]*$')]
        [string]$AliasName,
        [Parameter(Mandatory)]
        [string]$Stub
    )

    if (Test-PowerStubReservedName $AliasName) {
        throw "'$AliasName' is a reserved name and cannot be used as a direct alias."
    }
    if (Get-PowerStubAliasConflict $AliasName) {
        throw "A command named '$AliasName' already exists. Choose a different alias name."
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
    Set-Item -Path "function:global:$AliasName" -Value $scriptBlock -ErrorAction Stop
    $Script:RegisteredDirectAliasFunctions[$AliasName] = (Get-Item -LiteralPath "function:$AliasName").ScriptBlock

    # Remember which global functions are ours so module removal only cleans up those
    if ($Script:RegisteredDirectAliases -notcontains $AliasName) {
        $Script:RegisteredDirectAliases += $AliasName
    }

    # Tab completion for the alias comes from the module's TabExpansion2 wrapper,
    # which recognizes every name in $Script:RegisteredDirectAliases.

}
