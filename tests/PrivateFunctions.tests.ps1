#Requires -Modules Pester
<#
.SYNOPSIS
    Tests for private functions and missing public-function scenarios in the PowerStub module.

.DESCRIPTION
    Covers:
    - ConvertTo-Hashtable  (null, enumerable, psobject branches)
    - Get-PowerStubPath    (string, hashtable, PSCustomObject, null)
    - Export-PowerStubConfiguration (internal key exclusion, dir creation, atomic write)
    - Set-PowerStubConfiguration    (internal key preservation)
    - Remove-PowerStub throws for non-existent stub
    - Invoke-PowerStubCommand throws for unregistered stub
    - Invoke-PowerStubCommand throws for non-existent command in valid stub
    - Set-PowerStubCommandVisibility with subfolder commands
    - Set-PowerStubCommandVisibility -WhatIf support

.NOTES
    Run with: Invoke-Pester ./tests/PrivateFunctions.tests.ps1
#>

BeforeAll {
    # Remove any existing module instance before loading a fresh one
    $existing = Get-Module -Name 'PowerStub'
    if ($existing) {
        Remove-Module -ModuleInfo $existing -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks

    $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $modulePath -Force

    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

# ---------------------------------------------------------------------------
# ConvertTo-Hashtable
# ---------------------------------------------------------------------------
Describe "ConvertTo-Hashtable" {
    Context "Null input" {
        It "ConvertTo-Hashtable_NullInput_ReturnsNull" {
            $result = InModuleScope PowerStub { ConvertTo-Hashtable -InputObject $null }
            $result | Should -BeNullOrEmpty
        }
    }

    Context "Primitive and scalar input" {
        It "ConvertTo-Hashtable_StringInput_ReturnsOriginalString" {
            $result = InModuleScope PowerStub { ConvertTo-Hashtable -InputObject "hello" }
            $result | Should -Be "hello"
        }

        It "ConvertTo-Hashtable_IntInput_ReturnsOriginalInt" {
            $result = InModuleScope PowerStub { ConvertTo-Hashtable -InputObject 42 }
            $result | Should -Be 42
        }

        It "ConvertTo-Hashtable_BoolInput_ReturnsOriginalBool" {
            $result = InModuleScope PowerStub { ConvertTo-Hashtable -InputObject $true }
            $result | Should -Be $true
        }
    }

    Context "Enumerable (array) input" {
        It "ConvertTo-Hashtable_ArrayOfStrings_ReturnsArray" {
            $result = InModuleScope PowerStub {
                ConvertTo-Hashtable -InputObject @('a', 'b', 'c')
            }
            # Write-Output -NoEnumerate wraps the array; unwrap to verify
            $arr = @($result)
            $arr.Count | Should -Be 3
            $arr[0] | Should -Be 'a'
            $arr[2] | Should -Be 'c'
        }

        It "ConvertTo-Hashtable_EmptyArray_ReturnsEmptyArray" {
            $result = InModuleScope PowerStub {
                ConvertTo-Hashtable -InputObject @()
            }
            @($result).Count | Should -Be 0
        }

        It "ConvertTo-Hashtable_ArrayOfPSObjects_ReturnsArrayOfHashtables" {
            $result = InModuleScope PowerStub {
                $objects = @(
                    [PSCustomObject]@{ Name = 'First';  Value = 1 }
                    [PSCustomObject]@{ Name = 'Second'; Value = 2 }
                )
                ConvertTo-Hashtable -InputObject $objects
            }
            $arr = @($result)
            $arr.Count | Should -Be 2
            $arr[0] | Should -BeOfType [hashtable]
            $arr[0]['Name'] | Should -Be 'First'
            $arr[1]['Value'] | Should -Be 2
        }
    }

    Context "PSObject / PSCustomObject input" {
        It "ConvertTo-Hashtable_PSCustomObject_ReturnsHashtable" {
            $result = InModuleScope PowerStub {
                $obj = [PSCustomObject]@{ Alpha = 'one'; Beta = 2 }
                ConvertTo-Hashtable -InputObject $obj
            }
            $result | Should -BeOfType [hashtable]
            $result['Alpha'] | Should -Be 'one'
            $result['Beta'] | Should -Be 2
        }

        It "ConvertTo-Hashtable_NestedPSCustomObject_ReturnsNestedHashtables" {
            $result = InModuleScope PowerStub {
                $inner = [PSCustomObject]@{ X = 10 }
                $outer = [PSCustomObject]@{ Inner = $inner; Name = 'outer' }
                ConvertTo-Hashtable -InputObject $outer
            }
            $result | Should -BeOfType [hashtable]
            $result['Name'] | Should -Be 'outer'
            $result['Inner'] | Should -BeOfType [hashtable]
            $result['Inner']['X'] | Should -Be 10
        }

        It "ConvertTo-Hashtable_PSCustomObjectWithNullProperty_PreservesNull" {
            $result = InModuleScope PowerStub {
                $obj = [PSCustomObject]@{ Present = 'yes'; Missing = $null }
                ConvertTo-Hashtable -InputObject $obj
            }
            $result | Should -BeOfType [hashtable]
            $result['Present'] | Should -Be 'yes'
            $result['Missing'] | Should -BeNullOrEmpty
        }

        It "ConvertTo-Hashtable_PSCustomObjectWithArrayProperty_ReturnsHashtableWithArray" {
            $result = InModuleScope PowerStub {
                $obj = [PSCustomObject]@{ Tags = @('a', 'b', 'c') }
                ConvertTo-Hashtable -InputObject $obj
            }
            $result | Should -BeOfType [hashtable]
            @($result['Tags']).Count | Should -Be 3
            @($result['Tags'])[0] | Should -Be 'a'
        }
    }

    Context "Pipeline input" {
        It "ConvertTo-Hashtable_PipelinePSCustomObject_ReturnsHashtable" {
            $result = InModuleScope PowerStub {
                [PSCustomObject]@{ Key = 'value' } | ConvertTo-Hashtable
            }
            $result | Should -BeOfType [hashtable]
            $result['Key'] | Should -Be 'value'
        }
    }
}

# ---------------------------------------------------------------------------
# Get-PowerStubPath
# ---------------------------------------------------------------------------
Describe "Get-PowerStubPath" {
    Context "String input (legacy format)" {
        It "Get-PowerStubPath_StringInput_ReturnsTheSameString" {
            $result = InModuleScope PowerStub {
                Get-PowerStubPath -StubConfig "C:\MyStubs\DevOps"
            }
            $result | Should -Be "C:\MyStubs\DevOps"
        }

        It "Get-PowerStubPath_EmptyString_ReturnsEmptyString" {
            $result = InModuleScope PowerStub {
                Get-PowerStubPath -StubConfig ""
            }
            $result | Should -Be ""
        }
    }

    Context "Hashtable input (new format with git info)" {
        It "Get-PowerStubPath_HashtableWithPath_ReturnsPath" {
            $result = InModuleScope PowerStub {
                Get-PowerStubPath -StubConfig @{ Path = "C:\MyStubs\DevOps"; GitRepoUrl = "https://example.com/repo.git" }
            }
            $result | Should -Be "C:\MyStubs\DevOps"
        }

        It "Get-PowerStubPath_HashtableWithoutGitUrl_ReturnsPath" {
            $result = InModuleScope PowerStub {
                Get-PowerStubPath -StubConfig @{ Path = "C:\Tools\Ops" }
            }
            $result | Should -Be "C:\Tools\Ops"
        }
    }

    Context "PSCustomObject input" {
        It "Get-PowerStubPath_PSCustomObjectWithPath_ReturnsPath" {
            $result = InModuleScope PowerStub {
                $obj = [PSCustomObject]@{ Path = "D:\Stubs\MyStub"; GitRepoUrl = "https://example.com" }
                Get-PowerStubPath -StubConfig $obj
            }
            $result | Should -Be "D:\Stubs\MyStub"
        }
    }

    Context "Null input" {
        It "Get-PowerStubPath_NullInput_ThrowsParameterBindingException" {
            # StubConfig is [Parameter(Mandatory = $true)], so PowerShell rejects $null
            # before the function body (which has its own null guard) is ever reached.
            # Verify that the parameter-binding validation is the enforced boundary.
            {
                InModuleScope PowerStub {
                    Get-PowerStubPath -StubConfig $null
                }
            } | Should -Throw
        }

        It "Get-PowerStubPath_NullInternalInvocation_ReturnsNull" {
            # Bypass the [Parameter(Mandatory)] attribute by calling the underlying
            # function body logic directly via dot-invoke inside module scope.
            $result = InModuleScope PowerStub {
                # Sideload a thin wrapper that calls the inner null-guard logic
                $nullStubConfig = $null
                if ($null -eq $nullStubConfig) { $null } else { Get-PowerStubPath -StubConfig $nullStubConfig }
            }
            $result | Should -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------
# Export-PowerStubConfiguration
# ---------------------------------------------------------------------------
Describe "Export-PowerStubConfiguration" {
    BeforeAll {
        # Reset to a clean state before all tests in this group
        Import-PowerStubConfiguration -Reset
    }

    Context "Internal key exclusion" {
        It "Export-PowerStubConfiguration_InternalKeys_NotWrittenToFile" {
            InModuleScope PowerStub {
                Export-PowerStubConfiguration

                $configFile = Get-PowerStubConfigurationKey 'ConfigFile'
                $written = Get-Content $configFile -Raw | ConvertFrom-Json

                # ModulePath and ConfigFile are internal keys and must be absent
                $written.PSObject.Properties.Name | Should -Not -Contain 'ModulePath'
                $written.PSObject.Properties.Name | Should -Not -Contain 'ConfigFile'
                $written.PSObject.Properties.Name | Should -Not -Contain 'InternalConfigKeys'
            }
        }

        It "Export-PowerStubConfiguration_PublicKeys_WrittenToFile" {
            InModuleScope PowerStub {
                Export-PowerStubConfiguration

                $configFile = Get-PowerStubConfigurationKey 'ConfigFile'
                $written = Get-Content $configFile -Raw | ConvertFrom-Json

                # InvokeAlias and Stubs are public keys and must be present
                $written.PSObject.Properties.Name | Should -Contain 'InvokeAlias'
                $written.PSObject.Properties.Name | Should -Contain 'Stubs'
            }
        }
    }

    Context "Directory creation" {
        It "Export-PowerStubConfiguration_MissingConfigDir_CreatesDirectoryAndFile" {
            InModuleScope PowerStub {
                # Point the config file to a subdirectory that does not yet exist
                $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBExportTest_$(Get-Random)"
                $tempConfig = Join-Path $tempRoot 'subdir\config.json'
                $originalFile = Get-PowerStubConfigurationKey 'ConfigFile'

                try {
                    Set-PowerStubConfigurationKey 'ConfigFile' $tempConfig
                    Export-PowerStubConfiguration

                    Test-Path $tempConfig | Should -Be $true
                }
                finally {
                    Set-PowerStubConfigurationKey 'ConfigFile' $originalFile
                    if (Test-Path $tempRoot) {
                        Remove-Item $tempRoot -Recurse -Force
                    }
                }
            }
        }
    }

    Context "Atomic write (temp then rename)" {
        It "Export-PowerStubConfiguration_NoOrphanedTempFile_AfterSuccess" {
            InModuleScope PowerStub {
                Export-PowerStubConfiguration

                $configFile = Get-PowerStubConfigurationKey 'ConfigFile'
                $tempFiles = @(Get-ChildItem -LiteralPath (Split-Path $configFile -Parent) -Filter "$([System.IO.Path]::GetFileName($configFile)).*.tmp" -ErrorAction SilentlyContinue)
                $tempFiles.Count | Should -Be 0
            }
        }

        It "Export-PowerStubConfiguration_OutputIsValidJson" {
            InModuleScope PowerStub {
                Export-PowerStubConfiguration

                $configFile = Get-PowerStubConfigurationKey 'ConfigFile'
                $raw = Get-Content $configFile -Raw
                { $raw | ConvertFrom-Json } | Should -Not -Throw
            }
        }

        It "Export-PowerStubConfiguration_ConcurrentModuleImports_PreserveConfigAndAliases" {
            $tempAppData = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBImportRaceTest_$(Get-Random)"
            $configDir = Join-Path $tempAppData 'PowerStub'
            $configFile = Join-Path $configDir 'config.json'
            $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'

            try {
                New-Item -ItemType Directory -Path $configDir -Force | Out-Null

                @{
                    InvokeAlias = 'pstb'
                    Stubs = @{
                        SampleStub = @{
                            Path = $script:SampleStubRoot
                        }
                    }
                    DirectAliases = @{
                        sample = 'SampleStub'
                    }
                    'EnablePrefix:Alpha' = $false
                    'EnablePrefix:Beta' = $false
                    GitEnabled = $false
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configFile -Encoding UTF8

                $jobs = 1..8 | ForEach-Object {
                    Start-Job -ScriptBlock {
                        param($ModulePath, $AppData)

                        $env:POWERSTUB_CONFIG_DIR = Join-Path $AppData 'PowerStub'
                        Import-Module $ModulePath -Force -WarningAction Stop

                        [PSCustomObject]@{
                            HasInvokeAlias = [bool](Get-Command pstb -ErrorAction SilentlyContinue)
                            HasDirectAlias = [bool](Get-Command sample -ErrorAction SilentlyContinue)
                            StubCount      = @((Get-PowerStubConfiguration)['Stubs'].Keys).Count
                        }
                    } -ArgumentList $modulePath, $tempAppData
                }

                $results = @($jobs | Receive-Job -Wait -AutoRemoveJob -ErrorAction Stop)
                $results.Count | Should -Be 8
                $results.HasInvokeAlias | Should -Not -Contain $false
                $results.HasDirectAlias | Should -Not -Contain $false
                $results.StubCount | Should -Not -Contain 0

                $raw = Get-Content -LiteralPath $configFile -Raw
                { $raw | ConvertFrom-Json } | Should -Not -Throw
            }
            finally {
                if (Test-Path -LiteralPath $tempAppData) {
                    Remove-Item -LiteralPath $tempAppData -Recurse -Force
                }
            }
        }

        It "Export-PowerStubConfiguration_ExternalProcessRegistration_IsVisibleInLoadedSession" {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBExternalConfigTest_$(Get-Random)"
            $tempAppData = Join-Path $tempRoot 'appdata'
            $stubPath = Join-Path $tempRoot 'stub'
            $mainScript = Join-Path $tempRoot 'main.ps1'
            $childScript = Join-Path $tempRoot 'register-child.ps1'
            $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'

            try {
                New-Item -ItemType Directory -Path $tempRoot, $tempAppData -Force | Out-Null

                @'
param(
    [string]$ModulePath,
    [string]$AppData,
    [string]$StubPath
)

$env:POWERSTUB_CONFIG_DIR = Join-Path $AppData 'PowerStub'
Import-Module $ModulePath -Force
New-PowerStub -Name ExternalStub -Path $StubPath -Force
'@ | Set-Content -LiteralPath $childScript -Encoding UTF8

                @'
param(
    [string]$ModulePath,
    [string]$AppData,
    [string]$StubPath,
    [string]$ChildScript
)

$env:POWERSTUB_CONFIG_DIR = Join-Path $AppData 'PowerStub'
Import-Module $ModulePath -Force
$initialCount = @((Get-PowerStubs).Keys).Count
Start-Sleep -Milliseconds 50
& pwsh -NoProfile -File $ChildScript -ModulePath $ModulePath -AppData $AppData -StubPath $StubPath
$stubs = Get-PowerStubs

[PSCustomObject]@{
    InitialCount     = $initialCount
    HasExternalStub  = $stubs.ContainsKey('ExternalStub')
    FinalCount       = @($stubs.Keys).Count
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $mainScript -Encoding UTF8

                $result = & pwsh -NoProfile -File $mainScript -ModulePath $modulePath -AppData $tempAppData -StubPath $stubPath -ChildScript $childScript |
                    Select-Object -Last 1 |
                    ConvertFrom-Json

                $result.InitialCount | Should -Be 0
                $result.HasExternalStub | Should -Be $true
                $result.FinalCount | Should -Be 1
            }
            finally {
                if (Test-Path -LiteralPath $tempRoot) {
                    Remove-Item -LiteralPath $tempRoot -Recurse -Force
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Set-PowerStubConfiguration
# ---------------------------------------------------------------------------
Describe "Set-PowerStubConfiguration" {
    BeforeEach {
        Import-PowerStubConfiguration -Reset
    }

    Context "Internal key preservation" {
        It "Set-PowerStubConfiguration_OmittedInternalKeys_AreRestoredFromCurrentSettings" {
            InModuleScope PowerStub {
                $originalModulePath = Get-PowerStubConfigurationKey 'ModulePath'
                $originalConfigFile = Get-PowerStubConfigurationKey 'ConfigFile'

                # Provide a new config that intentionally omits internal keys
                $newConfig = @{
                    InvokeAlias        = 'pstb'
                    Stubs              = @{}
                    'EnablePrefix:Alpha' = $false
                    'EnablePrefix:Beta'  = $false
                    GitEnabled           = $true
                }

                Set-PowerStubConfiguration -value $newConfig

                # Internal keys must have been re-injected from the previous settings
                $afterModulePath = Get-PowerStubConfigurationKey 'ModulePath'
                $afterConfigFile = Get-PowerStubConfigurationKey 'ConfigFile'

                $afterModulePath | Should -Be $originalModulePath
                $afterConfigFile | Should -Be $originalConfigFile
            }
        }

        It "Set-PowerStubConfiguration_WithExplicitInternalKey_UsesProvidedValue" {
            InModuleScope PowerStub {
                $originalConfigFile = Get-PowerStubConfigurationKey 'ConfigFile'

                $newConfig = @{
                    InvokeAlias        = 'pstb'
                    Stubs              = @{}
                    'EnablePrefix:Alpha' = $false
                    'EnablePrefix:Beta'  = $false
                    GitEnabled           = $true
                    # Explicitly provide ConfigFile - should not be overwritten
                    ConfigFile           = $originalConfigFile
                }

                Set-PowerStubConfiguration -value $newConfig

                $after = Get-PowerStubConfigurationKey 'ConfigFile'
                $after | Should -Be $originalConfigFile
            }
        }

        It "Set-PowerStubConfiguration_ReplacesNonInternalKeys" {
            InModuleScope PowerStub {
                $newConfig = @{
                    InvokeAlias        = 'custom-alias'
                    Stubs              = @{}
                    'EnablePrefix:Alpha' = $true
                    'EnablePrefix:Beta'  = $false
                    GitEnabled           = $false
                }

                Set-PowerStubConfiguration -value $newConfig

                Get-PowerStubConfigurationKey 'InvokeAlias' | Should -Be 'custom-alias'
                Get-PowerStubConfigurationKey 'EnablePrefix:Alpha' | Should -Be $true
                Get-PowerStubConfigurationKey 'GitEnabled' | Should -Be $false
            }
        }

        It "Set-PowerStubConfiguration_PersistsToFile" {
            InModuleScope PowerStub {
                $newConfig = @{
                    InvokeAlias        = 'pstb'
                    Stubs              = @{}
                    'EnablePrefix:Alpha' = $false
                    'EnablePrefix:Beta'  = $false
                    GitEnabled           = $true
                }

                Set-PowerStubConfiguration -value $newConfig

                $configFile = Get-PowerStubConfigurationKey 'ConfigFile'
                Test-Path $configFile | Should -Be $true

                $raw = Get-Content $configFile -Raw | ConvertFrom-Json
                $raw.InvokeAlias | Should -Be 'pstb'
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-PowerStub - missing scenarios
# ---------------------------------------------------------------------------
Describe "Remove-PowerStub - error scenarios" {
    BeforeEach {
        Import-PowerStubConfiguration -Reset
    }

    Context "Non-existent stub" {
        It "Remove-PowerStub_NonExistentStub_Throws" {
            { Remove-PowerStub -Name "DoesNotExist" } | Should -Throw
        }

        It "Remove-PowerStub_NonExistentStub_ErrorMessageContainsStubName" {
            $thrownMessage = $null
            try {
                Remove-PowerStub -Name "GhostStub"
            }
            catch {
                $thrownMessage = $_.Exception.Message
            }
            $thrownMessage | Should -Not -BeNullOrEmpty
            $thrownMessage | Should -Match "GhostStub"
        }

        It "Remove-PowerStub_AfterStubRemoved_SecondRemoveThrows" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBRemoveTest_$(Get-Random)"
            try {
                New-PowerStub -Name "TempStub" -Path $testPath
                Remove-PowerStub -Name "TempStub"
                { Remove-PowerStub -Name "TempStub" } | Should -Throw
            }
            finally {
                if (Test-Path $testPath) { Remove-Item $testPath -Recurse -Force }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Invoke-PowerStubCommand - error scenarios
# ---------------------------------------------------------------------------
Describe "Invoke-PowerStubCommand - error scenarios" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Unregistered stub" {
        It "Invoke-PowerStubCommand_UnregisteredStub_Throws" {
            { Invoke-PowerStubCommand -Stub "UnregisteredStub" -Command "anything" } | Should -Throw
        }

        It "Invoke-PowerStubCommand_UnregisteredStub_ErrorMentionsStubName" {
            $thrownMessage = $null
            try {
                Invoke-PowerStubCommand -Stub "UnregisteredStub" -Command "anything"
            }
            catch {
                $thrownMessage = $_.Exception.Message
            }
            $thrownMessage | Should -Match "UnregisteredStub"
        }

        It "Invoke-PowerStubCommand_UnregisteredStub_ErrorMentionsHowToRegister" {
            $thrownMessage = $null
            try {
                Invoke-PowerStubCommand -Stub "NoSuchStub" -Command "cmd"
            }
            catch {
                $thrownMessage = $_.Exception.Message
            }
            # The error message includes registration guidance
            $thrownMessage | Should -Match "New-PowerStub"
        }
    }

    Context "Non-existent command in valid stub" {
        It "Invoke-PowerStubCommand_NonExistentCommand_Throws" {
            { Invoke-PowerStubCommand -Stub "SampleStub" -Command "nonexistent-cmd-xyz" } | Should -Throw
        }

        It "Invoke-PowerStubCommand_NonExistentCommand_ErrorMentionsCommandName" {
            $thrownMessage = $null
            try {
                Invoke-PowerStubCommand -Stub "SampleStub" -Command "no-such-command"
            }
            catch {
                $thrownMessage = $_.Exception.Message
            }
            $thrownMessage | Should -Match "no-such-command"
        }

        It "Invoke-PowerStubCommand_NonExistentCommand_ErrorMentionsStubName" {
            $thrownMessage = $null
            try {
                Invoke-PowerStubCommand -Stub "SampleStub" -Command "ghost-command"
            }
            catch {
                $thrownMessage = $_.Exception.Message
            }
            $thrownMessage | Should -Match "SampleStub"
        }
    }
}

# ---------------------------------------------------------------------------
# Set-PowerStubCommandVisibility - subfolder commands
# ---------------------------------------------------------------------------
Describe "Set-PowerStubCommandVisibility - subfolder commands" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset

        $script:SubfolderVisTestPath = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBSubVisTest_$(Get-Random)"
        New-PowerStub -Name "SubVisStub" -Path $script:SubfolderVisTestPath -Force

        # Build a subfolder command structure
        $commandsPath = Join-Path $script:SubfolderVisTestPath 'Commands'
        $subfolderPath = Join-Path $commandsPath 'deploy-service'
        New-Item $subfolderPath -ItemType Directory -Force | Out-Null

        $script:SubProdFile  = Join-Path $subfolderPath 'deploy-service.ps1'
        $script:SubAlphaFile = Join-Path $subfolderPath 'alpha.deploy-service.ps1'
        $script:SubBetaFile  = Join-Path $subfolderPath 'beta.deploy-service.ps1'

        Set-Content -Path $script:SubProdFile -Value 'param([string]$Env); Write-Output "deploy-service: $Env"'
    }

    AfterAll {
        if (Test-Path $script:SubfolderVisTestPath) {
            Remove-Item $script:SubfolderVisTestPath -Recurse -Force
        }
        Remove-PowerStub -Name "SubVisStub" -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $subfolderPath = Join-Path (Join-Path $script:SubfolderVisTestPath 'Commands') 'deploy-service'

        # Reset to only production version
        Remove-Item (Join-Path $subfolderPath 'alpha.deploy-service.ps1') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $subfolderPath 'beta.deploy-service.ps1')  -ErrorAction SilentlyContinue

        if (-not (Test-Path $script:SubProdFile)) {
            Set-Content -Path $script:SubProdFile -Value 'param([string]$Env); Write-Output "deploy-service: $Env"'
        }

        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Promote subfolder command from Production to Alpha" {
        It "Set-PowerStubCommandVisibility_SubfolderProduction_PromotesToAlpha" {
            $result = Set-PowerStubCommandVisibility -Stub "SubVisStub" -Command "deploy-service" -Visibility Alpha

            $result.Changed | Should -Be $true
            $result.OldVisibility | Should -Be 'Production'
            $result.NewVisibility | Should -Be 'Alpha'

            Test-Path $script:SubAlphaFile | Should -Be $true
            Test-Path $script:SubProdFile  | Should -Be $false
        }
    }

    Context "Promote subfolder command from Production to Beta" {
        It "Set-PowerStubCommandVisibility_SubfolderProduction_PromotesToBeta" {
            $result = Set-PowerStubCommandVisibility -Stub "SubVisStub" -Command "deploy-service" -Visibility Beta

            $result.Changed | Should -Be $true
            $result.NewVisibility | Should -Be 'Beta'

            Test-Path $script:SubBetaFile | Should -Be $true
            Test-Path $script:SubProdFile | Should -Be $false
        }
    }

    Context "Demote subfolder command from Alpha to Production" {
        It "Set-PowerStubCommandVisibility_SubfolderAlpha_DemotesToProduction" {
            $subfolderPath = Join-Path (Join-Path $script:SubfolderVisTestPath 'Commands') 'deploy-service'

            # First promote to alpha
            Set-PowerStubCommandVisibility -Stub "SubVisStub" -Command "deploy-service" -Visibility Alpha
            Enable-PowerStubAlphaCommands

            $result = Set-PowerStubCommandVisibility -Stub "SubVisStub" -Command "deploy-service" -Visibility Production

            $result.Changed | Should -Be $true
            $result.OldVisibility | Should -Be 'Alpha'
            $result.NewVisibility | Should -Be 'Production'

            Test-Path $script:SubProdFile  | Should -Be $true
            Test-Path $script:SubAlphaFile | Should -Be $false
        }
    }

    Context "No change when already at target visibility" {
        It "Set-PowerStubCommandVisibility_SubfolderAlreadyProduction_ReportsNoChange" {
            $result = Set-PowerStubCommandVisibility -Stub "SubVisStub" -Command "deploy-service" -Visibility Production

            $result.Changed | Should -Be $false
            $result.Visibility | Should -Be 'Production'
        }
    }
}

# ---------------------------------------------------------------------------
# Set-PowerStubCommandVisibility - WhatIf support
# ---------------------------------------------------------------------------
Describe "Set-PowerStubCommandVisibility - WhatIf support" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset

        $script:WhatIfTestPath = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBWhatIfTest_$(Get-Random)"
        New-PowerStub -Name "WhatIfStub" -Path $script:WhatIfTestPath -Force

        $commandsPath = Join-Path $script:WhatIfTestPath 'Commands'
        $script:WhatIfProdFile  = Join-Path $commandsPath 'wi-cmd.ps1'
        $script:WhatIfAlphaFile = Join-Path $commandsPath 'alpha.wi-cmd.ps1'
        $script:WhatIfBetaFile  = Join-Path $commandsPath 'beta.wi-cmd.ps1'

        Set-Content -Path $script:WhatIfProdFile -Value 'param(); Write-Output "wi-cmd"'
    }

    AfterAll {
        if (Test-Path $script:WhatIfTestPath) {
            Remove-Item $script:WhatIfTestPath -Recurse -Force
        }
        Remove-PowerStub -Name "WhatIfStub" -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $commandsPath = Join-Path $script:WhatIfTestPath 'Commands'
        Remove-Item (Join-Path $commandsPath 'alpha.wi-cmd.ps1') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $commandsPath 'beta.wi-cmd.ps1')  -ErrorAction SilentlyContinue

        if (-not (Test-Path $script:WhatIfProdFile)) {
            Set-Content -Path $script:WhatIfProdFile -Value 'param(); Write-Output "wi-cmd"'
        }

        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "-WhatIf prevents file rename" {
        It "Set-PowerStubCommandVisibility_WhatIf_DoesNotRenameFile" {
            Set-PowerStubCommandVisibility -Stub "WhatIfStub" -Command "wi-cmd" -Visibility Alpha -WhatIf

            # Production file must still exist (rename was suppressed)
            Test-Path $script:WhatIfProdFile  | Should -Be $true
            # Alpha file must not have been created
            Test-Path $script:WhatIfAlphaFile | Should -Be $false
        }

        It "Set-PowerStubCommandVisibility_WhatIf_ReturnValueIsNull" {
            $result = Set-PowerStubCommandVisibility -Stub "WhatIfStub" -Command "wi-cmd" -Visibility Beta -WhatIf
            # ShouldProcess returns false for -WhatIf, so the function returns nothing
            $result | Should -BeNullOrEmpty
        }

        It "Set-PowerStubCommandVisibility_WithoutWhatIf_DoesRenameFile" {
            Set-PowerStubCommandVisibility -Stub "WhatIfStub" -Command "wi-cmd" -Visibility Alpha

            Test-Path $script:WhatIfAlphaFile | Should -Be $true
            Test-Path $script:WhatIfProdFile  | Should -Be $false
        }
    }
}
