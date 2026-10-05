<#
.SYNOPSIS
  Sets a configuration key and updates the config file.

.DESCRIPTION
  Sets a single configuration key to the specified value. Validates the key
  against known configuration keys and emits a warning for unknown keys.

.PARAMETER key
  The configuration key to set.

.PARAMETER value
  The value to assign to the key.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
None.
#>


function Set-PowerStubConfigurationKey {
    param (
        [string] $key,
        $value
    )

    # Validate against known config keys to prevent orphan keys from typos
    $knownKeys = @(
        'Stubs', 'EnablePrefix:Alpha', 'EnablePrefix:Beta', 'GitEnabled', 'UpdateCheckIntervalHours', 'GitAvailable',
        'InvokeAlias', 'DirectAliases', 'ForcedDirectAliases', 'ModulePath', 'ConfigFile', 'LegacyConfigFile', 'InternalConfigKeys',
        'ConfigFileLastWriteUtc'
    )
    if ($key -notin $knownKeys) {
        Write-Warning "PowerStub: Unknown configuration key '$key'. Known keys: $($knownKeys -join ', ')"
    }

    # Internal keys are never persisted, so there is nothing to write
    if ((Get-PowerStubConfigurationKey 'InternalConfigKeys') -contains $key) {
        $Script:PSTBSettings[$key] = $value
        return
    }

    # Note: for keys holding a collection (Stubs, DirectAliases), change the entry inside
    # Update-PowerStubConfiguration instead, so other sessions' entries are kept.
    Update-PowerStubConfiguration { $Script:PSTBSettings[$key] = $value }
}
