<#
.SYNOPSIS
  Registers a new PowerStub in the specified path.

.DESCRIPTION
  Registers a new PowerStub in the specified path. A stub provides centralized access
  to a logical grouping of scripts or other tools, facilitating proper organization
  without requiring each element to be added to the system PATH.

  Creates the stub folder and required subfolders (.tests, Commands) if they don't exist.
  If git is enabled and the path is part of a git repository, the remote URL is automatically saved.

.PARAMETER Name
  The name of the stub. Must start with a letter and contain only alphanumeric characters,
  hyphens, and underscores. The virtual verbs help, search, and update are reserved.
  This is the name used to invoke commands via pstb.

.PARAMETER Path
  The file system path where the stub's commands and scripts are located.
  Will be created if it does not exist. Relative paths are resolved against the current
  PowerShell filesystem location and saved as absolute paths.

.PARAMETER Force
  If specified, overwrites an existing stub registration with the same name.

.INPUTS
  None. You cannot pipe objects to this function.

.OUTPUTS
  None. Updates the configuration with the new stub registration.

.EXAMPLE
  New-PowerStub -Name "DevOps" -Path "C:\Scripts\DevOps"

  Registers a new stub named "DevOps" pointing to the DevOps scripts folder.

.EXAMPLE
  New-PowerStub -Name "Tools" -Path "C:\Tools" -Force

  Registers or overwrites a stub named "Tools", forcing the update if it already exists.

#>

function New-PowerStub {
    param(
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_\-]*$')]
        [ValidateNotNullOrEmpty()]
        [string]$name,
        [ValidateNotNullOrEmpty()]
        [string]$path,
        [switch]$force
    )

    # These names dispatch virtual verbs and can never select a registered stub.
    if ($name -in @('help', 'search', 'update')) {
        throw "Stub name '$name' is reserved for a PowerStub virtual verb. Choose another name."
    }

    # Resolve against PowerShell's location (not the process working directory), even
    # when the folder does not yet exist. Persist an absolute, literal filesystem path.
    $provider = $null
    $drive = $null
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw 'A PowerStub path must use the FileSystem provider.'
    }

    # Build stub configuration - either simple path or hashtable with git info
    $stubConfig = $path

    # Check for git repo if git is enabled
    if ($Script:GitEnabled) {
        $gitInfo = Get-PowerStubGitInfo -Path $path
        if ($gitInfo.IsRepo -and $gitInfo.RemoteUrl) {
            $stubConfig = @{
                Path       = $path
                GitRepoUrl = $gitInfo.RemoteUrl
            }
            Write-Verbose "Detected Git repository: $($gitInfo.RemoteUrl)"
        }
    }

    Sync-PowerStubConfiguration
    if ((Get-PowerStubConfigurationKey 'Stubs').Keys -contains $name -and -not $force) {
        throw "Stub $name already exists. Use -Force to overwrite."
    }

    #create the folder and standard child folders, if necessary
    # Note: draft and beta commands use filename prefixes (draft.*, beta.*) instead of separate folders
    $paths = @($path, (Join-Path $path '.tests'), (Join-Path $path 'Commands'))
    try {
        foreach ($pathItem in $paths) {
            [System.IO.Directory]::CreateDirectory($pathItem) | Out-Null
        }
    }
    catch {
        # Never persist a registration when a file or inaccessible folder prevents
        # creating the required layout, even under ErrorActionPreference=Continue.
        throw
    }

    #update the configuration, adding only this stub so other sessions' registrations are kept
    Update-PowerStubConfiguration {
        $stubs = $Script:PSTBSettings['Stubs']
        if ($stubs.Keys -contains $name -and -not $force) {
            throw "Stub $name already exists. Use -Force to overwrite."
        }
        $stubs[$name] = $stubConfig
    }
}


