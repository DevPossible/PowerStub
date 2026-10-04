<#
.SYNOPSIS
  Finds all the commands for a stub while respecting the alpha and beta prefix settings.

.DESCRIPTION
  Discovers commands in a stub's Commands folder. Only exposes:
  - Direct .ps1 and .exe files in the Commands folder
  - For subfolders, only files matching the folder name (with optional alpha./beta. prefix)

  This prevents helper scripts and supporting files from being exposed as commands.
  Filters out 'alpha.' or 'beta.' prefixed commands unless those modes are enabled.
  Excludes 'metadata.*' files which provide help for executables.

.LINK

.PARAMETER stub
  The name of the stub to search for commands.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
  FileInfo objects for each discovered command.

.EXAMPLES
  Find-PowerStubCommands -stub "DevOps"

#>

function Find-PowerStubCommands {
    param(
        [string]$stub
    )
    Sync-PowerStubConfiguration

    $alpha = Get-PowerStubConfigurationKey 'EnablePrefix:Alpha'
    $beta = Get-PowerStubConfigurationKey 'EnablePrefix:Beta'
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    $stubConfig = $stubs.$stub

    if (!$stubConfig) {
        Write-Warning "Stub '$stub' not found in the configuration."
        return
    }

    # Extract path from stub config (handles both string and hashtable formats)
    $stubRoot = Get-PowerStubPath -StubConfig $stubConfig

    $commandsPath = Join-Path $stubRoot 'Commands'
    $commands = @()

    if (Test-Path -LiteralPath $commandsPath) {
        # 1. Get direct .ps1 and .exe files in Commands folder
        $commands += Get-ChildItem -LiteralPath $commandsPath -File | Where-Object {
            $_.Extension -in @('.ps1', '.exe')
        }

        # 2. For each subfolder, get files that match the folder name (with optional alpha./beta. prefix)
        $subfolders = Get-ChildItem -LiteralPath $commandsPath -Directory
        foreach ($folder in $subfolders) {
            $folderName = $folder.Name
            $matchingFiles = Get-ChildItem -LiteralPath $folder.FullName -File | Where-Object {
                $_.Extension -in @('.ps1', '.exe') -and (
                    $_.BaseName -eq $folderName -or
                    $_.BaseName -eq "alpha.$folderName" -or
                    $_.BaseName -eq "beta.$folderName"
                )
            }
            $commands += $matchingFiles
        }
    }

    # Filter out alpha-prefixed commands when alpha mode is not enabled
    if ($alpha -ne $true) {
        $commands = $commands | Where-Object { $_.BaseName -notmatch "^alpha\." }
    }

    # Filter out beta-prefixed commands when beta mode is not enabled
    if ($beta -ne $true) {
        $commands = $commands | Where-Object { $_.BaseName -notmatch "^beta\." }
    }

    # Filter out metadata files (used to provide help for executables)
    $commands = $commands | Where-Object { $_.BaseName -notmatch "^metadata\." }

    return $commands
}
