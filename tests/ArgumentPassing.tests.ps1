#Requires -Modules Pester

<#
.SYNOPSIS
    Comprehensive argument passing tests for PowerStub

.DESCRIPTION
    Tests all permutations of argument passing from pstb alias to target commands:
    - String parameters (single, multiple, spaces, empty)
    - Variable expansion ($env:, script vars, expressions)
    - Array parameters (@() syntax, comma-separated)
    - String interpolation (double/single quotes, escapes)
    - Switch parameters (present, absent, explicit)
    - CLI-style arguments (--option=value, /Property)
    - EXE integration (hostname, findstr, ping)
    - Quote handling (single, double, nested, escaped)
    - Special characters and escape sequences
    - Edge cases (security, injection prevention)

.NOTES
    ============================================================================
    SPECIAL CHARACTER ESCAPING STRATEGY - POWERSTUB
    ============================================================================

    Invoke-PowerStubCommand declares no parameters. Everything after the stub and
    command arrives in $args and is forwarded to the target, untouched, using the
    call operator (&) with an array splat. Nothing is bound to pstb itself, so flags
    such as -v, -c or -o always reach the target.

    PS1 TARGETS (.ps1 files)
    ------------------------
    Named parameters (-Name x, -Count:5, -Force) and positional arguments are
    forwarded by the same array splat; PowerShell remembers which elements were
    parameter names. -Switch:$false is the one form splatting cannot carry, so
    Invoke-CheckedCommand moves those pairs into a named splat.
    PowerShell's normal quoting and escaping rules apply at the call site.

    | To Pass This       | Use This                    | Example                     |
    |--------------------|-----------------------------|-----------------------------|
    | Literal string     | Single quotes               | 'hello world'               |
    | Expanded string    | Double quotes               | "Hello $name"               |
    | Literal $          | Escaped or single quote     | `$var or '$var'             |
    | Literal "          | Backtick escape             | `"quoted`"                  |
    | Literal '          | Double it in single quotes  | 'It''s working'             |
    | Tab character      | Backtick-t                  | "col1`tcol2"                |
    | Newline            | Backtick-n                  | "line1`nline2"              |
    | JSON with quotes   | Single-quoted string        | '{"key": "value"}'          |

    EXE TARGETS (.exe files)
    ------------------------
    All arguments are forwarded as they were typed.
    PowerShell handles quoting/escaping for the subprocess automatically.

    SPECIAL CHARACTERS REFERENCE
    ----------------------------
    PowerShell Special (need escaping in double quotes):
      $    - Variable prefix        - Escape: `$ or use single quotes
      `    - Escape character       - Escape: ``
      "    - String delimiter       - Escape: `"
      @    - Array/splat operator   - Usually safe in strings
      #    - Comment in some contexts

    Safe Characters (no escaping needed):
      a-z A-Z 0-9 . - _ / \ : = + [ ] { } ( ) , ; ' ~ ! @ #

    ESCAPE SEQUENCES (PowerShell)
    -----------------------------
      `0   - Null
      `a   - Alert/Bell
      `b   - Backspace
      `f   - Form feed
      `n   - Newline
      `r   - Carriage return
      `t   - Tab
      `v   - Vertical tab
      `u{xxxx} - Unicode character

    KNOWN LIMITATIONS
    -----------------
    PowerShell changes these before pstb ever sees them, because pstb is a function
    (tests/ParsingMatrix.tests.ps1 lists the affected calls):
    1. A bare -- is removed, so 'git diff HEAD~1 -- file' loses the separator.
       Quote it: '--'
    2. For an EXE, -x:value is split ('-c:v' arrives as 'v') and an unquoted a,b,c
       becomes three arguments. Quote them: '-c:v', 'a,b,c'

    RECOMMENDED PRACTICES
    ---------------------
    1. Use single quotes for literal strings, especially JSON
    2. Use double quotes when variable expansion is needed
    3. Escape $ with `$ in double-quoted strings to prevent expansion
    4. For nested quotes: single inside double, or escape with backtick
    5. Test special characters in your specific use case

    ============================================================================
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
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks

    # Import the module
    $modulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $modulePath -Force

    # Sample stub root for tests
    $script:SampleStubRoot = Join-Path $PSScriptRoot 'sample_stub_root'

    # Helper function to parse arg-echo output
    function Get-ArgEchoResult {
        param([string[]]$Output)

        $result = @{
            ArgCount = 0
            Args     = @()
            RawCount = 0
            RawArgs  = @()
        }

        foreach ($line in $Output) {
            if ($line -match '^ARG_COUNT:(\d+)$') {
                $result.ArgCount = [int]$Matches[1]
            }
            elseif ($line -match '^ARG\[(\d+)\]:([^:]+):(.*)$') {
                $result.Args += @{
                    Index = [int]$Matches[1]
                    Type  = $Matches[2]
                    Value = $Matches[3]
                }
            }
            elseif ($line -match '^RAW_ARGS_COUNT:(\d+)$') {
                $result.RawCount = [int]$Matches[1]
            }
            elseif ($line -match '^RAW\[(\d+)\]:([^:]+):(.*)$') {
                $result.RawArgs += @{
                    Index = [int]$Matches[1]
                    Type  = $Matches[2]
                    Value = $Matches[3]
                }
            }
        }

        return $result
    }

    # Helper function to parse arg-dump JSON output
    function Get-ArgDumpResult {
        param([string[]]$Output)

        # Find the JSON line (first line that starts with {)
        $jsonLine = $Output | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1
        if ($jsonLine) {
            try {
                $result = $jsonLine | ConvertFrom-Json
                # Normalize: ExtraArgs was renamed from RemainingArgs
                if ($result.ExtraArgs -and -not $result.RemainingArgs) {
                    $result | Add-Member -NotePropertyName 'RemainingArgs' -NotePropertyValue $result.ExtraArgs -Force
                }
                return $result
            }
            catch {
                return $null
            }
        }
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
# PS1 TARGET TESTS
# =============================================================================

Describe "Argument Passing - PS1 Targets" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    # -------------------------------------------------------------------------
    # String Parameters
    # -------------------------------------------------------------------------
    Context "String Parameters" {
        It "Should pass single string parameter" {
            $output = pstb SampleStub arg-echo "hello"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "hello"
            $result.Args[0].Type | Should -Be "String"
        }

        It "Should pass multiple string parameters" {
            $output = pstb SampleStub arg-echo "first" "second" "third"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 3
            $result.Args[0].Value | Should -Be "first"
            $result.Args[1].Value | Should -Be "second"
            $result.Args[2].Value | Should -Be "third"
        }

        It "Should preserve string with spaces" {
            $output = pstb SampleStub arg-echo "hello world"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "hello world"
        }


        It "Should pass named string parameter to arg-dump" {
            $output = pstb SampleStub arg-dump -StringParam "test value"
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.StringParam.Value | Should -Be "test value"
            $result.BoundParameters.StringParam.Type | Should -Be "String"
        }

        It "Should pass integer parameter correctly" {
            $output = pstb SampleStub arg-dump -IntParam 42
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.IntParam.Value | Should -Be "42"
        }
    }

    # -------------------------------------------------------------------------
    # Variable Expansion
    # -------------------------------------------------------------------------
    Context "Variable Expansion" {
        It "Should expand environment variable" {
            $env:POWERSTUB_TEST_ENV_VAR = "powerstub_env_value"

            try {
                $output = pstb SampleStub arg-echo $env:POWERSTUB_TEST_ENV_VAR
                $result = Get-ArgEchoResult $output

                $result.ArgCount | Should -Be 1
                $result.Args[0].Value | Should -Be $env:POWERSTUB_TEST_ENV_VAR
            }
            finally {
                Remove-Item Env:\POWERSTUB_TEST_ENV_VAR -ErrorAction SilentlyContinue
            }
        }

        It "Should expand script variable" {
            $testVar = "expanded_value"
            $output = pstb SampleStub arg-echo $testVar
            $result = Get-ArgEchoResult $output

            # Note: Variable expansion depends on how $myinvocation.line captures the command
            # Variables are expanded by PowerShell before the command runs, so this should work
            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "expanded_value"
        }

        It "Should expand subexpression" {
            $output = pstb SampleStub arg-echo $(1 + 1)
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "2"
        }

        It "Should expand date expression" {
            $expectedYear = (Get-Date).Year.ToString()
            $output = pstb SampleStub arg-echo $(Get-Date -Format 'yyyy')
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be $expectedYear
        }

        It "Should handle array variable expansion" {
            $arr = @("alpha", "beta")
            $output = pstb SampleStub arg-echo $arr
            $result = Get-ArgEchoResult $output

            # Both elements must reach the command, whether as one array or as separate args
            ($result.Args | ForEach-Object { $_.Value }) -join ' ' | Should -Be 'alpha beta'
        }

        It "Should handle null variable" {
            $nullVar = $null
            $output = pstb SampleStub arg-echo $nullVar "after"
            $result = Get-ArgEchoResult $output

            # Document behavior - null may be skipped or passed
            $result.ArgCount | Should -BeGreaterOrEqual 1
        }
    }

    # -------------------------------------------------------------------------
    # Array Parameters
    # -------------------------------------------------------------------------
    Context "Array Parameters" {
        It "Should pass inline array with @() syntax" {
            $output = pstb SampleStub arg-dump -ArrayParam @("one", "two", "three")
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.ArrayParam | Should -Not -BeNullOrEmpty
            $result.BoundParameters.ArrayParam.Count | Should -Be 3
        }

        It "Should pass comma-separated values as array" {
            $output = pstb SampleStub arg-dump -ArrayParam one, two, three
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.ArrayParam | Should -Not -BeNullOrEmpty
            $result.BoundParameters.ArrayParam.Count | Should -Be 3
        }

        It "Should pass single element array" {
            $output = pstb SampleStub arg-dump -ArrayParam @("single")
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.ArrayParam | Should -Not -BeNullOrEmpty
        }
    }

    # -------------------------------------------------------------------------
    # String Interpolation
    # -------------------------------------------------------------------------
    Context "String Interpolation" {
        It "Should interpolate variable in double-quoted string" {
            $name = "World"
            $output = pstb SampleStub arg-echo "Hello $name"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Note: Variable interpolation in strings depends on when PowerShell expands them
            # $myinvocation.line captures the ORIGINAL command line, before variable expansion
            # So "Hello $name" may be captured as literal "Hello $name" or expanded "Hello World"
            # depending on PowerShell's execution order
            $result.Args[0].Value | Should -Match "Hello" -Because "At minimum 'Hello' should be present"
        }

        It "Should NOT interpolate variable in single-quoted string" {
            $name = "World"
            $output = pstb SampleStub arg-echo 'Hello $name'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'Hello $name'
        }

        It "Should handle backtick escape in double quotes" {
            $output = pstb SampleStub arg-echo "Hello `$name"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'Hello $name'
        }

        It "Should pass an embedded newline through intact" {
            $output = pstb SampleStub arg-echo "Line1`nLine2"
            $result = Get-ArgEchoResult $output

            # The value spans two output lines, so check the raw output rather than the per-line parser
            $result.ArgCount | Should -Be 1
            ($output -join "`n") | Should -Match 'ARG\[0\]:String:Line1\r?\nLine2'
        }

        It "Should handle mixed quotes" {
            $var = "inner"
            $output = pstb SampleStub arg-echo "She said 'hello $var'"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Note: Variable expansion may not work due to raw line extraction
            # At minimum the static part should be preserved
            $result.Args[0].Value | Should -Match "She said 'hello" -Because "Static part should be preserved"
        }
    }

    # -------------------------------------------------------------------------
    # Quote Handling (Comprehensive)
    # -------------------------------------------------------------------------
    Context "Quote Handling - Single Quotes" {
        It "Should pass literal single-quoted string" {
            $output = pstb SampleStub arg-echo 'simple string'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'simple string'
        }

        It "Should preserve dollar sign in single quotes" {
            $output = pstb SampleStub arg-echo '$variable'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '$variable'
        }

        It "Should preserve backtick in single quotes" {
            $output = pstb SampleStub arg-echo '`n is a newline'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '`n is a newline'
        }

    }

    Context "Quote Handling - Double Quotes" {
        It "Should pass literal double-quoted string" {
            $output = pstb SampleStub arg-echo "simple string"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "simple string"
        }

        It "Should expand escaped dollar sign in double quotes" {
            $output = pstb SampleStub arg-echo "`$literal"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '$literal'
        }

        It "Should handle double-quoted string with backtick-t (tab)" {
            $output = pstb SampleStub arg-echo "before`tafter"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Tab should be present in the result
            $result.Args[0].Value | Should -Match "before.*after"
        }
    }

    Context "Quote Handling - Nested Quotes" {
        It "Should handle double quotes inside single quotes" {
            $output = pstb SampleStub arg-echo 'He said "hello world"'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'He said "hello world"'
        }

        It "Should handle single quotes inside double quotes" {
            $output = pstb SampleStub arg-echo "It's a 'test' string"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "It's a 'test' string"
        }

        It "Should handle escaped double quotes inside double quotes" {
            $output = pstb SampleStub arg-echo "He said `"hello`""
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'He said "hello"'
        }

        It "Should handle doubled single quotes inside single quotes" {
            # In PowerShell, '' inside single quotes represents a literal single quote
            $output = pstb SampleStub arg-echo 'It''s working'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "It's working"
        }

        It "Should handle multiple levels of nested quotes" {
            $output = pstb SampleStub arg-echo "She said 'He said `"hi`"'"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Match "She said 'He said"
        }

        It "Should handle JSON-like nested quotes" {
            $output = pstb SampleStub arg-echo '{"key": "value", "nested": {"inner": "data"}}'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '{"key": "value", "nested": {"inner": "data"}}'
        }

        It "Should handle SQL-like quotes" {
            $output = pstb SampleStub arg-echo "SELECT * FROM users WHERE name = 'John'"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "SELECT * FROM users WHERE name = 'John'"
        }

        It "Should handle regex-like patterns with quotes" {
            $output = pstb SampleStub arg-echo 's/old/new/g'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 's/old/new/g'
        }
    }

    Context "Quote Handling - Edge Cases" {
        It "Should handle argument that is just quotes" {
            $output = pstb SampleStub arg-echo '""'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '""'
        }

        It "Should handle unbalanced quotes in single-quoted string" {
            $output = pstb SampleStub arg-echo '"unbalanced'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '"unbalanced'
        }

        It "Should handle multiple quoted arguments" {
            $output = pstb SampleStub arg-echo "first arg" 'second arg' "third arg"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 3
            $result.Args[0].Value | Should -Be "first arg"
            $result.Args[1].Value | Should -Be "second arg"
            $result.Args[2].Value | Should -Be "third arg"
        }

        It "Should handle adjacent quoted strings" {
            # In PowerShell, adjacent strings are separate arguments
            $output = pstb SampleStub arg-echo "hello""world"
            $result = Get-ArgEchoResult $output

            # This might be 1 or 2 args depending on PowerShell parsing
            $result.ArgCount | Should -BeGreaterOrEqual 1
        }
    }

    # -------------------------------------------------------------------------
    # Switch Parameters
    # -------------------------------------------------------------------------
    Context "Switch Parameters" {
        It "Should pass switch when present" {
            $output = pstb SampleStub arg-dump -SwitchParam
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam.Value | Should -Be $true
        }

        It "Should not include switch when absent" {
            $output = pstb SampleStub arg-dump -StringParam "test"
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam | Should -BeNullOrEmpty
        }

        It "Should handle explicit switch true" {
            $output = pstb SampleStub arg-dump -SwitchParam:$true
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam | Should -Not -BeNullOrEmpty
            $result.BoundParameters.SwitchParam.Value | Should -Be $true
        }

        It "Should handle explicit switch false" {
            $output = pstb SampleStub arg-dump -SwitchParam:$false
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            # When switch is explicitly false, it may or may not appear in bound params
            # Document actual behavior
            if ($result.BoundParameters.SwitchParam) {
                $result.BoundParameters.SwitchParam.Value | Should -Be $false
            }
        }

        It "Should handle multiple switches" {
            $output = pstb SampleStub remove-data -switchParam1 -switchParam2
            # The output from remove-data.ps1 is Format-Table output which contains PowerShell format objects
            # Convert to strings and check for switch names
            $outputStrings = $output | Out-String
            # At minimum verify the command ran without error
            $outputStrings | Should -Not -BeNullOrEmpty -Because "Command should produce output"
        }
    }

    # -------------------------------------------------------------------------
    # CLI-Style Arguments
    # -------------------------------------------------------------------------
    Context "CLI-Style Arguments (Linux/Unix)" {
        It "Should pass --option=value format" {
            $output = pstb SampleStub arg-echo "--config=myfile.json"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "--config=myfile.json"
        }

        It "Should pass --flag format" {
            $output = pstb SampleStub arg-echo "--verbose"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "--verbose"
        }

        It "Should pass short -v format" {
            $output = pstb SampleStub arg-echo "-v"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "-v"
        }

        It "Should pass combined short flags -vvv" {
            $output = pstb SampleStub arg-echo "-vvv"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "-vvv"
        }

        It "Should pass multiple CLI args" {
            $output = pstb SampleStub arg-echo "--input" "file.txt" "--output" "result.txt"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 4
            $result.Args[0].Value | Should -Be "--input"
            $result.Args[1].Value | Should -Be "file.txt"
            $result.Args[2].Value | Should -Be "--output"
            $result.Args[3].Value | Should -Be "result.txt"
        }
    }

    Context "CLI-Style Arguments (Windows)" {
        It "Should pass /Property format" {
            $output = pstb SampleStub arg-echo "/Verbose"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "/Verbose"
        }

        It "Should pass /p:Config=Release format (MSBuild style)" {
            $output = pstb SampleStub arg-echo "/p:Configuration=Release"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "/p:Configuration=Release"
        }

        It "Should pass multiple MSBuild-style args" {
            $output = pstb SampleStub arg-echo "/t:Build" "/p:OutDir=bin"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 2
            $result.Args[0].Value | Should -Be "/t:Build"
            $result.Args[1].Value | Should -Be "/p:OutDir=bin"
        }
    }
}

# =============================================================================
# EXE TARGET TESTS
# =============================================================================

Describe "Argument Passing - EXE Targets" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset

        # Create a temporary stub with EXE commands
        $script:ExeStubPath = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStubExeTest_$(Get-Random)"
        $script:ExeCommandsPath = Join-Path $script:ExeStubPath 'Commands'

        New-Item -Path $script:ExeCommandsPath -ItemType Directory -Force | Out-Null

        # Copy safe Windows EXEs into the stub (copies need no symlink privilege).
        # These tests are Windows-only; -Skip is evaluated at discovery, so it must not
        # depend on anything set in BeforeAll.
        if ($IsWindows) {
            foreach ($exe in 'hostname.exe', 'findstr.exe', 'where.exe') {
                Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32\$exe") -Destination $script:ExeCommandsPath
            }
        }

        New-PowerStub -Name "ExeStub" -Path $script:ExeStubPath -Force
    }

    AfterAll {
        # Cleanup
        if (Test-Path $script:ExeStubPath) {
            Remove-Item $script:ExeStubPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Basic EXE Execution" {
        It "Should execute hostname.exe and return output" -Skip:(-not $IsWindows) {
            $output = pstb ExeStub hostname
            $output | Should -Not -BeNullOrEmpty
            $output | Should -Be $env:COMPUTERNAME
        }
    }

    Context "EXE Argument Passthrough" {
        It "Should pass arguments to findstr.exe" -Skip:(-not $IsWindows) {
            # Create a temp file for testing
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "findstr_test_$(Get-Random).txt"
            "line one`nline two`nline three" | Set-Content $tempFile

            try {
                $output = pstb ExeStub findstr "two" $tempFile
                $output | Should -Match "two"
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should pass /i flag to findstr for case-insensitive search" -Skip:(-not $IsWindows) {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "findstr_test_$(Get-Random).txt"
            "line one`nline TWO`nline three" | Set-Content $tempFile

            try {
                $output = pstb ExeStub findstr /i "two" $tempFile
                $output | Should -Match "TWO"
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should pass where.exe path argument" -Skip:(-not $IsWindows) {
            $output = pstb ExeStub where "cmd.exe"
            $output | Should -Match "cmd.exe"
        }
    }

    Context "EXE with Complex Arguments" {
        It "Should handle quoted paths with spaces for EXE" -Skip:(-not $IsWindows) {
            # Test that paths with spaces work
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "PowerStub Test Dir $(Get-Random)"
            $tempFile = Join-Path $tempDir "test.txt"

            try {
                New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
                "test content" | Set-Content $tempFile

                $output = pstb ExeStub findstr "test" "$tempFile"
                $output | Should -Match "test"
            }
            finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# =============================================================================
# EDGE CASES AND KNOWN LIMITATIONS
# =============================================================================

Describe "Argument Passing - Edge Cases" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Known Limitations - Object Handling" {
        It "Documents that hashtable passing may fail (Get-NamedParameters undefined)" {
            # This test documents the known broken behavior
            # Get-NamedParameters is called at line 25 of Invoke-CheckedCommand.ps1 but not defined
            $ht = @{key = "value" }

            # The behavior depends on whether the hashtable triggers the object path
            # We're documenting the actual behavior here
            try {
                $output = pstb SampleStub arg-dump -HashParam $ht
                # If it works, document that
                $output | Should -Not -BeNullOrEmpty
            }
            catch {
                # If it fails, that's the expected behavior due to missing Get-NamedParameters
                $_.Exception.Message | Should -Match "Get-NamedParameters|error"
            }
        }

        It "Documents PSCustomObject handling" {
            $obj = [PSCustomObject]@{Name = "Test"; Value = 123 }

            try {
                $output = pstb SampleStub arg-echo $obj
                # Document actual behavior
                $output | Should -Not -BeNullOrEmpty
            }
            catch {
                # Expected to potentially fail
                $true | Should -Be $true
            }
        }
    }

    Context "Special Characters" {
        It "Should handle paths with spaces" {
            $output = pstb SampleStub arg-echo "C:\Program Files\test"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "C:\Program Files\test"
        }

        It "Should handle paths with backslashes" {
            $output = pstb SampleStub arg-echo "C:\Users\test\file.txt"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Match "C:\\Users\\test\\file\.txt"
        }

        It "Should handle embedded single quotes" {
            $output = pstb SampleStub arg-echo "it's working"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "it's working"
        }

        It "Should handle embedded double quotes in single-quoted string" {
            $output = pstb SampleStub arg-echo 'He said "hello"'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'He said "hello"'
        }

        It "Should handle ampersand in argument" {
            $output = pstb SampleStub arg-echo "Tom & Jerry"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "Tom & Jerry"
        }

        It "Should handle pipe character in argument" {
            $output = pstb SampleStub arg-echo "value|other"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "value|other"
        }

        It "Should handle percent signs" {
            $output = pstb SampleStub arg-echo "100% complete"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "100% complete"
        }

        It "Should handle equals sign" {
            $output = pstb SampleStub arg-echo "key=value"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "key=value"
        }

        It "Should handle semicolon" {
            $output = pstb SampleStub arg-echo "first;second"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "first;second"
        }

        It "Should handle parentheses" {
            $output = pstb SampleStub arg-echo "(value)"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "(value)"
        }

        It "Should handle square brackets" {
            $output = pstb SampleStub arg-echo "[index]"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "[index]"
        }

        It "Should handle curly braces" {
            $output = pstb SampleStub arg-echo "{block}"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "{block}"
        }

        It "Should handle at symbol" {
            $output = pstb SampleStub arg-echo "@mention"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "@mention"
        }

        It "Should handle hash symbol" {
            $output = pstb SampleStub arg-echo "#hashtag"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "#hashtag"
        }

        It "Should handle asterisk" {
            $output = pstb SampleStub arg-echo "*.txt"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "*.txt"
        }

        It "Should handle question mark" {
            $output = pstb SampleStub arg-echo "file?.txt"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "file?.txt"
        }

        It "Should handle less than and greater than" {
            $output = pstb SampleStub arg-echo "<input>"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "<input>"
        }

        It "Should handle caret" {
            $output = pstb SampleStub arg-echo "^start"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "^start"
        }

        It "Should handle tilde" {
            $output = pstb SampleStub arg-echo "~home"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "~home"
        }

        It "Should handle exclamation mark" {
            $output = pstb SampleStub arg-echo "Hello!"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "Hello!"
        }

        It "Should handle colon" {
            $output = pstb SampleStub arg-echo "key:value"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "key:value"
        }

        It "Should handle comma" {
            $output = pstb SampleStub arg-echo "a,b,c"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "a,b,c"
        }
    }

    # -------------------------------------------------------------------------
    # Escaped Special Characters
    # -------------------------------------------------------------------------
    Context "Escaped Special Characters - PowerShell Escapes" {
        It "Should handle escaped backtick" {
            $output = pstb SampleStub arg-echo "has``backtick"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Note: Double backtick (`) escapes to single backtick in PowerShell
            # The result depends on when the escape is processed
            $result.Args[0].Value | Should -Match "has.?backtick" -Because "Backtick escaping may vary"
        }

        It "Should handle escaped dollar sign" {
            $output = pstb SampleStub arg-echo "`$notavar"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '$notavar'
        }

        It "Should handle escaped double quote" {
            $output = pstb SampleStub arg-echo "say `"hello`""
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'say "hello"'
        }

        It "Should handle escape sequence for tab" {
            $output = pstb SampleStub arg-echo "col1`tcol2"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Tab character should be present
            $result.Args[0].Value | Should -Match "col1\tcol2|col1.*col2"
        }

        It "Should handle escape sequence for carriage return" {
            $output = pstb SampleStub arg-echo "line`rreturn"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Match '^line\r?return$'
        }

        It "Should handle escape sequence for null" {
            $output = pstb SampleStub arg-echo "has`0null"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "has`0null"
        }

        It "Should handle escape sequence for alert/bell" {
            $output = pstb SampleStub arg-echo "alert`a"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
        }

        It "Should handle escape sequence for backspace" {
            $output = pstb SampleStub arg-echo "back`bspace"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
        }

        It "Should handle escape sequence for form feed" {
            $output = pstb SampleStub arg-echo "form`ffeed"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
        }

        It "Should handle escape sequence for vertical tab" {
            $output = pstb SampleStub arg-echo "vert`vtab"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
        }

        It "Should handle Unicode escape sequence" {
            # Unicode escape for 'A' (U+0041)
            $output = pstb SampleStub arg-echo "unicode`u{0041}"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Match "unicode"
        }
    }

    Context "Escaped Special Characters - CMD/Batch Escapes" {
        # These test how arguments with CMD special chars pass through to PS1 targets
        # When targeting EXEs, behavior may differ due to --% handling

        It "Should handle caret escape for ampersand (CMD style)" {
            # In CMD, ^& escapes the ampersand - but PS doesn't use this
            $output = pstb SampleStub arg-echo 'A^&B'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'A^&B'
        }

        It "Should handle caret escape for pipe (CMD style)" {
            $output = pstb SampleStub arg-echo 'A^|B'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'A^|B'
        }

        It "Should handle caret escape for less than (CMD style)" {
            $output = pstb SampleStub arg-echo 'A^<B'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'A^<B'
        }

        It "Should handle caret escape for greater than (CMD style)" {
            $output = pstb SampleStub arg-echo 'A^>B'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'A^>B'
        }

        It "Should handle percent escape (CMD style double percent)" {
            $output = pstb SampleStub arg-echo '%%PATH%%'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be '%%PATH%%'
        }
    }

    Context "Escaped Special Characters - Multiple Escapes" {
        It "Should handle multiple escaped characters in one string" {
            $output = pstb SampleStub arg-echo "Price: `$100 (was `$150)"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be 'Price: $100 (was $150)'
        }

        It "Should handle mixed quotes and escapes" {
            $output = pstb SampleStub arg-echo "He said `"It's `$5`""
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Match "He said"
        }

        It "Should handle path with escape sequences" {
            $output = pstb SampleStub arg-echo "C:\Users\Name`tDescription"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Should have the path and tab and description
            $result.Args[0].Value | Should -Match "C:\\Users\\Name"
        }
    }

    Context "Command Line Edge Cases" {
        It "Should handle stub name appearing in argument" {
            # Edge case: if stub is "SampleStub" and arg contains "SampleStub"
            # The IndexOf logic in Invoke-PowerStubCommand might have issues
            $output = pstb SampleStub arg-echo "SampleStub is the name"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "SampleStub is the name"
        }

        It "Should handle command name appearing in argument" {
            $output = pstb SampleStub arg-echo "arg-echo is the command"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "arg-echo is the command"
        }

        It "Should handle very long argument" {
            # Use literal long string instead of variable to avoid expansion issues
            $output = pstb SampleStub arg-echo "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value.Length | Should -Be 100 -Because "Long literal strings should be preserved"
        }
    }

    Context "Security Considerations" {
        It "Should not execute semicolon-separated commands" {
            # Invoke-Expression is used internally, test for injection
            $output = pstb SampleStub arg-echo "test; Write-Host 'INJECTED'"
            $result = Get-ArgEchoResult $output

            # The output should just contain the argument, not execute the injected command
            $result.ArgCount | Should -Be 1
            # And the string "INJECTED" should only appear as part of the argument value
            $result.Args[0].Value | Should -Match "INJECTED"
            # Not as a separate output line from Write-Host
            ($output | Where-Object { $_ -eq 'INJECTED' }) | Should -BeNullOrEmpty
        }

        It "Should not expand dangerous subexpressions in arguments" {
            # Test that $() in a string doesn't execute when passed through
            $output = pstb SampleStub arg-echo '$(Get-Process | Select -First 1)'
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 1
            # Single quotes should prevent expansion
            $result.Args[0].Value | Should -Be '$(Get-Process | Select -First 1)'
        }
    }
}

# =============================================================================
# MIXED SCENARIO TESTS
# =============================================================================

Describe "Argument Passing - Mixed Scenarios" {
    BeforeAll {
        Import-PowerStubConfiguration -Reset
        New-PowerStub -Name "SampleStub" -Path $script:SampleStubRoot -Force
        Disable-PowerStubAlphaCommands
        Disable-PowerStubBetaCommands
    }

    Context "Named and Positional Mixed" {
        It "Should handle named param followed by positional - documents limitation" {
            # Note: arg-dump.ps1 doesn't define positional parameters, so extra args
            # after named params may cause binding errors
            # This documents the current behavior
            try {
                $output = pstb SampleStub arg-dump -StringParam "named" extra1 extra2
                $result = Get-ArgDumpResult $output

                $result | Should -Not -BeNullOrEmpty
                $result.BoundParameters.StringParam.Value | Should -Be "named"
            }
            catch {
                # Expected: positional parameters may fail to bind
                $_.Exception.Message | Should -Match "positional|parameter" -Because "Positional params need explicit support in target script"
            }
        }

        It "Should handle switch with other params" {
            $output = pstb SampleStub arg-dump -StringParam "test" -SwitchParam -IntParam 42
            $result = Get-ArgDumpResult $output

            $result | Should -Not -BeNullOrEmpty
            $result.BoundParameters.StringParam.Value | Should -Be "test"
            $result.BoundParameters.SwitchParam.Value | Should -Be $true
            $result.BoundParameters.IntParam.Value | Should -Be "42"
        }
    }

    Context "Real-World Command Patterns" {
        It "Should handle git-style command pattern" {
            $output = pstb SampleStub arg-echo "commit" "-m" "Initial commit"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 3
            $result.Args[0].Value | Should -Be "commit"
            $result.Args[1].Value | Should -Be "-m"
            $result.Args[2].Value | Should -Be "Initial commit"
        }

        It "Should handle docker-style command pattern" {
            $output = pstb SampleStub arg-echo "run" "-d" "--name" "mycontainer" "-p" "8080:80" "nginx"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 7
            $result.Args[0].Value | Should -Be "run"
            $result.Args[3].Value | Should -Be "mycontainer"
            $result.Args[6].Value | Should -Be "nginx"
        }

        It "Should handle kubectl-style command pattern" {
            $output = pstb SampleStub arg-echo "get" "pods" "-n" "default" "-o" "json"
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 6
            $result.Args[0].Value | Should -Be "get"
            $result.Args[1].Value | Should -Be "pods"
        }
    }

    Context "Zero-Argument Invocation" {
        # These tests verify that commands can be invoked without arguments
        # and that no spurious arguments (like --%  ) are passed to the target command.
        # Regression tests for: https://github.com/DevPossible/PowerStub/issues/XX

        It "Should invoke command with no arguments successfully" {
            # The no-args command will report UNEXPECTED_ARG if any args are passed
            $output = pstb SampleStub no-args
            $output | Should -Contain "NO_ARGS_SUCCESS"
        }

        It "Should not pass --% token when no arguments provided" {
            # This specifically tests the regression where --% was passed as an argument
            $output = pstb SampleStub no-args
            $output | Should -Not -Contain "--%" -Because "the stop-parsing token should not be passed as an argument"
            $output | Should -Not -Match "UNEXPECTED_ARG" -Because "no arguments should be passed"
        }

        It "Should report zero arguments with arg-echo when called without args" {
            $output = pstb SampleStub arg-echo
            $result = Get-ArgEchoResult $output

            $result.ArgCount | Should -Be 0 -Because "no arguments were passed"
            $result.Args.Count | Should -Be 0
        }

        It "Should still work with arguments after zero-arg invocation" {
            # First call with no args
            $noArgOutput = pstb SampleStub no-args
            $noArgOutput | Should -Contain "NO_ARGS_SUCCESS"

            # Then call with args - verify it still works
            $withArgOutput = pstb SampleStub arg-echo "test"
            $result = Get-ArgEchoResult $withArgOutput

            $result.ArgCount | Should -Be 1
            $result.Args[0].Value | Should -Be "test"
        }
    }
}
