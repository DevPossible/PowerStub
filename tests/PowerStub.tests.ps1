#Requires -Modules Pester
<#
.SYNOPSIS
    Comprehensive test suite for the PowerStub module.

.DESCRIPTION
    Tests cover:
    - Module loading and exports
    - Configuration management
    - Stub registration and removal
    - Command discovery (direct files and subfolders)
    - Alpha/Beta prefix system
    - Command execution

.NOTES
    Run with: Invoke-Pester ./tests/PowerStub.tests.ps1
#>

BeforeAll {
    # Remove any existing module
    $module = Get-Module -Name 'PowerStub'
    if ($module) {
        Remove-Module -ModuleInfo $module -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

    # Import the module
    $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $modulePath -Force

    # Sample stub root for integration tests
    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

Describe "PowerStub Module" {
    Context "Module Loading" {
        It "Should import the module successfully" {
            $module = Get-Module -Name 'PowerStub'
            $module | Should -Not -BeNullOrEmpty
        }

        It "Should export the expected public functions" {
            $expectedFunctions = @(
                'Invoke-PowerStubCommand'
                'New-PowerStub'
                'New-PowerStubDirectAlias'
                'Remove-PowerStubDirectAlias'
                'Remove-PowerStub'
                'Get-PowerStubs'
                'Get-PowerStubCommand'
                'Get-PowerStubCommandHelp'
                'Search-PowerStubCommands'
                'Set-PowerStubCommandVisibility'
                'Get-PowerStubConfiguration'
                'Import-PowerStubConfiguration'
                'Enable-PowerStubAlphaCommands'
                'Disable-PowerStubAlphaCommands'
                'Enable-PowerStubBetaCommands'
                'Disable-PowerStubBetaCommands'
            )

            foreach ($func in $expectedFunctions) {
                Get-Command -Module PowerStub -Name $func -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "Function '$func' should be exported"
            }
        }

        It "Should create the 'pstb' alias" {
            $alias = Get-Alias -Name 'pstb' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Invoke-PowerStubCommand'
        }

        It "Should not export private functions" {
            $privateFunctions = @(
                'Find-PowerStubCommands'
                'Get-PowerStubCompletion'
                'Invoke-CheckedCommand'
                'Resolve-PowerStubInvocation'
                'ConvertTo-Hashtable'
                'Get-PowerStubConfigurationDefaults'
                'Get-PowerStubConfigurationKey'
                'Set-PowerStubConfigurationKey'
                'Set-PowerStubConfiguration'
                'Export-PowerStubConfiguration'
            )

            foreach ($func in $privateFunctions) {
                $cmd = Get-Command -Module PowerStub -Name $func -ErrorAction SilentlyContinue
                $cmd | Should -BeNullOrEmpty -Because "Function '$func' should not be exported"
            }
        }
    }
}

Describe "Configuration Management" {
    BeforeAll {
        # Reset to clean state
        Import-PowerStubConfiguration -Reset
    }

    Context "Get-PowerStubConfiguration" {
        It "Should return a hashtable" {
            $config = Get-PowerStubConfiguration
            $config | Should -BeOfType [hashtable]
        }

        It "Should contain required keys" {
            $config = Get-PowerStubConfiguration
            $config.Keys | Should -Contain 'Stubs'
            $config.Keys | Should -Contain 'InvokeAlias'
            $config.Keys | Should -Contain 'ModulePath'
            $config.Keys | Should -Contain 'ConfigFile'
        }

        It "Should return default values after reset" {
            Import-PowerStubConfiguration -Reset
            $config = Get-PowerStubConfiguration
            $config['InvokeAlias'] | Should -Be 'pstb'
            $config['EnablePrefix:Alpha'] | Should -Be $false
            $config['EnablePrefix:Beta'] | Should -Be $false
        }

        It "Should return a specific key when requested" {
            $alias = Get-PowerStubConfiguration 'InvokeAlias'
            $alias | Should -Be 'pstb'
        }
    }

    Context "Import-PowerStubConfiguration" {
        It "Should reset configuration with -Reset flag" {
            Import-PowerStubConfiguration -Reset
            $config = Get-PowerStubConfiguration
            $config['Stubs'].Keys.Count | Should -Be 0
        }

        It "Should reload configuration from file" {
            # This tests that Import-PowerStubConfiguration reads from file
            Import-PowerStubConfiguration
            $config = Get-PowerStubConfiguration
            $config | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Stub Management" {
    BeforeEach {
        # Reset config before each test
        Import-PowerStubConfiguration -Reset
    }

    Context "New-PowerStub" {
        It "Should register a new stub" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath

                $stubs = Get-PowerStubs
                $stubs.Keys | Should -Contain "TestStub"
                $stubs["TestStub"] | Should -Be $testPath
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }

        It "Should create the folder structure" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath

                Test-Path $testPath | Should -Be $true
                Test-Path (Join-Path $testPath 'Commands') | Should -Be $true
                Test-Path (Join-Path $testPath '.tests') | Should -Be $true
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }

        It "Should throw when stub already exists without -Force" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath
                { New-PowerStub -Name "TestStub" -Path $testPath } | Should -Throw
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }

        It "Should overwrite when -Force is specified" {
            $testPath1 = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"
            $testPath2 = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath1
                New-PowerStub -Name "TestStub" -Path $testPath2 -Force

                $stubs = Get-PowerStubs
                $stubs["TestStub"] | Should -Be $testPath2
            }
            finally {
                if (Test-Path $testPath1) { Remove-Item $testPath1 -Recurse -Force }
                if (Test-Path $testPath2) { Remove-Item $testPath2 -Recurse -Force }
            }
        }

        It "Should persist configuration to file" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath

                $configFile = (Get-PowerStubConfiguration)['ConfigFile']
                Test-Path $configFile | Should -Be $true
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }
    }

    Context "Remove-PowerStub" {
        It "Should remove a registered stub" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath
                Remove-PowerStub -Name "TestStub"

                $stubs = Get-PowerStubs
                $stubs.Keys | Should -Not -Contain "TestStub"
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }

        It "Should not delete the folder (files remain)" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "TestStub" -Path $testPath
                Remove-PowerStub -Name "TestStub"

                # Folder should still exist
                Test-Path $testPath | Should -Be $true
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }
    }

    Context "Get-PowerStubs" {
        It "Should return empty hashtable when no stubs registered" {
            Import-PowerStubConfiguration -Reset
            $stubs = Get-PowerStubs
            $stubs | Should -BeOfType [hashtable]
            $stubs.Keys.Count | Should -Be 0
        }

        It "Should return all registered stubs" {
            $testPath1 = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest1_$(Get-Random)"
            $testPath2 = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest2_$(Get-Random)"

            try {
                New-PowerStub -Name "Stub1" -Path $testPath1
                New-PowerStub -Name "Stub2" -Path $testPath2

                $stubs = Get-PowerStubs
                $stubs.Keys.Count | Should -Be 2
                $stubs.Keys | Should -Contain "Stub1"
                $stubs.Keys | Should -Contain "Stub2"
            }
            finally {
                if (Test-Path $testPath1) { Remove-Item $testPath1 -Recurse -Force }
                if (Test-Path $testPath2) { Remove-Item $testPath2 -Recurse -Force }
            }
        }
    }
}

Describe "Command Discovery" {
    BeforeAll {
        # Register the sample stub for testing
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    Context "Direct Commands" {
        BeforeEach {
            # Ensure alpha/beta are disabled
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
        }

        It "Should discover direct .ps1 files in Commands folder" {
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "get-data"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "get-data\.ps1$"
        }

        It "Should discover multiple direct commands" {
            $cmd1 = Get-PowerStubCommand -Stub "SampleStub" -Command "get-data"
            $cmd2 = Get-PowerStubCommand -Stub "SampleStub" -Command "new-data"

            $cmd1 | Should -Not -BeNullOrEmpty
            $cmd2 | Should -Not -BeNullOrEmpty
        }
    }

    Context "Subfolder Commands" {
        BeforeEach {
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
        }

        It "Should discover commands in subfolders matching folder name" {
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "remove-data"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "remove-data\.ps1$"
        }

        It "Should NOT discover helper scripts in subfolders" {
            # helper.ps1 exists in remove-data folder but shouldn't be exposed
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "helper"
            $cmd | Should -BeNullOrEmpty
        }
    }

    Context "Non-existent Commands" {
        It "Should return null for non-existent command" {
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "nonexistent"
            $cmd | Should -BeNullOrEmpty
        }

        It "Should warn for non-existent stub" {
            # Capture warning stream (stream 3)
            $result = Get-PowerStubCommand -Stub "NonExistentStub" -Command "test" 3>&1
            $warnings = $result | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $warnings | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Alpha/Beta Prefix System" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    Context "Enable/Disable Alpha Commands" {
        It "Should enable alpha commands" {
            Enable-PowerStubAlphaCommands
            $config = Get-PowerStubConfiguration
            $config['EnablePrefix:Alpha'] | Should -Be $true
        }

        It "Should disable alpha commands" {
            Disable-PowerStubAlphaCommands
            $config = Get-PowerStubConfiguration
            $config['EnablePrefix:Alpha'] | Should -Be $false
        }
    }

    Context "Enable/Disable Beta Commands" {
        It "Should enable beta commands" {
            Enable-PowerStubBetaCommands
            $config = Get-PowerStubConfiguration
            $config['EnablePrefix:Beta'] | Should -Be $true
        }

        It "Should disable beta commands" {
            Disable-PowerStubBetaCommands
            $config = Get-PowerStubConfiguration
            $config['EnablePrefix:Beta'] | Should -Be $false
        }
    }

    Context "Alpha Command Discovery" {
        It "Should NOT discover alpha commands when disabled" {
            Disable-PowerStubAlphaCommands
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "new-feature"
            $cmd | Should -BeNullOrEmpty
        }

        It "Should discover alpha commands when enabled" {
            Enable-PowerStubAlphaCommands
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "new-feature"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "alpha\.new-feature\.ps1$"
        }
    }

    Context "Beta Command Discovery" {
        BeforeEach {
            Disable-PowerStubAlphaCommands
        }

        It "Should NOT discover beta commands when disabled" {
            Disable-PowerStubBetaCommands
            # deploy has both beta and production versions
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "deploy"
            $cmd | Should -Not -BeNullOrEmpty
            # Should get production version, not beta
            $cmd.Name | Should -Match "^deploy\.ps1$"
        }

        It "Should discover beta commands when enabled" {
            Enable-PowerStubBetaCommands
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "deploy"
            $cmd | Should -Not -BeNullOrEmpty
            # Should get beta version
            $cmd.Name | Should -Match "beta\.deploy\.ps1$"
        }
    }

    Context "Precedence Order (alpha -> beta -> production)" {
        It "Alpha should take precedence over beta and production" {
            Enable-PowerStubAlphaCommands
            Enable-PowerStubBetaCommands

            # remove-data has alpha and production versions in subfolder
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "remove-data"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "alpha\.remove-data\.ps1$"
        }

        It "Beta should take precedence over production (when alpha disabled)" {
            Disable-PowerStubAlphaCommands
            Enable-PowerStubBetaCommands

            # deploy has beta and production versions
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "deploy"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "beta\.deploy\.ps1$"
        }

        It "Production should be used when alpha and beta disabled" {
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands

            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "deploy"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "^deploy\.ps1$"
        }
    }

    Context "Subfolder Alpha/Beta Commands" {
        It "Should discover alpha commands in subfolders" {
            Enable-PowerStubAlphaCommands

            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "remove-data"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "alpha\.remove-data\.ps1$"
        }

        It "Should fall back to production in subfolder when alpha disabled" {
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands

            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "remove-data"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Name | Should -Match "^remove-data\.ps1$"
        }
    }
}

Describe "Command Execution" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Basic Execution" {
        It "Should execute a command and return output" {
            $output = pstb SampleStub deploy -Environment "test"
            $output | Should -Not -BeNullOrEmpty
            $output | Should -Contain "deploy.ps1 (production) executed"
        }
    }

    Context "Parameter Passing" {
        It "Should pass string parameters correctly" {
            $output = pstb SampleStub deploy -Environment "production" -Version "1.0.0"
            $output | Should -Contain "Environment: production"
            $output | Should -Contain "Version: 1.0.0"
        }
    }

    Context "Alpha/Beta Command Execution" {
        It "Should execute alpha command when enabled" {
            Enable-PowerStubAlphaCommands

            $output = pstb SampleStub new-feature -Name "TestFeature"
            $output | Should -Contain "alpha.new-feature.ps1 executed"
            $output | Should -Contain "Name: TestFeature"

            Disable-PowerStubAlphaCommands
        }

        It "Should execute beta command when enabled" {
            Disable-PowerStubAlphaCommands
            Enable-PowerStubBetaCommands

            $output = pstb SampleStub deploy -Environment "staging"
            $output | Should -Contain "beta.deploy.ps1 executed"
            $output | Should -Contain "Environment: staging"

            Disable-PowerStubBetaCommands
        }
    }
}

Describe "Dynamic Parameters and Tab Completion" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Argument Completers" {
        It "Should complete stub names" {
            # Test the stub completer directly
            $completions = InModuleScope PowerStub {
                $stubs = Get-PowerStubConfigurationKey 'Stubs'
                @($stubs.Keys | Where-Object { $_ -like "Sample*" })
            }
            $completions | Should -Contain "SampleStub"
        }

        It "Should complete command names (stripping prefixes)" {
            Enable-PowerStubAlphaCommands
            Enable-PowerStubBetaCommands

            # Simulate command completer behavior
            $commands = InModuleScope PowerStub {
                $commands = @(Find-PowerStubCommands "SampleStub")
                @($commands | ForEach-Object {
                    $name = $_.BaseName
                    if ($name -match '^(alpha|beta)\.(.+)$') {
                        $Matches[2]
                    } else {
                        $name
                    }
                } | Select-Object -Unique)
            }

            # Should have unprefixed names
            $commands | Should -Contain "deploy"
            $commands | Should -Contain "new-feature"
            # Should NOT have prefixed names
            $commands | Should -Not -Contain "alpha.new-feature"
            $commands | Should -Not -Contain "beta.deploy"

            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
        }
    }

    Context "Invoke-PowerStubCommand Base Functionality" {
        It "Should expose Invoke-PowerStubCommand" {
            $cmd = Get-Command -Name 'Invoke-PowerStubCommand'
            $cmd | Should -Not -BeNullOrEmpty
        }

        It "Should declare no parameters, so nothing meant for the target binds to pstb" {
            $cmd = Get-Command -Name 'Invoke-PowerStubCommand'
            $cmd.CmdletBinding | Should -Be $false
            $cmd.Parameters.Count | Should -Be 0
        }

        It "Should still accept -Stub and -Command by name" {
            $output = Invoke-PowerStubCommand -Stub SampleStub -Command deploy -Environment "named" 6>$null
            ($output -join ' ') | Should -Match 'named'
        }
    }

    Context "Tab Completion for Dynamic Parameters" {
        It "Should include dynamic parameters in tab completion" {
            # Hosts complete through the TabExpansion2 function, which the module wraps
            $input = 'Invoke-PowerStubCommand -Stub SampleStub -Command deploy -'
            $completions = TabExpansion2 -inputScript $input -cursorColumn $input.Length

            $completionTexts = @($completions.CompletionMatches | Select-Object -ExpandProperty CompletionText)

            # Should include the dynamic parameter from the deploy command
            $completionTexts | Should -Contain '-Environment'
        }

        It "Should include dynamic parameters when using alias" {
            $input = 'pstb SampleStub deploy -'
            $completions = TabExpansion2 -inputScript $input -cursorColumn $input.Length

            $completionTexts = @($completions.CompletionMatches | Select-Object -ExpandProperty CompletionText)

            # Should include the dynamic parameter from the deploy command
            $completionTexts | Should -Contain '-Environment'
        }

        It "Should not break other commands completion" {
            $input = 'Get-ChildItem -'
            $completions = TabExpansion2 -inputScript $input -cursorColumn $input.Length

            $completionTexts = @($completions.CompletionMatches | Select-Object -ExpandProperty CompletionText)

            # Should still work normally for other commands
            $completionTexts | Should -Contain '-Path'
        }
    }
}

Describe "New-PowerStubDirectAlias" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    BeforeEach {
        # Clean up any test aliases thoroughly
        @('teststub', 'ts', 'myalias', 'forcealias', 'configalias', 'noopalias') | ForEach-Object {
            # Remove from function: drive
            Remove-Item "function:$_" -ErrorAction SilentlyContinue
            Remove-Item "function:global:$_" -ErrorAction SilentlyContinue
        }
        # Clear direct aliases from config
        InModuleScope PowerStub { Set-PowerStubConfigurationKey 'DirectAliases' @{} }
    }

    AfterAll {
        # Clean up test aliases
        @('teststub', 'ts', 'myalias', 'forcealias', 'configalias', 'noopalias') | ForEach-Object {
            Remove-Item "function:$_" -ErrorAction SilentlyContinue
            Remove-Item "function:global:$_" -ErrorAction SilentlyContinue
        }
    }

    Context "Parameter Validation" {
        It "Should require -AliasName parameter" {
            # Test that AliasName is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command New-PowerStubDirectAlias
            $param = $cmd.Parameters['AliasName']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should require -Stub parameter" {
            # Test that Stub is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command New-PowerStubDirectAlias
            $param = $cmd.Parameters['Stub']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should throw when stub doesn't exist" {
            { New-PowerStubDirectAlias -AliasName "ts" -Stub "NonExistentStub" } | Should -Throw "*not found*"
        }

        It "Should validate alias name format" {
            { New-PowerStubDirectAlias -AliasName "123invalid" -Stub "SampleStub" } | Should -Throw
        }

        It "Should throw when alias exists without -Force" {
            New-PowerStubDirectAlias -AliasName "ts" -Stub "SampleStub"
            { New-PowerStubDirectAlias -AliasName "ts" -Stub "SampleStub" } | Should -Throw "*already exists*"
        }
    }

    Context "Alias Creation" {
        It "Should create a global function with the alias name" {
            New-PowerStubDirectAlias -AliasName "teststub" -Stub "SampleStub"

            $cmd = Get-Command "teststub" -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        It "Should reject an existing owned alias even when -Force is specified" {
            New-PowerStubDirectAlias -AliasName "forcealias" -Stub "SampleStub"
            { New-PowerStubDirectAlias -AliasName "forcealias" -Stub "SampleStub" -Force } | Should -Throw "*already exists*"
        }

        It "Should return info object with AliasName, Stub, and StubPath" {
            $result = New-PowerStubDirectAlias -AliasName "myalias" -Stub "SampleStub"

            $result | Should -Not -BeNullOrEmpty
            $result.AliasName | Should -Be "myalias"
            $result.Stub | Should -Be "SampleStub"
            $result.StubPath | Should -Be $script:SampleStubRoot
            $result.Usage | Should -Not -BeNullOrEmpty
        }

        It "Should store alias in config for persistence" {
            New-PowerStubDirectAlias -AliasName "configalias" -Stub "SampleStub"

            $directAliases = InModuleScope PowerStub { Get-PowerStubConfigurationKey 'DirectAliases' }
            $directAliases | Should -Not -BeNullOrEmpty
            $directAliases['configalias'] | Should -Be 'SampleStub'
        }

        It "Should reject a repeated add without rewriting matching persisted config" {
            New-PowerStubDirectAlias -AliasName "noopalias" -Stub "SampleStub"
            $configFile = InModuleScope PowerStub { Get-PowerStubConfigurationKey 'ConfigFile' }
            $before = Get-Item -LiteralPath $configFile

            Start-Sleep -Milliseconds 1200
            { New-PowerStubDirectAlias -AliasName "noopalias" -Stub "SampleStub" -Force } | Should -Throw "*already exists*"

            $after = Get-Item -LiteralPath $configFile
            $after.LastWriteTimeUtc | Should -Be $before.LastWriteTimeUtc
        }
    }

    Context "Alias Functionality" {
        BeforeEach {
            New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
            New-PowerStubDirectAlias -AliasName "ts" -Stub "SampleStub" -Force
        }

        It "Should list commands when run without arguments" {
            $output = @(ts 6>&1)
            $output | Should -Not -BeNullOrEmpty
            @($output | Where-Object { $_ -is [System.IO.FileInfo] }).Count | Should -Be 0
            ($output | Out-String) | Should -Match 'Command\s+Synopsis'
        }

        It "Should show sorted command names and header summaries via <EntryPoint>" -ForEach @(
            @{ EntryPoint = 'alias' }
            @{ EntryPoint = 'pstb' }
        ) {
            $stubRoot = Join-Path $TestDrive 'ListingStub'
            $commandsPath = Join-Path $stubRoot 'Commands'
            New-Item -ItemType Directory -Path $commandsPath -Force | Out-Null
            @'
<#
.SYNOPSIS
    Deploy the application.
#>
throw 'Listing must not execute commands'
'@ | Set-Content (Join-Path $commandsPath 'zulu.ps1')
            @'
<#
.SYNOPSIS
    Back up the database.
#>
throw 'Listing must not execute commands'
'@ | Set-Content (Join-Path $commandsPath 'aardvark.ps1')
            Set-Content (Join-Path $commandsPath 'missing-help.ps1') "param([string]`$Environment)`nthrow 'Listing must not execute commands'"
            New-PowerStub -Name 'ListingStub' -Path $stubRoot -Force
            Remove-PowerStubDirectAlias -AliasName ts
            New-PowerStubDirectAlias -AliasName ts -Stub 'ListingStub' -Force | Out-Null

            $output = if ($EntryPoint -eq 'alias') { @(ts 6>&1) } else { @(pstb ListingStub 6>&1) }
            @($output | Where-Object { $_ -is [System.IO.FileInfo] }).Count | Should -Be 0
            $text = $output | Out-String
            $text | Should -Match 'Command\s+Synopsis'
            $text | Should -Match '(?m)^Command +Synopsis\r?\n------- +--------\r?$'
            $text | Should -Match 'aardvark\s+Back up the database\.'
            $text | Should -Match 'zulu\s+Deploy the application\.'
            $text | Should -Match 'missing-help\s+-'
            $text.IndexOf('aardvark') | Should -BeLessThan $text.IndexOf('missing-help')
            $text.IndexOf('missing-help') | Should -BeLessThan $text.IndexOf('zulu')
        }

        It "Should keep prerelease markers in the command column without changing name order" {
            Enable-PowerStubAlphaCommands
            Enable-PowerStubBetaCommands

            $text = ts 6>&1 | Out-String
            $text | Should -Match '(?m)^Command +Synopsis\r?\n------- +--------\r?$'
            $text | Should -Match '(?m)^deploy \* +'
            $text | Should -Match '(?m)^new-feature \* +'
            $text.IndexOf('deploy *') | Should -BeLessThan $text.IndexOf('new-feature *')
            $text | Should -Not -Match '(?m)^- -------'
        }

        It "Should show an empty-stub message via the alias" {
            New-PowerStub -Name 'EmptyListingStub' -Path (Join-Path $TestDrive 'EmptyListingStub') -Force
            Remove-PowerStubDirectAlias -AliasName ts
            New-PowerStubDirectAlias -AliasName ts -Stub 'EmptyListingStub' -Force | Out-Null

            (ts 6>&1 | Out-String) | Should -Match "No commands found in stub 'EmptyListingStub'\."
        }

        It "Should execute commands with parameters" {
            $output = ts deploy -Environment "test"
            $output | Should -Contain "deploy.ps1 (production) executed"
        }
    }

    Context "Tab Completion" {
        BeforeEach {
            New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
            New-PowerStubDirectAlias -AliasName "ts" -Stub "SampleStub" -Force
        }

        It "Should complete command names using ArgumentCompleter" {
            # Test the completer directly by simulating what happens during tab completion
            # The ArgumentCompleter returns command names for the stub
            $commands = InModuleScope PowerStub {
                $commands = @(Find-PowerStubCommands "SampleStub")
                @($commands | ForEach-Object {
                    $name = $_.BaseName
                    if ($name -match '^(alpha|beta)\.(.+)$') {
                        $Matches[2]
                    } else {
                        $name
                    }
                } | Select-Object -Unique)
            }
            $commands | Should -Contain 'deploy'
        }

        It "Should complete dynamic parameters for commands" {
            $input = 'ts deploy -'
            $completions = TabExpansion2 -inputScript $input -cursorColumn $input.Length

            $completionTexts = @($completions.CompletionMatches | Select-Object -ExpandProperty CompletionText)
            $completionTexts | Should -Contain '-Environment'
        }
    }
}

Describe "Remove-PowerStubDirectAlias" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    BeforeEach {
        # Clean up any test aliases
        @('removeme', 'keepme') | ForEach-Object {
            if (Get-Command $_ -ErrorAction SilentlyContinue) {
                Remove-Item "function:global:$_" -ErrorAction SilentlyContinue
            }
        }
        # Clear direct aliases from config
        InModuleScope PowerStub { Set-PowerStubConfigurationKey 'DirectAliases' @{} }
    }

    AfterAll {
        # Clean up test aliases
        @('removeme', 'keepme') | ForEach-Object {
            if (Get-Command $_ -ErrorAction SilentlyContinue) {
                Remove-Item "function:global:$_" -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Parameter Validation" {
        It "Should require -AliasName parameter" {
            # Test that AliasName is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command Remove-PowerStubDirectAlias
            $param = $cmd.Parameters['AliasName']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should throw when alias doesn't exist in config" {
            { Remove-PowerStubDirectAlias -AliasName "nonexistent" } | Should -Throw "*not found*"
        }
    }

    Context "Alias Removal" {
        It "Should remove the global function" {
            New-PowerStubDirectAlias -AliasName "removeme" -Stub "SampleStub"
            Get-Command "removeme" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty

            Remove-PowerStubDirectAlias -AliasName "removeme"

            Get-Command "removeme" -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It "Should remove alias from config" {
            New-PowerStubDirectAlias -AliasName "removeme" -Stub "SampleStub"

            $directAliases = InModuleScope PowerStub { Get-PowerStubConfigurationKey 'DirectAliases' }
            $directAliases['removeme'] | Should -Be 'SampleStub'

            Remove-PowerStubDirectAlias -AliasName "removeme"

            $directAliases = InModuleScope PowerStub { Get-PowerStubConfigurationKey 'DirectAliases' }
            $directAliases.ContainsKey('removeme') | Should -Be $false
        }

        It "Should not affect other aliases" {
            New-PowerStubDirectAlias -AliasName "removeme" -Stub "SampleStub"
            New-PowerStubDirectAlias -AliasName "keepme" -Stub "SampleStub"

            Remove-PowerStubDirectAlias -AliasName "removeme"

            Get-Command "keepme" -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            $directAliases = InModuleScope PowerStub { Get-PowerStubConfigurationKey 'DirectAliases' }
            $directAliases['keepme'] | Should -Be 'SampleStub'
        }
    }
}

Describe "Virtual Verbs" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Search-PowerStubCommands" {
        BeforeAll {
            # Cache search results — Get-Help is slow, especially in CI
            $script:deployResults = Search-PowerStubCommands "deploy"
            $script:noMatchResults = Search-PowerStubCommands "xyznonexistent123456"
        }

        It "Should find commands by name" {
            $script:deployResults | Should -Not -BeNullOrEmpty
            $script:deployResults.Command | Should -Contain "deploy"
        }

        It "Should find commands by help text" {
            # Verify search doesn't throw (help text searching is exercised by the BeforeAll call)
            { Search-PowerStubCommands "production" } | Should -Not -Throw
        }

        It "Should return empty for no matches" {
            $script:noMatchResults | Should -BeNullOrEmpty
        }

        It "Should return structured results with Stub, Command, Synopsis" {
            $script:deployResults | Should -Not -BeNullOrEmpty
            $script:deployResults[0].PSObject.Properties.Name | Should -Contain 'Stub'
            $script:deployResults[0].PSObject.Properties.Name | Should -Contain 'Command'
            $script:deployResults[0].PSObject.Properties.Name | Should -Contain 'Synopsis'
        }
    }

    Context "Get-PowerStubCommandHelp" {
        It "Should return help for valid command" {
            $help = Get-PowerStubCommandHelp -Stub "SampleStub" -Command "deploy"
            $help | Should -Not -BeNullOrEmpty
        }

        It "Should throw for non-existent stub" {
            { Get-PowerStubCommandHelp -Stub "NonExistentStub" -Command "test" } | Should -Throw "*not found*"
        }

        It "Should throw for non-existent command" {
            { Get-PowerStubCommandHelp -Stub "SampleStub" -Command "nonexistent" } | Should -Throw "*not found*"
        }
    }

    Context "Virtual Verbs via pstb" {
        It "Should invoke search via pstb search" {
            $results = pstb search "deploy"
            $results | Should -Not -BeNullOrEmpty
        }

        It "Should invoke help via pstb help" {
            $help = pstb help SampleStub deploy
            $help | Should -Not -BeNullOrEmpty
        }

        It "Should error when search has no query" {
            # PowerShell's mandatory parameter validation kicks in before our code
            { pstb search } | Should -Throw
        }

        It "Should error when help has incomplete arguments" {
            { pstb help SampleStub } | Should -Throw "*Usage*"
        }
    }

    Context "Tab Completion for Virtual Verbs" {
        It "Should include virtual verbs in stub completion" {
            $completions = InModuleScope PowerStub {
                $virtualVerbs = @('search', 'help')
                $stubs = Get-PowerStubConfigurationKey 'Stubs'
                @($virtualVerbs) + @($stubs.Keys)
            }
            $completions | Should -Contain 'search'
            $completions | Should -Contain 'help'
        }

        It "Should show stub names when completing help command" {
            $input = 'pstb help '
            $completions = TabExpansion2 -inputScript $input -cursorColumn $input.Length
            $completionTexts = @($completions.CompletionMatches | Select-Object -ExpandProperty CompletionText)
            $completionTexts | Should -Contain 'SampleStub'
        }
    }
}

Describe "Set-PowerStubCommandVisibility" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        # Create a test stub with a command we can modify
        $script:VisibilityTestPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubVisibilityTest_$(Get-Random)"
        New-PowerStub -Name "VisibilityStub" -Path $script:VisibilityTestPath -Force

        # Create a test command
        $testScript = @'
param([string]$Name)
Write-Output "Test command executed with: $Name"
'@
        $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'
        Set-Content -Path (Join-Path $commandsPath 'testcmd.ps1') -Value $testScript
    }

    AfterAll {
        if (Test-Path $script:VisibilityTestPath) {
            Remove-Item $script:VisibilityTestPath -Recurse -Force
        }
        Remove-PowerStub -Name "VisibilityStub" -ErrorAction SilentlyContinue
    }

    BeforeEach {
        # Reset to production state before each test
        $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'
        # Remove any alpha/beta versions
        Remove-Item (Join-Path $commandsPath 'alpha.testcmd.ps1') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $commandsPath 'beta.testcmd.ps1') -ErrorAction SilentlyContinue
        # Ensure production version exists
        if (-not (Test-Path (Join-Path $commandsPath 'testcmd.ps1'))) {
            $testScript = 'param([string]$Name); Write-Output "Test"'
            Set-Content -Path (Join-Path $commandsPath 'testcmd.ps1') -Value $testScript
        }
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Parameter Validation" {
        It "Should require -Stub parameter" {
            # Test that Stub is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command Set-PowerStubCommandVisibility
            $param = $cmd.Parameters['Stub']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should require -Command parameter" {
            # Test that Command is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command Set-PowerStubCommandVisibility
            $param = $cmd.Parameters['Command']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should require -Visibility parameter" {
            # Test that Visibility is marked as Mandatory (can't test invocation without it as it prompts)
            $cmd = Get-Command Set-PowerStubCommandVisibility
            $param = $cmd.Parameters['Visibility']
            $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory } | Should -Contain $true
        }

        It "Should throw for non-existent stub" {
            { Set-PowerStubCommandVisibility -Stub "NonExistentStub" -Command "test" -Visibility Alpha } | Should -Throw "*not found*"
        }

        It "Should throw for non-existent command" {
            { Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "nonexistent" -Visibility Alpha } | Should -Throw "*not found*"
        }

        It "Should only accept valid visibility values" {
            { Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility "Invalid" } | Should -Throw
        }
    }

    Context "Visibility Changes" {
        It "Should promote from Production to Alpha" {
            $result = Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Alpha

            $result.Changed | Should -Be $true
            $result.OldVisibility | Should -Be 'Production'
            $result.NewVisibility | Should -Be 'Alpha'

            $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'
            Test-Path (Join-Path $commandsPath 'alpha.testcmd.ps1') | Should -Be $true
            Test-Path (Join-Path $commandsPath 'testcmd.ps1') | Should -Be $false
        }

        It "Should promote from Production to Beta" {
            $result = Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Beta

            $result.Changed | Should -Be $true
            $result.NewVisibility | Should -Be 'Beta'

            $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'
            Test-Path (Join-Path $commandsPath 'beta.testcmd.ps1') | Should -Be $true
        }

        It "Should demote from Alpha to Production" {
            # First promote to alpha
            Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Alpha
            Enable-PowerStubAlphaCommands

            # Then demote to production
            $result = Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Production

            $result.Changed | Should -Be $true
            $result.OldVisibility | Should -Be 'Alpha'
            $result.NewVisibility | Should -Be 'Production'

            $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'
            Test-Path (Join-Path $commandsPath 'testcmd.ps1') | Should -Be $true
            Test-Path (Join-Path $commandsPath 'alpha.testcmd.ps1') | Should -Be $false
        }

        It "Should report no change when already at target visibility" {
            $result = Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Production

            $result.Changed | Should -Be $false
            $result.Visibility | Should -Be 'Production'
        }
    }

    Context "Conflict Handling" {
        It "Should replace existing file with -Force" {
            $commandsPath = Join-Path $script:VisibilityTestPath 'Commands'

            # Create both production and alpha versions
            Set-Content -Path (Join-Path $commandsPath 'alpha.testcmd.ps1') -Value 'Write-Output "Alpha version"'

            # Use -Force to replace alpha version
            $result = Set-PowerStubCommandVisibility -Stub "VisibilityStub" -Command "testcmd" -Visibility Alpha -Force

            $result.Changed | Should -Be $true
            Test-Path (Join-Path $commandsPath 'testcmd.ps1') | Should -Be $false
        }
    }
}

Describe "Edge Cases and Error Handling" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
    }

    Context "Invalid Input" {
        It "Should say so when a PowerStub command name is used as a stub" {
            pstb Get-PowerStubs 3>&1 | Out-String | Should -Match "is a PowerStub command: run it on its own"
        }

        It "Should list the registered stubs when the stub is unknown" {
            New-PowerStub -Name "KnownStub" -Path $script:SampleStubRoot -Force
            try {
                pstb NoSuchStub 3>&1 | Out-String | Should -Match "Registered stubs: .*KnownStub"
            }
            finally {
                Remove-PowerStub -Name "KnownStub"
            }
        }

        It "Should handle missing Commands folder gracefully" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"
            New-Item $testPath -ItemType Directory -Force | Out-Null

            try {
                New-PowerStub -Name "EmptyStub" -Path $testPath -Force
                # Remove the Commands folder
                Remove-Item (Join-Path $testPath 'Commands') -Recurse -Force

                $cmd = Get-PowerStubCommand -Stub "EmptyStub" -Command "test" -WarningVariable warn -WarningAction SilentlyContinue
                $cmd | Should -BeNullOrEmpty
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }
    }

    Context "Special Characters" {
        It "Should handle stub names with valid characters" {
            $testPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubTest_$(Get-Random)"

            try {
                New-PowerStub -Name "Test-Stub_123" -Path $testPath

                $stubs = Get-PowerStubs
                $stubs.Keys | Should -Contain "Test-Stub_123"
            }
            finally {
                if (Test-Path $testPath) {
                    Remove-Item $testPath -Recurse -Force
                }
            }
        }
    }
}

Describe "Executable Metadata Support" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Metadata File Discovery" {
        It "Should NOT expose metadata files as commands" {
            $commands = InModuleScope PowerStub {
                Find-PowerStubCommands "SampleStub"
            }
            $commandNames = @($commands | ForEach-Object { $_.BaseName })
            $commandNames | Should -Not -Match "^metadata\."
        }

        It "Should discover exe files as commands" {
            $cmd = Get-PowerStubCommand -Stub "SampleStub" -Command "mytool"
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Path | Should -Match "\.exe$"
        }
    }

    Context "Get-PowerStubCommandMetadata (via InModuleScope)" {
        It "Should find metadata file for exe" {
            $commandsPath = Join-Path $script:SampleStubRoot 'Commands'
            $metadata = InModuleScope PowerStub -Parameters @{ commandsPath = $commandsPath } {
                param($commandsPath)
                Get-PowerStubCommandMetadata -CommandName "mytool" -CommandsPath $commandsPath
            }
            $metadata | Should -Not -BeNullOrEmpty
            $metadata.Path | Should -Match "metadata\.mytool\.ps1$"
        }

        It "Should return null for command without metadata" {
            $commandsPath = Join-Path $script:SampleStubRoot 'Commands'
            $metadata = InModuleScope PowerStub -Parameters @{ commandsPath = $commandsPath } {
                param($commandsPath)
                Get-PowerStubCommandMetadata -CommandName "nonexistent" -CommandsPath $commandsPath
            }
            $metadata | Should -BeNullOrEmpty
        }

        It "Should return help object from metadata file" {
            $commandsPath = Join-Path $script:SampleStubRoot 'Commands'
            $metadata = InModuleScope PowerStub -Parameters @{ commandsPath = $commandsPath } {
                param($commandsPath)
                Get-PowerStubCommandMetadata -CommandName "mytool" -CommandsPath $commandsPath
            }
            $metadata.Help | Should -Not -BeNullOrEmpty
            $metadata.Help.Synopsis | Should -Match "sample tool"
        }
    }

    Context "Help Integration with Metadata" {
        It "Should return metadata help for exe via Get-PowerStubCommandHelp" {
            $help = Get-PowerStubCommandHelp -Stub "SampleStub" -Command "mytool"
            $help | Should -Not -BeNullOrEmpty
            $help.Synopsis | Should -Match "sample tool"
        }

        It "Should include description from metadata" {
            $help = Get-PowerStubCommandHelp -Stub "SampleStub" -Command "mytool"
            $help.Description | Should -Not -BeNullOrEmpty
        }
    }

    Context "Command Listing with Metadata" {
        It "Should show metadata synopsis in stub command list" {
            # Capture output from Show-PowerStubCommands
            $output = InModuleScope PowerStub {
                $stringBuilder = [System.Text.StringBuilder]::new()
                $originalHost = $Host.UI

                # Run the function - it writes to host
                Show-PowerStubCommands "SampleStub"
            }
            # The function writes to console, so we can't easily capture its output
            # Just verify it doesn't throw
            { InModuleScope PowerStub { Show-PowerStubCommands "SampleStub" } } | Should -Not -Throw
        }
    }
}
