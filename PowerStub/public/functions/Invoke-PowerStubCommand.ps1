<#
.SYNOPSIS
  Executes a command from a registered PowerStub.

.DESCRIPTION
  Invokes a command that is registered within a PowerStub stub. This is the main entry point
  for executing stubbed commands. It resolves the command path, forwards parameters and arguments,
  and executes the target script or executable with proper error handling and logging.

  Supports virtual verbs (search, help, update) that perform special operations without
  mapping to actual command files.

  This function deliberately declares no parameters. The first argument is the stub, the
  second is the command, and everything after that is handed to the target exactly as typed.
  (-Stub and -Command are still accepted by their full names, before the target's arguments.)
  Tab completion for stubs, commands and the target's own parameters is provided by the
  module's TabExpansion2 wrapper.

.INPUTS
  None. You cannot pipe objects to this function.

.OUTPUTS
  Output from the executed command. This varies depending on the target command.

.EXAMPLE
  pstb DevOps deploy -Environment Production

  Executes the deploy command in the DevOps stub with the Environment parameter.

.EXAMPLE
  pstb search "backup"

  Searches all registered stubs for commands matching "backup".

.EXAMPLE
  pstb help DevOps deploy

  Displays PowerShell help for the deploy command in the DevOps stub.

.EXAMPLE
  pstb update --check

  Checks the status of all stub Git repositories without pulling changes.

#>

function Invoke-PowerStubCommand {
    # NOT an advanced function, and no param block - on purpose.
    #
    # An advanced function always has the common parameters, and PowerShell matches every
    # -flag against them and against the function's own parameters by prefix. For a proxy
    # that is fatal: 'dotnet build -c Release' binds -c to -Command, 'curl -o file' fails as
    # ambiguous (-OutVariable/-OutBuffer), and -v, -d, -e, -i, -p and -w are swallowed or
    # rejected before any of this code runs. With no parameters, every argument arrives in
    # $args untouched and is splatted to the target, which keeps named parameters
    # (-Name x, -Count:5, -Force) working for script targets.
    #
    # tests/ParsingMatrix.tests.ps1 compares 300 calls through pstb with direct calls. Do not
    # change how arguments flow here without checking that its agreement count does not drop.

    $invocation = Resolve-PowerStubInvocation -Tokens $args
    $stub = if ($invocation.StubIndex -ge 0 -and $invocation.StubIndex -lt $args.Count) { [string]$args[$invocation.StubIndex] }
    $command = if ($invocation.CommandIndex -ge 0 -and $invocation.CommandIndex -lt $args.Count) { [string]$args[$invocation.CommandIndex] }
    # Slicing (rather than copying element by element) keeps each argument exactly as it was
    # bound, including the marker PowerShell uses to splat '-Name' as a parameter name.
    # Assign the slice directly: '$x = if (...) { $slice }' would unroll a one-element array
    # into a scalar, and a string then gets splatted character by character.
    $targetArgs = @()
    if ($invocation.RestStart -lt $args.Count) {
        $targetArgs = $args[$invocation.RestStart..($args.Count - 1)]
    }

    Sync-PowerStubConfiguration

    if (!$stub) {
        Show-PowerStubOverview
        return
    }

    # Virtual verb handling - these are reserved commands that don't map to script files
    $virtualVerbs = @('search', 'help', 'update')
    if ($virtualVerbs -contains $stub) {
        switch ($stub) {
            'search' {
                if ($command) {
                    return Search-PowerStubCommands $command
                }
                else {
                    throw "Usage: pstb search <query>"
                }
            }
            'help' {
                if ($command -and $targetArgs.Count -gt 0) {
                    # pstb help <stub> <command>
                    return Get-PowerStubCommandHelp -Stub $command -Command $targetArgs[0]
                }
                else {
                    throw "Usage: pstb help <stub> <command>"
                }
            }
            'update' {
                Invoke-PowerStubUpdate -Command $command -RemainingArgs $targetArgs
                return
            }
        }
    }

    if (!$command) {
        Show-PowerStubCommands $stub
        return
    }

    # Check if stub is registered first
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not $stubs -or -not $stubs.ContainsKey($stub)) {
        $registeredStubs = if ($stubs) { ($stubs.Keys -join ', ') } else { '(none)' }
        Throw "Stub '$stub' is not registered. Registered stubs: $registeredStubs`n`nTo register: New-PowerStub -Name '$stub' -Path '<path-to-stub-folder>'"
    }

    $commandObj = Get-PowerStubCommand $stub $command
    if (!$commandObj) {
        $stubConfig = $stubs[$stub]
        $stubPath = Get-PowerStubPath -StubConfig $stubConfig
        Throw "Command '$command' not found in stub '$stub'.`n`nStub path: $stubPath`nExpected: $stubPath\Commands\$command.ps1 or $stubPath\Commands\$command\$command.ps1"
    }

    $cmd = $commandObj.Path

    Write-Debug "Command path: $cmd"
    Write-Debug "Target args: $($targetArgs -join ', ')"

    Write-Host "Invoking $cmd"
    Invoke-CheckedCommand $cmd @targetArgs
}