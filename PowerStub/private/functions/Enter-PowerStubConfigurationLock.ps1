<#
.SYNOPSIS
  Acquires the cross-process configuration lock.

.DESCRIPTION
  Serializes access to the configuration file across all PowerShell sessions using
  a named mutex derived from the config file path. The lock is re-entrant, so code
  holding it may call other functions that take it again.

  Always release with Exit-PowerStubConfigurationLock in a finally block.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
System.Threading.Mutex. The held lock, to pass to Exit-PowerStubConfigurationLock.
#>


function Enter-PowerStubConfigurationLock {
    [CmdletBinding()]
    param ()

    $fileName = Get-PowerStubConfigurationKey 'ConfigFile'

    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($fileName).ToUpperInvariant())
    $hash = [System.BitConverter]::ToString($hashAlgorithm.ComputeHash($pathBytes)).Replace('-', '')
    $hashAlgorithm.Dispose()

    $mutex = [System.Threading.Mutex]::new($false, "PowerStubConfig-$hash")
    try {
        $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
    }
    catch [System.Threading.AbandonedMutexException] {
        # The previous owner died without releasing; the lock is ours now.
        $lockTaken = $true
    }

    if (-not $lockTaken) {
        $mutex.Dispose()
        throw "Timed out waiting for the PowerStub configuration lock for '$fileName'."
    }

    return $mutex
}
