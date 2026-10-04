<#
.SYNOPSIS
  Runs a target command with the caller's arguments, untouched, and reports a failure.

.DESCRIPTION
  Usage:  Invoke-CheckedCommand <command path> @targetArgs

  Deliberately a simple function with no param block: the arguments must arrive by splat
  and leave by splat. Passing them through a declared [object[]] parameter reshapes a
  one-element array, which breaks a lone -Switch, a lone array argument and a lone $null.
  Splatting also keeps the marker PowerShell uses to bind '-Name' as a parameter name.

  Uses the call operator rather than Invoke-Expression, so metacharacters in arguments
  are never interpreted.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
Whatever the target command outputs.
#>


function Invoke-CheckedCommand {
    $command = $args[0]

    $global:LASTEXITCODE = 0
    $exitCode = 0

    # Slice, do not copy element by element: see the description
    $targetArgs = @()
    if ($args.Count -gt 1) {
        $targetArgs = $args[1..($args.Count - 1)]
    }

    # '-Switch:$false' is the one form splatting cannot forward: it arrives as the two
    # arguments '-Switch:' and $false, and a switch does not take the second one, so the
    # target would see the switch as ON. Move such pairs into a named splat instead.
    # Only applies to PowerShell targets; an executable has no parameters to resolve.
    $switchValues = @{}
    $commandInfo = $null
    $i = 0
    while ($i -lt ($targetArgs.Count - 1)) {
        $parameter = $null
        if ($targetArgs[$i] -is [string] -and $targetArgs[$i] -match '^-([^:]+):$') {
            if (-not $commandInfo) {
                $commandInfo = Resolve-PowerStubFileCommand -Path $command
            }
            if ($commandInfo.Parameters) {
                try {
                    $parameter = $commandInfo.ResolveParameter($Matches[1])
                }
                catch {
                    # Not a parameter of the target (or ambiguous): forward it untouched
                    Write-Debug "Not resolving '$($targetArgs[$i])': $_"
                }
            }
        }

        if ($parameter -and $parameter.SwitchParameter) {
            $switchValues[$parameter.Name] = [bool]$targetArgs[$i + 1]
            # Remove the pair using slices only, for the same reason as above
            $head = @()
            $tail = @()
            if ($i -gt 0) { $head = $targetArgs[0..($i - 1)] }
            if (($i + 2) -lt $targetArgs.Count) { $tail = $targetArgs[($i + 2)..($targetArgs.Count - 1)] }
            $targetArgs = $head + $tail
        }
        else {
            $i++
        }
    }

    # Link the target pipeline to this function's command runtime. A plain call resets
    # the caller's $? to success when a simple function returns, even after exit 7.
    # Keep the argument splats intact: advanced-function binding would consume CLI flags.
    $pipeline = { & $command @switchValues @targetArgs }.GetSteppablePipeline($MyInvocation.CommandOrigin)
    try {
        $pipeline.Begin($false, $ExecutionContext)
        $pipeline.Process()
        $pipeline.End()
    }
    finally {
        $pipeline.Dispose()
    }

    # Stepping propagates the pipeline failure flag directly. $? here only describes
    # the successful End/Dispose method call; use LASTEXITCODE for the exit diagnostic.
    if (Test-Path VARIABLE:GLOBAL:LASTEXITCODE) { $exitCode = $GLOBAL:LASTEXITCODE; }
    else {
        if (Test-Path VARIABLE:LASTEXITCODE) { $exitCode = $LASTEXITCODE; }
        else { $exitCode = 0; }
    }

    if ($exitCode -ne 0) {
        Write-Debug $("$command exited with error code " + $exitCode)
        # Extract just the command name for cleaner error message
        $cmdName = Split-Path -Leaf $command
        # Use Write-Host for clean output without stack trace
        Write-Host "$cmdName exited with error code $exitCode" -ForegroundColor Red
        # Set LASTEXITCODE so callers can check it
        $global:LASTEXITCODE = $exitCode
    }
}
