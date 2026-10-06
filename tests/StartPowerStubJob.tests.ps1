#Requires -Modules Pester

<#
    Start-PowerStubJob (alias Start-PstbJob): Start-Job with PowerStub imported in the job, so
    pstb, Invoke-PowerStubCommand and direct aliases work in background jobs.

    Every test here starts real jobs. Tests that import or remove the module run in a fresh
    pwsh process so they cannot disturb the module this file is using.
#>

BeforeAll {
    $script:JobOriginalConfig = $env:POWERSTUB_CONFIG_DIR
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks
    $script:JobRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBJobs_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = Join-Path $script:JobRoot 'config'
    $script:JobManifest = (Resolve-Path (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1')).Path
    $script:JobPwsh = (Get-Process -Id $PID).Path
    Import-Module $script:JobManifest -Force

    $script:JobStubRoot = Join-Path $script:JobRoot 'stub'
    $commands = Join-Path $script:JobStubRoot 'Commands'
    [IO.Directory]::CreateDirectory($commands) | Out-Null
    $files = @{
        'echo.ps1'       = 'param([string]$Name = ''none'', [switch]$Loud) if ($Loud) { "ECHO:$Name" } else { "echo:$Name" }'
        'fail.ps1'       = '"failing"; exit 5'
        'throws.ps1'     = 'throw "target-threw"'
        'nested.ps1'     = 'pstb JobStub echo -Name nested'
        'nested-alias.ps1' = 'pstbjobalias echo -Name nested-alias'
        # The health-check pattern: a stub command that fans out to jobs which call stub commands.
        'fanout.ps1'     = 'param([string[]]$Names) $prefix = ''fan''; $jobs = foreach ($n in $Names) { Start-PowerStubJob { param($x) pstbjobalias echo -Name "$($using:prefix)-$x" 6>$null } -ArgumentList $n }; $jobs | Receive-Job -Wait -AutoRemoveJob'
    }
    foreach ($name in $files.Keys) {
        [IO.File]::WriteAllText((Join-Path $commands $name), $files[$name])
    }
    New-PowerStub -Name 'JobStub' -Path $script:JobStubRoot -Force | Out-Null
    New-PowerStubDirectAlias -AliasName 'pstbjobalias' -Stub 'JobStub' | Out-Null

    # Runs a script in a fresh pwsh with this file's config and module; returns its output lines.
    function Invoke-FreshPwsh {
        param([string]$Script)
        $file = Join-Path $script:JobRoot "fresh-$([guid]::NewGuid().ToString('N')).ps1"
        [IO.File]::WriteAllText($file, $Script)
        & $script:JobPwsh -NoProfile -NonInteractive -File $file 2>&1 | ForEach-Object { "$_" }
    }

    # Collects the jobs first: waiting inside the pipeline would deadlock a job that reads
    # pipeline input, because its input only ends when the whole pipeline does (the same is
    # true of Start-Job). A job that does not finish fails the test instead of hanging the run.
    function Receive-TestJob {
        param([Parameter(ValueFromPipeline)]$Job)
        begin { $jobs = [System.Collections.Generic.List[object]]::new() }
        process { $jobs.Add($Job) }
        end {
            $finished = @($jobs | Wait-Job -Timeout 120)
            if ($finished.Count -ne $jobs.Count) {
                $jobs | Remove-Job -Force
                throw 'A test job did not finish within 120 seconds.'
            }
            $jobs | Receive-Job -AutoRemoveJob -Wait 6>$null
        }
    }
}

AfterAll {
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:JobOriginalConfig
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:JobRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Start-PowerStubJob command' {
    It 'Is a global function that runs in the caller''s session state, not the module''s' {
        $command = Get-Command Start-PowerStubJob -CommandType Function
        $command | Should -Not -BeNullOrEmpty
        $command.ScriptBlock.Module | Should -BeNullOrEmpty
    }

    It 'Has the Start-PstbJob alias' {
        (Get-Alias Start-PstbJob).Definition | Should -Be 'Start-PowerStubJob'
    }

    It 'Has every parameter and parameter set of Start-Job' {
        $startJob = Get-Command Microsoft.PowerShell.Core\Start-Job
        $wrapper = Get-Command Start-PowerStubJob
        @($wrapper.Parameters.Keys | Sort-Object) | Should -Be @($startJob.Parameters.Keys | Sort-Object)
        @($wrapper.ParameterSets.Name | Sort-Object) | Should -Be @($startJob.ParameterSets.Name | Sort-Object)
        $wrapper.DefaultParameterSet | Should -Be $startJob.DefaultParameterSet
    }

    It 'Is not exported as a module function, so the module export list is unchanged' {
        (Get-Module PowerStub).ExportedFunctions.Keys | Should -Not -Contain 'Start-PowerStubJob'
    }

    It 'Has help describing PowerStub in jobs' {
        $help = Get-Help Start-PowerStubJob
        $help.Synopsis | Should -Match 'PowerStub commands work'
    }

    It 'Returns a normal background job' {
        $job = Start-PowerStubJob { 'ok' } -Name 'pstb-named-job'
        try {
            $job.Name | Should -Be 'pstb-named-job'
            $job.PSJobTypeName | Should -Be 'BackgroundJob'
            $job | Wait-Job | Out-Null
            $job.State | Should -Be 'Completed'
            $job | Receive-Job | Should -Be 'ok'
        }
        finally {
            $job | Remove-Job -Force
        }
    }
}

Describe 'PowerStub commands inside the job' {
    It 'Runs pstb' {
        Start-PowerStubJob { pstb JobStub echo -Name viapstb } | Receive-TestJob | Should -Be 'echo:viapstb'
    }

    It 'Runs Invoke-PowerStubCommand' {
        Start-PowerStubJob { Invoke-PowerStubCommand JobStub echo -Name viafull } | Receive-TestJob | Should -Be 'echo:viafull'
    }

    It 'Runs a direct alias' {
        Start-PowerStubJob { pstbjobalias echo -Name viaalias } | Receive-TestJob | Should -Be 'echo:viaalias'
    }

    It 'Passes named and switch parameters to the target' {
        Start-PowerStubJob { pstbjobalias echo -Name sw -Loud } | Receive-TestJob | Should -Be 'ECHO:sw'
    }

    It 'Runs a stub command that runs another stub command, through <Entry>' -ForEach @(
        @{ Entry = 'pstb'; Command = 'nested'; Expected = 'echo:nested' },
        @{ Entry = 'a direct alias'; Command = 'nested-alias'; Expected = 'echo:nested-alias' }
    ) {
        Start-PowerStubJob { param($c) pstb JobStub $c } -ArgumentList $Command | Receive-TestJob | Should -Be $Expected
    }

    It 'Sees the same stubs and aliases as this session' {
        $result = Start-PowerStubJob {
            [PSCustomObject]@{
                Stubs  = @((Get-PowerStubs).Keys)
                Alias  = [bool](Get-Command pstbjobalias -ErrorAction SilentlyContinue)
                Config = Get-PowerStubConfiguration -Key ConfigFile
            }
        } | Receive-TestJob
        $result.Stubs | Should -Contain 'JobStub'
        $result.Alias | Should -BeTrue
        $result.Config | Should -Be (Get-PowerStubConfiguration -Key ConfigFile)
    }

    It 'Loads the same PowerStub module as this session, not another installed version' {
        $modulePath = Start-PowerStubJob { (Get-Module PowerStub).Path } | Receive-TestJob
        $modulePath | Should -Be (Get-Module PowerStub).Path
    }

    It 'Turns off the background update check inside the job' {
        $saved = $env:POWERSTUB_NO_UPDATE_CHECK
        try {
            Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK
            Start-PowerStubJob { $env:POWERSTUB_NO_UPDATE_CHECK } | Receive-TestJob | Should -Be '1'
        }
        finally {
            $env:POWERSTUB_NO_UPDATE_CHECK = $saved
        }
    }

    It 'Reports a failing target through $LASTEXITCODE and $?' {
        $result = Start-PowerStubJob {
            $output = pstb JobStub fail 6>$null
            [PSCustomObject]@{ Output = $output; Succeeded = $?; ExitCode = $LASTEXITCODE }
        } | Receive-TestJob
        $result.Output | Should -Be 'failing'
        $result.Succeeded | Should -BeFalse
        $result.ExitCode | Should -Be 5
    }

    It 'Returns a target''s error to the caller' {
        $job = Start-PowerStubJob { pstb JobStub throws }
        $job | Wait-Job | Out-Null
        $errors = $null
        $job | Receive-Job -ErrorVariable errors -ErrorAction SilentlyContinue 6>$null | Out-Null
        $job | Remove-Job -Force
        "$errors" | Should -Match 'target-threw'
    }

    It 'Runs many jobs at once' {
        $jobs = foreach ($i in 1..6) { Start-PowerStubJob { param($n) pstbjobalias echo -Name $n } -ArgumentList $i }
        @($jobs | Receive-TestJob | Sort-Object) | Should -Be @(1..6 | ForEach-Object { "echo:$_" })
    }
}

Describe 'Start-Job behaviour is kept' {
    It 'Forwards -ArgumentList' {
        Start-PowerStubJob { param($a, $b) "$a+$b" } -ArgumentList 'one', 'two' | Receive-TestJob | Should -Be 'one+two'
    }

    It 'Forwards pipeline input as $input' {
        @('p1', 'p2', 'p3') | Start-PowerStubJob { @($input) -join ',' } | Receive-TestJob | Should -Be 'p1,p2,p3'
    }

    It 'Forwards -InputObject' {
        Start-PowerStubJob { @($input) -join ',' } -InputObject 'single' | Receive-TestJob | Should -Be 'single'
    }

    It 'Runs a -FilePath script that uses PowerStub' {
        $file = Join-Path $script:JobRoot 'job-file.ps1'
        [IO.File]::WriteAllText($file, 'param($n) pstbjobalias echo -Name $n')
        Start-PowerStubJob -FilePath $file -ArgumentList 'fromfile' | Receive-TestJob | Should -Be 'echo:fromfile'
    }

    It 'Resolves $using: of a <Scope> variable' -ForEach @(
        @{ Scope = 'session'; Expected = 'session-value' },
        @{ Scope = 'function-local'; Expected = 'function-value' },
        @{ Scope = 'nested script block'; Expected = 'nested-value' },
        @{ Scope = 'script-local'; Expected = 'script-value' }
    ) {
        $result = switch ($Scope) {
            'session' {
                $global:pstbJobUsingProbe = 'session-value'
                try { Start-PowerStubJob { "$using:pstbJobUsingProbe" } | Receive-TestJob }
                finally { Remove-Variable pstbJobUsingProbe -Scope Global }
            }
            'function-local' {
                function Test-JobUsingLocal { $local = 'function-value'; Start-PowerStubJob { "$using:local" } | Receive-TestJob }
                Test-JobUsingLocal
            }
            'nested script block' {
                $outer = 'nested-value'
                & { & { Start-PowerStubJob { "$using:outer" } | Receive-TestJob } }
            }
            'script-local' {
                $file = Join-Path $script:JobRoot 'using-script.ps1'
                [IO.File]::WriteAllText($file, '$w = "script-value"; Start-PowerStubJob { "$using:w" } | Receive-Job -Wait -AutoRemoveJob')
                & $file
            }
        }
        $result | Should -Be $Expected
    }

    It 'Resolves $using: of a variable local to a PowerStub command' {
        pstb JobStub fanout -Names a, b 6>$null | Sort-Object | Should -Be @('echo:fan-a', 'echo:fan-b')
    }

    It 'Still runs the caller''s -InitializationScript, after PowerStub is loaded' {
        $result = Start-PowerStubJob -InitializationScript {
            $global:initOrder = if (Get-Command pstbjobalias -ErrorAction SilentlyContinue) { 'powerstub-first' } else { 'init-first' }
            function Get-FromInit { pstbjobalias echo -Name frominit }
        } -ScriptBlock { "$global:initOrder|$(Get-FromInit)" } | Receive-TestJob
        $result | Should -Be 'powerstub-first|echo:frominit'
    }

    It 'Runs a -InitializationScript that has its own param block' {
        Start-PowerStubJob -InitializationScript { param() $global:initParam = 'ran' } -ScriptBlock { $global:initParam } |
            Receive-TestJob | Should -Be 'ran'
    }

    It 'Leaves plain Start-Job unchanged (no PowerStub in its jobs)' {
        Start-Job { [bool](Get-Command pstbjobalias -ErrorAction SilentlyContinue) } | Receive-TestJob | Should -BeFalse
    }

    It 'Refuses a Windows PowerShell -PSVersion job with a clear message' {
        { Start-PowerStubJob -PSVersion 5.1 { 1 } } | Should -Throw '*needs PowerShell 7*'
        @(Get-Job).Count | Should -Be 0
    }
}

Describe 'From inside a PowerStub command (the health-check pattern)' {
    It 'Fans out to jobs that call a direct alias, through <Entry>' -ForEach @(
        @{ Entry = 'pstb' }, @{ Entry = 'a direct alias' }
    ) {
        $output = if ($Entry -eq 'pstb') { pstb JobStub fanout -Names x, y, z 6>$null } else { pstbjobalias fanout -Names x, y, z 6>$null }
        @($output | Sort-Object) | Should -Be @('echo:fan-x', 'echo:fan-y', 'echo:fan-z')
    }
}

Describe 'Module import and removal' {
    It 'Creates the command and alias on import and removes both on removal' {
        $output = Invoke-FreshPwsh @"
Import-Module '$($script:JobManifest.Replace("'", "''"))'
"imported:`$([bool](Get-Command Start-PowerStubJob -ErrorAction SilentlyContinue)):`$([bool](Get-Alias Start-PstbJob -ErrorAction SilentlyContinue))"
Remove-Module PowerStub
"removed:`$([bool](Get-Command Start-PowerStubJob -ErrorAction SilentlyContinue)):`$([bool](Get-Alias Start-PstbJob -ErrorAction SilentlyContinue))"
"@
        $output | Should -Contain 'imported:True:True'
        $output | Should -Contain 'removed:False:False'
    }

    It 'Re-creates the command after Import-Module -Force' {
        $output = Invoke-FreshPwsh @"
Import-Module '$($script:JobManifest.Replace("'", "''"))'
Import-Module '$($script:JobManifest.Replace("'", "''"))' -Force
"after-force:`$((Start-PowerStubJob { pstb JobStub echo -Name forced 6>`$null } | Receive-Job -Wait -AutoRemoveJob))"
"@
        $output | Should -Contain 'after-force:echo:forced'
    }

    It 'Never replaces an existing <Name>, and leaves it in place on removal' -ForEach @(
        @{ Name = 'Start-PowerStubJob' }, @{ Name = 'Start-PstbJob' }
    ) {
        $output = Invoke-FreshPwsh @"
function global:$Name { 'users-own' }
Import-Module '$($script:JobManifest.Replace("'", "''"))' 3>&1 | ForEach-Object { "warning:`$_" }
"call:`$($Name)"
Remove-Module PowerStub
"after-remove:`$($Name)"
"@
        $output | Should -Contain 'call:users-own'
        $output | Should -Contain 'after-remove:users-own'
        ($output -join "`n") | Should -Match "warning:.*'$Name' is already an existing command"
    }

    It 'Does not remove a same-named function created after import' {
        $output = Invoke-FreshPwsh @"
Import-Module '$($script:JobManifest.Replace("'", "''"))'
function global:Start-PowerStubJob { 'replaced-later' }
Remove-Module PowerStub
"after-remove:`$(Start-PowerStubJob)"
"@
        $output | Should -Contain 'after-remove:replaced-later'
    }

    It 'Works when the module folder path has spaces, brackets and quotes' {
        $moduleRoot = Join-Path $script:JobRoot "mod [1] o'brien/PowerStub"
        [IO.Directory]::CreateDirectory((Split-Path $moduleRoot)) | Out-Null
        Copy-Item -LiteralPath (Split-Path $script:JobManifest) -Destination (Split-Path $moduleRoot) -Recurse
        $odd = (Join-Path $moduleRoot 'PowerStub.psd1').Replace("'", "''")
        $output = Invoke-FreshPwsh @"
Import-Module -Name '$odd'
`$job = Start-PowerStubJob { "`$((Get-Module PowerStub).Path)|`$(pstbjobalias echo -Name odd 6>`$null)" }
"result:`$(`$job | Receive-Job -Wait -AutoRemoveJob)"
"@
        $expectedModule = [IO.Path]::GetFullPath((Join-Path $moduleRoot 'PowerStub.psm1'))
        $output | Should -Contain "result:$expectedModule|echo:odd"
    }
}
