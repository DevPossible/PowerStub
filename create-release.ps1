<#
.SYNOPSIS
    Merges develop to main and pushes to all remotes.

.DESCRIPTION
    This script automates the release process:
    1. Verifies working directory is clean
    2. Pulls latest changes from develop
    3. Switches to main and pulls latest
    4. Merges develop into main (fast-forward when possible)
    5. Pushes main to all configured remotes
    6. Returns to the develop branch

    Tests are run by the CI/CD pipeline after push.

.PARAMETER DryRun
    Show what would happen without actually doing it.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\create-release.ps1
    # Interactive release with confirmation

.EXAMPLE
    .\create-release.ps1 -DryRun
    # Show what would happen without making changes

.EXAMPLE
    .\create-release.ps1 -Force
    # Non-interactive release
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Colors for output
function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "   $Message" -ForegroundColor Gray }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

# Check prerequisites
Write-Step "Checking prerequisites..."

# Verify git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Git is not installed or not in PATH"
}
Write-Success "Git is available"

# Verify we're in a git repository
$repoRoot = git rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not in a git repository"
}
Write-Success "Repository root: $repoRoot"

# Check for uncommitted changes
$status = git status --porcelain
if ($status) {
    Write-Host "`nUncommitted changes detected:" -ForegroundColor Red
    $status | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
    if ($DryRun) {
        Write-Warn "Continuing in dry-run mode despite uncommitted changes"
    }
    else {
        throw "Working directory is not clean. Commit or stash changes first."
    }
}
else {
    Write-Success "Working directory is clean"
}

# Get current branch
$currentBranch = git branch --show-current
Write-Info "Current branch: $currentBranch"

# Fetch all remotes
Write-Step "Fetching from all remotes..."
if (-not $DryRun) {
    git fetch --all --prune
    if ($LASTEXITCODE -ne 0) { throw "Failed to fetch from remotes" }
}
else {
    Write-Info "[DryRun] Would fetch from all remotes"
}
Write-Success "Fetched latest from all remotes"

# Ensure we're on develop
Write-Step "Switching to develop branch..."
if ($currentBranch -ne 'develop') {
    if (-not $DryRun) {
        git checkout develop
        if ($LASTEXITCODE -ne 0) { throw "Failed to checkout develop branch" }
    }
    else {
        Write-Info "[DryRun] Would checkout develop"
    }
}
Write-Success "On develop branch"

# Pull latest develop
Write-Step "Pulling latest develop..."
if (-not $DryRun) {
    git pull origin develop
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull develop from origin" }
}
else {
    Write-Info "[DryRun] Would pull origin develop"
}
Write-Success "Develop is up to date"

# Show commits to be merged
Write-Step "Commits to be merged into main..."
$commits = git log main..develop --oneline
if (-not $commits) {
    Write-Warn "No new commits to merge. Main is already up to date with develop."
    Write-Host "`nNothing to do." -ForegroundColor Yellow
    exit 0
}
$commits | ForEach-Object { Write-Info $_ }

# Calculate version
Write-Step "Calculating version from commits..."
$versionScript = Join-Path $PSScriptRoot "scripts\get-version.ps1"
if (Test-Path $versionScript) {
    $nextVersion = & $versionScript
    Write-Success "Next version will be: v$nextVersion"
}
else {
    Write-Warn "Version script not found, skipping version calculation"
}

# Confirmation
if (-not $Force -and -not $DryRun) {
    Write-Host "`n" -NoNewline
    $confirm = Read-Host "Proceed with merge and push? (y/N)"
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# Switch to main
Write-Step "Switching to main branch..."
if (-not $DryRun) {
    git checkout main
    if ($LASTEXITCODE -ne 0) { throw "Failed to checkout main branch" }
}
else {
    Write-Info "[DryRun] Would checkout main"
}
Write-Success "On main branch"

# Pull latest main
Write-Step "Pulling latest main..."
if (-not $DryRun) {
    git pull origin main
    if ($LASTEXITCODE -ne 0) { throw "Failed to pull main from origin" }
}
else {
    Write-Info "[DryRun] Would pull origin main"
}
Write-Success "Main is up to date"

# Merge develop into main
Write-Step "Merging develop into main..."
if (-not $DryRun) {
    git merge develop --no-edit
    if ($LASTEXITCODE -ne 0) { throw "Merge failed. Resolve conflicts and try again." }
}
else {
    Write-Info "[DryRun] Would merge develop into main"
}
Write-Success "Merge completed"

# Push to all remotes
Write-Step "Pushing main to all remotes..."
$remotes = git remote
foreach ($remote in $remotes) {
    Write-Info "Pushing to $remote..."
    if (-not $DryRun) {
        git push $remote main
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Failed to push to $remote, continuing..."
        }
        else {
            Write-Success "Pushed to $remote"
        }
    }
    else {
        Write-Info "[DryRun] Would push main to $remote"
    }
}

# Return to develop
Write-Step "Returning to develop branch..."
if (-not $DryRun) {
    git checkout develop
    if ($LASTEXITCODE -ne 0) { throw "Failed to checkout develop branch" }
}
else {
    Write-Info "[DryRun] Would checkout develop"
}
Write-Success "Back on develop branch"

# Summary
Write-Host "`n" -NoNewline
Write-Host "========================================" -ForegroundColor Green
Write-Host " Release completed successfully!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
if ($nextVersion) {
    Write-Host "Version: v$nextVersion" -ForegroundColor Cyan
}
Write-Host "Main branch has been updated and pushed to all remotes."
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  - CI/CD pipeline will handle PSGallery publish and GitHub release"
Write-Host "  - Monitor pipeline at: https://gitlab.devpossible.com/devpossible/opensource/power-stub/-/pipelines"
Write-Host ""
