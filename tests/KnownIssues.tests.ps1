#Requires -Modules Pester
<#
.SYNOPSIS
    Tests for known, not yet fixed, argument-passing bugs. THESE ARE EXPECTED TO FAIL.

.DESCRIPTION
    Each test asserts the CORRECT behavior, so it fails today and passes once the bug is fixed.
    All of them are tagged 'KnownIssue', which dev-test.ps1 and the CI pipelines exclude, so
    they do not block a release. When a bug is fixed, move its test into the regular suite.

    Covers:
    - .exe commands crash on any argument starting with '-'
    - $? and the && / || operators report success after a failed command
    - Direct aliases do not re-parse splatted named parameters the way pstb does
    - Re-parsed array parameters keep only their first value
    - Empty-string arguments are dropped

.NOTES
    Run with: Invoke-Pester ./tests/KnownIssues.tests.ps1
#>

BeforeAll {
    $existing = Get-Module -Name 'PowerStub'
    if ($existing) {
        Remove-Module -ModuleInfo $existing -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

    $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $modulePath -Force

    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'
    New-PowerStub -Name 'SampleStub' -Path $script:SampleStubRoot -Force
    New-PowerStubDirectAlias -AliasName 'pstbknown' -Stub 'SampleStub' -Force | Out-Null

    # Helper: parse arg-dump JSON output
    function Get-ArgDumpResult {
        param([string[]]$Output)
        $jsonLine = $Output | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1
        if ($jsonLine) { return $jsonLine | ConvertFrom-Json }
        return $null
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

Describe "Known issue: .exe commands and dash arguments" -Tag 'KnownIssue' {
    BeforeAll {
        $script:ExeStubPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubKnownExe_$(Get-Random)"
        $exeCommandsPath = Join-Path $script:ExeStubPath 'Commands'
        New-Item -Path $exeCommandsPath -ItemType Directory -Force | Out-Null
        if ($IsWindows) {
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exeCommandsPath
        }
        New-PowerStub -Name 'KnownExeStub' -Path $script:ExeStubPath -Force
    }

    AfterAll {
        Remove-Item -LiteralPath $script:ExeStubPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Get-Command returns no Parameters for an application, and the named-parameter
    # re-parse in Invoke-PowerStubCommand calls .ContainsKey() on that null.
    It "InvokePowerStubCommand_ExeWithDashArgument_PassesArgumentThrough" -Skip:(-not $IsWindows) {
        $output = pstb KnownExeStub cmd /c echo -v 6>$null

        $output | Should -Be '-v'
    }
}

Describe "Known issue: failure is not visible to `$? and && / ||" -Tag 'KnownIssue' {
    # Invoke-CheckedCommand ends its failure path with an assignment to $LASTEXITCODE,
    # which succeeds, so the caller always sees success.
    It "InvokePowerStubCommand_CommandExitsNonZero_SetsDollarQuestionToFalse" {
        pstb SampleStub exit-code -Code 7 *> $null
        $succeeded = $?

        $succeeded | Should -Be $false
    }

    It "InvokePowerStubCommand_CommandExitsNonZero_DoesNotRunAndAndChain" {
        $chained = & { pstb SampleStub exit-code -Code 7 *> $null && 'continued' }

        $chained | Should -BeNullOrEmpty
    }

    It "InvokePowerStubCommand_CommandExitsNonZero_RunsOrOrChain" {
        $chained = & { pstb SampleStub exit-code -Code 7 *> $null || 'fallback' }

        $chained | Should -Be 'fallback'
    }
}

Describe "Known issue: named parameters passed by array splat" -Tag 'KnownIssue' {
    # An array splat delivers '-Name value' as positional strings. pstb re-parses them into
    # named parameters; the generated direct-alias function does not.
    It "DirectAlias_SplattedNamedParameter_BindsLikePstb" {
        $splat = @('-StringParam', 'hello')

        $viaPstb = Get-ArgDumpResult (pstb SampleStub arg-dump @splat 6>$null)
        $viaAlias = Get-ArgDumpResult (pstbknown arg-dump @splat 6>$null)

        $viaPstb.BoundParameters.StringParam.Value | Should -Be 'hello'
        $viaAlias.BoundParameters.StringParam.Value | Should -Be 'hello'
    }

    # The re-parse takes a single token as the value, so the rest of an array spills into positional args.
    It "InvokePowerStubCommand_SplattedArrayParameter_KeepsAllValues" {
        $splat = @('-ArrayParam', 'a', 'b', 'c')

        $result = Get-ArgDumpResult (pstb SampleStub arg-dump @splat 6>$null)

        @($result.BoundParameters.ArrayParam.Value).Count | Should -Be 3
    }
}

Describe "Known issue: empty-string arguments are dropped" -Tag 'KnownIssue' {
    # Calling the script directly passes '' through as one argument; the proxy loses it.
    It "InvokePowerStubCommand_EmptyStringArgument_IsPassedThrough" {
        $direct = & (Join-Path $script:SampleStubRoot 'Commands\arg-echo.ps1') ''
        $proxied = pstb SampleStub arg-echo '' 6>$null

        $direct | Should -Contain 'ARG_COUNT:1'
        $proxied | Should -Contain 'ARG_COUNT:1'
    }
}
