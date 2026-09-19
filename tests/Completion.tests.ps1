#Requires -Modules Pester
<#
.SYNOPSIS
    Tab completion for pstb, Invoke-PowerStubCommand and direct aliases.

.DESCRIPTION
    Invoke-PowerStubCommand declares no parameters (so that nothing meant for the target is
    bound to pstb), which means PowerShell cannot complete it by itself. The module supplies
    completion by wrapping TabExpansion2. These tests call TabExpansion2, as every host does.

    Covers:
    - stub names, virtual verbs and command names
    - the target's own parameters, including a partly typed name, and their values
    - the -Stub/-Command named form, direct aliases and pstb in the middle of a line
    - both TabExpansion2 call forms (text and AST)
    - other commands are unaffected, and removing the module restores the original

.NOTES
    Run with: Invoke-Pester ./tests/Completion.tests.ps1
#>

BeforeAll {
    $existing = Get-Module -Name 'PowerStub'
    if ($existing) {
        Remove-Module -ModuleInfo $existing -Force
    }

    # Point the module at a throwaway config dir so the tests never touch the real config
    $script:TestConfigDir = Join-Path ([System.IO.Path]::GetTempPath()) "PSTBTestConfig_$([guid]::NewGuid())"
    $env:POWERSTUB_CONFIG_DIR = $script:TestConfigDir

    $script:ModulePath = Join-Path $PSScriptRoot '..\PowerStub\PowerStub.psm1'
    Import-Module $script:ModulePath -Force

    New-PowerStub -Name 'SampleStub' -Path (Join-Path $PSScriptRoot 'sample_stub_root') -Force
    New-PowerStub -Name 'MatrixStub' -Path (Join-Path $PSScriptRoot 'parsing_stub_root') -Force
    New-PowerStubDirectAlias -AliasName 'pstbcmpl' -Stub 'MatrixStub' -Force | Out-Null

    function Get-CompletionText {
        param([string]$Line)
        @((TabExpansion2 -inputScript $Line -cursorColumn $Line.Length).CompletionMatches.CompletionText)
    }
}

AfterAll {
    Remove-Module -Name 'PowerStub' -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\POWERSTUB_CONFIG_DIR -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $script:TestConfigDir) {
        Remove-Item -LiteralPath $script:TestConfigDir -Recurse -Force
    }
}

Describe "Stub and command completion" {
    It "Completion_EmptyStubPosition_OffersVirtualVerbsAndStubs" {
        $texts = Get-CompletionText 'pstb '

        $texts | Should -Contain 'SampleStub'
        $texts | Should -Contain 'MatrixStub'
        $texts | Should -Contain 'search'
        $texts | Should -Contain 'help'
        $texts | Should -Contain 'update'
    }

    It "Completion_PartialStubName_OffersMatchingStubOnly" {
        Get-CompletionText 'pstb Sam' | Should -Be @('SampleStub')
    }

    It "Completion_EmptyCommandPosition_OffersStubCommands" {
        $texts = Get-CompletionText 'pstb SampleStub '

        $texts | Should -Contain 'deploy'
        $texts | Should -Contain 'arg-echo'
    }

    It "Completion_PartialCommandName_OffersMatchingCommand" {
        Get-CompletionText 'pstb SampleStub dep' | Should -Contain 'deploy'
    }

    It "Completion_CommandNames_DoNotShowAlphaOrBetaPrefix" {
        Enable-PowerStubAlphaCommands
        Enable-PowerStubBetaCommands
        try {
            $texts = Get-CompletionText 'pstb SampleStub '

            $texts | Should -Contain 'new-feature'
            $texts | Where-Object { $_ -match '^(alpha|beta)\.' } | Should -BeNullOrEmpty
        }
        finally {
            Disable-PowerStubAlphaCommands
            Disable-PowerStubBetaCommands
        }
    }

    It "Completion_ReplacementRange_CoversOnlyTheWordBeingTyped" {
        $line = 'pstb SampleStub dep'
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length

        $result.ReplacementIndex | Should -Be 16
        $result.ReplacementLength | Should -Be 3
    }
}

Describe "Virtual verb completion" {
    It "Completion_AfterHelp_OffersStubNames" {
        Get-CompletionText 'pstb help ' | Should -Contain 'SampleStub'
    }

    It "Completion_AfterHelpAndStub_OffersThatStubsCommands" {
        Get-CompletionText 'pstb help SampleStub dep' | Should -Contain 'deploy'
    }

    It "Completion_AfterUpdate_OffersStubNames" {
        Get-CompletionText 'pstb update ' | Should -Contain 'SampleStub'
    }
}

Describe "Target parameter completion" {
    It "Completion_BareDash_OffersAllTargetParameters" {
        $texts = Get-CompletionText 'pstb SampleStub deploy -'

        $texts | Should -Contain '-Environment'
        $texts | Should -Contain '-Version'
    }

    It "Completion_PartlyTypedParameterName_CompletesIt" {
        Get-CompletionText 'pstb MatrixStub echo-params -Na' | Should -Be @('-Name')
    }

    It "Completion_AfterOtherParameters_StillCompletes" {
        Get-CompletionText 'pstb MatrixStub echo-params -Name x -Fo' | Should -Be @('-Force')
    }

    It "Completion_DoesNotOfferPstbsOwnOrCommonParameters" {
        $texts = Get-CompletionText 'pstb SampleStub deploy -'

        $texts | Should -Not -Contain '-Stub'
        $texts | Should -Not -Contain '-Command'
        $texts | Should -Not -Contain '-Verbose'
    }

    It "Completion_ValidateSetValue_OffersTheAllowedValues" {
        $texts = Get-CompletionText 'pstb MatrixStub echo-params -Environment '

        $texts | Should -Contain 'dev'
        $texts | Should -Contain 'test'
        $texts | Should -Contain 'prod'
    }

    It "Completion_PartlyTypedValue_OffersMatchingValue" {
        Get-CompletionText 'pstb MatrixStub echo-params -Environment pr' | Should -Be @('prod')
    }

    It "Completion_ReplacementRange_IsRelativeToTheOriginalLine" {
        $line = 'pstb MatrixStub echo-params -Na'
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length

        $result.ReplacementIndex | Should -Be 28
        $result.ReplacementLength | Should -Be 3
    }
}

Describe "Other ways of calling" {
    It "Completion_NamedStubAndCommand_CompletesTargetParameters" {
        Get-CompletionText 'Invoke-PowerStubCommand -Stub SampleStub -Command deploy -Env' | Should -Be @('-Environment')
    }

    It "Completion_NamedStubValue_OffersStubNames" {
        Get-CompletionText 'Invoke-PowerStubCommand -Stub Sam' | Should -Be @('SampleStub')
    }

    It "Completion_DirectAlias_OffersCommands" {
        Get-CompletionText 'pstbcmpl ' | Should -Contain 'echo-params'
    }

    It "Completion_DirectAlias_CompletesTargetParameters" {
        Get-CompletionText 'pstbcmpl echo-params -Cou' | Should -Be @('-Count')
    }

    It "Completion_PstbAfterAnotherStatement_StillCompletes" {
        Get-CompletionText 'Write-Output 1; pstb MatrixStub echo-params -Cou' | Should -Be @('-Count')
    }

    It "Completion_AstCallForm_Works" {
        $line = 'pstb MatrixStub echo-params -Na'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
        $cursor = $tokens[-2].Extent.EndScriptPosition

        $result = TabExpansion2 -ast $ast -tokens $tokens -positionOfCursor $cursor

        $result.CompletionMatches.CompletionText | Should -Contain '-Name'
    }

    It "Completion_CursorReportedPastTheEndOfTheText_StillCompletes" {
        $line = 'pstb MatrixStub echo-params -Na'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$parseErrors)
        # The end-of-input token is one past the last character
        $cursor = $tokens[-1].Extent.StartScriptPosition

        $result = TabExpansion2 -ast $ast -tokens $tokens -positionOfCursor $cursor

        $result.CompletionMatches.CompletionText | Should -Contain '-Name'
    }
}

Describe "Completion safety" {
    It "Completion_OtherCommands_AreUnaffected" {
        $texts = Get-CompletionText 'Get-ChildItem -Fil'

        $texts | Should -Contain '-Filter'
        $texts | Should -Contain '-File'
    }

    It "Completion_NestedCommandInsidePstbLine_UsesNormalCompletion" {
        Get-CompletionText 'pstb MatrixStub echo-params -Name (Get-ChildI' | Should -Contain 'Get-ChildItem'
    }

    It "Completion_UnknownStubOrCommand_DoesNotThrow" {
        { Get-CompletionText 'pstb NoSuchStub nothing -x' } | Should -Not -Throw
        { Get-CompletionText 'pstb SampleStub no-such-command -x' } | Should -Not -Throw
    }

    It "Completion_RemovingTheModule_RestoresTheOriginalTabExpansion2" {
        (Get-Command TabExpansion2).ScriptBlock.Module.Name | Should -Be 'PowerStub'

        Remove-Module -Name 'PowerStub' -Force
        try {
            (Get-Command TabExpansion2).ScriptBlock.Module | Should -BeNullOrEmpty
            Get-CompletionText 'Get-ChildItem -Fil' | Should -Contain '-Filter'
        }
        finally {
            Import-Module $script:ModulePath -Force
        }
    }
}
