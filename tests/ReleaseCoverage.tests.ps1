#Requires -Modules Pester
<#
.SYNOPSIS
    Installed-module, lifecycle, filesystem, and persistence release contracts.

.DESCRIPTION
    Import the manifest, as normal module installations do. Every case gets an isolated
    configuration and disposable commands; original environment/location are restored.
    Regression cases assert the intended contract and run in the default release gate.
#>

BeforeAll {
    $script:ReleaseManifest = (Resolve-Path (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1')).Path
    $script:ReleaseOriginalConfig = $env:POWERSTUB_CONFIG_DIR
    $script:ReleaseOriginalLocation = Get-Location
    $script:ReleaseOriginalTab = (Get-Command TabExpansion2).ScriptBlock

    function New-ReleaseStub {
        param([string]$Name = 'ReleaseStub', [string]$Folder = 'stub space ü')
        $root = Join-Path $script:ReleaseRoot $Folder
        [IO.Directory]::CreateDirectory((Join-Path $root 'Commands')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Commands/ok.ps1'), "'release-ok'")
        New-PowerStub -Name $Name -Path $root
        return $root
    }

    function New-ReleaseGitRepository {
        # Local paths only: no network, credentials, global Git config or existing repo.
        $root = Join-Path $script:ReleaseRoot 'git-stub'
        $origin = Join-Path $script:ReleaseRoot 'origin.git'
        & git init --bare --quiet $origin
        if ($LASTEXITCODE) { throw 'Could not create local Git origin' }
        & git init --quiet --initial-branch=main $root
        [IO.Directory]::CreateDirectory((Join-Path $root 'Commands')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'Commands/ok.ps1'), "'git-ok'")
        & git -C $root add .
        & git -C $root -c user.name=PowerStubTests -c user.email=tests@example.invalid commit --quiet -m fixture
        if ($LASTEXITCODE) { throw 'Could not commit local Git fixture' }
        & git -C $root remote add origin $origin
        & git -C $root push --quiet --set-upstream origin main 2>$null
        if ($LASTEXITCODE) { throw 'Could not seed local Git origin' }
        New-PowerStub -Name OfflineStub -Path $root
        # Leave valid stale tracking data, but make the subsequent fetch/pull fail locally.
        & git -C $root remote set-url origin (Join-Path $script:ReleaseRoot 'missing-origin.git')
        return $root
    }
}

AfterAll {
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:ReleaseOriginalConfig
    Set-Location -LiteralPath $script:ReleaseOriginalLocation.Path
    Set-Item function:global:TabExpansion2 $script:ReleaseOriginalTab
}

Describe 'Release contracts through the installed manifest' -Tag 'ReleaseCoverage' {
    BeforeEach {
        Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
        $script:ReleaseRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBRelease_$([guid]::NewGuid())"
        $env:POWERSTUB_CONFIG_DIR = Join-Path $script:ReleaseRoot 'config'
        [IO.Directory]::CreateDirectory($env:POWERSTUB_CONFIG_DIR) | Out-Null
        $script:ReleaseConfigFile = Join-Path $env:POWERSTUB_CONFIG_DIR 'config.json'
        # Avoid incidental Git probing except in the explicitly local Git cases below.
        @{ GitEnabled = $false; Stubs = @{}; InvokeAlias = 'pstb' } |
            ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
        Import-Module $script:ReleaseManifest -Force
    }

    AfterEach {
        Set-Location -LiteralPath $script:ReleaseOriginalLocation.Path
        Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
        foreach ($name in 'pstbreleasealias', 'pstbreleasecustom') {
            Remove-Item "function:$name" -Force -ErrorAction SilentlyContinue
            Remove-Item "alias:$name" -Force -ErrorAction SilentlyContinue
        }
        Set-Item function:global:TabExpansion2 $script:ReleaseOriginalTab
        if (Test-Path -LiteralPath $script:ReleaseRoot) {
            Remove-Item -LiteralPath $script:ReleaseRoot -Recurse -Force
        }
    }

    Context 'Manifest and reload' {
        It 'Exports exactly the public function files and the default invocation alias' {
            $expected = @(Get-ChildItem (Join-Path $PSScriptRoot '../PowerStub/public/functions') -Filter '*.ps1' |
                Select-Object -ExpandProperty BaseName | Sort-Object)
            @((Get-Module PowerStub).ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
            (Get-Command pstb).Definition | Should -Be 'Invoke-PowerStubCommand'
            (Get-Module PowerStub).ExportedAliases.Keys | Should -Be @('pstb')
        }

        It 'Invokes a saved stub and direct alias after manifest reload without rewriting config' {
            $null = New-ReleaseStub
            New-PowerStubDirectAlias -AliasName pstbreleasealias -Stub ReleaseStub | Out-Null
            $bytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ReleaseConfigFile))
            $timestamp = (Get-Item -LiteralPath $script:ReleaseConfigFile).LastWriteTimeUtc
            Import-Module $script:ReleaseManifest -Force
            (pstb ReleaseStub ok 6>$null) | Should -Be 'release-ok'
            (pstbreleasealias ok 6>$null) | Should -Be 'release-ok'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ReleaseConfigFile)) | Should -Be $bytes
            (Get-Item -LiteralPath $script:ReleaseConfigFile).LastWriteTimeUtc | Should -Be $timestamp
        }

        It 'Falls back safely for invalid or reserved InvokeAlias <Alias>' -ForEach @(
            @{ Alias = 'git' }, @{ Alias = 'bad;name' }, @{ Alias = '' }
        ) {
            @{ InvokeAlias = $Alias; Stubs = @{}; GitEnabled = $false } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
            Import-Module $script:ReleaseManifest -Force -WarningAction SilentlyContinue
            (Get-Command pstb).Definition | Should -Be 'Invoke-PowerStubCommand'
        }

        It 'A configured cmdlet collision preserves the cmdlet and exports the free default alias' {
            $original = (Get-Command Get-Date).Definition
            @{ InvokeAlias = 'Get-Date'; GitEnabled = $false; Stubs = @{} } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
            $before = [IO.File]::ReadAllText($script:ReleaseConfigFile)
            $records = @(Import-Module $script:ReleaseManifest -Force -WarningAction Continue 3>&1)
            (Get-Command Get-Date).CommandType | Should -Be 'Cmdlet'
            (Get-Command Get-Date).Definition | Should -BeExactly $original
            (Get-Command pstb).Definition | Should -Be 'Invoke-PowerStubCommand'
            @((Get-Module PowerStub).ExportedAliases.Keys) | Should -Be @('pstb')
            @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -BeGreaterThan 0
            [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $before
        }

        It 'Occupied configured and default alias names are preserved while the full command remains available' {
            Remove-Module PowerStub -Force
            Set-Item function:global:pstbreleasecustom { 'configured-user-function' }
            Set-Alias -Name pstb -Value Get-Date -Scope Global
            try {
                @{ InvokeAlias = 'pstbreleasecustom'; GitEnabled = $false; Stubs = @{} } |
                    ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
                $before = [IO.File]::ReadAllText($script:ReleaseConfigFile)
                $records = @(Import-Module $script:ReleaseManifest -Force -WarningAction Continue 3>&1)
                pstbreleasecustom | Should -Be 'configured-user-function'
                (Get-Command pstb).CommandType | Should -Be 'Alias'
                (Get-Command pstb).Definition | Should -Be 'Get-Date'
                @((Get-Module PowerStub).ExportedAliases.Keys).Count | Should -Be 0
                (Get-Command Invoke-PowerStubCommand).ModuleName | Should -Be 'PowerStub'
                @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -BeGreaterThan 0
                [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $before
            }
            finally { Remove-Item alias:pstb -Force -ErrorAction SilentlyContinue }
        }

        It 'A configured language keyword falls back without creating an unusable alias or rewriting config' {
            @{ InvokeAlias = 'do'; GitEnabled = $false; Stubs = @{} } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
            $before = [IO.File]::ReadAllText($script:ReleaseConfigFile)
            $records = @(Import-Module $script:ReleaseManifest -Force -WarningAction Continue 3>&1)
            Get-Command do -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            (Get-Command pstb).Definition | Should -Be 'Invoke-PowerStubCommand'
            @($records | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -BeGreaterThan 0
            [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $before
        }

        It 'Restores completion on unload and does not accumulate wrappers after repeated reload' {
            1..3 | ForEach-Object { Import-Module $script:ReleaseManifest -Force }
            $line = 'Get-ChildItem -Pa'
            (TabExpansion2 $line $line.Length).CompletionMatches.CompletionText | Should -Contain '-Path'
            Remove-Module PowerStub -Force
            (Get-Command TabExpansion2).ScriptBlock.ToString() | Should -Be $script:ReleaseOriginalTab.ToString()
        }

        It 'Preserves a completion function installed by someone else after import' {
            $replacement = { 'third-party completion' }
            Set-Item function:global:TabExpansion2 $replacement
            Remove-Module PowerStub -Force
            (Get-Command TabExpansion2).ScriptBlock.ToString() | Should -Be $replacement.ToString()
        }
    }

    Context 'Direct alias cleanup preserves foreign replacements' {
        It '<Removal> must preserve a user replacement for a formerly owned alias function' -ForEach @(
            @{ Removal = 'Module unload' }, @{ Removal = 'Alias removal' }, @{ Removal = 'Stub removal' }
        ) {
            $null = New-ReleaseStub
            New-PowerStubDirectAlias -AliasName pstbreleasealias -Stub ReleaseStub | Out-Null
            Set-Item function:global:pstbreleasealias { 'user-replacement' }
            switch ($Removal) {
                'Module unload' { Remove-Module PowerStub -Force }
                'Alias removal' { Remove-PowerStubDirectAlias pstbreleasealias }
                'Stub removal' { Remove-PowerStub ReleaseStub }
            }
            # Cleanup may delete only the exact function owned by PowerStub, not a
            # same-named replacement installed later by the user or another module.
            Get-Command pstbreleasealias -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            pstbreleasealias | Should -Be 'user-replacement'
        }
    }

    Context 'Filesystem and lifecycle safety' {
        It 'Invokes an absolute path containing spaces and Unicode after changing location' {
            $root = New-ReleaseStub
            Set-Location -LiteralPath ([IO.Path]::GetTempPath())
            (pstb ReleaseStub ok 6>$null) | Should -Be 'release-ok'
            (Get-PowerStubCommand ReleaseStub ok).Path | Should -Be (Join-Path $root 'Commands/ok.ps1')
        }

        It 'Does not resolve a traversal command outside Commands' {
            $null = New-ReleaseStub
            [IO.File]::WriteAllText((Join-Path $script:ReleaseRoot 'outside.ps1'), "'outside'")
            Get-PowerStubCommand ReleaseStub '../../outside' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
            { pstb ReleaseStub '../../outside' 3>$null 6>$null } | Should -Throw '*not found*'
        }

        It 'Force with WhatIf preserves both conflicting lifecycle files byte for byte' {
            $root = New-ReleaseStub
            $alpha = Join-Path $root 'Commands/alpha.ok.ps1'
            [IO.File]::WriteAllText($alpha, "'alpha-ok'")
            $production = Join-Path $root 'Commands/ok.ps1'
            $before = @([IO.File]::ReadAllText($production), [IO.File]::ReadAllText($alpha))
            Set-PowerStubCommandVisibility -Stub ReleaseStub -Command ok -Visibility Alpha -Force -WhatIf 6>$null
            @([IO.File]::ReadAllText($production), [IO.File]::ReadAllText($alpha)) | Should -Be $before
        }

        It 'A visibility change in one stub leaves a same-named command in another stub untouched' {
            $first = New-ReleaseStub -Name First -Folder first
            $second = New-ReleaseStub -Name Second -Folder second
            Set-PowerStubCommandVisibility -Stub First -Command ok -Visibility Beta 6>$null | Out-Null
            Test-Path -LiteralPath (Join-Path $first 'Commands/beta.ok.ps1') | Should -BeTrue
            (pstb Second ok 6>$null) | Should -Be 'release-ok'
            Test-Path -LiteralPath (Join-Path $second 'Commands/beta.ok.ps1') | Should -BeFalse
        }
    }

    Context 'Persistent configuration failures and concurrent writers' {
        It 'Preserves <Label> config bytes and a matching recovery copy' -ForEach @(
            @{ Label = 'malformed JSON'; Text = '{"Stubs": {"keep' },
            @{ Label = 'JSON null'; Text = 'null' },
            @{ Label = 'JSON array'; Text = '[]' }
        ) {
            [IO.File]::WriteAllText($script:ReleaseConfigFile, $Text)
            Import-Module $script:ReleaseManifest -Force -WarningAction SilentlyContinue
            [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $Text
            $copies = @(Get-ChildItem -LiteralPath $env:POWERSTUB_CONFIG_DIR -Filter 'config.json.corrupt-*')
            $copies.Count | Should -Be 1
            [IO.File]::ReadAllText($copies[0].FullName) | Should -BeExactly $Text
            (Get-Command pstb).Definition | Should -Be 'Invoke-PowerStubCommand'
        }

        It 'Ignores persisted internal configuration paths' {
            $other = Join-Path $script:ReleaseRoot 'do-not-write.json'
            @{ Stubs = @{}; GitEnabled = $false; ConfigFile = $other; ModulePath = 'injected';
                InternalConfigKeys = @(); GitAvailable = $true } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
            Import-PowerStubConfiguration
            $config = Get-PowerStubConfiguration
            $config.ConfigFile | Should -Be $script:ReleaseConfigFile
            $config.ModulePath | Should -Be (Split-Path $script:ReleaseManifest)
            $null = New-ReleaseStub
            Test-Path -LiteralPath $other | Should -BeFalse
        }

        It 'Does not persist a failed mutation and releases its lock for the next writer' {
            $before = [IO.File]::ReadAllText($script:ReleaseConfigFile)
            InModuleScope PowerStub {
                { Update-PowerStubConfiguration {
                        $Script:PSTBSettings['Stubs']['NotCommitted'] = 'unused'
                        throw 'intentional mutation failure'
                    } } | Should -Throw '*intentional mutation failure*'
            }
            [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $before
            # Use another process: an unreleased re-entrant mutex would be invisible to
            # a second write on the same test thread, but must block this writer.
            $job = Start-Job -ScriptBlock {
                param($Manifest, $ConfigDir, $Root)
                $ErrorActionPreference = 'Stop'
                $env:POWERSTUB_CONFIG_DIR = $ConfigDir
                Import-Module $Manifest -Force
                New-PowerStub -Name NextWriter -Path (Join-Path $Root 'next-writer')
                'writer-complete'
            } -ArgumentList $script:ReleaseManifest, $env:POWERSTUB_CONFIG_DIR, $script:ReleaseRoot
            try {
                $null = $job | Wait-Job -Timeout 15
                $job.State | Should -Be 'Completed'
                ($job | Receive-Job -ErrorAction Stop) | Should -Be 'writer-complete'
            }
            finally {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
            }
            (Get-PowerStubs).Keys | Should -Not -Contain 'NotCommitted'
            (Get-PowerStubs).Keys | Should -Contain 'NextWriter'
            @(Get-ChildItem -LiteralPath $env:POWERSTUB_CONFIG_DIR -Filter '*.tmp').Count | Should -Be 0
        }

        It 'Merges registrations from four simultaneous processes without losing any writer' {
            $gate = Join-Path $script:ReleaseRoot 'start-writers'
            $jobs = @()
            try {
                $jobs = @(1..4 | ForEach-Object {
                    Start-Job -ScriptBlock {
                        param($Manifest, $ConfigDir, $Root, $Gate, $Writer)
                        $ErrorActionPreference = 'Stop'
                        $env:POWERSTUB_CONFIG_DIR = $ConfigDir
                        Import-Module $Manifest -Force
                        [IO.File]::WriteAllText((Join-Path $Root "ready-$Writer"), '')
                        $deadline = [DateTime]::UtcNow.AddSeconds(30)
                        while (-not (Test-Path -LiteralPath $Gate)) {
                            if ([DateTime]::UtcNow -gt $deadline) { throw 'Writer start barrier timed out' }
                            Start-Sleep -Milliseconds 25
                        }
                        foreach ($number in 1..4) {
                            $name = "Writer${Writer}Stub$number"
                            New-PowerStub -Name $name -Path (Join-Path $Root $name)
                        }
                        "writer-$Writer-complete"
                    } -ArgumentList $script:ReleaseManifest, $env:POWERSTUB_CONFIG_DIR, $script:ReleaseRoot, $gate, $_
                })
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (@(Get-ChildItem -LiteralPath $script:ReleaseRoot -Filter 'ready-*').Count -ne 4) {
                    if ([DateTime]::UtcNow -gt $deadline) { throw 'Child import barrier timed out' }
                    Start-Sleep -Milliseconds 25
                }
                [IO.File]::WriteAllText($gate, '')
                $null = $jobs | Wait-Job -Timeout 30
                @($jobs | Where-Object State -ne Completed).Count | Should -Be 0
                $results = @($jobs | Receive-Job -ErrorAction Stop)
                $results.Count | Should -Be 4
                $saved = Get-Content -LiteralPath $script:ReleaseConfigFile -Raw | ConvertFrom-Json -AsHashtable
                $expected = @(foreach ($writer in 1..4) { foreach ($number in 1..4) { "Writer${writer}Stub$number" } })
                @($saved.Stubs.Keys | Sort-Object) | Should -Be @($expected | Sort-Object)
                @(Get-ChildItem -LiteralPath $env:POWERSTUB_CONFIG_DIR -Filter '*.tmp').Count | Should -Be 0
                @(Get-ChildItem -LiteralPath $env:POWERSTUB_CONFIG_DIR -Filter '*.corrupt-*').Count | Should -Be 0
            }
            finally {
                $jobs | Stop-Job -ErrorAction SilentlyContinue
                $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Local offline Git behavior' {
        BeforeEach {
            InModuleScope PowerStub { $Script:GitEnabled = $true; $Script:GitAvailable = $true }
        }

        It 'Restores Git prompt variables and working directory after a failed fetch' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $root = New-ReleaseGitRepository
            $beforeLocation = (Get-Location).Path
            $originalPrompt = $env:GIT_TERMINAL_PROMPT
            $originalInteractive = $env:GCM_INTERACTIVE
            try {
                $env:GIT_TERMINAL_PROMPT = 'original-prompt'
                $env:GCM_INTERACTIVE = 'original-interactive'
                InModuleScope PowerStub -Parameters @{ Root = $root } { Get-PowerStubGitInfo -Path $Root -Fetch } | Out-Null
                $env:GIT_TERMINAL_PROMPT | Should -BeExactly 'original-prompt'
                $env:GCM_INTERACTIVE | Should -BeExactly 'original-interactive'
                (Get-Location).Path | Should -Be $beforeLocation
            }
            finally {
                $env:GIT_TERMINAL_PROMPT = $originalPrompt
                $env:GCM_INTERACTIVE = $originalInteractive
            }
        }

        It 'Reports a failed pull as unsuccessful and preserves prompt state' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $root = New-ReleaseGitRepository
            $beforePrompt = $env:GIT_TERMINAL_PROMPT
            $result = InModuleScope PowerStub -Parameters @{ Root = $root } { Update-PowerStubGitRepo -Path $Root }
            $result.Success | Should -BeFalse
            $result.Message | Should -BeLike 'Failed to update:*'
            $env:GIT_TERMINAL_PROMPT | Should -Be $beforePrompt
        }
    }

    Context 'Installed alias, literal paths, reserved verbs and offline status regressions' {
        It 'Invalid JSON root <Label> must be rejected and backed up before a later write' -ForEach @(
            @{ Label = 'number'; Text = '42' },
            @{ Label = 'boolean'; Text = 'true' },
            @{ Label = 'string'; Text = '"config"' },
            @{ Label = 'single-object array'; Text = '[{"Stubs":{}}]' }
        ) {
            [IO.File]::WriteAllText($script:ReleaseConfigFile, $Text)
            Import-Module $script:ReleaseManifest -Force -WarningAction SilentlyContinue
            [IO.File]::ReadAllText($script:ReleaseConfigFile) | Should -BeExactly $Text
            $copies = @(Get-ChildItem -LiteralPath $env:POWERSTUB_CONFIG_DIR -Filter 'config.json.corrupt-*')
            $copies.Count | Should -Be 1
            [IO.File]::ReadAllText($copies[0].FullName) | Should -BeExactly $Text
            $null = New-ReleaseStub
            [IO.File]::ReadAllText($copies[0].FullName) | Should -BeExactly $Text
            (pstb ReleaseStub ok 6>$null) | Should -Be 'release-ok'
        }

        It 'Custom InvokeAlias must be exported by a manifest import, just as by psm1' {
            @{ InvokeAlias = 'pstbreleasecustom'; GitEnabled = $false; Stubs = @{} } |
                ConvertTo-Json | Set-Content -LiteralPath $script:ReleaseConfigFile
            Import-Module $script:ReleaseManifest -Force
            Get-Command pstbreleasecustom -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            @((Get-Module PowerStub).ExportedAliases.Keys) | Should -Be @('pstbreleasecustom')
            $null = New-ReleaseStub
            (pstbreleasecustom ReleaseStub ok 6>$null) | Should -Be 'release-ok'
            Import-Module $script:ReleaseManifest -Force
            (pstbreleasecustom ReleaseStub ok 6>$null) | Should -Be 'release-ok'
            Get-Command pstb -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'A registered folder containing literal brackets must remain invocable' {
            $null = New-ReleaseStub -Folder 'stub[1]'
            (pstb ReleaseStub ok 3>$null 6>$null) | Should -Be 'release-ok'
        }

        It 'Literal bracket paths support discovery, completion and lifecycle changes without touching lookalikes' {
            $literal = New-ReleaseStub -Name Literal -Folder 'stub[1]'
            $lookalike = New-ReleaseStub -Name Lookalike -Folder 'stub1'
            [IO.File]::WriteAllText((Join-Path $lookalike 'Commands/ok.ps1'), "'lookalike-must-not-run'")
            (Get-PowerStubCommand Literal ok).Path | Should -BeExactly (Join-Path $literal 'Commands/ok.ps1')
            (pstb Literal ok 6>$null) | Should -BeExactly 'release-ok'
            $names = InModuleScope PowerStub { @(Find-PowerStubCommands Literal).BaseName }
            $names | Should -Contain 'ok'
            $line = 'pstb Literal o'
            (TabExpansion2 $line $line.Length).CompletionMatches.CompletionText | Should -Contain 'ok'
            Set-PowerStubCommandVisibility Literal ok Beta 6>$null | Out-Null
            Test-Path -LiteralPath (Join-Path $literal 'Commands/beta.ok.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $lookalike 'Commands/ok.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $lookalike 'Commands/beta.ok.ps1') | Should -BeFalse
            Enable-PowerStubBetaCommands
            (pstb Literal ok 6>$null) | Should -Be 'release-ok'
        }

        It 'Literal bracket targets use their own switch metadata and help beside wildcard lookalikes' {
            $literal = New-ReleaseStub -Name Literal -Folder 'tools[q]'
            $lookalike = New-ReleaseStub -Name Lookalike -Folder 'toolsq'
            [IO.File]::WriteAllText((Join-Path $literal 'Commands/probe.ps1'), @'
<#
.SYNOPSIS
    literal-target-help
#>
param([switch]$Flag)
"literal:$Flag"
'@)
            [IO.File]::WriteAllText((Join-Path $lookalike 'Commands/probe.ps1'), @'
<#
.SYNOPSIS
    lookalike-help-must-not-be-used
#>
param([string]$Flag)
"lookalike:$Flag"
'@)
            [IO.File]::WriteAllText((Join-Path $literal 'Commands/probe.ps1-extra.ps1'), "'prefix-lookalike'")
            New-PowerStubDirectAlias -AliasName pstbreleasealias -Stub Literal | Out-Null
            $beforeLocation = (Get-Location).Path
            (Get-PowerStubCommand Literal probe).Path | Should -BeExactly (Join-Path $literal 'Commands/probe.ps1')
            (pstb Literal probe -Flag:$false 6>$null) | Should -BeExactly 'literal:False'
            (pstbreleasealias probe -Flag:$false 6>$null) | Should -BeExactly 'literal:False'
            (Get-PowerStubCommandHelp Literal probe).Synopsis | Should -Match 'literal-target-help'
            (Get-Location).Path | Should -BeExactly $beforeLocation
        }

        It 'Literal bracket filenames resolve exactly beside wildcard and prefix siblings' {
            $literal = New-ReleaseStub -Name Literal -Folder 'tools[q]'
            $lookalike = New-ReleaseStub -Name Lookalike -Folder 'toolsq'
            $target = Join-Path $literal 'Commands/probe[q].ps1'
            [IO.File]::WriteAllText($target, @'
<#
.SYNOPSIS
    literal-filename-help
#>
param([switch]$Flag)
"literal-name:$Flag"
'@)
            [IO.File]::WriteAllText((Join-Path $literal 'Commands/probeq.ps1'), "'filename-lookalike'")
            [IO.File]::WriteAllText((Join-Path $lookalike 'Commands/probeq.ps1'), "'directory-lookalike'")
            [IO.File]::WriteAllText((Join-Path $literal 'Commands/probe[q].ps1.bak'), "'prefix-lookalike'")
            (Get-PowerStubCommand Literal 'probe[q]').Path | Should -BeExactly $target
            (pstb Literal 'probe[q]' -Flag:$false 6>$null) | Should -BeExactly 'literal-name:False'
            (Get-PowerStubCommandHelp Literal 'probe[q]').Synopsis | Should -Match 'literal-filename-help'

            $nativeSource = if ($IsWindows) { $env:ComSpec } else { (Get-Command sh -CommandType Application).Source }
            foreach ($path in @((Join-Path $literal 'Commands/native[q].exe'), (Join-Path $literal 'Commands/nativeq.exe'), (Join-Path $lookalike 'Commands/nativeq.exe'))) {
                Copy-Item -LiteralPath $nativeSource -Destination $path
            }
            (Get-PowerStubCommand Literal 'native[q]').Path | Should -BeExactly (Join-Path $literal 'Commands/native[q].exe')
        }

        It 'Imports from a literal bracket module folder with a literal bracket config folder' {
            Remove-Module PowerStub -Force
            $moduleRoot = Join-Path $script:ReleaseRoot 'modules[1]/PowerStub'
            [IO.Directory]::CreateDirectory($moduleRoot) | Out-Null
            Copy-Item -LiteralPath (Split-Path $script:ReleaseManifest) -Destination (Split-Path $moduleRoot) -Recurse -Force
            $env:POWERSTUB_CONFIG_DIR = Join-Path $script:ReleaseRoot 'config[1]'
            Import-Module (Join-Path $moduleRoot 'PowerStub.psd1') -Force
            $null = New-ReleaseStub -Folder 'stub[1]'
            (pstb ReleaseStub ok 6>$null) | Should -Be 'release-ok'
            Test-Path -LiteralPath (Join-Path $env:POWERSTUB_CONFIG_DIR 'config.json') | Should -BeTrue
            Import-Module (Join-Path $moduleRoot 'PowerStub.psd1') -Force
            (pstb ReleaseStub ok 6>$null) | Should -Be 'release-ok'
        }

        It 'Rejects non-filesystem registration paths without persisting a stub' {
            { New-PowerStub -Name Environment -Path 'Env:POWERSTUB_CONFIG_DIR' } | Should -Throw '*FileSystem*'
            (Get-PowerStubs).Keys | Should -Not -Contain 'Environment'
        }

        It 'Does not persist a registration when a required directory is an existing file' {
            $root = Join-Path $script:ReleaseRoot 'blocked-stub'
            [IO.Directory]::CreateDirectory($root) | Out-Null
            [IO.File]::WriteAllText((Join-Path $root 'Commands'), 'do not replace')
            { New-PowerStub -Name Blocked -Path $root } | Should -Throw
            (Get-PowerStubs).Keys | Should -Not -Contain 'Blocked'
            [IO.File]::ReadAllText((Join-Path $root 'Commands')) | Should -BeExactly 'do not replace'
        }

        It 'A relative registration must persist an absolute filesystem path' {
            Set-Location -LiteralPath $script:ReleaseRoot
            New-PowerStub -Name Relative -Path relative
            [IO.Path]::IsPathRooted((Get-PowerStubs).Relative) | Should -BeTrue
        }

        It 'A relative registration must still invoke after the caller changes location' {
            Set-Location -LiteralPath $script:ReleaseRoot
            New-PowerStub -Name Relative -Path relative
            [IO.File]::WriteAllText((Join-Path $script:ReleaseRoot 'relative/Commands/ok.ps1'), "'relative-ok'")
            Set-Location -LiteralPath ([IO.Path]::GetTempPath())
            (pstb Relative ok 3>$null 6>$null) | Should -Be 'relative-ok'
        }

        It 'Registration must reject unusable virtual-verb stub name <Name>' -ForEach @(
            @{ Name = 'help' }, @{ Name = 'search' }, @{ Name = 'update' }, @{ Name = 'HeLp' }, @{ Name = 'SEARCH' }, @{ Name = 'UPDATE' }
        ) {
            # Dispatch always treats these names as virtual verbs, so registration is misleading.
            { New-PowerStub -Name $Name -Path (Join-Path $script:ReleaseRoot $Name) -Force } | Should -Throw '*reserved*'
            Test-Path -LiteralPath (Join-Path $script:ReleaseRoot $Name) | Should -BeFalse
            (Get-PowerStubs).Keys | Should -Not -Contain $Name
        }

        It 'A failed fetch must not claim <Scope> is up to date' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) -ForEach @(
            @{ Scope = 'one stub' }, @{ Scope = 'all stubs' }
        ) {
            InModuleScope PowerStub { $Script:GitEnabled = $true; $Script:GitAvailable = $true }
            $null = New-ReleaseGitRepository
            $output = if ($Scope -eq 'one stub') { pstb update OfflineStub --check 6>&1 } else { pstb update --check 6>&1 }
            ($output | Out-String) | Should -Not -Match 'up to date'
        }

        It 'A README-advertised GitEnabled setter must be callable after a normal manifest import' {
            # Either expose a supported setter or correct the README workflow. Do not
            # require adding a public API once the broken example is removed/replaced.
            $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../README.md') -Raw
            if ($readme -match '(?m)^Set-PowerStubConfigurationKey [''"]GitEnabled[''"]') {
                Get-Command Set-PowerStubConfigurationKey -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }
}
