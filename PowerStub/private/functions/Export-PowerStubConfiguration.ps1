<#
.SYNOPSIS
  Exports configuration to the configuration file.

.DESCRIPTION
  Serializes the current configuration (excluding internal keys) to JSON
  and writes it to the config file using atomic write (temp + rename).

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
None.
#>


function Export-PowerStubConfiguration {
    $noExport = Get-PowerStubConfigurationKey 'InternalConfigKeys'
    $fileName = Get-PowerStubConfigurationKey 'ConfigFile'

    # Ensure config directory exists
    $configDir = Split-Path $fileName -Parent
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $exportConfig = @{}
    foreach ($key in $Script:PSTBSettings.Keys) {
        #do not export values for internal keys
        if ($noExport -contains $key) { continue }
        $exportConfig[$key] = $Script:PSTBSettings[$key]
    }

    $hashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
    $pathBytes = [System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($fileName).ToUpperInvariant())
    $hash = [System.BitConverter]::ToString($hashAlgorithm.ComputeHash($pathBytes)).Replace('-', '')
    $mutexName = "PowerStubConfig-$hash"
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $lockTaken = $false
    $tempFile = Join-Path $configDir "$([System.IO.Path]::GetFileName($fileName)).$PID.$([guid]::NewGuid()).tmp"

    try {
        $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $lockTaken) {
            throw "Timed out waiting to write PowerStub configuration file '$fileName'."
        }

        # Atomic write: write to a process-unique temp file, then rename into place.
        $exportConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tempFile -Encoding UTF8
        # File.Move with overwrite replaces the destination in one step. Move-Item -Force
        # deletes the destination first, leaving a window where readers see no config.
        # The move fails briefly while another process has the config open for reading, so retry.
        for ($attempt = 1; ; $attempt++) {
            try {
                [System.IO.File]::Move($tempFile, $fileName, $true)
                break
            }
            catch [System.UnauthorizedAccessException], [System.IO.IOException] {
                if ($attempt -ge 20) { throw }
                Start-Sleep -Milliseconds 25
            }
        }
        $Script:PSTBSettings['ConfigFileLastWriteUtc'] = (Get-Item -LiteralPath $fileName).LastWriteTimeUtc
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if ($lockTaken) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
        $hashAlgorithm.Dispose()
    }
}
