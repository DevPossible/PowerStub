<#
.SYNOPSIS
  Unregisters a PowerStub from the configuration.

.DESCRIPTION
  Removes a PowerStub from the configuration, but does not delete any files or folders.
  The stub can be re-registered later with New-PowerStub. This only removes the stub
  from the registry; the actual command files remain on disk.

.PARAMETER Name
  The name of the stub to remove.

.INPUTS
  None. You cannot pipe objects to this function.

.OUTPUTS
  None. Updates the configuration by removing the stub.

.EXAMPLE
  Remove-PowerStub -Name "OldStub"

  Unregisters the "OldStub" stub while preserving its files.

.EXAMPLE
  Remove-PowerStub DevOps

  Removes the DevOps stub registration (positional parameter).

#>

function Remove-PowerStub {
    param(
        [string]$name
    )

    # Remove only this stub (and the direct aliases pointing at it) so other sessions' changes are kept
    $removedAliases = Update-PowerStubConfiguration {
        $stubs = $Script:PSTBSettings['Stubs']
        if (-not $stubs.ContainsKey($name)) {
            throw "Stub $name does not exist."
        }
        $stubs.Remove($name)

        $directAliases = $Script:PSTBSettings['DirectAliases']
        if ($directAliases) {
            foreach ($aliasName in @($directAliases.Keys | Where-Object { $directAliases[$_] -eq $name })) {
                $directAliases.Remove($aliasName)
                $aliasName
            }
            $Script:PSTBSettings['ForcedDirectAliases'] = @($Script:PSTBSettings['ForcedDirectAliases'] | Where-Object { $_ -and $directAliases.ContainsKey($_) })
        }
    }

    foreach ($aliasName in $removedAliases) {
        # Note: Remove-Item does nothing for a 'function:global:' path; the unqualified path works
        if (Test-Path "function:$aliasName") {
            Remove-Item "function:$aliasName" -Force
        }
    }
}
