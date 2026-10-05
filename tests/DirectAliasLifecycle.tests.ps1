#Requires -Modules Pester
<#
.SYNOPSIS
    Direct-alias creation, persistence, and real PowerShell profile-startup contracts.

.DESCRIPTION
    Uses the installed manifest rather than importing the psm1 directly. Every test owns
    a disposable configuration; profile tests start genuinely new pwsh processes WITHOUT
    -NoProfile. A separate -NoProfile discovery process proves that the actual $PROFILE
    is inside the disposable home before anything is written. Platforms whose special
    folders cannot be isolated this way are explicitly skipped, never written to.

    All cases gate the explicit no-clobber contract: PowerShell keywords and existing
    commands are never replaceable, including with -Force or legacy forced config.
    Ownership-safe cleanup is covered in ReleaseCoverage.tests.ps1 as well.
#>

BeforeAll {
    $script:AliasManifest = (Resolve-Path (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1')).Path
    $script:AliasOriginalConfig = $env:POWERSTUB_CONFIG_DIR
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'  # tests must not start background Git update checks
    $script:AliasOriginalModule = @(Get-Module PowerStub | Select-Object -ExpandProperty Path)
    $script:AliasOriginalTab = (Get-Command TabExpansion2 -CommandType Function).ScriptBlock
    $script:AliasPwsh = (Get-Process -Id $PID).Path

    function Get-AliasLifecycleSavedConfig {
        Get-Content -LiteralPath $script:AliasConfigFile -Raw | ConvertFrom-Json -AsHashtable
    }

    function Get-AliasLifecycleConfigBytes {
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:AliasConfigFile))
    }

    function Set-AliasLifecycleLegacyForce {
        param([string[]]$Names)
        $saved = Get-AliasLifecycleSavedConfig
        $saved.ForcedDirectAliases = @($Names)
        $saved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:AliasConfigFile
        Import-PowerStubConfiguration
    }

    function New-AliasLifecycleStub {
        param([string]$Name = 'AliasFirst', [string]$Folder = $Name)
        $root = Join-Path $script:AliasRoot $Folder
        New-PowerStub -Name $Name -Path $root
        [IO.File]::WriteAllText((Join-Path $root 'Commands/identify.ps1'), "'$Name'")
        [IO.File]::WriteAllText((Join-Path $root 'Commands/deploy.ps1'), @'
param([ValidateSet('blue', 'green')][string]$Environment, [switch]$Force)
[pscustomobject]@{ Environment = $Environment; Force = [bool]$Force }
'@)
        return $root
    }

    function Invoke-AliasLifecycleChild {
        param([string]$HomeRoot, [string]$Code, [switch]$NoProfile)
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $script:AliasPwsh
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.WorkingDirectory = $HomeRoot
        foreach ($arg in '-NoLogo', '-NonInteractive') { $start.ArgumentList.Add($arg) }
        if ($NoProfile) { $start.ArgumentList.Add('-NoProfile') }
        $start.ArgumentList.Add('-EncodedCommand')
        $start.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))
        # Only the child's environment changes; the test runner's HOME/PROFILE/TEMP stay intact.
        $isolated = @{
            HOME = $HomeRoot; USERPROFILE = $HomeRoot
            XDG_CONFIG_HOME = (Join-Path $HomeRoot '.config')
            XDG_DATA_HOME = (Join-Path $HomeRoot '.local/share')
            XDG_CACHE_HOME = (Join-Path $HomeRoot '.cache')
            APPDATA = (Join-Path $HomeRoot 'AppData/Roaming')
            LOCALAPPDATA = (Join-Path $HomeRoot 'AppData/Local')
            TEMP = (Join-Path $HomeRoot 'temp'); TMP = (Join-Path $HomeRoot 'temp')
            TMPDIR = (Join-Path $HomeRoot 'temp')
        }
        foreach ($entry in $isolated.GetEnumerator()) {
            [IO.Directory]::CreateDirectory($entry.Value) | Out-Null
            $start.Environment[$entry.Key] = $entry.Value
        }
        # New homes must not opt into first-run telemetry while exercising startup.
        $start.Environment['POWERSHELL_TELEMETRY_OPTOUT'] = '1'
        $start.Environment['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
        $start.Environment['POWERSTUB_CONFIG_DIR'] = $env:POWERSTUB_CONFIG_DIR
        # Name-based Import-Module PowerStub discovers the repository's manifest as an installation.
        $start.Environment['PSModulePath'] = (Split-Path (Split-Path $script:AliasManifest)) +
            [IO.Path]::PathSeparator + $env:PSModulePath
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) {
                $process.Kill($true)
                throw 'Isolated profile test process timed out after 30 seconds.'
            }
            $output = $stdout.GetAwaiter().GetResult()
            $errors = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                throw "Isolated pwsh exited $($process.ExitCode): $errors $output"
            }
            if ($errors) { throw "Unexpected isolated pwsh stderr: $errors" }
            return ($output | ConvertFrom-Json)
        }
        finally { $process.Dispose() }
    }

    function Invoke-AliasLifecycleProfile {
        param([string]$Probe, [string]$BeforeImport = '')
        $homeRoot = Join-Path $script:AliasRoot "profile-home-$([guid]::NewGuid())"
        [IO.Directory]::CreateDirectory($homeRoot) | Out-Null
        $discovery = Invoke-AliasLifecycleChild -HomeRoot $homeRoot -NoProfile -Code @'
[pscustomobject]@{ Profile = [string]$PROFILE; Home = $HOME } | ConvertTo-Json -Compress
'@
        $profile = [IO.Path]::GetFullPath($discovery.Profile)
        $prefix = [IO.Path]::GetFullPath($homeRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $profile.StartsWith($prefix, $comparison)) {
            Set-ItResult -Skipped -Because 'This platform does not relocate $PROFILE into HOME/USERPROFILE; refusing to write the real user profile.'
            return
        }
        [IO.Directory]::CreateDirectory((Split-Path $profile)) | Out-Null
        $profileCode = @'
$ErrorActionPreference = 'Stop'
$global:AliasLifecycleModulesBeforeProfile = @(Get-Module PowerStub).Count
__BEFORE_IMPORT__
$profileWarnings = @(Import-Module PowerStub -ErrorAction Stop 3>&1)
$global:AliasLifecycleStartupWarnings = @($profileWarnings | ForEach-Object { $_.Message })
$global:AliasLifecycleProfileRan = [string]$PROFILE
'@.Replace('__BEFORE_IMPORT__', $BeforeImport)
        [IO.File]::WriteAllText($profile, $profileCode)
        $probeCode = @'
$ErrorActionPreference = 'Stop'
[pscustomobject]@{
    ProcessId = $PID
    Profile = [string]$PROFILE
    ProfileRan = $global:AliasLifecycleProfileRan
    ModulesBeforeProfile = $global:AliasLifecycleModulesBeforeProfile
    LoadedModulePaths = @(Get-Module PowerStub | ForEach-Object Path)
    Warnings = @($global:AliasLifecycleStartupWarnings)
    Data = & { __PROBE__ }
} | ConvertTo-Json -Depth 12 -Compress
'@.Replace('__PROBE__', $Probe)
        # Deliberately no -NoProfile and no Import-Module in the probe. Startup must load it.
        $result = Invoke-AliasLifecycleChild -HomeRoot $homeRoot -Code $probeCode
        $result.ProcessId | Should -Not -Be $PID
        $result.Profile | Should -BeExactly $profile
        $result.ProfileRan | Should -BeExactly $profile
        $result.ModulesBeforeProfile | Should -Be 0
        @($result.LoadedModulePaths).Count | Should -Be 1
        $result.LoadedModulePaths[0] | Should -Be (Join-Path (Split-Path $script:AliasManifest) 'PowerStub.psm1')
        return $result
    }
}

AfterAll {
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:AliasOriginalConfig
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    foreach ($path in $script:AliasOriginalModule) { Import-Module $path -Force -WarningAction SilentlyContinue }
    Set-Item function:global:TabExpansion2 $script:AliasOriginalTab
}

Describe 'Direct alias creation and session lifecycle through the manifest' -Tag 'DirectAliasLifecycle' {
    BeforeEach {
        Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
        $script:AliasRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBAlias_$([guid]::NewGuid())"
        $env:POWERSTUB_CONFIG_DIR = Join-Path $script:AliasRoot 'config'
        [IO.Directory]::CreateDirectory($env:POWERSTUB_CONFIG_DIR) | Out-Null
        $script:AliasConfigFile = Join-Path $env:POWERSTUB_CONFIG_DIR 'config.json'
        @{ GitEnabled = $false; Stubs = @{}; DirectAliases = @{}; InvokeAlias = 'pstb' } |
            ConvertTo-Json | Set-Content -LiteralPath $script:AliasConfigFile
        $script:AliasName = 'pstbal' + [guid]::NewGuid().ToString('N')
        $script:AliasOther = $script:AliasName + 'other'
        $script:AliasOwnedNames = @($script:AliasName, $script:AliasOther)
        Import-Module $script:AliasManifest -Force
        $script:AliasFirstPath = New-AliasLifecycleStub
    }

    AfterEach {
        Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
        foreach ($name in $script:AliasOwnedNames) {
            Remove-Item "function:$name" -Force -ErrorAction SilentlyContinue
            Remove-Item "alias:$name" -Force -ErrorAction SilentlyContinue
        }
        Set-Item function:global:TabExpansion2 $script:AliasOriginalTab
        if (Test-Path -LiteralPath $script:AliasRoot) { Remove-Item -LiteralPath $script:AliasRoot -Recurse -Force }
    }

    Context 'Adding and updating direct aliases' {
        It 'Creates an immediately callable global proxy and persists accurate result metadata' {
            $result = New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst
            $result.AliasName | Should -Be $script:AliasName
            $result.Stub | Should -Be 'AliasFirst'
            $result.StubPath | Should -Be $script:AliasFirstPath
            $result.Usage | Should -Match 'Import-Module PowerStub'
            (Get-Command $script:AliasName).CommandType | Should -Be 'Function'
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
            $listing = & $script:AliasName 6>&1 | Out-String
            $listing | Should -Match 'Command\s+Synopsis'
            $listing | Should -Match '\bdeploy\b'
            (Get-AliasLifecycleSavedConfig).DirectAliases[$script:AliasName] | Should -Be 'AliasFirst'
            @((Get-AliasLifecycleSavedConfig).ForcedDirectAliases) | Should -Not -Contain $script:AliasName
        }

        It 'Accepts the valid <Suffix> name form and invokes it after manifest reload' -ForEach @(
            @{ Suffix = '-dash' }, @{ Suffix = '_underscore' }, @{ Suffix = 'Mixed42' }
        ) {
            $name = $script:AliasName + $Suffix
            $script:AliasOwnedNames += $name
            New-PowerStubDirectAlias -AliasName $name -Stub AliasFirst | Out-Null
            Import-Module $script:AliasManifest -Force
            (& $name identify 6>$null) | Should -Be 'AliasFirst'
        }

        It 'Rejects invalid alias name <Label> without changing persisted configuration' -ForEach @(
            @{ Label = 'empty'; Name = '' }, @{ Label = 'numeric prefix'; Name = '7invalid' },
            @{ Label = 'space'; Name = 'two names' }, @{ Label = 'scope syntax'; Name = 'global:injected' },
            @{ Label = 'semicolon'; Name = 'bad;name' }, @{ Label = 'quote'; Name = "bad'name" },
            @{ Label = 'wildcard'; Name = 'bad*name' }, @{ Label = 'path'; Name = 'bad/name' },
            @{ Label = 'leading underscore'; Name = '_invalid' }
        ) {
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $Name -Stub AliasFirst -Force } | Should -Throw
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            @((Get-AliasLifecycleSavedConfig).DirectAliases.Keys).Count | Should -Be 0
        }

        It 'Rejects reserved <Name> even with Force without modifying the existing command' -ForEach @(
            @{ Name = 'git' }, @{ Name = 'Cd' }, @{ Name = 'EXIT' }, @{ Name = 'rm' },
            @{ Name = 'if' }, @{ Name = 'DO' }, @{ Name = 'function' }, @{ Name = 'foreach' },
            @{ Name = 'return' }, @{ Name = 'try' }, @{ Name = 'class' }
        ) {
            $before = Get-AliasLifecycleConfigBytes
            $existing = @(Get-Command $Name -ErrorAction SilentlyContinue | ForEach-Object Definition)
            { New-PowerStubDirectAlias -AliasName $Name -Stub AliasFirst -Force } | Should -Throw '*reserved*'
            @(Get-Command $Name -ErrorAction SilentlyContinue | ForEach-Object Definition) | Should -Be $existing
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Rejects a missing stub without overwriting an existing function even with Force' {
            Set-Item "function:global:$script:AliasName" { 'existing-function' }
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $script:AliasName -Stub MissingStub -Force } | Should -Throw
            (& $script:AliasName) | Should -Be 'existing-function'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Rejects duplicate creation and retargeting without Force while preserving the original target' {
            $null = New-AliasLifecycleStub -Name AliasSecond
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $before = Get-AliasLifecycleConfigBytes
            foreach ($stub in 'AliasFirst', 'AliasSecond') {
                { New-PowerStubDirectAlias -AliasName $script:AliasName -Stub $stub } | Should -Throw '*already exists*'
            }
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Rejects a case-insensitive duplicate even with Force and preserves the saved original target' {
            $null = New-AliasLifecycleStub -Name AliasSecond
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $script:AliasName.ToUpperInvariant() -Stub AliasSecond -Force } | Should -Throw
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
            @((Get-AliasLifecycleSavedConfig).DirectAliases.Keys).Count | Should -Be 1
            (Get-AliasLifecycleSavedConfig).DirectAliases[$script:AliasName] | Should -Be 'AliasFirst'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            Import-Module $script:AliasManifest -Force
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
        }

        It 'Repeated duplicate rejection with Force is byte- and timestamp-idempotent and grants no shadow permission' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $before = Get-AliasLifecycleConfigBytes
            $stamp = (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc
            1..3 | ForEach-Object {
                { New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst -Force } | Should -Throw
            }
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc | Should -Be $stamp
            @((Get-AliasLifecycleSavedConfig).ForcedDirectAliases) | Should -Not -Contain $script:AliasName
        }

        It 'Rejects a saved-only duplicate targeting <Target> with Force=<Force> and still restores it on reload' -ForEach @(
            @{ Target = 'AliasFirst'; Force = $false }, @{ Target = 'AliasFirst'; Force = $true },
            @{ Target = 'AliasSecond'; Force = $false }, @{ Target = 'AliasSecond'; Force = $true }
        ) {
            $null = New-AliasLifecycleStub -Name AliasSecond
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            Remove-Item "function:$script:AliasName" -Force
            Get-Command $script:AliasName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $script:AliasName.ToUpperInvariant() -Stub $Target -Force:$Force } | Should -Throw
            Get-Command $script:AliasName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            Import-Module $script:AliasManifest -Force
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Rejects a conflicting <Kind> with Force=<Force> and preserves command identity and config' -ForEach @(
            @{ Kind = 'function'; Force = $false }, @{ Kind = 'function'; Force = $true },
            @{ Kind = 'PowerShell Alias'; Force = $false }, @{ Kind = 'PowerShell Alias'; Force = $true }
        ) {
            if ($Kind -eq 'function') { Set-Item "function:global:$script:AliasName" { 'existing-function' } }
            else { Set-Alias -Name $script:AliasName -Value Get-Date -Scope Global }
            $existing = Get-Command $script:AliasName
            $definition = $existing.Definition
            $kindBefore = $existing.CommandType
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst -Force:$Force } | Should -Throw '*already exists*'
            (Get-Command $script:AliasName).Definition | Should -BeExactly $definition
            (Get-Command $script:AliasName).CommandType | Should -Be $kindBefore
            if ($Kind -eq 'function') {
                [object]::ReferenceEquals((Get-Command $script:AliasName).ScriptBlock, $existing.ScriptBlock) | Should -BeTrue
            }
            else {
                @(Get-Command $script:AliasName -CommandType Function -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Rejects existing <Kind> command <Name> even with Force and does not mutate config' -ForEach @(
            @{ Kind = 'cmdlet'; Name = 'Get-Date' }, @{ Kind = 'native executable'; Name = 'pwsh' },
            @{ Kind = 'module function'; Name = 'Invoke-PowerStubCommand' }, @{ Kind = 'entrypoint alias'; Name = 'pstb' }
        ) {
            $before = Get-AliasLifecycleConfigBytes
            $existing = Get-Command $Name -ErrorAction Stop
            { New-PowerStubDirectAlias -AliasName $Name.ToUpperInvariant() -Stub AliasFirst -Force } | Should -Throw
            (Get-Command $Name).Definition | Should -BeExactly $existing.Definition
            (Get-Command $Name).CommandType | Should -Be $existing.CommandType
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Allows Force on an unused name without creating legacy shadow permission' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst -Force | Out-Null
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
            @((Get-AliasLifecycleSavedConfig).ForcedDirectAliases) | Should -Not -Contain $script:AliasName
        }

        It 'Rejects a module-private helper name without exporting, replacing, or persisting it' {
            $name = 'Get-PowerStubConfigurationDefaults'
            $before = Get-AliasLifecycleConfigBytes
            $definition = InModuleScope PowerStub { (Get-Command Get-PowerStubConfigurationDefaults).ScriptBlock.ToString() }
            $defaultAlias = InModuleScope PowerStub { (Get-PowerStubConfigurationDefaults).InvokeAlias }
            Get-Command $name -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            { New-PowerStubDirectAlias -AliasName $name -Stub AliasFirst -Force } | Should -Throw
            Get-Command $name -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            InModuleScope PowerStub { (Get-Command Get-PowerStubConfigurationDefaults).ScriptBlock.ToString() } | Should -BeExactly $definition
            InModuleScope PowerStub { (Get-PowerStubConfigurationDefaults).InvokeAlias } | Should -Be $defaultAlias
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }
    }

    Context 'Stub changes, removal, and unload' {
        It 'An existing direct alias follows a changed stub path immediately and after reload' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $second = New-AliasLifecycleStub -Name AliasSecond
            New-PowerStub -Name AliasFirst -Path $second -Force
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasSecond'
            Import-Module $script:AliasManifest -Force
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasSecond'
        }

        It 'Removing an alias clears its saved Force permission and keeps another alias across reload' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $script:AliasOther -Stub AliasFirst | Out-Null
            Set-AliasLifecycleLegacyForce -Names $script:AliasName
            Remove-PowerStubDirectAlias $script:AliasName
            Import-Module $script:AliasManifest -Force
            Get-Command $script:AliasName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            (Get-AliasLifecycleSavedConfig).DirectAliases.Keys | Should -Not -Contain $script:AliasName
            @((Get-AliasLifecycleSavedConfig).ForcedDirectAliases) | Should -Not -Contain $script:AliasName
            (& $script:AliasOther identify 6>$null) | Should -Be 'AliasFirst'
        }

        It 'Stub removal cleans all of its aliases and Force permissions but preserves another stub and command files' {
            $null = New-AliasLifecycleStub -Name AliasSecond
            $secondName = $script:AliasName + 'second'
            $script:AliasOwnedNames += $secondName
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $script:AliasOther -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $secondName -Stub AliasSecond | Out-Null
            Set-AliasLifecycleLegacyForce -Names $script:AliasName
            Remove-PowerStub AliasFirst
            Import-Module $script:AliasManifest -Force
            foreach ($name in $script:AliasName, $script:AliasOther) {
                Get-Command $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                (Get-AliasLifecycleSavedConfig).DirectAliases.Keys | Should -Not -Contain $name
                @((Get-AliasLifecycleSavedConfig).ForcedDirectAliases) | Should -Not -Contain $name
            }
            Test-Path -LiteralPath (Join-Path $script:AliasFirstPath 'Commands/identify.ps1') | Should -BeTrue
            (& $secondName identify 6>$null) | Should -Be 'AliasSecond'
        }

        It 'Unload removes only registered proxies and leaves persistence available for the next import' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            Set-Item "function:global:$script:AliasOther" { 'unrelated-function' }
            $before = Get-AliasLifecycleConfigBytes
            Remove-Module PowerStub -Force
            Get-Command $script:AliasName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            (& $script:AliasOther) | Should -Be 'unrelated-function'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            Import-Module $script:AliasManifest -Force
            (& $script:AliasName identify 6>$null) | Should -Be 'AliasFirst'
        }
    }

    Context 'Actual fresh-process automatic profile startup' {
        It 'Two independent sessions automatically run the real PROFILE and restore multiple aliases without rewriting config' {
            $null = New-AliasLifecycleStub -Name AliasSecond
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $script:AliasOther -Stub AliasSecond | Out-Null
            $before = Get-AliasLifecycleConfigBytes
            $stamp = (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc
            $probe = "@(& '$script:AliasName' identify 6>`$null; & '$script:AliasOther' identify 6>`$null)"
            $first = Invoke-AliasLifecycleProfile -Probe $probe
            $second = Invoke-AliasLifecycleProfile -Probe $probe
            $first.Data | Should -Be @('AliasFirst', 'AliasSecond')
            $second.Data | Should -Be @('AliasFirst', 'AliasSecond')
            $first.ProcessId | Should -Not -Be $second.ProcessId
            @($first.Warnings).Count | Should -Be 0
            @($second.Warnings).Count | Should -Be 0
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc | Should -Be $stamp
        }

        It 'Profile-restored aliases list commands, bind target parameters, and complete commands, parameters, and values' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $probe = @'
$name = '__ALIAS__'
$commandLine = "$name dep"
$parameterLine = "$name deploy -Env"
$valueLine = "$name deploy -Environment gr"
[pscustomobject]@{
    Commands = & $name 6>&1 | Out-String
    Invocation = & $name deploy -Environment green -Force:$false 6>$null
    CommandCompletion = @((TabExpansion2 $commandLine $commandLine.Length).CompletionMatches.CompletionText)
    ParameterCompletion = @((TabExpansion2 $parameterLine $parameterLine.Length).CompletionMatches.CompletionText)
    ValueCompletion = @((TabExpansion2 $valueLine $valueLine.Length).CompletionMatches.CompletionText)
}
'@.Replace('__ALIAS__', $script:AliasName)
            $result = Invoke-AliasLifecycleProfile -Probe $probe
            $result.Data.Commands | Should -Match 'Command\s+Synopsis'
            $result.Data.Commands | Should -Match '\bidentify\b'
            $result.Data.Commands | Should -Match '\bdeploy\b'
            $result.Data.Invocation.Environment | Should -Be 'green'
            $result.Data.Invocation.Force | Should -BeFalse
            $result.Data.CommandCompletion | Should -Contain 'deploy'
            $result.Data.ParameterCompletion | Should -Contain '-Environment'
            $result.Data.ValueCompletion | Should -Contain 'green'
        }

        It 'Profile loading preserves an existing function without saved Force consent and still restores other aliases' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $script:AliasOther -Stub AliasFirst | Out-Null
            $before = Get-AliasLifecycleConfigBytes
            $result = Invoke-AliasLifecycleProfile -BeforeImport "function global:$script:AliasName { 'profile-owned' }" -Probe @"
@(& '$script:AliasName'; & '$script:AliasOther' identify 6>`$null)
"@
            $result.Data | Should -Be @('profile-owned', 'AliasFirst')
            ($result.Warnings -join ' ') | Should -Match 'already exists'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Profile loading ignores legacy Force permission and preserves a preexisting function without rewriting config' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            Set-AliasLifecycleLegacyForce -Names $script:AliasName
            $before = Get-AliasLifecycleConfigBytes
            $stamp = (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc
            $result = Invoke-AliasLifecycleProfile -BeforeImport "function global:$script:AliasName { 'profile-owned' }" -Probe "& '$script:AliasName' | ForEach-Object { `$_.ToString() }"
            $result.Data | Should -Be 'profile-owned'
            ($result.Warnings -join ' ') | Should -Match 'already exists'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
            (Get-Item -LiteralPath $script:AliasConfigFile).LastWriteTimeUtc | Should -Be $stamp
        }

        It 'Profile loading skips orphaned, invalid, reserved, and keyword aliases but keeps valid aliases usable' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            $saved = Get-AliasLifecycleSavedConfig
            $saved.DirectAliases[$script:AliasOther] = 'MissingStub'
            $saved.DirectAliases['bad;name'] = 'AliasFirst'
            $saved.DirectAliases['git'] = 'AliasFirst'
            $saved.DirectAliases['do'] = 'AliasFirst'
            $saved.ForcedDirectAliases = @('git', 'bad;name', 'do')
            $saved | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $script:AliasConfigFile
            $before = Get-AliasLifecycleConfigBytes
            $result = Invoke-AliasLifecycleProfile -Probe @"
[pscustomobject]@{
    Value = & '$script:AliasName' identify 6>`$null
    Orphan = @(Get-Command '$script:AliasOther' -ErrorAction SilentlyContinue).Count
    Invalid = @(Get-Command 'bad;name' -ErrorAction SilentlyContinue).Count
    ReservedFunctions = @(Get-Command git -CommandType Function -ErrorAction SilentlyContinue).Count
    KeywordFunctions = @(Get-Command do -CommandType Function -ErrorAction SilentlyContinue).Count
}
"@
            $result.Data.Value | Should -Be 'AliasFirst'
            $result.Data.Orphan | Should -Be 0
            $result.Data.Invalid | Should -Be 0
            $result.Data.ReservedFunctions | Should -Be 0
            $result.Data.KeywordFunctions | Should -Be 0
            @($result.Warnings).Count | Should -Be 3
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'A removed alias does not resurrect at automatic profile startup while another alias remains callable' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            New-PowerStubDirectAlias -AliasName $script:AliasOther -Stub AliasFirst | Out-Null
            Remove-PowerStubDirectAlias $script:AliasName
            $result = Invoke-AliasLifecycleProfile -Probe @"
[pscustomobject]@{
    Removed = @(Get-Command '$script:AliasName' -ErrorAction SilentlyContinue).Count
    Kept = & '$script:AliasOther' identify 6>`$null
}
"@
            $result.Data.Removed | Should -Be 0
            $result.Data.Kept | Should -Be 'AliasFirst'
        }
    }

    Context 'Foreign commands and legacy forced configuration are never replaceable' {
        It 'Force must not reclaim a user replacement for a formerly owned direct-alias function' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            Set-Item "function:global:$script:AliasName" { 'user-replacement' }
            $before = Get-AliasLifecycleConfigBytes
            { New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst -Force } | Should -Throw
            (& $script:AliasName) | Should -Be 'user-replacement'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }

        It 'Profile loading must preserve an existing PowerShell Alias even with legacy Force permission' {
            New-PowerStubDirectAlias -AliasName $script:AliasName -Stub AliasFirst | Out-Null
            Set-AliasLifecycleLegacyForce -Names $script:AliasName
            $before = Get-AliasLifecycleConfigBytes
            $result = Invoke-AliasLifecycleProfile -BeforeImport "Set-Alias -Name '$script:AliasName' -Value Get-Date -Scope Global" -Probe @"
[pscustomobject]@{
    Kind = (Get-Command '$script:AliasName').CommandType.ToString()
    Definition = (Get-Command '$script:AliasName').Definition
    HiddenFunctions = @(Get-Command '$script:AliasName' -CommandType Function -ErrorAction SilentlyContinue).Count
}
"@
            $result.Data.Kind | Should -Be 'Alias'
            $result.Data.Definition | Should -Be 'Get-Date'
            $result.Data.HiddenFunctions | Should -Be 0
            ($result.Warnings -join ' ') | Should -Match 'already exists'
            Get-AliasLifecycleConfigBytes | Should -BeExactly $before
        }
    }
}
