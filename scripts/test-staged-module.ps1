<#
.SYNOPSIS
    Exercises a staged package in a clean pwsh process; never publishes or touches user config.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ModulePath,
    [Parameter(Mandatory)] [string]$ExpectedVersion
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('powerstub-package-smoke-' + [guid]::NewGuid())
$originalConfig = $env:POWERSTUB_CONFIG_DIR
$env:POWERSTUB_CONFIG_DIR = Join-Path $root 'config'
$manifestPath = Join-Path $ModulePath 'PowerStub.psd1'
function Assert-Package([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($file in @('PowerStub.psd1', 'PowerStub.psm1', 'LICENSE.txt', 'README.md', 'Templates/command_template.ps1')) {
        Assert-Package (Test-Path -LiteralPath (Join-Path $ModulePath $file) -PathType Leaf) "Missing package file: $file"
    }
    Assert-Package (@(Get-ChildItem -LiteralPath $ModulePath -Recurse -Force -Filter '*.pssproj').Count -eq 0) 'Development project files shipped.'
    Assert-Package (-not (Test-Path -LiteralPath (Join-Path $ModulePath '.gitignore'))) 'Development ignore file shipped.'
    Assert-Package (-not (Test-Path -LiteralPath (Join-Path $ModulePath 'PowerStub.json'))) 'A legacy user configuration shipped.'
    $manifestData = Import-PowerShellDataFile -LiteralPath $manifestPath
    Assert-Package ($manifestData.ModuleVersion -eq $ExpectedVersion) 'Incorrect package version.'
    Assert-Package ($manifestData.PrivateData.PSData.LicenseUri -eq "https://github.com/DevPossible/PowerStub/blob/v$ExpectedVersion/LICENSE.txt") 'License link is not release-stable.'
    Assert-Package ($manifestData.PrivateData.PSData.ProjectUri -eq 'https://github.com/DevPossible/PowerStub') 'Project link does not use the canonical repository.'
    Assert-Package ($manifestData.PrivateData.PSData.ReleaseNotes -eq 'See https://github.com/DevPossible/PowerStub/releases') 'Release notes link does not use the canonical repository.'
    Import-Module $manifestPath -Force
    foreach ($name in $manifestData.FunctionsToExport) {
        Assert-Package ($null -ne (Get-Command $name -Module PowerStub -ErrorAction SilentlyContinue)) "Missing manifest export: $name"
    }
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ModulePath 'public/functions') -Filter '*.ps1') {
        Assert-Package ($file.BaseName -in $manifestData.FunctionsToExport) "Public function missing from manifest: $($file.BaseName)"
    }
    Assert-Package ($null -eq (Get-Command Set-PowerStubConfigurationKey -ErrorAction SilentlyContinue)) 'A private helper leaked into public exports.'
    Assert-Package ((Get-Alias pstb).Definition -eq 'Invoke-PowerStubCommand') 'Default alias was not exported.'
    Assert-Package ((Get-Help New-PowerStub).Synopsis -match 'Registers') 'Installed command help is missing.'

    $stub = Join-Path $root 'tools'
    New-PowerStub -Name PackageSmoke -Path $stub
    @'
<#
.SYNOPSIS
    Package smoke command.
#>
param([string]$Environment, [string]$c)
"$Environment|$c"
'@ | Set-Content -LiteralPath (Join-Path $stub 'Commands/echo.ps1')
    Assert-Package ((pstb PackageSmoke echo -Environment prod -c Release) -eq 'prod|Release') 'Target flags did not reach the packaged script.'
    'exit 7' | Set-Content -LiteralPath (Join-Path $stub 'Commands/fail.ps1')
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    pstb PackageSmoke fail 2>$null
    $scriptSucceeded = $?
    $ErrorActionPreference = $savedErrorAction
    Assert-Package (-not $scriptSucceeded) 'Packaged script failure was reported as success.'

    # Copy a real native shell under the supported .exe extension; no compiler/network needed.
    $nativeSource = if ($IsWindows) { $env:ComSpec } else { (Get-Command sh -CommandType Application).Source }
    Copy-Item -LiteralPath $nativeSource -Destination (Join-Path $stub 'Commands/native.exe')
    $nativeArgs = if ($IsWindows) { @('/d', '/c', 'echo package-native') } else { @('-c', 'printf package-native') }
    $nativeOutput = pstb PackageSmoke native @nativeArgs
    Assert-Package (($nativeOutput | Out-String).Trim() -eq 'package-native') 'Packaged native flags/output failed.'
    $nativeArgs = if ($IsWindows) { @('/d', '/c', 'exit 7') } else { @('-c', 'exit 7') }
    $ErrorActionPreference = 'Continue'
    pstb PackageSmoke native @nativeArgs 2>$null
    $nativeSucceeded = $?
    $nativeExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorAction
    Assert-Package (-not $nativeSucceeded -and $nativeExitCode -eq 7) 'Packaged native failure/exit status failed.'

    New-PowerStubDirectAlias -AliasName pstdoc -Stub PackageSmoke
    Assert-Package ((pstdoc echo -Environment prod -c Release) -eq 'prod|Release') 'Packaged direct alias failed.'
    $line = 'pstb PackageSmoke echo -En'
    $completion = TabExpansion2 $line $line.Length
    Assert-Package ('-Environment' -in @($completion.CompletionMatches.CompletionText)) 'Installed target completion failed.'
    Assert-Package ((Get-PowerStubCommand -Stub PackageSmoke -Command echo).Path -eq (Join-Path $stub 'Commands/echo.ps1')) 'Installed command discovery failed.'
    Assert-Package (Test-Path -LiteralPath (Get-PowerStubConfiguration -Key ConfigFile)) 'Configuration was not saved.'

    Remove-Module PowerStub
    Import-Module $manifestPath -Force
    Assert-Package ((Get-PowerStubs).ContainsKey('PackageSmoke')) 'Registration did not survive reimport.'
    Assert-Package ((pstdoc echo -Environment restored -c Release) -eq 'restored|Release') 'Direct alias did not survive reimport.'
    Remove-PowerStubDirectAlias -AliasName pstdoc
    Assert-Package ($null -eq (Get-Command pstdoc -ErrorAction SilentlyContinue)) 'Direct alias cleanup failed.'
    Write-Host "Package smoke passed: PowerStub $ExpectedVersion on $($PSVersionTable.OS), PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    Remove-Module PowerStub -Force -ErrorAction SilentlyContinue
    $env:POWERSTUB_CONFIG_DIR = $originalConfig
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
