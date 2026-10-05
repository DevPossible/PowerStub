#Requires -Modules Pester

<#
    The background update check: when a stub command runs, PowerStub reads the last result for
    the stub's repository, says so if it is behind, and starts a background fetch at most every
    UpdateCheckIntervalHours. It must be invisible to users without Git, to stubs outside a
    repository, and to the command's own output and status.
#>

BeforeAll {
    $script:UpdateOriginalConfig = $env:POWERSTUB_CONFIG_DIR
    $script:UpdateOriginalNoCheck = $env:POWERSTUB_NO_UPDATE_CHECK
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    $script:UpdateRoot = Join-Path ([IO.Path]::GetTempPath()) "PSTBUpdateCheck_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = Join-Path $script:UpdateRoot 'config'
    Import-Module (Join-Path $PSScriptRoot '../PowerStub/PowerStub.psd1') -Force
    $script:BackgroundScript = Join-Path $PSScriptRoot '../PowerStub/private/scripts/Update-PowerStubRemoteStatus.ps1'

    function Invoke-GitFixture {
        & git @args 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Local Git fixture command failed: git $args" }
    }

    function New-UpdateStubFolder {
        param([string]$Root)
        [IO.Directory]::CreateDirectory((Join-Path $Root 'Commands')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root 'Commands/hello.ps1'), "'hello output'")
        return $Root
    }

    # A stub in a repository whose local bare remote has one commit the stub does not.
    function New-BehindRepository {
        param([string]$Name)
        $root = New-UpdateStubFolder (Join-Path $script:UpdateRoot $Name)
        $origin = Join-Path $script:UpdateRoot "$Name-origin.git"
        $other = Join-Path $script:UpdateRoot "$Name-other"
        $identity = @('-c', 'user.name=PowerStubTests', '-c', 'user.email=tests@example.invalid', '-c', 'commit.gpgSign=false')
        Invoke-GitFixture init --bare --quiet $origin
        Invoke-GitFixture init --quiet --initial-branch=main $root
        Invoke-GitFixture -C $root add .
        Invoke-GitFixture -C $root @identity commit --quiet -m one
        Invoke-GitFixture -C $root remote add origin $origin
        Invoke-GitFixture -C $root push --quiet --set-upstream origin main
        Invoke-GitFixture clone --quiet $origin $other
        Invoke-GitFixture -C $other @identity commit --allow-empty --quiet -m two
        Invoke-GitFixture -C $other push --quiet
        return $root
    }

    function Get-StateFile {
        param([string]$StubPath)
        InModuleScope PowerStub -Parameters @{ StubPath = $StubPath } { Get-PowerStubUpdateCheckFile -StubPath $StubPath }
    }

    function Set-State {
        param([string]$StubPath, [string]$Status = 'Ready', $BehindCount = 0, [datetime]$LastCheckUtc = [datetime]::UtcNow, [string]$RepoRoot = $StubPath)
        $file = Get-StateFile $StubPath
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        @{ Path = $StubPath; LastCheckUtc = $LastCheckUtc.ToString('o'); Status = $Status; RepoRoot = $RepoRoot; BehindCount = $BehindCount } |
            ConvertTo-Json | Set-Content -LiteralPath $file
    }

    function Invoke-Background {
        param([string]$StubPath)
        & $script:BackgroundScript -Path $StubPath -StateFile (Get-StateFile $StubPath)
        InModuleScope PowerStub -Parameters @{ File = (Get-StateFile $StubPath) } { Read-PowerStubUpdateCheckState -File $File }
    }

    function Get-Notices {
        param([object[]]$Records)
        @($Records | Where-Object { $_ -is [Management.Automation.InformationRecord] -and "$_" -like 'You do not have the latest version*' } |
            ForEach-Object { "$_" })
    }

    function Reset-Session {
        InModuleScope PowerStub {
            $Script:UpdateNoticesShown = @{}
            $Script:GitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
            $Script:GitEnabled = $Script:GitAvailable
            Set-PowerStubConfigurationKey 'UpdateCheckIntervalHours' 4
        }
    }

    $script:GitInstalled = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    $script:PlainStub = New-UpdateStubFolder (Join-Path $script:UpdateRoot 'plain')
    New-PowerStub -Name 'PlainStub' -Path $script:PlainStub -Force | Out-Null
    if ($script:GitInstalled) {
        $script:BehindStub = New-BehindRepository 'behind'
        New-PowerStub -Name 'BehindStub' -Path $script:BehindStub -Force | Out-Null
        New-PowerStubDirectAlias -AliasName 'pstbupdatealias' -Stub 'BehindStub'
    }
}

AfterAll {
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $script:UpdateOriginalConfig
    if ($null -ne $script:UpdateOriginalNoCheck) { $env:POWERSTUB_NO_UPDATE_CHECK = $script:UpdateOriginalNoCheck }
    if (Test-Path -LiteralPath $script:UpdateRoot) {
        Remove-Item -LiteralPath $script:UpdateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Update check gating' {
    BeforeEach {
        Reset-Session
        Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
        Mock Test-PowerStubInteractiveSession { $true } -ModuleName PowerStub
        Mock Start-PowerStubUpdateCheck { } -ModuleName PowerStub
    }

    It 'Starts a check for a stub that has never been checked' {
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 1 -Exactly
    }

    It 'Does nothing when Git is not installed' {
        InModuleScope PowerStub { $Script:GitAvailable = $false; $Script:GitEnabled = $false }
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
        Test-Path -LiteralPath (Get-StateFile $script:PlainStub) | Should -BeFalse
    }

    It 'Does nothing when Git integration is disabled' {
        InModuleScope PowerStub { $Script:GitEnabled = $false }
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Does nothing when UpdateCheckIntervalHours is <Value>' -ForEach @(
        @{ Value = 0 }, @{ Value = -1 }, @{ Value = 'never' }
    ) {
        InModuleScope PowerStub -Parameters @{ Value = $Value } { Set-PowerStubConfigurationKey 'UpdateCheckIntervalHours' $Value }
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Does nothing when POWERSTUB_NO_UPDATE_CHECK is set' {
        $env:POWERSTUB_NO_UPDATE_CHECK = '1'
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Does nothing in a non-interactive session' {
        Mock Test-PowerStubInteractiveSession { $false } -ModuleName PowerStub
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Does not check again within the interval' {
        Set-State $script:PlainStub -Status 'NotRepository' -RepoRoot '' -LastCheckUtc ([datetime]::UtcNow.AddHours(-3.9))
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Checks again once the interval has passed' {
        Set-State $script:PlainStub -Status 'NotRepository' -RepoRoot '' -LastCheckUtc ([datetime]::UtcNow.AddHours(-4.1))
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 1 -Exactly
    }

    It 'Treats an unreadable state file as due for a check' {
        $file = Get-StateFile $script:PlainStub
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        Set-Content -LiteralPath $file -Value '{ not json'
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 1 -Exactly
    }

    It 'Still runs the command, with its status, when the check itself fails' {
        Mock Get-PowerStubUpdateCheckFile { throw 'simulated failure' } -ModuleName PowerStub
        $output = pstb PlainStub hello 6>$null
        $succeeded = $?
        $output | Should -Be 'hello output'
        $succeeded | Should -BeTrue
    }
}

Describe 'Update check message' {
    BeforeEach {
        Reset-Session
        Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
        Mock Test-PowerStubInteractiveSession { $true } -ModuleName PowerStub
        Mock Start-PowerStubUpdateCheck { } -ModuleName PowerStub
        Set-State $script:PlainStub -Status 'Ready' -BehindCount 2 -RepoRoot 'C:/fake/plain'
    }

    It 'Says the stub is behind, outside the command output' {
        $records = pstb PlainStub hello 6>&1
        @($records | Where-Object { $_ -isnot [Management.Automation.InformationRecord] }) | Should -Be @('hello output')
        Get-Notices $records | Should -Be @("You do not have the latest version of 'PlainStub' (2 commit(s) behind). Run 'pstb update PlainStub' to get the latest version.")
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It 'Says it once per repository per session' {
        Get-Notices (pstb PlainStub hello 6>&1) | Should -HaveCount 1
        Get-Notices (pstb PlainStub hello 6>&1) | Should -HaveCount 0
    }

    It 'Says nothing when the stub is up to date or could not be checked' -ForEach @(
        @{ Status = 'Ready'; Behind = 0 }, @{ Status = 'FetchFailed'; Behind = $null },
        @{ Status = 'NotRepository'; Behind = $null }, @{ Status = 'CheckFailed'; Behind = $null }
    ) {
        Set-State $script:PlainStub -Status $Status -BehindCount $Behind
        Get-Notices (pstb PlainStub hello 6>&1) | Should -HaveCount 0
    }

    It 'Is not affected by WarningPreference Stop' {
        $WarningPreference = 'Stop'
        pstb PlainStub hello 6>$null | Should -Be 'hello output'
    }
}

Describe 'Background check' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeEach {
        Reset-Session
        Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
        Mock Test-PowerStubInteractiveSession { $true } -ModuleName PowerStub
        Remove-Item -LiteralPath (Join-Path $env:POWERSTUB_CONFIG_DIR 'update-check') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Records how far behind a repository is' {
        $state = Invoke-Background $script:BehindStub
        $state.Status | Should -Be 'Ready'
        $state.BehindCount | Should -Be 1
        $state.RepoRoot | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath "$(Get-StateFile $script:BehindStub).lock" | Should -BeFalse
    }

    It 'Records a stub outside any repository' {
        $state = Invoke-Background $script:PlainStub
        $state.Status | Should -Be 'NotRepository'
        $state.BehindCount | Should -BeNullOrEmpty
    }

    It 'Records a failed fetch without a behind count' {
        $root = New-BehindRepository 'unreachable'
        Remove-Item -LiteralPath (Join-Path $script:UpdateRoot 'unreachable-origin.git') -Recurse -Force
        $state = Invoke-Background $root
        $state.Status | Should -Be 'FetchFailed'
        $state.BehindCount | Should -BeNullOrEmpty
    }

    It 'Runs detached and reports through pstb and a direct alias' {
        $file = Get-StateFile $script:BehindStub
        $first = pstb BehindStub hello 6>&1
        Get-Notices $first | Should -HaveCount 0
        $deadline = [datetime]::UtcNow.AddSeconds(60)
        while ([datetime]::UtcNow -lt $deadline -and (-not (Test-Path -LiteralPath $file) -or (Test-Path -LiteralPath "$file.lock"))) {
            Start-Sleep -Milliseconds 200
        }
        Test-Path -LiteralPath "$file.lock" | Should -BeFalse

        Get-Notices (pstbupdatealias hello 6>&1) | Should -Be @("You do not have the latest version of 'BehindStub' (1 commit(s) behind). Run 'pstb update BehindStub' to get the latest version.")
    }

    It 'Starts only one check while another is running' {
        $file = Get-StateFile $script:BehindStub
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        [IO.File]::WriteAllText("$file.lock", '')
        InModuleScope PowerStub -Parameters @{ Path = $script:BehindStub; File = $file } { Start-PowerStubUpdateCheck -StubPath $Path -StateFile $File }
        Start-Sleep -Seconds 1
        Test-Path -LiteralPath $file | Should -BeFalse
        Test-Path -LiteralPath "$file.lock" | Should -BeTrue
    }

    It 'Takes over a check that died' {
        $file = Get-StateFile $script:BehindStub
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        [IO.File]::WriteAllText("$file.lock", '')
        [IO.File]::SetLastWriteTimeUtc("$file.lock", [datetime]::UtcNow.AddMinutes(-31))
        InModuleScope PowerStub -Parameters @{ Path = $script:BehindStub; File = $file } { Start-PowerStubUpdateCheck -StubPath $Path -StateFile $File }
        $deadline = [datetime]::UtcNow.AddSeconds(60)
        while ([datetime]::UtcNow -lt $deadline -and (Test-Path -LiteralPath "$file.lock")) { Start-Sleep -Milliseconds 200 }
        (InModuleScope PowerStub -Parameters @{ File = $file } { Read-PowerStubUpdateCheckState -File $File }).BehindCount | Should -Be 1
    }

    It 'Checks each stub on its own when only some are in repositories' {
        Mock Start-PowerStubUpdateCheck { } -ModuleName PowerStub
        Set-State $script:PlainStub -Status 'NotRepository' -RepoRoot ''
        $null = Invoke-Background $script:BehindStub
        Get-Notices (pstb PlainStub hello 6>&1) | Should -HaveCount 0
        Get-Notices (pstb BehindStub hello 6>&1) | Should -HaveCount 1
        Should -Invoke Start-PowerStubUpdateCheck -ModuleName PowerStub -Times 0 -Exactly
    }

    It "Forgets the result after 'pstb update' pulls the repository" {
        $root = New-BehindRepository 'pulled'
        New-PowerStub -Name 'PulledStub' -Path $root -Force | Out-Null
        $null = Invoke-Background $root
        Test-Path -LiteralPath (Get-StateFile $root) | Should -BeTrue

        pstb update PulledStub 6>$null
        Test-Path -LiteralPath (Get-StateFile $root) | Should -BeFalse
        Remove-PowerStub -Name 'PulledStub' | Out-Null
    }
}

Describe 'Interactive session detection' {
    It 'Is false in CI' {
        $saved = $env:CI
        try {
            $env:CI = 'true'
            InModuleScope PowerStub { Test-PowerStubInteractiveSession } | Should -BeFalse
        }
        finally {
            if ($null -eq $saved) { Remove-Item Env:\CI } else { $env:CI = $saved }
        }
    }
}
