<#
.SYNOPSIS
  Tab completion for pstb, Invoke-PowerStubCommand and direct aliases.

.DESCRIPTION
  Called by the module's TabExpansion2 wrapper. Returns $null for anything that is not a
  PowerStub call, and the wrapper then uses PowerShell's normal completion.

  Invoke-PowerStubCommand declares no parameters (see the comment in that function), so
  PowerShell has nothing to complete from. This function supplies it instead:

  - stub position:    registered stubs and the virtual verbs
  - command position: the stub's commands (stub names after 'help' and 'update')
  - after that:       the line is rewritten to the direct call, & '<target path>' ..., and
                      handed to PowerShell's own completion. The user therefore gets exactly
                      what they would get calling the target directly: its parameters,
                      ValidateSet and enum values, paths, and so on.

.PARAMETER InputScript
  The whole line being completed.

.PARAMETER CursorColumn
  The cursor offset into InputScript.

.PARAMETER Options
  Completion options, passed through to PowerShell's completion.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
System.Management.Automation.CommandCompletion, or nothing.
#>


function Get-PowerStubCompletion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $InputScript,

        [Parameter(Mandatory)]
        [int] $CursorColumn,

        [hashtable] $Options
    )

    # A host can report the cursor one past the text (the end-of-input token sits there)
    $CursorColumn = [Math]::Max(0, [Math]::Min($CursorColumn, $InputScript.Length))

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($InputScript, [ref]$tokens, [ref]$parseErrors)

    # The innermost command the cursor is in. For 'pstb S c -Name (Get-Date ' that is Get-Date,
    # which is not ours, so normal completion handles it.
    $commandAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.Extent.StartOffset -le $CursorColumn
        }, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -Last 1
    if (-not $commandAst) { return }

    # The cursor must be inside the command, or separated from its end only by whitespace
    if ($CursorColumn -gt $commandAst.Extent.EndOffset) {
        $gap = $InputScript.Substring($commandAst.Extent.EndOffset, $CursorColumn - $commandAst.Extent.EndOffset)
        if ($gap.Trim()) { return }
    }

    $commandName = $commandAst.GetCommandName()
    if (-not $commandName) { return }

    $aliasStub = $null
    if ($commandName -ne 'Invoke-PowerStubCommand' -and $commandName -ne $Script:InvokeAlias) {
        if ($Script:RegisteredDirectAliases -notcontains $commandName -or
            -not (Test-PowerStubDirectAliasFunction $commandName)) { return }
        $aliasStub = (Get-PowerStubConfigurationKey 'DirectAliases')[$commandName]
        if (-not $aliasStub) { return }
    }

    Sync-PowerStubConfiguration

    # Split the arguments into those completely before the cursor and the one being typed
    $elements = @($commandAst.CommandElements | Select-Object -Skip 1)
    $current = $elements | Where-Object { $_.Extent.StartOffset -le $CursorColumn -and $CursorColumn -le $_.Extent.EndOffset } | Select-Object -First 1
    $before = @($elements | Where-Object { $_.Extent.EndOffset -lt $CursorColumn -and $_ -ne $current })

    $replaceStart = if ($current) { $current.Extent.StartOffset } else { $CursorColumn }
    $word = $InputScript.Substring($replaceStart, $CursorColumn - $replaceStart)

    $beforeTokens = @($before | ForEach-Object {
            if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value } else { $_.Extent.Text }
        })
    $invocation = Resolve-PowerStubInvocation -Tokens $beforeTokens -StubIsKnown:([bool]$aliasStub)
    $position = $before.Count

    $stub = if ($aliasStub) { $aliasStub } elseif ($invocation.StubIndex -ge 0 -and $invocation.StubIndex -lt $position) { $beforeTokens[$invocation.StubIndex] }
    $command = if ($invocation.CommandIndex -ge 0 -and $invocation.CommandIndex -lt $position) { $beforeTokens[$invocation.CommandIndex] }

    $virtualVerbs = @('search', 'help', 'update')
    $stubNames = @((Get-PowerStubConfigurationKey 'Stubs').Keys | Sort-Object)

    $candidates = $null
    if (-not $stub) {
        if ($word.StartsWith('-')) { return }
        $candidates = $virtualVerbs + $stubNames
    }
    elseif (-not $command) {
        if ($word.StartsWith('-')) { return }
        $candidates = switch ($stub) {
            'search' { return }
            { $_ -in 'help', 'update' } { $stubNames; break }
            default { Get-PowerStubCompletionCommandName -Stub $stub }
        }
    }
    elseif ($stub -eq 'help' -and $position -eq $invocation.RestStart) {
        # pstb help <stub> <command>
        $candidates = Get-PowerStubCompletionCommandName -Stub $command
    }
    elseif ($stub -in $virtualVerbs) {
        return
    }

    if ($null -ne $candidates) {
        $matching = @($candidates | Where-Object { $_ -like "$word*" })
        if (-not $matching) { return }

        $results = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
        foreach ($text in $matching) {
            $results.Add([System.Management.Automation.CompletionResult]::new($text, $text, 'ParameterValue', $text))
        }
        return [System.Management.Automation.CommandCompletion]::new($results, -1, $replaceStart, $word.Length)
    }

    # The target's own arguments: complete them as if the target had been called directly
    if (-not $Script:OriginalTabExpansion2) { return }
    $target = Get-PowerStubCommand $stub $command -WarningAction SilentlyContinue
    if (-not $target) { return }

    $argsStart = if ($invocation.RestStart -lt $elements.Count) { $elements[$invocation.RestStart].Extent.StartOffset } else { $CursorColumn }
    $directCall = "& '$($target.Path -replace "'", "''")' "
    $commandStart = $commandAst.Extent.StartOffset
    $rewritten = $InputScript.Substring(0, $commandStart) + $directCall + $InputScript.Substring($argsStart)
    $shift = ($commandStart + $directCall.Length) - $argsStart

    $completion = & $Script:OriginalTabExpansion2 -inputScript $rewritten -cursorColumn ($CursorColumn + $shift) -options $Options
    if ($completion) {
        $completion.ReplacementIndex -= $shift
    }
    return $completion
}
