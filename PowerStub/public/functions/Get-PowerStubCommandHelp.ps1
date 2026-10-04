<#
.SYNOPSIS
    Displays help for a PowerStub command.

.DESCRIPTION
    Retrieves and displays the PowerShell comment-based help for a command
    in a registered stub. This includes synopsis, description, parameters,
    and examples.

    For executables (.exe), looks for a metadata.<command>.ps1 file that
    contains the help documentation.

.PARAMETER Stub
    The name of the stub containing the command.

.PARAMETER Command
    The name of the command to get help for.

.EXAMPLE
    Get-PowerStubCommandHelp -Stub DevOps -Command deploy

    Displays full help for the deploy command in the DevOps stub.

.EXAMPLE
    pstb help DevOps deploy

    Same as above, using the virtual verb syntax.

.OUTPUTS
    PowerShell help object
#>

function Get-PowerStubCommandHelp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Stub,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Command
    )

    # Verify stub exists
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not ($stubs.Keys -contains $Stub)) {
        throw "Stub '$Stub' not found. Use Get-PowerStubs to see registered stubs."
    }

    # Get the command
    $cmd = Get-PowerStubCommand -Stub $Stub -Command $Command
    if (-not $cmd) {
        throw "Command '$Command' not found in stub '$Stub'."
    }

    $stubConfig = $stubs[$Stub]
    # Extract path from stub config (handles both string and hashtable formats)
    $stubRoot = Get-PowerStubPath -StubConfig $stubConfig
    $commandsPath = Join-Path $stubRoot 'Commands'
    $help = $null

    # For executables, check for metadata file first
    if ($cmd.Path -match '\.exe$') {
        $metadata = Get-PowerStubCommandMetadata -CommandName $Command -CommandsPath $commandsPath
        if ($metadata -and $metadata.Help) {
            $help = $metadata.Help
        }
    }
    else {
        # For .ps1 files, get help directly
        $help = Get-Help ([System.Management.Automation.WildcardPattern]::Escape($cmd.Path)) -Full -ErrorAction SilentlyContinue
    }

    if (-not $help -or $help.Synopsis -eq $cmd.Path) {
        # No help defined, return basic info
        Write-Warning "No help documentation found for '$Command'. Showing basic info."
        [PSCustomObject]@{
            Name        = $Command
            Stub        = $Stub
            Path        = $cmd.Path
            Synopsis    = "No help available"
            Description = "This command does not have comment-based help defined."
        }
    }
    else {
        $help
    }
}
