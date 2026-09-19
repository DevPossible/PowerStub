#Requires -Modules Pester
<#
.SYNOPSIS
    Tests for known, not yet fixed, argument-passing bugs. THESE ARE EXPECTED TO FAIL.

.DESCRIPTION
    Each test asserts the CORRECT behavior, so it fails today and passes once the bug is fixed.
    All of them are tagged 'KnownIssue', which dev-test.ps1 and the CI pipelines exclude, so
    they do not block a release. When a bug is fixed, move its test into the regular suite.

    Covers:
    - $? and the && / || operators report success after a failed command

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

}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
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
