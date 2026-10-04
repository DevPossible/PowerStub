<#
.SYNOPSIS
  Gets the executable file or script file of the stub command

.DESCRIPTION
  Locates and returns a PowerShell command object for the specified command in a stub.
  Searches in the Commands folder for:
  - Direct files matching the command name
  - Subfolders matching the command name, containing a file with the same name

  When alpha or beta modes are enabled, searches for prefixed versions with precedence:
  alpha.* -> beta.* -> unprefixed (production)

.LINK

.PARAMETER stub
  The name of the stub to search in.

.PARAMETER command
  The name of the command to find (without prefix).

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
  A PowerShell command object for the found script or executable.

.EXAMPLES
  Get-PowerStubCommand -stub "DevOps" -command "deploy"

#>

function Get-PowerStubCommand {
    param(
        [string] $stub,
        [string] $command
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
    $commandFile = $null

    if (!(Test-Path -LiteralPath $commandsPath)) {
        Write-Warning "Commands folder not found for stub '$stub'."
        return
    }

    # Helper: Find a file by name in a path (direct file only, not recursive)
    $findDirectFile = {
        param($searchPath, $baseName)
        Get-ChildItem -LiteralPath $searchPath -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -in @('.ps1', '.exe') -and $_.BaseName -eq $baseName
        } | Select-Object -First 1
    }

    # Helper: Find a file in a subfolder where file basename matches the given name
    $findInSubfolder = {
        param($searchPath, $folderName, $baseName)
        $subfolderPath = Join-Path $searchPath $folderName
        if (Test-Path -LiteralPath $subfolderPath -PathType Container) {
            Get-ChildItem -LiteralPath $subfolderPath -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Extension -in @('.ps1', '.exe') -and $_.BaseName -eq $baseName
            } | Select-Object -First 1
        }
    }

    # Precedence order: alpha -> beta -> production
    # 1. Try alpha-prefixed version first (if alpha enabled)
    if ($alpha -eq $true -and !$commandFile) {
        $alphaName = "alpha.$command"
        # Try direct file
        $commandFile = & $findDirectFile $commandsPath $alphaName
        # Try subfolder (folder named after unprefixed command)
        if (!$commandFile) {
            $commandFile = & $findInSubfolder $commandsPath $command $alphaName
        }
    }

    # 2. Try beta-prefixed version (if beta enabled)
    if ($beta -eq $true -and !$commandFile) {
        $betaName = "beta.$command"
        # Try direct file
        $commandFile = & $findDirectFile $commandsPath $betaName
        # Try subfolder
        if (!$commandFile) {
            $commandFile = & $findInSubfolder $commandsPath $command $betaName
        }
    }

    # 3. Try unprefixed (production) version
    if (!$commandFile) {
        # Try direct file
        $commandFile = & $findDirectFile $commandsPath $command
        # Try subfolder
        if (!$commandFile) {
            $commandFile = & $findInSubfolder $commandsPath $command $command
        }
    }

    if (!$commandFile) {
        Write-Warning "Command '$command' not found in the stub '$stub'."
        return
    }

    # Validate command file is within the Commands directory (prevent path traversal)
    $resolvedPath = [System.IO.Path]::GetFullPath($commandFile.FullName)
    $resolvedCommandsPath = [System.IO.Path]::GetFullPath($commandsPath)
    if (-not $resolvedPath.StartsWith($resolvedCommandsPath + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $resolvedPath.Equals($resolvedCommandsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Command '$command' resolved outside the Commands directory. Blocked."
        return
    }

    $commandObj = Resolve-PowerStubFileCommand -Path $commandFile.FullName
    return $commandObj
}
