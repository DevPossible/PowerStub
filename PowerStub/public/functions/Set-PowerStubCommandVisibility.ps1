<#
.SYNOPSIS
    Changes the visibility/lifecycle stage of a PowerStub command.

.DESCRIPTION
    Renames a command script file to change its visibility prefix:
    - Alpha: alpha.commandname.ps1 (work-in-progress, requires Enable-PowerStubAlphaCommands)
    - Beta: beta.commandname.ps1 (testing, requires Enable-PowerStubBetaCommands)
    - Production: commandname.ps1 (always visible)

    If the target file already exists, prompts for confirmation unless -Force is specified.

.PARAMETER Stub
    The name of the stub containing the command.

.PARAMETER Command
    The name of the command (without visibility prefix).

.PARAMETER Visibility
    The target visibility level: Alpha, Beta, or Production.

.PARAMETER Force
    Skip confirmation prompt if target file already exists (replaces it).

.EXAMPLE
    Set-PowerStubCommandVisibility -Stub DevOps -Command deploy -Visibility Beta

    Promotes the deploy command to beta stage.

.EXAMPLE
    Set-PowerStubCommandVisibility -Stub DevOps -Command deploy -Visibility Production -Force

    Promotes to production, replacing any existing production version.

.OUTPUTS
    PSCustomObject with OldPath, NewPath, and Visibility properties.
#>

function Set-PowerStubCommandVisibility {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Stub,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Command,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet('Alpha', 'Beta', 'Production')]
        [string]$Visibility,

        [switch]$Force
    )

    # Verify stub exists
    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    if (-not ($stubs.Keys -contains $Stub)) {
        throw "Stub '$Stub' not found. Use Get-PowerStubs to see registered stubs."
    }

    $stubRoot = Get-PowerStubPath -StubConfig $stubs[$Stub]
    $commandsPath = Join-Path $stubRoot 'Commands'

    if (-not (Test-Path -LiteralPath $commandsPath)) {
        throw "Commands folder not found for stub '$Stub'."
    }

    # Find all versions of this command (alpha, beta, production)
    $versions = @{
        Alpha      = $null
        Beta       = $null
        Production = $null
    }

    # Check for direct files
    $alphaFile = Join-Path $commandsPath "alpha.$Command.ps1"
    $betaFile = Join-Path $commandsPath "beta.$Command.ps1"
    $prodFile = Join-Path $commandsPath "$Command.ps1"

    # Check for subfolder files
    $subfolderPath = Join-Path $commandsPath $Command
    $alphaSubFile = Join-Path $subfolderPath "alpha.$Command.ps1"
    $betaSubFile = Join-Path $subfolderPath "beta.$Command.ps1"
    $prodSubFile = Join-Path $subfolderPath "$Command.ps1"

    # Determine which files exist and where
    $isSubfolder = $false

    if (Test-Path -LiteralPath $alphaFile) { $versions.Alpha = $alphaFile }
    elseif (Test-Path -LiteralPath $alphaSubFile) { $versions.Alpha = $alphaSubFile; $isSubfolder = $true }

    if (Test-Path -LiteralPath $betaFile) { $versions.Beta = $betaFile }
    elseif (Test-Path -LiteralPath $betaSubFile) { $versions.Beta = $betaSubFile; $isSubfolder = $true }

    if (Test-Path -LiteralPath $prodFile) { $versions.Production = $prodFile }
    elseif (Test-Path -LiteralPath $prodSubFile) { $versions.Production = $prodSubFile; $isSubfolder = $true }

    # Count how many versions exist
    $existingVersions = $versions.GetEnumerator() | Where-Object { $_.Value -ne $null }
    $existingCount = @($existingVersions).Count

    if ($existingCount -eq 0) {
        throw "Command '$Command' not found in stub '$Stub'."
    }

    # Determine source file (the one to rename)
    $sourceFile = $null
    $sourceVisibility = $null

    if ($existingCount -eq 1) {
        # Only one version exists, use it
        $sourceVisibility = $existingVersions[0].Key
        $sourceFile = $existingVersions[0].Value
    }
    else {
        # Multiple versions exist - use precedence order based on enabled modes
        $alpha = Get-PowerStubConfigurationKey 'EnablePrefix:Alpha'
        $beta = Get-PowerStubConfigurationKey 'EnablePrefix:Beta'

        if ($alpha -and $versions.Alpha) {
            $sourceVisibility = 'Alpha'
            $sourceFile = $versions.Alpha
        }
        elseif ($beta -and $versions.Beta) {
            $sourceVisibility = 'Beta'
            $sourceFile = $versions.Beta
        }
        elseif ($versions.Production) {
            $sourceVisibility = 'Production'
            $sourceFile = $versions.Production
        }
        else {
            # Fall back to first available
            $sourceVisibility = $existingVersions[0].Key
            $sourceFile = $existingVersions[0].Value
        }

        Write-Verbose "Multiple versions exist. Using active version: $sourceVisibility ($sourceFile)"
    }

    # Check if already at target visibility
    if ($sourceVisibility -eq $Visibility) {
        Write-Host "Command '$Command' is already at $Visibility visibility." -ForegroundColor Yellow
        return [PSCustomObject]@{
            Command    = $Command
            Stub       = $Stub
            Path       = $sourceFile
            Visibility = $Visibility
            Changed    = $false
        }
    }

    # Determine target file path
    $sourceDir = Split-Path $sourceFile -Parent
    $extension = [System.IO.Path]::GetExtension($sourceFile)

    $targetFileName = switch ($Visibility) {
        'Alpha' { "alpha.$Command$extension" }
        'Beta' { "beta.$Command$extension" }
        'Production' { "$Command$extension" }
    }
    $targetFile = Join-Path $sourceDir $targetFileName

    # Check if target already exists (and it's not the source)
    if ((Test-Path -LiteralPath $targetFile) -and ($targetFile -ne $sourceFile)) {
        if (-not $Force) {
            $response = Read-Host "Target file '$targetFileName' already exists. Replace it? (y/N)"
            if ($response -notmatch '^[Yy]') {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                return
            }
        }
        # Remove existing target
        Remove-Item -LiteralPath $targetFile -Force
        Write-Verbose "Removed existing target file: $targetFile"
    }

    # Rename the file
    if ($PSCmdlet.ShouldProcess($sourceFile, "Rename to $targetFileName")) {
        Rename-Item -LiteralPath $sourceFile -NewName $targetFileName -Force

        Write-Host "Changed '$Command' visibility: $sourceVisibility -> $Visibility" -ForegroundColor Green

        return [PSCustomObject]@{
            Command       = $Command
            Stub          = $Stub
            OldPath       = $sourceFile
            NewPath       = $targetFile
            OldVisibility = $sourceVisibility
            NewVisibility = $Visibility
            Changed       = $true
        }
    }
}
