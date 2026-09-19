<#
.SYNOPSIS
    Calculates the next semantic version based on conventional commits.

.DESCRIPTION
    Analyzes git commits since the last tag and determines the next version:
    - BREAKING CHANGE or !: -> major bump
    - feat: -> minor bump
    - fix:, docs:, etc. -> patch bump

.PARAMETER Verbose
    Show detailed output during version calculation.

.EXAMPLE
    ./get-version.ps1
    # Returns the next version number (e.g., "2.1.0")

.EXAMPLE
    ./get-version.ps1 -Verbose
    # Returns version with detailed analysis output
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Get-LastTag {
    $tag = git describe --tags --abbrev=0 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $tag
}

function Parse-Version {
    param([string]$Tag)

    if (-not $Tag) {
        return @{ Major = 0; Minor = 0; Patch = 0 }
    }

    $version = $Tag -replace '^v', ''
    if ($version -match '^(\d+)\.(\d+)\.(\d+)') {
        return @{
            Major = [int]$Matches[1]
            Minor = [int]$Matches[2]
            Patch = [int]$Matches[3]
        }
    }

    return @{ Major = 0; Minor = 0; Patch = 0 }
}

function Get-CommitsSinceTag {
    param([string]$Tag)

    # Use %B (full body) instead of %s (subject only) to detect BREAKING CHANGE in commit body/footer.
    # Merge commits are skipped: their bodies can quote other commits' subjects and footers.
    $separator = '---COMMIT-SEPARATOR---'
    if ($Tag) {
        $raw = git log "$Tag..HEAD" --no-merges --pretty=format:"%B${separator}" 2>$null
    } else {
        $raw = git log --no-merges --pretty=format:"%B${separator}" 2>$null
    }

    if ($LASTEXITCODE -ne 0) { return @() }

    # Split on separator and return non-empty commit bodies
    $commitBodies = ($raw -join "`n") -split [regex]::Escape($separator) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return $commitBodies
}

# Main logic
Write-Verbose "Analyzing commits for version calculation..."

$lastTag = Get-LastTag
Write-Verbose "Last tag: $($lastTag ?? '(none)')"

$version = Parse-Version -Tag $lastTag
Write-Verbose "Current version: $($version.Major).$($version.Minor).$($version.Patch)"

$commits = Get-CommitsSinceTag -Tag $lastTag
$commitCount = $commits.Count
Write-Verbose "Commits since last tag: $commitCount"

if ($commitCount -eq 0) {
    Write-Verbose "No new commits, keeping version: $($version.Major).$($version.Minor).$($version.Patch)"
    return "$($version.Major).$($version.Minor).$($version.Patch)"
}

# Analyze commits
$hasBreaking = $false
$hasFeat = $false
$hasFix = $false
$breakingCount = 0
$featCount = 0
$fixCount = 0
$otherCount = 0

# Regex patterns for conventional commits
$breakingPattern = '^[a-z]+(\([^)]+\))?!:'
# A footer starts its own line; this avoids matching the phrase inside prose
$breakingChangePattern = '(?m)^BREAKING[ -]CHANGE:'
$featPattern = '^feat(\([^)]+\))?:'
$fixPattern = '^fix(\([^)]+\))?:'
$otherPattern = '^(docs|style|refactor|perf|test|build|ci|chore)(\([^)]+\))?:'

foreach ($commit in $commits) {
    if (-not $commit) { continue }

    # Check for breaking changes (type!: or BREAKING CHANGE:)
    if ($commit -match $breakingPattern -or $commit -match $breakingChangePattern) {
        $hasBreaking = $true
        $breakingCount++
        Write-Verbose "BREAKING: $commit"
    }
    # Check for features
    elseif ($commit -match $featPattern) {
        $hasFeat = $true
        $featCount++
        Write-Verbose "FEAT: $commit"
    }
    # Check for fixes
    elseif ($commit -match $fixPattern) {
        $hasFix = $true
        $fixCount++
        Write-Verbose "FIX: $commit"
    }
    # Other conventional commits
    elseif ($commit -match $otherPattern) {
        $otherCount++
        Write-Verbose "OTHER: $commit"
    }
    else {
        Write-Verbose "SKIP: $commit"
    }
}

# Calculate next version
if ($hasBreaking) {
    $version.Major++
    $version.Minor = 0
    $version.Patch = 0
    Write-Verbose "Bump: MAJOR (breaking change)"
}
elseif ($hasFeat) {
    $version.Minor++
    $version.Patch = 0
    Write-Verbose "Bump: MINOR (new feature)"
}
elseif ($hasFix -or $otherCount -gt 0) {
    $version.Patch++
    Write-Verbose "Bump: PATCH (fix or maintenance)"
}
else {
    $version.Patch++
    Write-Verbose "Bump: PATCH (default)"
}

Write-Verbose "Summary:"
Write-Verbose "  Breaking changes: $breakingCount"
Write-Verbose "  Features: $featCount"
Write-Verbose "  Fixes: $fixCount"
Write-Verbose "  Other: $otherCount"
Write-Verbose "Next version: $($version.Major).$($version.Minor).$($version.Patch)"

return "$($version.Major).$($version.Minor).$($version.Patch)"
