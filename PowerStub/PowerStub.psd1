@{
    RootModule        = 'PowerStub.psm1'
    # Development baseline, not necessarily the latest published version. CI stamps
    # only the staged package using git tags and commit messages (scripts/get-version.ps1).
    ModuleVersion     = '1.1.0'
    GUID              = '9b623f79-6872-4f0a-9029-37d9c95e3d9a'
    Author            = 'DevPossible LLC'
    CompanyName       = 'DevPossible LLC'
    Copyright         = '(c) 2024 DevPossible LLC. All rights reserved.'
    Description       = 'System for organizing PowerShell scripts or other tools using a stub function.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Disable-PowerStubAlphaCommands',
        'Disable-PowerStubBetaCommands',
        'Enable-PowerStubAlphaCommands',
        'Enable-PowerStubBetaCommands',
        'Get-PowerStubCommand',
        'Get-PowerStubCommandHelp',
        'Get-PowerStubConfiguration',
        'Get-PowerStubs',
        'Import-PowerStubConfiguration',
        'Invoke-PowerStubCommand',
        'New-PowerStub',
        'New-PowerStubDirectAlias',
        'Remove-PowerStub',
        'Remove-PowerStubDirectAlias',
        'Search-PowerStubCommands',
        'Set-PowerStubCommandVisibility'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    # The loader explicitly exports only the validated configured invocation alias.
    # A fixed 'pstb' allowlist would hide custom aliases on manifest imports.
    AliasesToExport    = @('*')

    PrivateData = @{
        PSData = @{
            Tags         = @('PowerShell', 'CLI', 'Stub', 'Proxy', 'Commands', 'Tools', 'Organizer')
            LicenseUri   = 'https://github.com/DevPossible/PowerStub/blob/main/LICENSE.txt'
            ProjectUri   = 'https://github.com/DevPossible/PowerStub'
            ReleaseNotes = 'See https://github.com/DevPossible/PowerStub/releases'
        }
    }
}
