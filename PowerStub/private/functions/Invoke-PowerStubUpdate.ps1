<#
.SYNOPSIS
    Handles the 'pstb update' virtual verb for updating git repositories.

.DESCRIPTION
    Updates git repositories for registered stubs. Supports updating all stubs
    or a specific stub, with an optional --check flag for status-only mode.

.PARAMETER Command
    The command argument (may contain a stub name).

.PARAMETER RemainingArgs
    Additional arguments (may contain --check flag or stub name).

.OUTPUTS
    None. Writes status information to the host.
#>

function Invoke-PowerStubUpdate {
    [CmdletBinding()]
    param(
        [string]$Command,
        [object[]]$RemainingArgs
    )

    if (-not $Script:GitEnabled) {
        throw "Git integration is disabled. Set GitEnabled to true in the file returned by Get-PowerStubConfiguration -Key ConfigFile, then reload PowerStub."
    }
    if (-not $Script:GitAvailable) {
        throw "Git is not available on this system."
    }

    # Parse arguments for --check flag and stub name
    $checkOnly = $false
    $targetStub = $null
    $allArgs = @()
    if ($Command) { $allArgs += $Command }
    if ($RemainingArgs) { $allArgs += $RemainingArgs }

    foreach ($arg in $allArgs) {
        if ($arg -eq '--check' -or $arg -eq '-Check') {
            $checkOnly = $true
        }
        elseif (-not $arg.StartsWith('-')) {
            $targetStub = $arg
        }
    }

    $stubs = Get-PowerStubConfigurationKey 'Stubs'
    $processedRepos = @{}
    $showStatus = {
        param($StubName, $GitInfo)
        if ($GitInfo.Status -ne 'Ready') {
            Write-Host "Stub '$StubName': $($GitInfo.StatusMessage)." -ForegroundColor Yellow
        }
        elseif ($GitInfo.BehindCount -gt 0 -and $GitInfo.AheadCount -gt 0) {
            Write-Host "Stub '$StubName' has diverged: $($GitInfo.BehindCount) commit(s) behind and $($GitInfo.AheadCount) commit(s) ahead." -ForegroundColor Yellow
        }
        elseif ($GitInfo.BehindCount -gt 0) {
            Write-Host "Stub '$StubName' is $($GitInfo.BehindCount) commit(s) behind." -ForegroundColor Yellow
        }
        elseif ($GitInfo.AheadCount -gt 0) {
            Write-Host "Stub '$StubName' is $($GitInfo.AheadCount) commit(s) ahead." -ForegroundColor Cyan
        }
        else {
            Write-Host "Stub '$StubName' is up to date." -ForegroundColor Green
        }
    }

    if ($targetStub) {
        # Process specific stub
        if (-not ($stubs.Keys -contains $targetStub)) {
            throw "Stub '$targetStub' not found."
        }
        $stubConfig = $stubs[$targetStub]
        $stubPath = Get-PowerStubPath -StubConfig $stubConfig
        $gitInfo = Get-PowerStubGitInfo -Path $stubPath -Fetch:$checkOnly
        if (-not $gitInfo.IsRepo) {
            throw "Stub '$targetStub' is not in a Git repository."
        }

        if ($checkOnly) {
            & $showStatus $targetStub $gitInfo
        }
        else {
            Write-Host "Updating stub '$targetStub'..." -ForegroundColor Cyan
            $result = Update-PowerStubGitRepo -Path $stubPath
            if ($result.Success) {
                Clear-PowerStubUpdateCheckState -RepoRoot $result.Path
                Write-Host "  $($result.Message)" -ForegroundColor Green
            }
            else {
                Write-Host "  $($result.Message)" -ForegroundColor Red
            }
        }
    }
    else {
        # Process all stubs
        $behindCount = 0
        $aheadCount = 0
        $uncheckedCount = 0
        $updatedCount = 0
        $failedCount = 0
        foreach ($stubName in $stubs.Keys) {
            $stubConfig = $stubs[$stubName]
            $stubPath = Get-PowerStubPath -StubConfig $stubConfig
            $gitInfo = Get-PowerStubGitInfo -Path $stubPath -Fetch:$checkOnly
            if ($gitInfo.IsRepo -and $gitInfo.RepoRoot -and -not $processedRepos.ContainsKey($gitInfo.RepoRoot)) {
                if ($checkOnly) {
                    & $showStatus $stubName $gitInfo
                    if ($gitInfo.Status -ne 'Ready') {
                        $uncheckedCount++
                    }
                    else {
                        if ($gitInfo.BehindCount -gt 0) { $behindCount++ }
                        if ($gitInfo.AheadCount -gt 0) { $aheadCount++ }
                    }
                }
                else {
                    Write-Host "Updating stub '$stubName' ($($gitInfo.RepoRoot))..." -ForegroundColor Cyan
                    $result = Update-PowerStubGitRepo -Path $stubPath
                    if ($result.Success) {
                        Clear-PowerStubUpdateCheckState -RepoRoot $result.Path
                        $updatedCount++
                        Write-Host "  $($result.Message)" -ForegroundColor Green
                    }
                    else {
                        $failedCount++
                        Write-Host "  $($result.Message)" -ForegroundColor Red
                    }
                }
                $processedRepos[$gitInfo.RepoRoot] = $true
            }
        }
        if ($processedRepos.Count -eq 0) {
            Write-Host "No stubs with Git repositories found." -ForegroundColor Yellow
        }
        elseif ($checkOnly) {
            if ($behindCount -gt 0) {
                Write-Host "`n$behindCount stub(s) have updates available. Run 'pstb update' to pull changes." -ForegroundColor Yellow
            }
            if ($aheadCount -gt 0) {
                Write-Host "`n$aheadCount repository(ies) have local commits ahead of their tracking branch." -ForegroundColor Cyan
            }
            if ($uncheckedCount -gt 0) {
                Write-Host "`n$uncheckedCount repository(ies) could not be checked." -ForegroundColor Yellow
            }
            if ($behindCount -eq 0 -and $aheadCount -eq 0 -and $uncheckedCount -eq 0) {
                Write-Host "`nAll $($processedRepos.Count) stub(s) are up to date." -ForegroundColor Green
            }
        }
        else {
            Write-Host "`nUpdated $updatedCount repository(ies)." -ForegroundColor Cyan
            if ($failedCount -gt 0) {
                Write-Host "$failedCount repository(ies) failed to update." -ForegroundColor Red
            }
        }
    }
}
