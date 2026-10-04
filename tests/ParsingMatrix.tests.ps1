#Requires -Modules Pester
<#
.SYNOPSIS
    Parsing matrix: 300 sample calls, each run directly and through pstb, which must agree.

.DESCRIPTION
    The cases live in ParsingMatrix.cases.ps1. For every case the same argument text is run
    through the main proxy and a registered direct alias, and compared with:

        & '<target>' <argument text>              # what the user would get without PowerStub
        pstb <stub> <command> <argument text>     # what they get through the proxy

    The targets only echo what they received (tests/parsing_stub_root and
    tests/fixtures/echoargs.cs), so any difference between the two results is an argument
    that was lost, split, merged, re-typed or re-quoted by the proxy. Errors are compared by
    kind, so a call that fails directly must fail the same way through pstb.

    The default gate runs all passing cases. Only the exact platform-specific inputs enumerated in
    ParsingMatrix.KnownIssues.psd1 are tagged KnownIssue and excluded by the runners.
    Run the entire matrix, including those expected failures, with:
      ./dev-test.ps1 -Tag ParsingMatrix -IncludeKnownIssues
    For a summary by category:  ./tests/Show-ParsingMatrix.ps1

    Windows compiles echoargs.cs with the .NET Framework csc.exe. Linux compiles
    a tiny argv-only C target with cc, gcc or clang. If no compiler is available, only
    native cases are skipped with a warning. CI requires native coverage and installs
    gcc; POWERSTUB_REQUIRE_NATIVE_MATRIX=1 turns a missing compiler into a failure.
#>

BeforeDiscovery {
    $script:MatrixCases = @(& (Join-Path $PSScriptRoot 'ParsingMatrix.cases.ps1'))
    $script:KnownMatrixCases = @( (Import-PowerShellDataFile (Join-Path $PSScriptRoot 'ParsingMatrix.KnownIssues.psd1')).Cases )
    $script:KnownMatrixIds = @($script:KnownMatrixCases | Where-Object {
        $_.Platform -eq 'All' -or ($IsLinux -and $_.Platform -eq 'Linux')
    } | ForEach-Object Id)
    $script:MatrixCompiler = $null
    if ($IsWindows) {
        foreach ($framework in 'Framework64', 'Framework') {
            $candidate = Join-Path $env:WINDIR "Microsoft.NET/$framework/v4.0.30319/csc.exe"
            if (Test-Path -LiteralPath $candidate) {
                $script:MatrixCompiler = $candidate
                break
            }
        }
    }
    elseif ($IsLinux) {
        $compiler = Get-Command cc, gcc, clang -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($compiler) { $script:MatrixCompiler = $compiler.Source }
    }
    $script:NativeMatrixAvailable = $null -ne $script:MatrixCompiler
}

Describe "Parsing matrix" -Tag 'ParsingMatrix' -ForEach @{
    Compiler = $script:MatrixCompiler; NativeAvailable = $script:NativeMatrixAvailable
} {
    BeforeAll {
        $script:MatrixCompiler = $Compiler
        $script:NativeMatrixAvailable = $NativeAvailable
        $script:OriginalEnvironment = @{}
        foreach ($name in 'POWERSTUB_CONFIG_DIR', 'PSTB_MATRIX') {
            $script:OriginalEnvironment[$name] = @{
                Exists = Test-Path "Env:$name"
                Value = [Environment]::GetEnvironmentVariable($name)
            }
        }
        $script:LocationPushed = $false
        if (-not $script:NativeMatrixAvailable) {
            $reason = 'Native parsing matrix requires .NET Framework csc.exe on Windows or cc/gcc/clang on Linux.'
            if ($env:POWERSTUB_REQUIRE_NATIVE_MATRIX -eq '1') { throw $reason }
            Write-Warning "$reason Native cases will be skipped; explicitly excluded KnownIssue cases stay excluded."
        }

        $existing = Get-Module -Name 'PowerStub'
        if ($existing) {
            Remove-Module -ModuleInfo $existing -Force
        }

        # Point the module at a throwaway config dir so the tests never touch the real config
        $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
        $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

        Import-Module (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1') -Force

        # Script targets
        $script:ScriptStubRoot = Join-Path $PSScriptRoot 'parsing_stub_root'
        New-PowerStub -Name 'MatrixScripts' -Path $script:ScriptStubRoot -Force
        New-PowerStubDirectAlias -AliasName 'MatrixDirectScripts' -Stub 'MatrixScripts'

        # A real native executable exercises PowerShell's native argument binder. Keeping
        # the .exe suffix on Unix matches the product's intentionally narrow discovery.
        $script:ExeStubRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBMatrixExe_$([guid]::NewGuid())"
        $exeCommands = Join-Path $script:ExeStubRoot 'Commands'
        New-Item -Path $exeCommands -ItemType Directory -Force | Out-Null
        $script:ExeTarget = Join-Path $exeCommands 'echoargs.exe'
        if ($script:NativeMatrixAvailable) {
            if ($IsWindows) {
                $source = Join-Path $PSScriptRoot 'fixtures/echoargs.cs'
                $compileOutput = & $script:MatrixCompiler /nologo /optimize+ /target:exe "/out:$script:ExeTarget" $source 2>&1
            }
            else {
                # Unix exposes argv, not a Windows raw command line. Compare the actual
                # Count/Args JSON here; Windows also retains its RawTail comparison.
                $source = Join-Path $script:ExeStubRoot 'echoargs.c'
                @'
#include <stdio.h>
static void quote(const unsigned char *s) {
    putchar('"');
    for (; *s; ++s) {
        if (*s == '"' || *s == '\\') { putchar('\\'); putchar(*s); }
        else if (*s < 32) printf("\\u%04x", *s);
        else putchar(*s);
    }
    putchar('"');
}
int main(int argc, char **argv) {
    printf("{\"Count\":%d,\"Args\":[", argc - 1);
    for (int i = 1; i < argc; ++i) {
        if (i > 1) putchar(',');
        quote((const unsigned char *)argv[i]);
    }
    puts("]}");
    return 0;
}
'@ | Set-Content -LiteralPath $source -Encoding utf8
                $compileOutput = & $script:MatrixCompiler -std=c99 -Wall -Wextra -Werror -O2 $source -o $script:ExeTarget 2>&1
            }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:ExeTarget)) {
                throw "Could not compile the native parsing fixture: $compileOutput"
            }
            New-PowerStub -Name 'MatrixExe' -Path $script:ExeStubRoot -Force
            New-PowerStubDirectAlias -AliasName 'MatrixDirectExe' -Stub 'MatrixExe'
        }

        # Quoted globs must stay literal even when matching files exist. Do not let the
        # caller's current directory decide whether native argument-loss bugs appear.
        $script:MatrixWorkingDir = Join-Path $script:ExeStubRoot 'working'
        New-Item -ItemType Directory -Path $script:MatrixWorkingDir -Force | Out-Null
        foreach ($name in 'matrix-glob.txt', 'matrix-glob.ps1', 'file1.log') {
            '# parsing matrix fixture' | Set-Content -LiteralPath (Join-Path $script:MatrixWorkingDir $name)
        }
        Push-Location -LiteralPath $script:MatrixWorkingDir
        $script:LocationPushed = $true

        $env:PSTB_MATRIX = 'envvalue'

        # Variables the argument texts refer to
        $script:Prelude = @'
$str = 'hello world'; $word = 'alpha'; $num = 42; $dbl = 3.14; $empty = ''; $nul = $null; $flag = $true
$arr = @('one', 'two', 'three'); $path = 'C:\Program Files\App\'; $hash = @{ b = 2; a = 1 }
$splatArr = @('x', 'y'); $splatHash = @{ Name = 'splatted'; Count = 3 }
$namedArr = @('-Name', 'viaarray'); $tagsArr = @('-Tags', 'a', 'b')
'@

        # Runs "<invocation> <argument text>" and reduces the result to one comparable string.
        function Get-MatrixOutcome {
            param([string]$Invocation, [string]$ArgText)

            $scriptBlock = [scriptblock]::Create("$script:Prelude`n$Invocation $ArgText")
            try {
                # 6>: pstb announces the command with Write-Host, which is not part of the result.
                # 4> 5>: cases like -Verbose and -Debug switch those streams on.
                $items = & $scriptBlock 2>&1 3>$null 4>$null 5>$null 6>$null
            }
            catch {
                return 'THROW:' + ($_.FullyQualifiedErrorId -split ',')[0]
            }

            $lines = foreach ($item in $items) {
                if ($item -is [System.Management.Automation.ErrorRecord]) {
                    # The part after the comma names the command, which legitimately differs
                    'ERROR:' + ($item.FullyQualifiedErrorId -split ',')[0]
                }
                else {
                    "$item"
                }
            }
            return $lines -join "`n"
        }

        function Get-MatrixTarget {
            param([string]$Command)

            if ($Command -eq 'echoargs') {
                return [PSCustomObject]@{
                    Stub = 'MatrixExe'
                    Alias = 'MatrixDirectExe'
                    Path = $script:ExeTarget
                }
            }
            return [PSCustomObject]@{
                Stub = 'MatrixScripts'
                Alias = 'MatrixDirectScripts'
                Path = Join-Path $script:ScriptStubRoot "Commands\$Command.ps1"
            }
        }

        function Assert-MatrixCase {
            param([string]$Id, [string]$Group, [string]$Category, [string]$Command, [string]$ArgText)

            $target = Get-MatrixTarget $Command
            $direct = Get-MatrixOutcome -Invocation "& '$($target.Path)'" -ArgText $ArgText
            $proxied = Get-MatrixOutcome -Invocation "pstb $($target.Stub) $Command" -ArgText $ArgText
            $directAlias = Get-MatrixOutcome -Invocation "$($target.Alias) $Command" -ArgText $ArgText

            # Show-ParsingMatrix.ps1 collects both outcomes here for its report.
            if ($null -ne $global:PSTBMatrixResults) {
                $global:PSTBMatrixResults.Add([PSCustomObject]@{
                    Id = $Id; Group = $Group; Category = $Category; Command = $Command; ArgText = $ArgText
                    Match = ($proxied -ceq $direct); Direct = $direct; Proxied = $proxied
                    AliasMatch = ($directAlias -ceq $direct); DirectAlias = $directAlias
                })
            }

            $proxied | Should -BeExactly $direct -Because "arguments were: $ArgText"
            $directAlias | Should -BeExactly $direct -Because "direct-alias arguments were: $ArgText"
        }

    }

    It 'Preserves native syntax with the resolved command path: <Id>' -Skip:(-not $script:NativeMatrixAvailable) -ForEach $script:KnownMatrixCases {
        # Keep a passing escape hatch for every audited mismatch, without weakening the
        # original proxy equality assertions or trying to re-evaluate caller source.
        $direct = Get-MatrixOutcome -Invocation "& '$script:ExeTarget'" -ArgText $ArgText
        $resolved = Get-MatrixOutcome -Invocation "& (Get-PowerStubCommand -Stub MatrixExe -Command echoargs).Path" -ArgText $ArgText
        $resolved | Should -BeExactly $direct -Because "resolved-path arguments were: $ArgText"
    }

    It 'Keeps caller-local native argument mode <Mode> with the resolved command path' -Skip:(-not $script:NativeMatrixAvailable) -ForEach @(
        @{ Mode = 'Legacy' }
        @{ Mode = 'Standard' }
        @{ Mode = 'Windows' }
    ) {
        function Get-LocalNativeOutcome {
            param([string]$Invocation, [string]$Mode)
            # This preference deliberately belongs to a calling function, rather than
            # global/module scope. Native argument parsing must use that caller context.
            $PSNativeCommandArgumentPassing = $Mode
            Get-MatrixOutcome -Invocation $Invocation -ArgText ''''' ''"quoted"'' ''space value'' ''--'' ''-k:value'' ''a,b,c'' ''*.txt'''
        }
        $direct = Get-LocalNativeOutcome -Invocation "& '$script:ExeTarget'" -Mode $Mode
        $resolved = Get-LocalNativeOutcome -Invocation "& (Get-PowerStubCommand -Stub MatrixExe -Command echoargs).Path" -Mode $Mode
        $resolved | Should -BeExactly $direct
        $direct | Should -Not -BeNullOrEmpty
    }

    AfterAll {
        Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
        foreach ($name in $script:OriginalEnvironment.Keys) {
            if ($script:OriginalEnvironment[$name].Exists) {
                Set-Item -LiteralPath "Env:$name" -Value $script:OriginalEnvironment[$name].Value
            }
            else {
                Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
            }
        }
        if ($script:LocationPushed) { Pop-Location }
        foreach ($dir in $script:TestConfigDir, $script:ExeStubRoot) {
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }
    }

    It "Has 100 calls in each of the three groups" -ForEach @{ Cases = $script:MatrixCases } {
        $counts = $Cases | Group-Object Group | ForEach-Object { "$($_.Name)=$($_.Count)" }

        ($counts | Sort-Object) -join ' ' | Should -Be 'ExeGeneric=100 ExeRealWorld=100 Script=100'
        @($Cases.Id | Sort-Object -Unique).Count | Should -Be 300
    }

    It 'Excludes only audited native inputs on their affected platforms' -ForEach @{
        Cases = $script:MatrixCases; KnownCases = $script:KnownMatrixCases; ActiveKnownIds = $script:KnownMatrixIds
    } {
        # Pin IDs AND input text so inserting/reordering cases cannot silently exclude
        # a different call. Broadening this list requires a deliberate audited change.
        $auditedIds = 'E-032 E-034 E-035 E-076 R-010 R-017 R-020 R-048 R-052 R-059 R-065 R-066 R-067 R-085 R-093'
        $KnownCases.Count | Should -Be 17
        (($KnownCases | Where-Object Platform -eq 'All').Id | Sort-Object) -join ' ' | Should -BeExactly $auditedIds
        (($KnownCases | Where-Object Platform -eq 'Linux').Id | Sort-Object) -join ' ' | Should -BeExactly 'E-071 E-072'
        $expectedActiveIds = if ($IsLinux) { ($auditedIds + ' E-071 E-072').Split(' ') } else { $auditedIds.Split(' ') }
        ($ActiveKnownIds | Sort-Object) -join ' ' | Should -BeExactly (($expectedActiveIds | Sort-Object) -join ' ')
        @($Cases | Where-Object Id -notin $ActiveKnownIds).Count | Should -Be (300 - $expectedActiveIds.Count)
        foreach ($known in $KnownCases) {
            $matching = @($Cases | Where-Object Id -eq $known.Id)
            $matching.Count | Should -Be 1
            $matching[0].Group | Should -BeExactly $known.Group
            $matching[0].Group | Should -BeIn 'ExeGeneric', 'ExeRealWorld'
            $matching[0].Command | Should -BeExactly $known.Command
            $matching[0].ArgText | Should -BeExactly $known.ArgText
            $known.Platform | Should -BeIn 'All', 'Linux'
            $known.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context "<_> calls" -ForEach 'Script', 'ExeGeneric', 'ExeRealWorld' {
        BeforeDiscovery {
            $groupName = $_
            # Pester only turns hashtable keys into test variables ($Id, $ArgText, ...).
            $groupCases = @($script:MatrixCases | Where-Object Group -eq $groupName | ForEach-Object {
                @{ Group = $_.Group; Id = $_.Id; Category = $_.Category; Command = $_.Command; ArgText = $_.ArgText }
            })
            $passingCases = @($groupCases | Where-Object Id -notin $script:KnownMatrixIds)
            $knownCases = @($groupCases | Where-Object Id -in $script:KnownMatrixIds)
            $skipGroup = $groupName -like 'Exe*' -and -not $script:NativeMatrixAvailable
        }

        It "<Id> <Category> (<Command>)" -Skip:$skipGroup -ForEach $passingCases {
            Assert-MatrixCase -Id $Id -Group $Group -Category $Category -Command $Command -ArgText $ArgText
        }

        if ($knownCases.Count -gt 0) {
            It "<Id> <Category> (<Command>)" -Tag 'KnownIssue' -Skip:$skipGroup -ForEach $knownCases {
                # These still assert correct equivalence, never the known broken outcome.
                Assert-MatrixCase -Id $Id -Group $Group -Category $Category -Command $Command -ArgText $ArgText
            }
        }
    }
}
