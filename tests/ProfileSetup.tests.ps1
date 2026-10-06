#Requires -Modules Pester
<#
.SYNOPSIS
    Tests for Add-PowerStubToProfile and Remove-PowerStubFromProfile.

.DESCRIPTION
    Every test passes -Path to a file in a throwaway folder, so the real profile is never read or written.
#>

BeforeAll {
    $module = Get-Module -Name 'PowerStub'
    if ($module) {
        Remove-Module -ModuleInfo $module -Force
    }

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBProfileTests_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = Join-Path $script:TestRoot 'config'
    $env:POWERSTUB_NO_UPDATE_CHECK = '1'

    $script:Manifest = (Resolve-Path (Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psd1')).Path
    Import-Module $script:Manifest -Force

    # Loaded from the repository, not from PSModulePath, so the import names the manifest
    $script:ImportLine = "Import-Module '$($script:Manifest.Replace("'", "''"))'"

    function script:New-ProfilePath {
        Join-Path $script:TestRoot "$([guid]::NewGuid())/profile.ps1"
    }

    function script:Set-ProfileText([string]$Path, [string]$Text, [System.Text.Encoding]$Encoding = [System.Text.UTF8Encoding]::new($false)) {
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text, $Encoding)
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_NO_UPDATE_CHECK -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestRoot) {
        Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
    }
}

Describe 'Add-PowerStubToProfile' {
    It 'AddPowerStubToProfile_MissingFileAndFolder_CreatesProfileWithImport' {
        $path = New-ProfilePath

        $result = Add-PowerStubToProfile -Path $path

        $result.Added | Should -BeTrue
        $result.Line | Should -BeExactly $script:ImportLine
        Get-Content -LiteralPath $path | Should -Be @('# PowerStub', $script:ImportLine)
    }

    It 'AddPowerStubToProfile_FileWithoutTrailingNewline_AddsImportAsSeparateStatement' {
        $path = New-ProfilePath
        Set-ProfileText $path "Set-Alias ll Get-ChildItem`r`n# last line has no newline"

        Add-PowerStubToProfile -Path $path | Out-Null

        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -BeExactly "Set-Alias ll Get-ChildItem`r`n# last line has no newline`r`n`r`n# PowerStub`r`n$script:ImportLine`r`n"
    }

    It 'AddPowerStubToProfile_RunTwice_AddsOnlyOnce' {
        $path = New-ProfilePath

        Add-PowerStubToProfile -Path $path | Out-Null
        $second = Add-PowerStubToProfile -Path $path

        $second.Added | Should -BeFalse
        @(Get-Content -LiteralPath $path | Where-Object { $_ -like 'Import-Module*' }).Count | Should -Be 1
    }

    It 'AddPowerStubToProfile_ExistingImportByName_LeavesFileUnchanged' {
        $path = New-ProfilePath
        Set-ProfileText $path "if (`$true) {`n    Import-Module -Name PowerStub -ErrorAction Stop`n}`n"

        $result = Add-PowerStubToProfile -Path $path

        $result.Added | Should -BeFalse
        $result.Line | Should -BeExactly 'Import-Module -Name PowerStub -ErrorAction Stop'
        [System.IO.File]::ReadAllText($path) | Should -BeExactly "if (`$true) {`n    Import-Module -Name PowerStub -ErrorAction Stop`n}`n"
    }

    It 'AddPowerStubToProfile_ProfileWithSyntaxError_ThrowsAndLeavesFileUnchanged' {
        $path = New-ProfilePath
        Set-ProfileText $path "function Broken {`n"

        { Add-PowerStubToProfile -Path $path } | Should -Throw '*syntax errors*Nothing was changed*'

        [System.IO.File]::ReadAllText($path) | Should -BeExactly "function Broken {`n"
    }

    It 'AddPowerStubToProfile_TrailingLineContinuation_ThrowsAndLeavesFileUnchanged' {
        $path = New-ProfilePath
        $original = "Write-Output a ``"
        Set-ProfileText $path $original

        { Add-PowerStubToProfile -Path $path } | Should -Throw

        [System.IO.File]::ReadAllText($path) | Should -BeExactly $original
    }

    It 'AddPowerStubToProfile_Utf8BomFile_KeepsSingleBom' {
        $path = New-ProfilePath
        Set-ProfileText $path "Set-Alias ll Get-ChildItem`n" ([System.Text.UTF8Encoding]::new($true))

        Add-PowerStubToProfile -Path $path | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        $text | Should -BeExactly "Set-Alias ll Get-ChildItem`n`n# PowerStub`n$script:ImportLine`n"
    }

    It 'AddPowerStubToProfile_WhatIf_DoesNotCreateFile' {
        $path = New-ProfilePath

        Add-PowerStubToProfile -Path $path -WhatIf

        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'AddPowerStubToProfile_NewProfile_ImportsPowerStubInFreshSession' {
        $path = New-ProfilePath
        Add-PowerStubToProfile -Path $path | Out-Null
        $pwsh = (Get-Process -Id $PID).Path

        $output = & $pwsh -NoProfile -NonInteractive -Command ". '$($path.Replace("'", "''"))'; (Get-Command Invoke-PowerStubCommand).Source"

        $output | Should -Be 'PowerStub'
    }
}

Describe 'Remove-PowerStubFromProfile' {
    It 'RemovePowerStubFromProfile_AfterAdd_RestoresOriginalText' {
        $path = New-ProfilePath
        $original = "Set-Alias ll Get-ChildItem`r`n"
        Set-ProfileText $path $original
        Add-PowerStubToProfile -Path $path | Out-Null

        $result = Remove-PowerStubFromProfile -Path $path

        $result.Removed | Should -BeTrue
        $result.Lines | Should -Be @($script:ImportLine)
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $original
    }

    It 'RemovePowerStubFromProfile_HandWrittenImports_RemovesEach' {
        $path = New-ProfilePath
        Set-ProfileText $path "Import-Module PowerStub`nSet-Alias ll Get-ChildItem`nif (`$true) {`n    ipmo 'C:\Tools\PowerStub\PowerStub.psd1'`n}`n"

        $result = Remove-PowerStubFromProfile -Path $path

        $result.Lines.Count | Should -Be 2
        [System.IO.File]::ReadAllText($path) | Should -BeExactly "Set-Alias ll Get-ChildItem`nif (`$true) {`n}`n"
    }

    It 'RemovePowerStubFromProfile_ImportSharesLine_WarnsAndLeavesIt' {
        $path = New-ProfilePath
        $original = "Import-Module PowerStub; Set-Alias ll Get-ChildItem`n"
        Set-ProfileText $path $original

        $result = Remove-PowerStubFromProfile -Path $path -WarningVariable warnings -WarningAction SilentlyContinue

        $result.Removed | Should -BeFalse
        $warnings | Should -Not -BeNullOrEmpty
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $original
    }

    It 'RemovePowerStubFromProfile_NoImport_ReturnsNotRemoved' {
        $path = New-ProfilePath
        Set-ProfileText $path "Set-Alias ll Get-ChildItem`n"

        (Remove-PowerStubFromProfile -Path $path).Removed | Should -BeFalse
    }

    It 'RemovePowerStubFromProfile_MissingFile_ReturnsNotRemovedWithoutCreatingFile' {
        $path = New-ProfilePath

        (Remove-PowerStubFromProfile -Path $path).Removed | Should -BeFalse
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'RemovePowerStubFromProfile_ProfileWithSyntaxError_ThrowsAndLeavesFileUnchanged' {
        $path = New-ProfilePath
        $original = "Import-Module PowerStub`nfunction Broken {`n"
        Set-ProfileText $path $original

        { Remove-PowerStubFromProfile -Path $path } | Should -Throw '*syntax errors*Nothing was changed*'

        [System.IO.File]::ReadAllText($path) | Should -BeExactly $original
    }

    It 'RemovePowerStubFromProfile_Utf8BomFile_KeepsBom' {
        $path = New-ProfilePath
        Set-ProfileText $path "Set-Alias ll Get-ChildItem`nImport-Module PowerStub`n" ([System.Text.UTF8Encoding]::new($true))

        Remove-PowerStubFromProfile -Path $path | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -BeExactly "Set-Alias ll Get-ChildItem`n"
    }

    It 'RemovePowerStubFromProfile_WhatIf_LeavesFileUnchanged' {
        $path = New-ProfilePath
        Set-ProfileText $path "Import-Module PowerStub`n"

        Remove-PowerStubFromProfile -Path $path -WhatIf

        [System.IO.File]::ReadAllText($path) | Should -BeExactly "Import-Module PowerStub`n"
    }
}
