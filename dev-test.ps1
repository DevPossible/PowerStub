<#
.SYNOPSIS
    Runs the PowerStub test suite using Pester.

.DESCRIPTION
    This script runs all Pester tests for the PowerStub module. It automatically
    reloads the module before running tests to ensure the latest code is tested.

.PARAMETER Filter
    Run only tests matching this filter pattern (passed to Pester's -FullNameFilter).

.PARAMETER Tag
    Run only tests with these tags.

.PARAMETER Output
    Pester output verbosity: None, Normal, Detailed, Diagnostic. Default: Detailed.

.PARAMETER PassThru
    Returns the Pester result object for programmatic inspection.

.PARAMETER SkipReload
    Skip reloading the module before running tests.

.EXAMPLE
    .\dev-test.ps1
    # Runs all tests with detailed output

.EXAMPLE
    .\dev-test.ps1 -Filter "*Alpha*"
    # Runs only tests with "Alpha" in the name

.EXAMPLE
    .\dev-test.ps1 -Tag ParsingMatrix
    # Runs the tests for known, unfixed bugs (expected to fail; excluded by default)

.EXAMPLE
    .\dev-test.ps1 -Output Normal
    # Runs tests with minimal output

.EXAMPLE
    .\dev-test.ps1 -SkipReload
    # Runs tests without reloading the module first
#>
param(
    [string]$Filter,
    [string[]]$Tag,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Detailed',
    [switch]$PassThru,
    [switch]$SkipReload
)

$ErrorActionPreference = 'Stop'

# Check for Pester
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Error "Pester is not installed. Install it with: Install-Module Pester -Force -SkipPublisherCheck"
    return
}

if ($pester.Version.Major -lt 5) {
    Write-Warning "Pester version $($pester.Version) detected. Tests require Pester 5.x or later."
    Write-Warning "Update with: Install-Module Pester -Force -SkipPublisherCheck"
}

# Reload module unless skipped
if (-not $SkipReload) {
    Write-Host "Reloading module before tests..." -ForegroundColor Cyan
    & "$PSScriptRoot\dev-reload.ps1"
    Write-Host ""
}

# Build Pester configuration
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'tests'
$config.Output.Verbosity = $Output

if ($Filter) {
    $config.Filter.FullName = $Filter
}

if ($Tag) {
    $config.Filter.Tag = $Tag
}
else {
    # The parsing matrix still includes known argument differences.
    # Run it explicitly with: .\dev-test.ps1 -Tag ParsingMatrix
    $config.Filter.ExcludeTag = 'ParsingMatrix'
}

# Always enable PassThru so $result is populated for exit code checking
$config.Run.PassThru = $true

# Run tests
Write-Host "Running Pester tests..." -ForegroundColor Cyan
Write-Host "  Test path: $($config.Run.Path.Value)" -ForegroundColor Gray
if ($Filter) {
    Write-Host "  Filter: $Filter" -ForegroundColor Gray
}
Write-Host ""

$result = Invoke-Pester -Configuration $config

# Return result if PassThru
if ($PassThru) {
    return $result
}

# Exit with appropriate code for CI
if ($result.FailedCount -gt 0) {
    exit 1
}
