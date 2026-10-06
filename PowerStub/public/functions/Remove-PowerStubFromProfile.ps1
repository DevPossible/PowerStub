<#
.SYNOPSIS
    Removes the lines that import PowerStub from a PowerShell profile.

.DESCRIPTION
    Undoes Add-PowerStubToProfile, and also removes imports added by hand, such as
    'Import-Module PowerStub' or an import of a PowerStub.psd1 path. The '# PowerStub'
    comment that Add-PowerStubToProfile writes above its line is removed with it.

    Only a statement that is the whole of its line(s) is removed. An import sharing a
    line with other code is left alone and reported with a warning. The profile must
    parse cleanly before and after the change, otherwise nothing is written. The file
    keeps its encoding, and a symbolic link to a dotfiles profile is written through.

    This does not unload PowerStub from the current session.

.PARAMETER Path
    The profile file to change. Defaults to $PROFILE.CurrentUserAllHosts, the profile
    Add-PowerStubToProfile writes. Pass $PROFILE for the current host's profile.

.EXAMPLE
    Remove-PowerStubFromProfile

    Removes the PowerStub import from the current user's all-hosts profile.

.EXAMPLE
    Remove-PowerStubFromProfile -Path $PROFILE -WhatIf

    Shows what would be removed from the current host's profile without changing it.

.OUTPUTS
    PSCustomObject with Path, Lines (the import statements removed) and Removed.
#>

function Remove-PowerStubFromProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path = $PROFILE.CurrentUserAllHosts
    )

    if (-not $Path) {
        throw 'This session has no $PROFILE path. Pass the profile file with -Path.'
    }
    $Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)

    $profileInfo = Read-PowerStubProfile -Path $Path
    if ($profileInfo.Errors) {
        $first = $profileInfo.Errors[0]
        throw "Profile '$Path' has syntax errors (line $($first.Extent.StartLineNumber): $($first.Message)). Fix them, then run Remove-PowerStubFromProfile again. Nothing was changed."
    }

    $text = $profileInfo.Text
    $ranges = [System.Collections.Generic.List[object]]::new()
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($import in $profileInfo.Imports) {
        # Remove the whole statement, so only a pipeline made of just this command qualifies
        $statement = $import.Parent
        if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or $statement.PipelineElements.Count -ne 1) {
            Write-Warning "Profile '$Path' line $($import.Extent.StartLineNumber): '$($import.Extent.Text)' is part of a larger statement. Remove it by hand."
            continue
        }

        $statementStart = $statement.Extent.StartOffset
        $statementEnd = $statement.Extent.EndOffset
        $start = if ($statementStart -eq 0) { 0 } else { $text.LastIndexOf("`n", $statementStart - 1) + 1 }
        $end = $text.IndexOf("`n", $statementEnd)
        $end = if ($end -lt 0) { $text.Length } else { $end + 1 }
        if ($text.Substring($start, $statementStart - $start).Trim() -or $text.Substring($statementEnd, $end - $statementEnd).Trim()) {
            Write-Warning "Profile '$Path' line $($import.Extent.StartLineNumber): '$($import.Extent.Text)' shares its line with other code. Remove it by hand."
            continue
        }

        # Also take the '# PowerStub' marker above it, and the blank line Add-PowerStubToProfile put above that
        $previousLineStart = { param($lineStart) if ($lineStart -le 1) { 0 } else { $text.LastIndexOf("`n", $lineStart - 2) + 1 } }
        if ($start -gt 0) {
            $markerStart = & $previousLineStart $start
            if ($text.Substring($markerStart, $start - $markerStart).Trim() -eq '# PowerStub') {
                $start = $markerStart
                if ($start -gt 0) {
                    $blankStart = & $previousLineStart $start
                    if (-not $text.Substring($blankStart, $start - $blankStart).Trim()) {
                        $start = $blankStart
                    }
                }
            }
        }

        $ranges.Add([PSCustomObject]@{ Start = $start; End = $end })
        $lines.Add($statement.Extent.Text)
    }

    if ($ranges.Count -eq 0) {
        Write-Verbose "Profile '$Path' has no PowerStub import to remove"
        return [PSCustomObject]@{ Path = $Path; Lines = @(); Removed = $false }
    }

    $newText = $text
    foreach ($range in ($ranges | Sort-Object Start -Descending)) {
        $newText = $newText.Remove($range.Start, $range.End - $range.Start)
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($newText, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        throw "Removing PowerStub from profile '$Path' would leave syntax errors (line $($errors[0].Extent.StartLineNumber): $($errors[0].Message)). Remove it by hand. Nothing was changed."
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Remove $($lines -join ', ')")) {
        return
    }

    [System.IO.File]::WriteAllText($Path, $newText, $profileInfo.Encoding)

    Write-Verbose "Removed $($lines.Count) PowerStub import(s) from profile '$Path'. New sessions will not load PowerStub."
    [PSCustomObject]@{ Path = $Path; Lines = $lines.ToArray(); Removed = $true }
}
