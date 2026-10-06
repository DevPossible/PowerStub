<#
.SYNOPSIS
    Searches for commands across all registered stubs.

.DESCRIPTION
    Searches command names and help text (synopsis, description) across all
    registered PowerStub stubs. Returns matching commands with their stub,
    name, synopsis, and path.

.PARAMETER Query
    The search term to find. Searches command names, synopsis, and description.
    Case-insensitive partial matching.

.EXAMPLE
    Search-PowerStubCommands "deploy"

    Finds all commands containing "deploy" in their name or help text.

.EXAMPLE
    Search-PowerStubCommands "environment"

    Finds commands that mention "environment" in their help documentation.

.OUTPUTS
    PSCustomObject[] with properties: Stub, Command, Synopsis, Path
#>

function Search-PowerStubCommands {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Query
    )

    $results = @()
    $stubs = Get-PowerStubConfigurationKey 'Stubs'

    if (-not $stubs -or $stubs.Count -eq 0) {
        Write-Verbose "No stubs registered"
        return $results
    }

    foreach ($stubName in $stubs.Keys) {
        Write-Verbose "Searching stub: $stubName"

        $commands = @(Find-PowerStubCommands $stubName)
        if (-not $commands) { continue }

        foreach ($cmd in $commands) {
            $commandName = $cmd.BaseName

            # Strip alpha./beta. prefix for display
            $displayName = $commandName
            if ($commandName -match '^(alpha|beta)\.(.+)$') {
                $displayName = $Matches[2]
            }

            # Check if command name matches
            $nameMatch = $displayName -like "*$Query*"

            # Get help information
            $synopsis = $null
            $description = $null
            $helpMatch = $false

            try {
                $help = Get-PowerStubScriptHelp -Path $cmd.FullName
                if ($help) {
                    $synopsis = if ($help.Synopsis) { $help.Synopsis.Trim() } else { $null }
                    $description = if ($help.Description) { $help.Description.Trim() } else { $null }

                    # Check if help text matches
                    if ($synopsis -and $synopsis -like "*$Query*") {
                        $helpMatch = $true
                    }
                    if ($description -and $description -like "*$Query*") {
                        $helpMatch = $true
                    }
                }
            }
            catch {
                Write-Verbose "Could not get help for $($cmd.FullName): $_"
            }

            # Add to results if any match
            if ($nameMatch -or $helpMatch) {
                $results += [PSCustomObject]@{
                    Stub     = $stubName
                    Command  = $displayName
                    Synopsis = $synopsis
                }
            }
        }
    }

    return $results
}
