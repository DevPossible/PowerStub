#Requires -Modules Pester
<#
.SYNOPSIS
    Parsing matrix: 300 sample calls, each run directly and through pstb, which must agree.

.DESCRIPTION
    The cases live in ParsingMatrix.cases.ps1. For every case the same argument text is run
    twice:

        & '<target>' <argument text>              # what the user would get without PowerStub
        pstb <stub> <command> <argument text>     # what they get through the proxy

    The targets only echo what they received (tests/parsing_stub_root and
    tests/fixtures/echoargs.cs), so any difference between the two results is an argument
    that was lost, split, merged, re-typed or re-quoted by the proxy. Errors are compared by
    kind, so a call that fails directly must fail the same way through pstb.

    Tagged 'ParsingMatrix' and excluded from dev-test.ps1 and CI while known parsing bugs
    remain. Run it with:  ./dev-test.ps1 -Tag ParsingMatrix
    For a summary by category:  ./tests/Show-ParsingMatrix.ps1

    The EXE groups are Windows-only: echoargs.exe is compiled with the csc.exe that ships
    with Windows.
#>

BeforeDiscovery {
    $script:MatrixCases = @(& (Join-Path $PSScriptRoot 'ParsingMatrix.cases.ps1'))
}

BeforeAll {
    $existing = Get-Module -Name 'PowerStub'
    if ($existing) {
        Remove-Module -ModuleInfo $existing -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

    Import-Module (Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1') -Force

    # Script targets
    $script:ScriptStubRoot = Join-Path $PSScriptRoot 'parsing_stub_root'
    New-PowerStub -Name 'MatrixScripts' -Path $script:ScriptStubRoot -Force

    # EXE target, compiled into a temporary stub
    $script:ExeStubRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBMatrixExe_$([guid]::NewGuid())"
    $exeCommands = Join-Path $script:ExeStubRoot 'Commands'
    New-Item -Path $exeCommands -ItemType Directory -Force | Out-Null
    if ($IsWindows) {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        $source = Join-Path $PSScriptRoot 'fixtures\echoargs.cs'
        $compileOutput = & $csc /nologo /optimize+ /target:exe "/out:$exeCommands\echoargs.exe" $source
        if ($LASTEXITCODE -ne 0) {
            throw "Could not compile echoargs.exe: $compileOutput"
        }
    }
    New-PowerStub -Name 'MatrixExe' -Path $script:ExeStubRoot -Force

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
                Path = Join-Path $script:ExeStubRoot 'Commands\echoargs.exe'
            }
        }
        return [PSCustomObject]@{
            Stub = 'MatrixScripts'
            Path = Join-Path $script:ScriptStubRoot "Commands\$Command.ps1"
        }
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\PSTB_MATRIX -ErrorAction SilentlyContinue
    foreach ($dir in $script:TestConfigDir, $script:ExeStubRoot) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }
}

Describe "Parsing matrix" -Tag 'ParsingMatrix' {
    It "Has 100 calls in each of the three groups" -ForEach @{ Cases = $script:MatrixCases } {
        $counts = $Cases | Group-Object Group | ForEach-Object { "$($_.Name)=$($_.Count)" }

        ($counts | Sort-Object) -join ' ' | Should -Be 'ExeGeneric=100 ExeRealWorld=100 Script=100'
    }

    Context "<_> calls" -ForEach 'Script', 'ExeGeneric', 'ExeRealWorld' {
        BeforeDiscovery {
            $groupName = $_
            # Pester only turns hashtable keys into test variables ($Id, $ArgText, ...)
            $groupCases = @($script:MatrixCases | Where-Object Group -eq $groupName | ForEach-Object {
                @{ Group = $_.Group; Id = $_.Id; Category = $_.Category; Command = $_.Command; ArgText = $_.ArgText }
            })
            $skipGroup = $groupName -like 'Exe*' -and -not $IsWindows
        }

        It "<Id> <Category> (<Command>)" -Skip:$skipGroup -ForEach $groupCases {
            $target = Get-MatrixTarget $Command

            $direct = Get-MatrixOutcome -Invocation "& '$($target.Path)'" -ArgText $ArgText
            $proxied = Get-MatrixOutcome -Invocation "pstb $($target.Stub) $Command" -ArgText $ArgText

            # Show-ParsingMatrix.ps1 collects both outcomes here for its report
            if ($null -ne $global:PSTBMatrixResults) {
                $global:PSTBMatrixResults.Add([PSCustomObject]@{
                        Id = $Id; Group = $Group; Category = $Category; Command = $Command; ArgText = $ArgText
                        Match = ($proxied -ceq $direct); Direct = $direct; Proxied = $proxied
                    })
            }

            $proxied | Should -Be $direct -Because "arguments were: $ArgText"
        }
    }
}
