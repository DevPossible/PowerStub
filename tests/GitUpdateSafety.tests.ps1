#Requires -Modules Pester

BeforeAll {
    $script:GitTestOriginalConfig = $env:POWERSTUB_CONFIG_DIR
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks
    $script:GitTestOriginalTab = (Get-Command TabExpansion2).ScriptBlock
    $script:GitTestOriginalLocation = Get-Location
    $script:GitTestRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBGitSafety_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = Join-Path $script:GitTestRoot 'config'
    [IO.Directory]::CreateDirectory($env:POWERSTUB_CONFIG_DIR) | Out-Null
    @{ GitEnabled = $false; Stubs = @{}; InvokeAlias = 'pstb' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:POWERSTUB_CONFIG_DIR 'config.json')
    Import-Module (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1') -Force

    function Invoke-GitFixture {
        & git @args 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Local Git fixture command failed: git $args" }
    }

    function New-GitTestRepository {
        param([string]$Name = 'repo')
        $root = Join-Path $script:GitCaseRoot $Name
        $origin = Join-Path $script:GitCaseRoot "$Name-origin.git"
        # Every remote is a disposable local directory. No network or user Git config writes.
        Invoke-GitFixture init --bare --quiet $origin
        Invoke-GitFixture init --quiet --initial-branch=main $root
        [IO.Directory]::CreateDirectory((Join-Path $root 'Commands')) | Out-Null
        Invoke-GitFixture -C $root -c user.name=PowerStubTests -c user.email=tests@example.invalid -c commit.gpgSign=false commit --allow-empty --quiet -m fixture
        Invoke-GitFixture -C $root remote add origin $origin
        Invoke-GitFixture -C $root push --quiet --set-upstream origin main
        return $root
    }

    function Set-GitTestFault {
        param([string]$Operation, [string]$Output, [int]$ExitCode = 0, [switch]$Throw)
        # A module-local shim keeps native argument forwarding intact across Pester versions.
        InModuleScope PowerStub -Parameters @{ Operation = $Operation; Output = $Output; ExitCode = $ExitCode; Throw = $Throw.IsPresent } {
            $Script:GitFault = @{ Operation = $Operation; Output = $Output; ExitCode = $ExitCode;
                Throw = $Throw; Count = 0; Prompt = $null; Interactive = $null }
            function script:git {
                if ($args -contains $Script:GitFault.Operation) {
                    $Script:GitFault.Count++
                    $Script:GitFault.Prompt = $env:GIT_TERMINAL_PROMPT
                    $Script:GitFault.Interactive = $env:GCM_INTERACTIVE
                    if ($Script:GitFault.Throw) { throw $Script:GitFault.Output }
                    $global:LASTEXITCODE = $Script:GitFault.ExitCode
                    $Script:GitFault.Output
                }
                else {
                    & $Script:GitTestBinary @args
                }
            }
        }
    }

    function Get-GitTestFault {
        InModuleScope PowerStub { $Script:GitFault }
    }

    function Get-GitTestInfo {
        param([switch]$Fetch)
        InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo; Fetch = $Fetch.IsPresent } {
            Get-PowerStubGitInfo -Path $Root -Fetch:$Fetch
        }
    }

    function Get-GitTestUpdateOutput {
        param([switch]$Check, [switch]$All)
        InModuleScope PowerStub -Parameters @{ Check = $Check.IsPresent; All = $All.IsPresent } {
            $arguments = @{}
            if (-not $All) { $arguments.Command = 'GitTest' }
            if ($Check) { $arguments.RemainingArgs = @('--check') }
            (Invoke-PowerStubUpdate @arguments 6>&1 | Out-String)
        }
    }
}

AfterAll {
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:GitTestOriginalConfig
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    Set-Location -LiteralPath $script:GitTestOriginalLocation.Path
    Set-Item function:global:TabExpansion2 $script:GitTestOriginalTab
    if (Test-Path -LiteralPath $script:GitTestRoot) {
        Remove-Item -LiteralPath $script:GitTestRoot -Recurse -Force
    }
}

Describe 'Git status and update safety' -Tag 'GitSafety' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:GitCaseRoot = Join-Path $script:GitTestRoot ([guid]::NewGuid().ToString())
        [IO.Directory]::CreateDirectory($script:GitCaseRoot) | Out-Null
        $script:GitRepo = New-GitTestRepository
        $script:GitPromptBefore = $env:GIT_TERMINAL_PROMPT
        $script:GitInteractiveBefore = $env:GCM_INTERACTIVE
        InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo } {
            $Script:GitTestBinary = (Get-Command git -CommandType Application | Select-Object -First 1).Source
            $Script:GitAvailable = $true
            $Script:GitEnabled = $true
            $Script:PSTBSettings['Stubs'] = @{ GitTest = $Root }
        }
    }

    AfterEach {
        InModuleScope PowerStub { Remove-Item function:git -ErrorAction SilentlyContinue }
        $env:GIT_TERMINAL_PROMPT = $script:GitPromptBefore
        $env:GCM_INTERACTIVE = $script:GitInteractiveBefore
        Set-Location -LiteralPath $script:GitTestOriginalLocation.Path
    }

    It 'Points disabled Git users to the public configuration lookup' {
        InModuleScope PowerStub {
            $Script:GitEnabled = $false
            { Invoke-PowerStubUpdate } | Should -Throw '*Get-PowerStubConfiguration -Key ConfigFile*'
            try { Invoke-PowerStubUpdate } catch { $_.Exception.Message | Should -Not -Match 'Set-PowerStubConfigurationKey' }
        }
    }

    It 'Reports matching branches as current only after a successful fetch' {
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'Ready'
        $info.BehindCount | Should -Be 0
        $info.AheadCount | Should -Be 0
        Get-GitTestUpdateOutput -Check | Should -Match "Stub 'GitTest' is up to date"
        Get-GitTestUpdateOutput -Check -All | Should -Match 'All 1 stub\(s\) are up to date'
    }

    It 'Returns unavailable counts after a failed fetch instead of stale zero counts' {
        Invoke-GitFixture -C $script:GitRepo remote set-url origin (Join-Path $script:GitCaseRoot 'missing.git')
        $info = Get-GitTestInfo -Fetch
        $info.IsRepo | Should -BeTrue
        $info.Status | Should -Be 'FetchFailed'
        $info.BehindCount | Should -BeNullOrEmpty
        $info.AheadCount | Should -BeNullOrEmpty
        foreach ($all in $false, $true) {
            $output = Get-GitTestUpdateOutput -Check -All:$all
            $output | Should -Match 'Fetch failed'
            $output | Should -Not -Match 'up to date'
        }
    }

    It 'Distinguishes a missing remote from an unconfigured tracking branch' {
        Invoke-GitFixture -C $script:GitRepo remote remove origin
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'NoRemote'
        Get-GitTestUpdateOutput -Check | Should -Match 'No remote configured'
        Get-GitTestUpdateOutput -Check -All | Should -Not -Match 'up to date'

        Invoke-GitFixture -C $script:GitRepo remote add origin (Join-Path $script:GitCaseRoot 'repo-origin.git')
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'NoUpstream'
        $info.BehindCount | Should -BeNullOrEmpty
        Get-GitTestUpdateOutput -Check | Should -Match 'No tracking branch configured'
        Get-GitTestUpdateOutput -Check -All | Should -Not -Match 'up to date'
    }

    It 'Reports an unreadable configured upstream as failed status computation' {
        Invoke-GitFixture -C $script:GitRepo update-ref -d refs/remotes/origin/main
        $info = Get-GitTestInfo
        $info.Status | Should -Be 'StatusFailed'
        $info.StatusMessage | Should -Match 'Unable to determine repository status'
        $info.BehindCount | Should -BeNullOrEmpty
        $info.AheadCount | Should -BeNullOrEmpty
    }

    It 'Rejects invalid count output instead of assuming zero counts' {
        Set-GitTestFault -Operation rev-list -Output 'not-a-count 0'
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'StatusFailed'
        Get-GitTestUpdateOutput -Check -All | Should -Not -Match 'up to date'
        (Get-GitTestFault).Count | Should -Be 2
    }

    It 'Rejects failed count commands even when they return apparent zero counts' {
        Set-GitTestFault -Operation rev-list -Output '0 0' -ExitCode 128
        (Get-GitTestInfo -Fetch).Status | Should -Be 'StatusFailed'
        Get-GitTestUpdateOutput -Check -All | Should -Not -Match 'up to date'
        (Get-GitTestFault).Count | Should -Be 2
    }

    It 'Reports local commits without an all-current summary' {
        Invoke-GitFixture -C $script:GitRepo -c user.name=PowerStubTests -c user.email=tests@example.invalid -c commit.gpgSign=false commit --allow-empty --quiet -m ahead
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'Ready'
        $info.AheadCount | Should -Be 1
        $output = Get-GitTestUpdateOutput -Check -All
        $output | Should -Match '1 commit\(s\) ahead'
        $output | Should -Not -Match 'All .* up to date'
    }

    It 'Reports remote commits without an all-current summary' {
        $writer = Join-Path $script:GitCaseRoot 'writer'
        Invoke-GitFixture clone --quiet --branch main (Join-Path $script:GitCaseRoot 'repo-origin.git') $writer
        Invoke-GitFixture -C $writer -c user.name=PowerStubTests -c user.email=tests@example.invalid -c commit.gpgSign=false commit --allow-empty --quiet -m remote
        Invoke-GitFixture -C $writer push --quiet origin main
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'Ready'
        $info.BehindCount | Should -Be 1
        $output = Get-GitTestUpdateOutput -Check -All
        $output | Should -Match '1 commit\(s\) behind'
        $output | Should -Match 'updates available'
        $output | Should -Not -Match 'All .* up to date'
    }

    It 'Reports both sides of a diverged branch' {
        $writer = Join-Path $script:GitCaseRoot 'writer'
        Invoke-GitFixture clone --quiet --branch main (Join-Path $script:GitCaseRoot 'repo-origin.git') $writer
        Invoke-GitFixture -C $writer -c user.name=PowerStubTests -c user.email=tests@example.invalid -c commit.gpgSign=false commit --allow-empty --quiet -m remote
        Invoke-GitFixture -C $writer push --quiet origin main
        Invoke-GitFixture -C $script:GitRepo -c user.name=PowerStubTests -c user.email=tests@example.invalid -c commit.gpgSign=false commit --allow-empty --quiet -m local
        $output = Get-GitTestUpdateOutput -Check -All
        $output | Should -Match 'has diverged: 1 commit\(s\) behind and 1 commit\(s\) ahead'
        $output | Should -Not -Match 'up to date'
    }

    It 'Restores absent credential environment variables after a successful <Operation>' -ForEach @(
        @{ Operation = 'fetch' }, @{ Operation = 'pull' }
    ) {
        Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        Remove-Item Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
        if ($Operation -eq 'fetch') {
            (Get-GitTestInfo -Fetch).Status | Should -Be 'Ready'
        }
        else {
            $result = InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo } {
                Update-PowerStubGitRepo -Path $Root
            }
            $result.Success | Should -BeTrue
        }
        Test-Path Env:GIT_TERMINAL_PROMPT | Should -BeFalse
        Test-Path Env:GCM_INTERACTIVE | Should -BeFalse
    }

    It 'Fetches the actual upstream remote when it is not named origin' {
        Invoke-GitFixture -C $script:GitRepo remote rename origin upstream
        $info = Get-GitTestInfo -Fetch
        $info.Status | Should -Be 'Ready'
        $info.TrackingBranch | Should -Be 'upstream/main'
        $info.RemoteUrl | Should -Be (Join-Path $script:GitCaseRoot 'repo-origin.git')
    }

    It 'Supports literal repository paths containing brackets' {
        $bracketRepo = New-GitTestRepository -Name 'repo[1]'
        $info = InModuleScope PowerStub -Parameters @{ Root = $bracketRepo } {
            Get-PowerStubGitInfo -Path $Root -Fetch
        }
        $info.Status | Should -Be 'Ready'
    }

    It 'Keeps environment and location unchanged after a failed fetch with strict native errors' {
        Invoke-GitFixture -C $script:GitRepo remote set-url origin (Join-Path $script:GitCaseRoot 'missing.git')
        $env:GIT_TERMINAL_PROMPT = 'original-prompt'
        $env:GCM_INTERACTIVE = 'original-interactive'
        $beforeLocation = (Get-Location).Path
        InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo } {
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'
            (Get-PowerStubGitInfo -Path $Root -Fetch).Status | Should -Be 'FetchFailed'
            $PSNativeCommandUseErrorActionPreference | Should -BeTrue
        }
        $env:GIT_TERMINAL_PROMPT | Should -BeExactly 'original-prompt'
        $env:GCM_INTERACTIVE | Should -BeExactly 'original-interactive'
        (Get-Location).Path | Should -Be $beforeLocation
    }

    It 'Disables both credential prompts during fetch and restores them after a thrown failure' {
        $env:GIT_TERMINAL_PROMPT = 'original-prompt'
        $env:GCM_INTERACTIVE = 'original-interactive'
        Set-GitTestFault -Operation fetch -Output 'mock fetch failure' -Throw
        (Get-GitTestInfo -Fetch).Status | Should -Be 'FetchFailed'
        $env:GIT_TERMINAL_PROMPT | Should -BeExactly 'original-prompt'
        $env:GCM_INTERACTIVE | Should -BeExactly 'original-interactive'
        (Get-GitTestFault).Count | Should -Be 1
        (Get-GitTestFault).Prompt | Should -Be '0'
        (Get-GitTestFault).Interactive | Should -Be 'never'
    }

    It 'Does not count a failed pull as an updated repository' {
        Invoke-GitFixture -C $script:GitRepo remote set-url origin (Join-Path $script:GitCaseRoot 'missing.git')
        $output = Get-GitTestUpdateOutput -All
        $output | Should -Match 'Failed to update:'
        $output | Should -Match 'Updated 0 repository\(ies\)'
        $output | Should -Match '1 repository\(ies\) failed to update'
        $output | Should -Not -Match 'Updated 1 repository'
    }

    It 'Counts only successful unique repositories in a mixed update' {
        $other = New-GitTestRepository -Name 'other'
        Invoke-GitFixture -C $other remote set-url origin (Join-Path $script:GitCaseRoot 'missing.git')
        InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo; Other = $other } {
            $Script:PSTBSettings['Stubs'] = @{ GitTest = $Root; Duplicate = $Root; Failed = $Other }
        }
        $output = Get-GitTestUpdateOutput -All
        $output | Should -Match 'Updated 1 repository\(ies\)'
        $output | Should -Match '1 repository\(ies\) failed to update'
        ([regex]::Matches($output, 'Repository updated successfully')).Count | Should -Be 1
    }

    It 'Disables both credential prompts during pull and restores them after a thrown failure' {
        $env:GIT_TERMINAL_PROMPT = 'original-prompt'
        $env:GCM_INTERACTIVE = 'original-interactive'
        Set-GitTestFault -Operation pull -Output 'mock pull failure' -Throw
        $result = InModuleScope PowerStub -Parameters @{ Root = $script:GitRepo } {
            Update-PowerStubGitRepo -Path $Root
        }
        $result.Success | Should -BeFalse
        $result.Message | Should -Match 'Failed to update: mock pull failure'
        $env:GIT_TERMINAL_PROMPT | Should -BeExactly 'original-prompt'
        $env:GCM_INTERACTIVE | Should -BeExactly 'original-interactive'
        (Get-GitTestFault).Count | Should -Be 1
        (Get-GitTestFault).Prompt | Should -Be '0'
        (Get-GitTestFault).Interactive | Should -Be 'never'
    }
}
