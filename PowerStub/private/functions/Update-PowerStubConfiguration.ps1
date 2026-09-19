<#
.SYNOPSIS
  Applies a change to the configuration without losing changes made by other sessions.

.DESCRIPTION
  Holds the configuration lock, reloads the config file so the in-memory settings
  reflect what other sessions have saved, runs the change to modify
  $Script:PSTBSettings, then writes the file. Nothing is written if the change throws.

  Always change persisted settings through this function. Modifying a stale
  in-memory copy and exporting it overwrites other sessions' changes.

.PARAMETER Change
  The code that modifies $Script:PSTBSettings. It can read the caller's variables.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
Whatever the change outputs.
#>


function Update-PowerStubConfiguration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock] $Change
    )

    $lock = Enter-PowerStubConfigurationLock
    try {
        Import-PowerStubConfiguration
        & $Change
        Export-PowerStubConfiguration
    }
    finally {
        Exit-PowerStubConfigurationLock $lock
    }
}
