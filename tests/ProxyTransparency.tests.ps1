#Requires -Modules Pester

<#
.SYNOPSIS
    Proxy transparency tests for PowerStub's argument forwarding.

.DESCRIPTION
    Tests that PowerStub's command proxy is TRANSPARENT - the target command should
    receive arguments identically to a direct invocation. These tests compare
    direct invocation results against proxied invocation results.

    Also covers gaps in argument forwarding:
    - Mixed dynamic params + remaining positional args (both non-empty)
    - Direct alias argument forwarding accuracy
    - Exit code propagation through the proxy
    - Literal parameter-like strings passed as values
    - Zero-arg invocation cleanliness (no phantom args from proxy machinery)
#>

BeforeAll {
    $module = Get-Module -Name 'PowerStub'
    if ($module) { Remove-Module -ModuleInfo $module -Force }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks

    $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $modulePath -Force

    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'

    Import-PowerStubConfiguration -Reset
    New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force

    # Helper: parse arg-echo output
    function Get-ArgEchoResult {
        param([string[]]$Output)
        $result = @{ ArgCount = 0; Args = @() }
        foreach ($line in $Output) {
            if ($line -match '^ARG_COUNT:(\d+)$') { $result.ArgCount = [int]$Matches[1] }
            elseif ($line -match '^ARG\[(\d+)\]:([^:]+):(.*)$') {
                $result.Args += @{ Index = [int]$Matches[1]; Type = $Matches[2]; Value = $Matches[3] }
            }
        }
        return $result
    }

    # Helper: parse arg-dump JSON output
    function Get-ArgDumpResult {
        param([string[]]$Output)
        $jsonLine = $Output | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        if ($jsonLine) { return $jsonLine | ConvertFrom-Json }
        return $null
    }

    # Helper: parse mixed-params JSON output
    function Get-MixedResult {
        param([string[]]$Output)
        $jsonLine = $Output | Where-Object { $_ -match '^\{' } | Select-Object -First 1
        if ($jsonLine) { return $jsonLine | ConvertFrom-Json }
        return $null
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

# =============================================================================
# PROXY TRANSPARENCY: Direct vs Proxied invocation
# =============================================================================
Describe "Proxy Transparency - Direct vs Proxied" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        $script:ArgEchoPath = Join-Path $script:SampleStubRoot 'Commands\arg-echo.ps1'
        $script:ArgDumpPath = Join-Path $script:SampleStubRoot 'Commands\arg-dump.ps1'
    }

    Context "Simple string arguments" {
        It "Should produce identical output for single arg" {
            $direct = & $script:ArgEchoPath "hello"
            $proxied = pstb SampleStub arg-echo "hello"

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.ArgCount | Should -Be $directResult.ArgCount
            $proxiedResult.Args[0].Value | Should -Be $directResult.Args[0].Value
        }

        It "Should produce identical output for multiple args" {
            $direct = & $script:ArgEchoPath "one" "two" "three"
            $proxied = pstb SampleStub arg-echo "one" "two" "three"

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.ArgCount | Should -Be $directResult.ArgCount
            for ($i = 0; $i -lt $directResult.ArgCount; $i++) {
                $proxiedResult.Args[$i].Value | Should -Be $directResult.Args[$i].Value
            }
        }

        It "Should produce identical output for string with spaces" {
            $direct = & $script:ArgEchoPath "hello world"
            $proxied = pstb SampleStub arg-echo "hello world"

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.ArgCount | Should -Be $directResult.ArgCount
            $proxiedResult.Args[0].Value | Should -Be $directResult.Args[0].Value
        }
    }

    Context "Named parameters via dynamic params" {
        It "Should produce identical output for named string param" {
            $direct = & $script:ArgDumpPath -StringParam "test value"
            $proxied = pstb SampleStub arg-dump -StringParam "test value"

            $directResult = Get-ArgDumpResult $direct
            $proxiedResult = Get-ArgDumpResult $proxied

            $proxiedResult.BoundParameters.StringParam.Value | Should -Be $directResult.BoundParameters.StringParam.Value
        }

        It "Should produce identical output for named int param" {
            $direct = & $script:ArgDumpPath -IntParam 42
            $proxied = pstb SampleStub arg-dump -IntParam 42

            $directResult = Get-ArgDumpResult $direct
            $proxiedResult = Get-ArgDumpResult $proxied

            $proxiedResult.BoundParameters.IntParam.Value | Should -Be $directResult.BoundParameters.IntParam.Value
        }

        It "Should produce identical output for switch param" {
            $direct = & $script:ArgDumpPath -SwitchParam
            $proxied = pstb SampleStub arg-dump -SwitchParam

            $directResult = Get-ArgDumpResult $direct
            $proxiedResult = Get-ArgDumpResult $proxied

            $proxiedResult.BoundParameters.SwitchParam.Value | Should -Be $directResult.BoundParameters.SwitchParam.Value
        }

        It "Should produce identical output for multiple named params" {
            $direct = & $script:ArgDumpPath -StringParam "hello" -IntParam 7 -SwitchParam
            $proxied = pstb SampleStub arg-dump -StringParam "hello" -IntParam 7 -SwitchParam

            $directResult = Get-ArgDumpResult $direct
            $proxiedResult = Get-ArgDumpResult $proxied

            $proxiedResult.BoundParameters.StringParam.Value | Should -Be $directResult.BoundParameters.StringParam.Value
            $proxiedResult.BoundParameters.IntParam.Value | Should -Be $directResult.BoundParameters.IntParam.Value
            $proxiedResult.BoundParameters.SwitchParam.Value | Should -Be $directResult.BoundParameters.SwitchParam.Value
        }
    }

    Context "Special characters" {
        It "Should handle JSON string identically" {
            $json = '{"key": "value", "num": 42}'
            $direct = & $script:ArgEchoPath $json
            $proxied = pstb SampleStub arg-echo $json

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.Args[0].Value | Should -Be $directResult.Args[0].Value
        }

        It "Should handle regex pattern identically" {
            $regex = '^[a-z]+\d{3}$'
            $direct = & $script:ArgEchoPath $regex
            $proxied = pstb SampleStub arg-echo $regex

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.Args[0].Value | Should -Be $directResult.Args[0].Value
        }

        It "Should handle path with spaces identically" {
            $path = 'C:\Program Files\My App\config.json'
            $direct = & $script:ArgEchoPath $path
            $proxied = pstb SampleStub arg-echo $path

            $directResult = Get-ArgEchoResult $direct
            $proxiedResult = Get-ArgEchoResult $proxied

            $proxiedResult.Args[0].Value | Should -Be $directResult.Args[0].Value
        }
    }
}

# =============================================================================
# MIXED DYNAMIC PARAMS + REMAINING ARGS
# =============================================================================
Describe "Mixed Dynamic Params + Remaining Args" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    Context "Named params with extra positional args" {
        It "Should forward both named param and extra args" {
            $output = pstb SampleStub mixed-params -Env "prod" extraArg1 extraArg2
            $result = Get-MixedResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.Named.Env | Should -Be "prod"
            $result.Extra.Count | Should -Be 2
            $result.Extra[0] | Should -Be "extraArg1"
            $result.Extra[1] | Should -Be "extraArg2"
        }

        It "Should forward switch + string param + extra args" {
            $output = pstb SampleStub mixed-params -Env "staging" -Force extraArg
            $result = Get-MixedResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.Named.Env | Should -Be "staging"
            $result.Switch | Should -Be $true
            $result.Extra.Count | Should -Be 1
            $result.Extra[0] | Should -Be "extraArg"
        }

        It "Should forward int param + multiple extra args" {
            $output = pstb SampleStub mixed-params -Count 5 one two three
            $result = Get-MixedResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.Named.Count | Should -Be 5
            $result.Extra.Count | Should -Be 3
        }

        It "Should forward only extra args when no named params match" {
            $output = pstb SampleStub mixed-params positional1 positional2
            $result = Get-MixedResult $output

            $result | Should -Not -BeNullOrEmpty
            # Env and Count should have defaults
            $result.Named.Env | Should -Be "default"
            $result.Named.Count | Should -Be 0
            # Extra args captured
            $result.Extra.Count | Should -Be 2
        }
    }
}

# =============================================================================
# EXIT CODE PROPAGATION
# =============================================================================
Describe "Exit Code Propagation" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    It "Should propagate exit code 0 on success" {
        $output = pstb SampleStub exit-code -Code 0
        $output | Should -Contain "EXIT_CODE:0"
        # LASTEXITCODE should be 0 after successful command
        $LASTEXITCODE | Should -Be 0
    }

    It "Should propagate non-zero exit code" {
        $output = pstb SampleStub exit-code -Code 42
        $output | Should -Contain "EXIT_CODE:42"
        $LASTEXITCODE | Should -Be 42
    }

    It "Should propagate exit code 1" {
        $output = pstb SampleStub exit-code -Code 1
        $output | Should -Contain "EXIT_CODE:1"
        $LASTEXITCODE | Should -Be 1
    }
}

# =============================================================================
# ZERO-ARG CLEANLINESS
# =============================================================================
Describe "Zero-Argument Invocation Cleanliness" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    It "Should pass zero args to no-args command" {
        $output = pstb SampleStub no-args
        $output | Should -Contain "NO_ARGS_SUCCESS"
    }

    It "Should not leak proxy machinery as phantom arguments" {
        # Specifically verify no --%, no empty strings, no null args leak through
        $output = pstb SampleStub arg-echo
        $result = Get-ArgEchoResult $output
        $result.ArgCount | Should -Be 0
    }
}

# =============================================================================
# DIRECT ALIAS ARGUMENT FORWARDING
# =============================================================================
Describe "Direct Alias Argument Forwarding" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        New-PowerStubDirectAlias -AliasName "tstproxy" -Stub "SampleStub" -Force | Out-Null
    }

    AfterAll {
        Remove-PowerStubDirectAlias -AliasName "tstproxy" -ErrorAction SilentlyContinue
    }

    Context "Basic alias forwarding" {
        It "Should forward single arg through alias" {
            $output = tstproxy arg-echo "hello"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "hello"
        }

        It "Should forward multiple args through alias" {
            $output = tstproxy arg-echo "one" "two" "three"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 3
            $result.Args[0].Value | Should -Be "one"
            $result.Args[1].Value | Should -Be "two"
            $result.Args[2].Value | Should -Be "three"
        }

        It "Should forward named params through alias" {
            $output = tstproxy arg-dump -StringParam "via alias"
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.StringParam.Value | Should -Be "via alias"
        }

        It "Should forward switch params through alias" {
            $output = tstproxy arg-dump -SwitchParam
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam.Value | Should -Be $true
        }

        It "Should forward mixed params + extra args through alias" {
            $output = tstproxy mixed-params -Env "prod" -Force extraArg
            $result = Get-MixedResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.Named.Env | Should -Be "prod"
            $result.Switch | Should -Be $true
            $result.Extra.Count | Should -Be 1
        }
    }

    Context "Alias vs pstb equivalence" {
        It "Should produce identical output via alias and pstb" {
            $viaPstb = pstb SampleStub arg-echo "test" "data" "123"
            $viaAlias = tstproxy arg-echo "test" "data" "123"

            $pstbResult = Get-ArgEchoResult $viaPstb
            $aliasResult = Get-ArgEchoResult $viaAlias

            $aliasResult.ArgCount | Should -Be $pstbResult.ArgCount
            for ($i = 0; $i -lt $pstbResult.ArgCount; $i++) {
                $aliasResult.Args[$i].Value | Should -Be $pstbResult.Args[$i].Value
            }
        }
    }
}

# =============================================================================
# PARAMETER-LIKE STRINGS AS VALUES
# =============================================================================
Describe "Parameter-Like Strings Passed as Values" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
    }

    It "Should pass --flag as a string value to arg-echo" {
        $output = pstb SampleStub arg-echo "--not-a-real-flag"
        $result = Get-ArgEchoResult $output

        $result.ArgCount | Should -Be 1
        $result.Args[0].Value | Should -Be "--not-a-real-flag"
    }

    It "Should pass -ShortFlag as string value" {
        $output = pstb SampleStub arg-echo "-x"
        $result = Get-ArgEchoResult $output

        $result.ArgCount | Should -Be 1
        $result.Args[0].Value | Should -Be "-x"
    }

    It "Should handle --key=value format" {
        $output = pstb SampleStub arg-echo "--config=production.json"
        $result = Get-ArgEchoResult $output

        $result.ArgCount | Should -Be 1
        $result.Args[0].Value | Should -Be "--config=production.json"
    }

    It "Should handle multiple flag-like strings" {
        $output = pstb SampleStub arg-echo "--verbose" "--dry-run" "--output=result.txt"
        $result = Get-ArgEchoResult $output

        $result.ArgCount | Should -Be 3
        $result.Args[0].Value | Should -Be "--verbose"
        $result.Args[1].Value | Should -Be "--dry-run"
        $result.Args[2].Value | Should -Be "--output=result.txt"
    }
}

# =============================================================================
# ARGUMENTS THE PROXY USED TO LOSE
# Regression tests for bugs fixed by making Invoke-PowerStubCommand a parameterless
# pass-through. tests/ParsingMatrix.tests.ps1 covers the same ground with 300 calls.
# =============================================================================
Describe "Arguments the proxy used to lose" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        $script:ArgEcho = Join-Path $script:SampleStubRoot 'Commands\arg-echo.ps1'

        $script:LostExeStubPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubLostExe_$(Get-Random)"
        $exeCommandsPath = Join-Path $script:LostExeStubPath 'Commands'
        New-Item -Path $exeCommandsPath -ItemType Directory -Force | Out-Null
        if ($IsWindows) {
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\cmd.exe') -Destination $exeCommandsPath
        }
        New-PowerStub -Name 'LostExeStub' -Path $script:LostExeStubPath -Force
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:LostExeStubPath) {
            Remove-Item -LiteralPath $script:LostExeStubPath -Recurse -Force
        }
    }

    It "InvokePowerStubCommand_ExeWithDashArgument_PassesArgumentThrough" -Skip:(-not $IsWindows) {
        $output = pstb LostExeStub cmd /c echo -v 6>$null

        $output | Should -Be '-v'
    }

    It "InvokePowerStubCommand_ExeFlagsThatLookLikePstbParameters_ReachTheExe" -Skip:(-not $IsWindows) {
        # -c used to bind to pstb's -Command, -o was ambiguous, -v became -Verbose
        $output = pstb LostExeStub cmd /c echo -c Release -o out -v -e K=V 6>$null

        $output | Should -Be '-c Release -o out -v -e K=V'
    }

    It "InvokePowerStubCommand_EmptyStringArgument_IsPassedThrough" {
        $direct = & $script:ArgEcho ''
        $proxied = pstb SampleStub arg-echo '' 6>$null

        $proxied | Should -Be $direct
        $proxied | Should -Contain 'ARG_COUNT:1'
    }

    It "InvokePowerStubCommand_LoneZeroArgument_IsPassedThrough" {
        $proxied = pstb SampleStub arg-echo 0 6>$null

        $proxied | Should -Contain 'ARG_COUNT:1'
        $proxied | Should -Contain 'ARG[0]:Int32:0'
    }

    It "InvokePowerStubCommand_ArrayArgument_ArrivesAsSingleArrayLikeDirectCall" {
        $arr = @('alpha', 'beta')

        $direct = & $script:ArgEcho $arr
        $proxied = pstb SampleStub arg-echo $arr 6>$null

        $proxied | Should -Be $direct
        $proxied | Should -Contain 'ARG[0]:Object[]:alpha beta'
    }

    It "InvokePowerStubCommand_SwitchWithExplicitFalse_IsOff" {
        $output = pstb SampleStub arg-dump -SwitchParam:$false 6>$null
        $result = Get-ArgDumpResult $output

        $result.BoundParameters.SwitchParam.Value | Should -Be 'False'
    }

    It "InvokePowerStubCommand_CommonParameterNames_GoToTheTargetNotToPstb" {
        $proxied = pstb SampleStub arg-echo -Verbose -ErrorAction Stop 6>$null

        $proxied | Should -Contain 'ARG_COUNT:3'
        $proxied | Should -Contain 'ARG[0]:String:-Verbose'
    }
}
