<#
.SYNOPSIS
    Displays an overview of PowerStub when run without parameters.

.DESCRIPTION
    Shows a brief description, module commands, virtual commands, registered stubs, and usage hints.
#>

function Show-PowerStubOverview {
    [CmdletBinding()]
    param()

    $alias = Get-PowerStubConfigurationKey 'InvokeAlias'

    # Header
    Write-Host ""
    Write-Host "PowerStub - Command proxy for organizing scripts and CLI tools" -ForegroundColor Cyan
    Write-Host "Usage: $alias <stub> <command> [arguments]" -ForegroundColor Gray
    Write-Host ""

    # Module commands table
    Write-Host "Module Commands:" -ForegroundColor Yellow
    $moduleCommands = @(
        [PSCustomObject]@{ Command = "New-PowerStub"; Synopsis = "Register a new stub with folder structure" }
        [PSCustomObject]@{ Command = "Remove-PowerStub"; Synopsis = "Unregister a stub from configuration" }
        [PSCustomObject]@{ Command = "Get-PowerStubs"; Synopsis = "List all registered stubs" }
        [PSCustomObject]@{ Command = "New-PowerStubDirectAlias"; Synopsis = "Create a shortcut alias for a stub" }
        [PSCustomObject]@{ Command = "Remove-PowerStubDirectAlias"; Synopsis = "Remove a direct alias" }
        [PSCustomObject]@{ Command = "Set-PowerStubCommandVisibility"; Synopsis = "Change command lifecycle (alpha/beta/prod)" }
        [PSCustomObject]@{ Command = "Add-PowerStubToProfile"; Synopsis = "Load PowerStub in every new session" }
        [PSCustomObject]@{ Command = "Get-PowerStubConfiguration"; Synopsis = "View current configuration" }
        [PSCustomObject]@{ Command = "Enable-PowerStubAlphaCommands"; Synopsis = "Show alpha.* prefixed commands" }
        [PSCustomObject]@{ Command = "Enable-PowerStubBetaCommands"; Synopsis = "Show beta.* prefixed commands" }
    )
    $moduleCommands | Format-Table -AutoSize -HideTableHeaders | Out-String | ForEach-Object { $_.Trim() } | Write-Host

    # Virtual commands table
    Write-Host ""
    Write-Host "Built-in Commands:" -ForegroundColor Yellow
    $virtualCommands = @(
        [PSCustomObject]@{ Command = "$alias search <query>"; Description = "Search commands across all stubs" }
        [PSCustomObject]@{ Command = "$alias help <stub> <cmd>"; Description = "Display help for a command" }
    )
    $virtualCommands | Format-Table -AutoSize -HideTableHeaders | Out-String | ForEach-Object { $_.Trim() } | Write-Host

    # Stubs table
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    Write-Host ""
    Write-Host "Registered Stubs:" -ForegroundColor Yellow

    if ($stubs -and $stubs.Count -gt 0) {
        $stubList = @()
        foreach ($stubName in $stubs.Keys) {
            $stubList += [PSCustomObject]@{
                Stub = $stubName
                Path = $stubs[$stubName]
            }
        }
        $stubList | Format-Table -AutoSize | Out-String | ForEach-Object { $_.Trim() } | Write-Host

        # Example using first stub
        $firstStub = @($stubs.Keys)[0]
        Write-Host ""
        Write-Host "Get started:" -ForegroundColor Green
        Write-Host "  $alias $firstStub" -ForegroundColor White -NoNewline
        Write-Host "              # List commands in '$firstStub'" -ForegroundColor DarkGray
        Write-Host "  $alias search ""deploy""" -ForegroundColor White -NoNewline
        Write-Host "      # Search all stubs for 'deploy'" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  (none)" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "Get started:" -ForegroundColor Green
        Write-Host "  New-PowerStub -Name ""MyStub"" -Path ""C:\Scripts\MyStub""" -ForegroundColor White
    }

    Write-Host ""
}
