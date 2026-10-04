<#
.SYNOPSIS
    Gets metadata for a command, typically used for executables.

.DESCRIPTION
    Looks for a metadata.<commandname>.ps1 file that provides comment-based help
    for executables or other commands that can't contain their own help.

    The metadata file should contain comment-based help (.SYNOPSIS, .DESCRIPTION,
    .PARAMETER, .EXAMPLE, etc.) and optionally parameter definitions for future
    tab completion support.

.PARAMETER CommandFile
    The FileInfo object for the command file.

.PARAMETER CommandName
    The base name of the command (without extension or prefix).

.PARAMETER CommandsPath
    The path to the Commands folder.

.OUTPUTS
    PSCustomObject with Path and Help properties, or $null if no metadata found.

.EXAMPLE
    Get-PowerStubCommandMetadata -CommandFile $fileInfo -CommandName "terraform" -CommandsPath "C:\Stubs\DevOps\Commands"
#>

function Get-PowerStubCommandMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [System.IO.FileInfo]$CommandFile,

        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$CommandsPath
    )

    # Build possible metadata file paths
    $metadataFileName = "metadata.$CommandName.ps1"

    # Check direct location in Commands folder
    $directPath = Join-Path $CommandsPath $metadataFileName

    # Check subfolder location
    $subfolderPath = Join-Path $CommandsPath $CommandName
    $subfolderMetadataPath = Join-Path $subfolderPath $metadataFileName

    $metadataPath = $null

    # If CommandFile is provided, look in the same directory first
    if ($CommandFile) {
        $sameDir = Join-Path (Split-Path $CommandFile.FullName -Parent) $metadataFileName
        if (Test-Path -LiteralPath $sameDir) {
            $metadataPath = $sameDir
        }
    }

    # Fall back to standard locations
    if (-not $metadataPath) {
        if (Test-Path -LiteralPath $directPath) {
            $metadataPath = $directPath
        }
        elseif (Test-Path -LiteralPath $subfolderMetadataPath) {
            $metadataPath = $subfolderMetadataPath
        }
    }

    if (-not $metadataPath) {
        return $null
    }

    # Get help from the metadata file
    try {
        $help = Get-Help ([System.Management.Automation.WildcardPattern]::Escape($metadataPath)) -Full -ErrorAction SilentlyContinue
        return [PSCustomObject]@{
            Path = $metadataPath
            Help = $help
        }
    }
    catch {
        Write-Warning "Failed to parse metadata file: $metadataPath"
        return $null
    }
}
