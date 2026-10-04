#Requires -Modules Pester
<#
.SYNOPSIS
    Regression tests for command success, failure, streams, and pipeline chaining.

.DESCRIPTION
    These tests run in the regular release gate. The first three assertions previously
    lived in KnownIssues.tests.ps1, excluded from CI. Cover both scripts and real native
    processes through pstb and direct aliases, including fresh pwsh -Command processes.
#>

BeforeAll {
    $existing = Get-Module -Name PowerStub
    if ($existing) { Remove-Module -ModuleInfo $existing -Force }

    $script:OriginalConfigDir = $env:POWERSTUB_CONFIG_DIR
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

AfterAll {
    Remove-Module -Name PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:OriginalConfigDir
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Describe 'Failure is visible to $? and && / ||' {
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

Describe '<Kind> target via <Entry> with <Preference> error preference' -ForEach @(
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

Describe 'Fresh pwsh -Command process exit status' -ForEach @(
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

Describe 'Merged PowerShell stream routing through <Entry>' -ForEach 'pstb', 'pstbstatus' {
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
