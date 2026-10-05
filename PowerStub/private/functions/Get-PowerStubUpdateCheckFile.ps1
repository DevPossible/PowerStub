<#
.SYNOPSIS
  Gets the path of the file that holds the last update check result for a stub.

.DESCRIPTION
  Update check results live next to the configuration file, in an 'update-check' folder,
  one file per stub folder. They are deliberately kept out of config.json: they change
  on their own schedule and must never contend with the shared configuration lock.
  The file name is a hash of the stub folder, so any path can be stored safely.

.PARAMETER StubPath
  The stub's root folder.

.OUTPUTS
  The full path of the state file. The file may not exist yet.
#>

function Get-PowerStubUpdateCheckFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StubPath
    )

    $fullPath = [IO.Path]::GetFullPath($StubPath).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($IsWindows) { $fullPath = $fullPath.ToLowerInvariant() }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))
    }
    finally {
        $sha.Dispose()
    }
    $name = -join ($hash[0..7] | ForEach-Object { $_.ToString('x2') })

    $configFolder = Split-Path -Parent (Get-PowerStubConfigurationKey 'ConfigFile')
    return Join-Path $configFolder "update-check/$name.json"
}
