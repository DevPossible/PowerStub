<#
.SYNOPSIS
  Gets an instance of the configuration with default values.

.DESCRIPTION

.LINK

.PARAMETER

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS

.EXAMPLES

#>


function Get-PowerStubConfigurationDefaults {

    # Use version-independent config path to persist across module updates.
    # POWERSTUB_CONFIG_DIR overrides the location (used by the tests to stay away from the real config).
    $configDir = if ($env:POWERSTUB_CONFIG_DIR) {
        $env:POWERSTUB_CONFIG_DIR
    } elseif ($env:APPDATA) {
        Join-Path $env:APPDATA 'PowerStub'
    } else {
        Join-Path $HOME '.config/powerstub'
    }

    $defaults = @{
        'ModulePath'         = $Script:ModulePath
        'ConfigFile'         = Join-Path $configDir 'config.json'
        'LegacyConfigFile'   = Join-Path $Script:ModulePath 'PowerStub.json'
        'InternalConfigKeys' = @('InternalConfigKeys', 'ModulePath', 'ConfigFile', 'LegacyConfigFile', 'GitAvailable', 'ConfigFileLastWriteUtc')
        'InvokeAlias'        = 'pstb'
        'Stubs'              = @{}
        'EnablePrefix:Alpha' = $false
        'EnablePrefix:Beta'  = $false
        'GitEnabled'         = $true
        'GitAvailable'       = $false
        'ConfigFileLastWriteUtc' = $null
    }

    return $defaults
}
