#Requires -Modules Pester
<#
.SYNOPSIS
    Regression tests for command success, failure, streams, and pipeline chaining.

.DESCRIPTION
    These tests run in the regular release gate. The first three assertions previously
    lived in KnownIssues.tests.ps1, excluded from CI. Cover both scripts and real native
    processes through pstb and direct aliases, including fresh pwsh -Command processes.
#>

Describe 'Execution status and target error semantics' {
    BeforeAll {
        $existing = Get-Module -Name PowerStub
        if ($existing) { Remove-Module -ModuleInfo $existing -Force }

        $script:OriginalConfigDir = $env:POWERSTUB_CONFIG_DIR
        $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks
        $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBStatus_$([guid]::NewGuid())"
        $env:POWERSTUB_CONFIG_DIR = Join-Path $script:TestRoot 'config'
        $script:ModulePath = (Resolve-Path (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psm1')).Path
        Import-Module $script:ModulePath -Force

        $script:CommandsPath = Join-Path $script:TestRoot 'stub/Commands'
        New-Item -ItemType Directory -Path $script:CommandsPath -Force | Out-Null
        @'
    param([int]$Code)
    Write-Output "stdout-$Code"
    Write-Error "stderr-$Code" -ErrorAction Continue
    exit $Code
'@ | Set-Content (Join-Path $script:CommandsPath 'script.ps1')

        @'
    Write-Output 'before'
    Write-Error 'target-error' -ErrorAction Continue
    Write-Warning 'target-warning'
    Write-Verbose 'target-verbose' -Verbose
    Write-Debug 'target-debug' -Debug
    Write-Information 'target-information' -InformationAction Continue
    Write-Output 'after'
    exit 0
'@ | Set-Content (Join-Path $script:CommandsPath 'streams.ps1')

        'throw [InvalidOperationException]::new("target-throw")' |
            Set-Content (Join-Path $script:CommandsPath 'throw.ps1')
        'Write-Error "target-stop" -ErrorAction Stop' |
            Set-Content (Join-Path $script:CommandsPath 'error-stop.ps1')
        @'
    [CmdletBinding()]
    param()
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('target-terminating'),
        'TargetTerminatingFailure', [System.Management.Automation.ErrorCategory]::InvalidOperation, 'target')
    $PSCmdlet.ThrowTerminatingError($errorRecord)
'@ | Set-Content (Join-Path $script:CommandsPath 'terminating.ps1')
        @'
    [CmdletBinding()]
    param()
    $errorRecord = [System.Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new('target-nonterminating'),
        'TargetNonTerminatingFailure', [System.Management.Automation.ErrorCategory]::InvalidOperation, 'target')
    $PSCmdlet.WriteError($errorRecord)
'@ | Set-Content (Join-Path $script:CommandsPath 'nonterminating.ps1')
        'Write-Error "target-simple-error" -ErrorAction Continue' |
            Set-Content (Join-Path $script:CommandsPath 'simple-error.ps1')

        # A real platform shell tests native process status on every supported platform,
        # without requiring a compiler or treating a .ps1 script as an executable.
        $nativeShell = if ($IsWindows) { Join-Path $env:SystemRoot 'System32/cmd.exe' } else { '/bin/sh' }
        Copy-Item -LiteralPath $nativeShell -Destination (Join-Path $script:CommandsPath 'native.exe')
        New-PowerStub -Name StatusStub -Path (Join-Path $script:TestRoot 'stub') -Force
        New-PowerStubDirectAlias -AliasName pstbstatus -Stub StatusStub -Force | Out-Null

        function Get-StatusArguments {
            param([string]$Kind, [int]$Code)
            if ($Kind -eq 'script') { return ,@($Code) }
            if ($IsWindows) { return ,@('/d', '/c', "echo stdout-$Code& echo stderr-$Code 1>&2& exit /b $Code") }
            return ,@('-c', "printf 'stdout-$Code\n'; printf 'stderr-$Code\n' >&2; exit $Code")
        }

        $script:PwshPath = (Get-Process -Id $PID).Path
    }

    # Pester runs each It in its own local scope. Module functions inherit the runspace
    # preference variables, so set and restore those as well as each test's local values.
    BeforeEach {
        $script:SavedErrorPreference = $global:ErrorActionPreference
        $script:SavedNativePreference = Get-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction Ignore
        $script:SavedNativeValue = if ($script:SavedNativePreference) { $script:SavedNativePreference.Value }
        $preferenceValue = Get-Variable Preference -ValueOnly -ErrorAction Ignore
        $global:ErrorActionPreference = if ($preferenceValue) { $preferenceValue } else { 'Continue' }
        $global:PSNativeCommandUseErrorActionPreference = $false
    }

    AfterEach {
        $global:ErrorActionPreference = $script:SavedErrorPreference
        if ($script:SavedNativePreference) {
            $global:PSNativeCommandUseErrorActionPreference = $script:SavedNativeValue
        }
        else {
            Remove-Variable PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue
        }
    }

    AfterAll {
        Remove-Module -Name PowerStub -Force -ErrorAction SilentlyContinue
        $env:POWERSTUB_CONFIG_DIR = $script:OriginalConfigDir
        Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:TestRoot) {
            Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
        }
    }

    Context 'Failure is visible to $? and && / ||' {
        It 'CommandExitsNonZero_SetsDollarQuestionToFalse' {
            pstb StatusStub script 7 *> $null
            $succeeded = $?
            $succeeded | Should -BeFalse
        }

        It 'CommandExitsNonZero_DoesNotRunAndAndChain' {
            $chained = & { pstb StatusStub script 7 *> $null && 'continued' }
            $chained | Should -BeNullOrEmpty
        }

        It 'CommandExitsNonZero_RunsOrOrChain' {
            $chained = & { pstb StatusStub script 7 *> $null || 'fallback' }
            $chained | Should -Be 'fallback'
        }
    }

    Context '<Kind> target via <Entry> with <Preference> error preference' -ForEach @(
        foreach ($kind in 'script', 'native') {
            foreach ($entry in 'pstb', 'pstbstatus') {
                foreach ($preference in 'Continue', 'Stop') {
                    @{ Kind = $kind; Entry = $entry; Preference = $preference }
                }
            }
        }
    ) {
        BeforeAll {
            $prefix = @($Kind)
            if ($Entry -eq 'pstb') { $prefix = @('StatusStub', $Kind) }
            $failureArgs = $prefix + (Get-StatusArguments $Kind 7)
            $successArgs = $prefix + (Get-StatusArguments $Kind 0)
        }

        It 'Preserves failure status and exit code without terminating the caller' {
            $ErrorActionPreference = $Preference
            $PSNativeCommandUseErrorActionPreference = $false
            & $Entry @failureArgs *> $null
            $succeeded = $?
            $exitCode = $LASTEXITCODE
            $succeeded | Should -BeFalse
            $exitCode | Should -Be 7
        }

        It 'Skips && and runs || after failure' {
            $ErrorActionPreference = $Preference
            $PSNativeCommandUseErrorActionPreference = $false
            $and = & { & $Entry @failureArgs *> $null && 'continued' }
            $or = & { & $Entry @failureArgs *> $null || 'fallback' }
            $and | Should -BeNullOrEmpty
            $or | Should -Be 'fallback'
        }

        It 'Preserves success status and clears a previous nonzero exit code' {
            $ErrorActionPreference = $Preference
            $PSNativeCommandUseErrorActionPreference = $false
            & $Entry @failureArgs *> $null
            & $Entry @successArgs *> $null
            $succeeded = $?
            $exitCode = $LASTEXITCODE
            $succeeded | Should -BeTrue
            $exitCode | Should -Be 0
        }

        It 'Runs && and skips || after success' {
            $ErrorActionPreference = $Preference
            $PSNativeCommandUseErrorActionPreference = $false
            $and = & { & $Entry @successArgs *> $null && 'continued' }
            $or = & { & $Entry @successArgs *> $null || 'fallback' }
            $and | Should -Be 'continued'
            $or | Should -BeNullOrEmpty
        }

        It 'Preserves merged stdout and stderr, without duplicate or synthetic errors' {
            $ErrorActionPreference = $Preference
            $PSNativeCommandUseErrorActionPreference = $false
            $extension = if ($Kind -eq 'script') { 'ps1' } else { 'exe' }
            $target = Join-Path $script:CommandsPath "$Kind.$extension"
            $targetArgs = Get-StatusArguments $Kind 7
            $direct = & $target @targetArgs 2>&1
            $proxied = & $Entry @failureArgs 2>&1 6>$null
            # Native stdout/stderr interleaving is asynchronous; compare their contents.
            # PowerShell script stream order is deterministic and must remain unchanged.
            $directText = @($direct | ForEach-Object { "$_" })
            $proxyText = @($proxied | ForEach-Object { "$_" })
            if ($Kind -eq 'native') {
                $directText = @($directText | Sort-Object)
                $proxyText = @($proxyText | Sort-Object)
            }
            $proxyText | Should -Be $directText
            @($proxied).Count | Should -Be 2
        }
    }

    Context 'Fresh pwsh -Command process exit status' -ForEach @(
        foreach ($kind in 'script', 'native') {
            foreach ($entry in 'pstb', 'pstbstatus') {
                foreach ($code in 0, 7) { @{ Kind = $kind; Entry = $entry; Code = $code } }
            }
        }
    ) {
        It '<Kind> via <Entry>, target exit <Code>, matches direct process result' {
            $extension = if ($Kind -eq 'script') { 'ps1' } else { 'exe' }
            $target = (Join-Path $script:CommandsPath "$Kind.$extension").Replace("'", "''")
            $module = $script:ModulePath.Replace("'", "''")
            $targetArgs = Get-StatusArguments $Kind $Code
            $arguments = ($targetArgs | ForEach-Object { "'$($_.ToString().Replace("'", "''"))'" }) -join ', '
            $prefix = if ($Entry -eq 'pstb') { "pstb StatusStub $Kind" } else { "pstbstatus $Kind" }
            $direct = "`$PSNativeCommandUseErrorActionPreference = `$false; `$a = @($arguments); & '$target' @a *> `$null"
            $proxied = "`$PSNativeCommandUseErrorActionPreference = `$false; Import-Module '$module'; `$a = @($arguments); $prefix @a *> `$null"
            & $script:PwshPath -NoProfile -Command $direct
            $directExit = $LASTEXITCODE
            & $script:PwshPath -NoProfile -Command $proxied
            $proxyExit = $LASTEXITCODE
            $proxyExit | Should -Be $directExit
            $proxyExit | Should -Be $(if ($Code -eq 0) { 0 } else { 1 })
        }
    }

    Context 'Merged PowerShell stream routing through <Entry>' -ForEach 'pstb', 'pstbstatus' {
        BeforeAll { $Entry = $_ }

        It 'Keeps every target stream in order when all streams are redirected' {
            $direct = @(& (Join-Path $script:CommandsPath 'streams.ps1') *>&1)
            $invokeArgs = @('streams')
            if ($Entry -eq 'pstb') { $invokeArgs = @('StatusStub', 'streams') }
            $proxied = @(& $Entry @invokeArgs *>&1)
            $direct.Count | Should -Be 7
            $proxied.Count | Should -Be 8
            # PowerStub's existing invocation banner is the only extra record.
            "$($proxied[0])" | Should -BeLike 'Invoking *streams.ps1'
            $directRecords = @($direct | ForEach-Object { "$($_.GetType().FullName):$_" })
            $proxyRecords = @($proxied[1..7] | ForEach-Object { "$($_.GetType().FullName):$_" })
            $proxyRecords | Should -Be $directRecords
        }
    }

    Context 'Target error semantics through <Entry> with <Preference>' -ForEach @(
        foreach ($entry in 'pstb', 'pstbstatus') {
            foreach ($preference in 'Continue', 'Stop') { @{ Entry = $entry; Preference = $preference } }
        }
    ) {
        It 'Preserves <Target> terminating exception identity and caller catch behavior' -ForEach @(@{ Target = 'throw' }, @{ Target = 'error-stop' }, @{ Target = 'terminating' }) {
            $ErrorActionPreference = $Preference
            $directError = $null
            $proxyError = $null
            try { & (Join-Path $script:CommandsPath "$Target.ps1") *> $null }
            catch { $directError = $_ }
            $invokeArgs = @($Target)
            if ($Entry -eq 'pstb') { $invokeArgs = @('StatusStub', $Target) }
            try { & $Entry @invokeArgs *> $null }
            catch { $proxyError = $_ }
            $directError | Should -Not -BeNullOrEmpty
            $proxyError | Should -Not -BeNullOrEmpty
            $proxyError.Exception.GetType().FullName | Should -Be $directError.Exception.GetType().FullName
            $proxyError.Exception.Message | Should -Be $directError.Exception.Message
            $proxyError.FullyQualifiedErrorId | Should -Be $directError.FullyQualifiedErrorId
            $proxyError.CategoryInfo.Category | Should -Be $directError.CategoryInfo.Category
        }

        It 'Preserves native-error preference failures and success recovery' -Skip:($PSVersionTable.PSVersion -lt [version]'7.4') {
            # Module functions inherit runspace preferences rather than Pester's local It
            # scope. Set and restore the globals to model a user's top-level preferences.
            $oldErrorPreference = $global:ErrorActionPreference
            $oldNativePreference = $global:PSNativeCommandUseErrorActionPreference
            try {
                $global:ErrorActionPreference = $Preference
                $global:PSNativeCommandUseErrorActionPreference = $true
                $ErrorActionPreference = $Preference
                $directError = $null
                $proxyError = $null
                $targetArgs = Get-StatusArguments native 7
                try {
                    & (Join-Path $script:CommandsPath 'native.exe') @targetArgs *> $null
                    $directSuccess = $?
                }
                catch { $directError = $_ }
                $directCode = $LASTEXITCODE
                $invokeArgs = @('native') + $targetArgs
                if ($Entry -eq 'pstb') { $invokeArgs = @('StatusStub', 'native') + $targetArgs }
                try {
                    & $Entry @invokeArgs *> $null
                    $proxySuccess = $?
                }
                catch { $proxyError = $_ }
                $proxyCode = $LASTEXITCODE
                $proxyCode | Should -Be 7
                $proxyCode | Should -Be $directCode
                if ($Preference -eq 'Stop') {
                    $directError | Should -Not -BeNullOrEmpty
                    $proxyError | Should -Not -BeNullOrEmpty
                    $proxyError.Exception.GetType().FullName | Should -Be $directError.Exception.GetType().FullName
                    $proxyError.FullyQualifiedErrorId | Should -Be $directError.FullyQualifiedErrorId
                }
                else {
                    $directError | Should -BeNullOrEmpty
                    $proxyError | Should -BeNullOrEmpty
                    $directSuccess | Should -BeFalse
                    $proxySuccess | Should -BeFalse
                }
                $invokeArgs = @('native') + (Get-StatusArguments native 0)
                if ($Entry -eq 'pstb') { $invokeArgs = @('StatusStub', 'native') + (Get-StatusArguments native 0) }
                & $Entry @invokeArgs *> $null
                $success = $?
                $exitCode = $LASTEXITCODE
                $success | Should -BeTrue
                $exitCode | Should -Be 0
            }
            finally {
                $global:ErrorActionPreference = $oldErrorPreference
                $global:PSNativeCommandUseErrorActionPreference = $oldNativePreference
            }
        }
    }

    Context 'Non-terminating target error semantics through <Entry>' -ForEach 'pstb', 'pstbstatus' {
        BeforeAll { $Entry = $_ }

        It 'Preserves the direct success status of a <Target> target' -ForEach @(@{ Target = 'simple-error' }, @{ Target = 'nonterminating' }) {
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            & (Join-Path $script:CommandsPath "$Target.ps1") *> $null
            $directSuccess = $?
            $invokeArgs = @($Target)
            if ($Entry -eq 'pstb') { $invokeArgs = @('StatusStub', $Target) }
            & $Entry @invokeArgs *> $null
            $proxySuccess = $?
            $exitCode = $LASTEXITCODE
            $proxySuccess | Should -Be $directSuccess
            $proxySuccess | Should -Be ($Target -eq 'simple-error')
            $exitCode | Should -Be 0
        }
    }
}
