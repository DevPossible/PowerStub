<#
.SYNOPSIS
    Displays commands for a stub with synopsis and visibility indicators.

.DESCRIPTION
    Shows a formatted list of commands in a stub, including:
    - Stub root path
    - Command name (with prefix stripped)
    - Synopsis from comment-based help (or metadata file for executables)
    - Visibility indicator (* before alpha/beta commands, which are listed first)
#>

function Show-PowerStubCommands {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stub
    )

    # Help lookup is part of rendering the table, not a separate user operation.
    $ProgressPreference = 'SilentlyContinue'

    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not ($stubs.Keys -contains $Stub)) {
        $message = "Stub '$Stub' not found in the configuration."
        # A common slip is putting pstb in front of one of PowerStub's own commands
        if ($MyInvocation.MyCommand.Module.ExportedCommands.ContainsKey($Stub)) {
            $message += " '$Stub' is a PowerStub command: run it on its own, without pstb."
        }
        else {
            $registered = if ($stubs.Count -gt 0) { ($stubs.Keys | Sort-Object) -join ', ' } else { '(none)' }
            $message += " Registered stubs: $registered"
        }
        Write-Warning $message
        return
    }

    $stubConfig = $stubs[$Stub]
    # Extract path from stub config (handles both string and hashtable formats)
    $stubRoot = Get-PowerStubPath -StubConfig $stubConfig
    $commandsPath = Join-Path $stubRoot 'Commands'
    $commands = @(Find-PowerStubCommands $Stub)

    if (-not $commands -or $commands.Count -eq 0) {
        Write-Host "No commands found in stub '$Stub'." -ForegroundColor Yellow
        return
    }

    # Build display list
    $displayList = @()

    foreach ($cmd in $commands) {
        $baseName = $cmd.BaseName
        $displayName = $baseName
        $prefix = ""

        # Check for alpha/beta prefix
        if ($baseName -match '^(alpha|beta)\.(.+)$') {
            $prefix = "*"
            $displayName = $Matches[2]
        }

        # Get synopsis from help
        $synopsis = $null
        try {
            # For executables, check for metadata file
            if ($cmd.Extension -eq '.exe') {
                $metadata = Get-PowerStubCommandMetadata -CommandFile $cmd -CommandName $displayName -CommandsPath $commandsPath
                if ($metadata -and $metadata.Help -and $metadata.Help.Synopsis) {
                    $synopsis = $metadata.Help.Synopsis.Trim()
                }
            }
            else {
                # For .ps1 files, read the help block from the file (Get-Help is far slower)
                $help = Get-PowerStubScriptHelp -Path $cmd.FullName
                if ($help -and $help.Synopsis) {
                    $synopsis = $help.Synopsis.Trim()
                }
            }

            # Truncate if too long
            if ($synopsis -and $synopsis.Length -gt 60) {
                $synopsis = $synopsis.Substring(0, 57) + "..."
            }
        }
        catch {
            # Ignore help errors
        }

        if (-not $synopsis) {
            $synopsis = "-"
        }

        $displayList += [PSCustomObject]@{
            Prefix   = $prefix
            Command  = $displayName
            Synopsis = $synopsis
        }
    }

    # Pre-release (alpha/beta) commands first, then by command name
    $displayList = $displayList | Sort-Object @{ Expression = { -not $_.Prefix } }, Command

    Write-Host ""
    Write-Host "Commands in '$Stub':" -ForegroundColor Cyan
    Write-Host "  Path: $stubRoot" -ForegroundColor DarkGray

    $alpha = Get-PowerStubConfigurationKey 'EnablePrefix:Alpha'
    $beta = Get-PowerStubConfigurationKey 'EnablePrefix:Beta'
    if ($alpha -or $beta) {
        $modes = @()
        if ($alpha) { $modes += "alpha" }
        if ($beta) { $modes += "beta" }
        Write-Host "  (* = $($modes -join '/') command)" -ForegroundColor DarkGray
    }

    Write-Host ""
    $displayList | Format-Table -Property @{
        Label = 'Command'
        Expression = {
            if ($_.Prefix) { "$($_.Prefix) $($_.Command)" } else { $_.Command }
        }
    }, Synopsis -AutoSize | Out-String | ForEach-Object { $_.Trim() } | Write-Host
    Write-Host ""
}
