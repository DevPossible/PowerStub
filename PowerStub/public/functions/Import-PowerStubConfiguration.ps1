<#
.SYNOPSIS
  Imports PowerStub configuration from the configuration file or resets to defaults.

.DESCRIPTION
  Imports the PowerStub configuration from PowerStub.json in the module configuration directory.
  Automatically migrates configuration from legacy module version locations if found.
  Supports resetting the configuration to defaults and re-exporting to the config file.

.PARAMETER Reset
  If specified, resets the configuration to defaults, clears all custom settings, and saves the defaults to the config file.

.INPUTS
  None. You cannot pipe objects to this function.

.OUTPUTS
  None. Updates the in-memory configuration from the file or defaults.

.EXAMPLE
  Import-PowerStubConfiguration

  Loads the configuration from PowerStub.json file.

.EXAMPLE
  Import-PowerStubConfiguration -Reset

  Resets the configuration to factory defaults and saves to the config file.

#>


function Import-PowerStubConfiguration {
    [CmdletBinding()]
    param (
        [switch] $reset
    )

    if ($reset) {
        $Script:PSTBSettings = Get-PowerStubConfigurationDefaults
        Export-PowerStubConfiguration
        return
    }

    $noImport = Get-PowerStubConfigurationKey 'InternalConfigKeys'
    $fileName = Get-PowerStubConfigurationKey 'ConfigFile'
    $legacyFileName = Get-PowerStubConfigurationKey 'LegacyConfigFile'

    # Ensure config directory exists
    $configDir = Split-Path $fileName -Parent
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Verbose "Created config directory: $configDir"
    }

    Write-Verbose "Current Configuration:"
    Write-Verbose ($Script:PSTBSettings | ConvertTo-Json)

    # Check for config file, with migration from legacy location
    $configToLoad = $null
    $migrating = $false
    if (Test-Path -LiteralPath $fileName) {
        $configToLoad = $fileName
        Write-Verbose "Using config file: $fileName"
    }
    elseif ($legacyFileName) {
        # Old versions kept the config in the version-specific module folder. Look in this
        # module's folder and its sibling version folders for one that has registered stubs.
        # The PowerStub.json shipped with the module is empty and is never migrated.
        $moduleParent = Split-Path $Script:ModulePath -Parent
        $legacyCandidates = @($legacyFileName) + @(
            Get-ChildItem -LiteralPath $moduleParent -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'PowerStub.json' }
        ) | Select-Object -Unique | Where-Object { Test-Path -LiteralPath $_ }

        $configToLoad = $legacyCandidates |
            Where-Object {
                try {
                    $legacyStubs = (Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json -ErrorAction Stop).Stubs
                    $legacyStubs -and @($legacyStubs.PSObject.Properties).Count -gt 0
                }
                catch { $false }
            } |
            Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
            Select-Object -First 1

        if ($configToLoad) {
            $migrating = $true
            Write-Host "Migrating PowerStub config from legacy location: $configToLoad" -ForegroundColor Yellow
        }
    }

    if ($configToLoad) {
        Write-Verbose "Importing File: $configToLoad"
        try {
            $configJson = Get-Content -LiteralPath $configToLoad -Raw -ErrorAction Stop
        }
        catch {
            if (-not (Test-Path -LiteralPath $configToLoad)) {
                Write-Verbose "Configuration file disappeared before it could be read: $configToLoad"
                return
            }
            throw
        }

        $newConfig = $null
        try {
            # Preserve the root JSON type: pipeline enumeration could otherwise turn
            # a single-object array into an accepted object, or wrap scalars as objects.
            $parsedConfig = ConvertFrom-Json -InputObject $configJson -NoEnumerate -ErrorAction Stop
            if ($null -ne $parsedConfig -and $parsedConfig.GetType() -eq [System.Management.Automation.PSCustomObject]) {
                # Keep case-insensitive maps for stub/alias names. -AsHashtable uses
                # case-sensitive JSON keys and would allow saved-only alias duplicates.
                $newConfig = ConvertTo-Hashtable -InputObject $parsedConfig
            }
        }
        catch {
            Write-Verbose "Configuration file is not valid JSON: $_"
        }

        if ($newConfig -isnot [System.Collections.IDictionary]) {
            # Blank or corrupt. Keep a copy, because the next save replaces the file,
            # and carry on with the current settings so the module still loads.
            $corruptCopy = "$configToLoad.corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Copy-Item -LiteralPath $configToLoad -Destination $corruptCopy -Force
            Write-Warning "PowerStub: Configuration file '$configToLoad' is blank or corrupt and was ignored. A copy was saved to '$corruptCopy'."
            $Script:PSTBSettings['ConfigFileLastWriteUtc'] = (Get-Item -LiteralPath $configToLoad).LastWriteTimeUtc
            return
        }

        foreach ($key in $newConfig.Keys) {
            #do not import values for internal keys
            if ($noImport -contains $key) { continue }
            Write-Verbose "Importing Configuration Key: $key"
            $Script:PSTBSettings[$key] = $newConfig[$key]
        }

        if ($migrating) {
            Export-PowerStubConfiguration
            Write-Host "  Config migrated to: $fileName" -ForegroundColor Green
            return
        }

        try {
            $Script:PSTBSettings['ConfigFileLastWriteUtc'] = (Get-Item -LiteralPath $configToLoad -ErrorAction Stop).LastWriteTimeUtc
        }
        catch {
            if (-not (Test-Path -LiteralPath $configToLoad)) {
                Write-Verbose "Configuration file disappeared after it was read: $configToLoad"
            }
            else {
                throw
            }
        }
    }
    else {
        Write-Verbose "No configuration file found. Using defaults."
    }

    Write-Verbose "New Configuration:"
    Write-Verbose ($Script:PSTBSettings | ConvertTo-Json)
}
