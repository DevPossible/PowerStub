#Requires -Modules Pester
<#
.SYNOPSIS
    Tests that the saved configuration survives concurrent sessions, bad files and unsafe aliases.

.DESCRIPTION
    Covers:
    - POWERSTUB_CONFIG_DIR override (what keeps every test file away from the real config)
    - Module load never writes the config file
    - Changes made by another session are merged, not overwritten (lost update)
    - Blank or corrupt config files are preserved and do not stop the module loading
    - Legacy migration ignores the empty PowerStub.json shipped with the module
    - Direct aliases cannot use reserved names or replace existing commands on module load
    - Remove-PowerStub also removes the stub's direct aliases

.NOTES
    Run with: Invoke-Pester ./tests/ConfigSafety.tests.ps1
#>

BeforeAll {
    $existing = Get-Module -Name 'PowerStub'
    if ($existing) {
        Remove-Module -ModuleInfo $existing -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

    $script:ModulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $script:ModulePath -Force

    $script:ConfigFile = Join-Path $script:TestConfigDir 'config.json'
    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'

    # Simulates another session saving a change: edits the file without touching this session's memory
    function Edit-ConfigFileExternally {
        param([scriptblock]$Edit)

        $config = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        & $Edit $config
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

Describe "Config location" {
    It "Get-PowerStubConfiguration_WithConfigDirOverride_UsesOverrideDirectory" {
        (Get-PowerStubConfiguration)['ConfigFile'] | Should -Be $script:ConfigFile
    }
}

Describe "Module load" {
    It "ImportModule_WithExistingConfig_DoesNotRewriteConfigFile" {
        Import-PowerStubConfiguration -Reset
        $before = (Get-Item -LiteralPath $script:ConfigFile).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50

        Import-Module $script:ModulePath -Force

        (Get-Item -LiteralPath $script:ConfigFile).LastWriteTimeUtc | Should -Be $before
    }

    It "ImportModule_WithNoConfigAndOnlyShippedLegacyFile_DoesNotCreateConfigFile" {
        Remove-Item -LiteralPath $script:ConfigFile -Force -ErrorAction SilentlyContinue

        Import-Module $script:ModulePath -Force

        Test-Path -LiteralPath $script:ConfigFile | Should -Be $false
    }
}

Describe "Changes from other sessions" {
    BeforeEach {
        Import-PowerStubConfiguration -Reset
    }

    It "NewPowerStub_AfterAnotherSessionAddedStub_KeepsBothStubs" {
        Edit-ConfigFileExternally { param($c) $c['Stubs']['OtherSessionStub'] = 'C:\Other' }

        New-PowerStub -Name 'ThisSessionStub' -Path $script:SampleStubRoot

        $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
        $saved.Stubs.PSObject.Properties.Name | Should -Contain 'OtherSessionStub'
        $saved.Stubs.PSObject.Properties.Name | Should -Contain 'ThisSessionStub'
    }

    It "RemovePowerStub_AfterAnotherSessionAddedStub_KeepsOtherStub" {
        New-PowerStub -Name 'ThisSessionStub' -Path $script:SampleStubRoot
        Edit-ConfigFileExternally { param($c) $c['Stubs']['OtherSessionStub'] = 'C:\Other' }

        Remove-PowerStub -Name 'ThisSessionStub'

        $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
        $saved.Stubs.PSObject.Properties.Name | Should -Contain 'OtherSessionStub'
        $saved.Stubs.PSObject.Properties.Name | Should -Not -Contain 'ThisSessionStub'
    }

    It "EnablePowerStubBetaCommands_AfterAnotherSessionAddedStub_KeepsStub" {
        Edit-ConfigFileExternally { param($c) $c['Stubs']['OtherSessionStub'] = 'C:\Other' }

        Enable-PowerStubBetaCommands

        $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
        $saved.Stubs.PSObject.Properties.Name | Should -Contain 'OtherSessionStub'
        $saved.'EnablePrefix:Beta' | Should -Be $true
    }

    It "NewPowerStubDirectAlias_AfterAnotherSessionAddedAlias_KeepsBothAliases" {
        New-PowerStub -Name 'SampleStub' -Path $script:SampleStubRoot
        Edit-ConfigFileExternally { param($c) $c['DirectAliases'] = @{ otheralias = 'SampleStub' } }

        try {
            New-PowerStubDirectAlias -AliasName 'pstbthisalias' -Stub 'SampleStub' | Out-Null

            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
            $saved.DirectAliases.PSObject.Properties.Name | Should -Contain 'otheralias'
            $saved.DirectAliases.PSObject.Properties.Name | Should -Contain 'pstbthisalias'
        }
        finally {
            Remove-Item 'function:global:pstbthisalias' -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "Blank or corrupt config file" {
    AfterEach {
        Get-ChildItem -LiteralPath $script:TestConfigDir -Filter 'config.json.corrupt-*' | Remove-Item -Force
        Import-PowerStubConfiguration -Reset
    }

    It "ImportModule_WithCorruptConfig_LoadsAndKeepsCopyOfBadFile" {
        '{"Stubs": {"Real' | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8

        { Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue } | Should -Not -Throw

        Get-Command pstb -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        $copy = @(Get-ChildItem -LiteralPath $script:TestConfigDir -Filter 'config.json.corrupt-*')
        $copy.Count | Should -BeGreaterThan 0
        Get-Content -LiteralPath $copy[0].FullName -Raw | Should -Match 'Real'
    }

    It "ImportPowerStubConfiguration_WithBlankConfig_WarnsAndKeepsCurrentSettings" {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name 'SampleStub' -Path $script:SampleStubRoot
        Set-Content -LiteralPath $script:ConfigFile -Value '' -Encoding UTF8

        Import-PowerStubConfiguration -WarningVariable warnings -WarningAction SilentlyContinue

        $warnings | Should -Not -BeNullOrEmpty
        (Get-PowerStubs).Keys | Should -Contain 'SampleStub'
    }
}

Describe "Legacy config migration" {
    It "ImportPowerStubConfiguration_WithLegacyFileContainingStubs_MigratesIt" {
        $legacyFile = Join-Path $script:TestConfigDir 'legacy-PowerStub.json'
        @{ Stubs = @{ LegacyStub = 'C:\Legacy' }; InvokeAlias = 'pstb' } |
            ConvertTo-Json | Set-Content -LiteralPath $legacyFile -Encoding UTF8
        Remove-Item -LiteralPath $script:ConfigFile -Force -ErrorAction SilentlyContinue

        InModuleScope PowerStub -Parameters @{ LegacyFile = $legacyFile } {
            $Script:PSTBSettings = Get-PowerStubConfigurationDefaults
            $Script:PSTBSettings['LegacyConfigFile'] = $LegacyFile
            Import-PowerStubConfiguration 6>$null
        }

        (Get-PowerStubs).Keys | Should -Contain 'LegacyStub'
        $saved = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json
        $saved.Stubs.PSObject.Properties.Name | Should -Contain 'LegacyStub'
    }
}

Describe "Direct alias safety" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name 'SampleStub' -Path $script:SampleStubRoot
    }

    It "NewPowerStubDirectAlias_WithReservedName_Throws" {
        { New-PowerStubDirectAlias -AliasName 'git' -Stub 'SampleStub' -Force } | Should -Throw '*reserved*'
    }

    It "ImportModule_WithAliasNamedLikeExistingCommand_DoesNotReplaceIt" {
        # 'pwsh' is always a real application while these tests run
        Edit-ConfigFileExternally { param($c) $c['DirectAliases'] = @{ pwsh = 'SampleStub' } }

        Import-Module $script:ModulePath -Force -WarningAction SilentlyContinue

        (Get-Command pwsh).CommandType | Should -Be 'Application'
    }

    It "RemovePowerStub_WithDirectAlias_RemovesAliasFromConfigAndSession" {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name 'AliasedStub' -Path $script:SampleStubRoot
        New-PowerStubDirectAlias -AliasName 'pstbaliased' -Stub 'AliasedStub' | Out-Null

        Remove-PowerStub -Name 'AliasedStub'

        (Get-PowerStubConfiguration)['DirectAliases'].Keys | Should -Not -Contain 'pstbaliased'
        Test-Path 'function:global:pstbaliased' | Should -Be $false
    }
}
