<#
.SYNOPSIS
  Releases the lock taken by Enter-PowerStubConfigurationLock.

.PARAMETER Lock
  The mutex returned by Enter-PowerStubConfigurationLock. Null is ignored so this
  is safe to call from a finally block when the lock was never acquired.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
None.
#>


function Exit-PowerStubConfigurationLock {
    [CmdletBinding()]
    param (
        [System.Threading.Mutex] $Lock
    )

    if ($Lock) {
        $Lock.ReleaseMutex()
        $Lock.Dispose()
    }
}
