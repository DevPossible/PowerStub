<#
.SYNOPSIS
    Adds an Import-Module line for PowerStub to a PowerShell profile.

.DESCRIPTION
    Makes PowerStub load in every new session. Safer than appending the line by hand:

    - Creates the profile file and its folder when they do not exist yet.
    - Does nothing when the profile already imports PowerStub.
    - Refuses to touch a profile that already has syntax errors, and checks that the
      profile still parses with the new line as its own statement before writing.
    - Appends in place, so the file's encoding is kept and a symbolic link to a
      dotfiles profile is followed rather than replaced.

    The line is 'Import-Module PowerStub' when the running module can be found by name
    on PSModulePath (a PowerShell Gallery install), otherwise an import of this module's
    manifest path (a source or archive install).

.PARAMETER Path
    The profile file to change. Defaults to $PROFILE.CurrentUserAllHosts, which every
    PowerShell host (console, Windows Terminal, VS Code) runs for the current user.
    Pass $PROFILE to change only the current host's profile.

.EXAMPLE
    Add-PowerStubToProfile

    Adds the import to the current user's all-hosts profile.

.EXAMPLE
    Add-PowerStubToProfile -Path $PROFILE -WhatIf

    Shows what would be added to the current host's profile without changing it.

.OUTPUTS
    PSCustomObject with Path, Line (the import line added or already present) and Added.
#>

function Add-PowerStubToProfile {
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

    $manifest = Join-Path $Script:ModulePath 'PowerStub.psd1'
    $onModulePath = Get-Module -ListAvailable -Name PowerStub | Where-Object { $_.Path -eq $manifest }
    $importLine = if ($onModulePath) { 'Import-Module PowerStub' } else { "Import-Module '$($manifest.Replace("'", "''"))'" }

    $profileInfo = Read-PowerStubProfile -Path $Path
    if ($profileInfo.Errors) {
        $first = $profileInfo.Errors[0]
        throw "Profile '$Path' has syntax errors (line $($first.Extent.StartLineNumber): $($first.Message)). Fix them, then run Add-PowerStubToProfile again. Nothing was changed."
    }

    $existing = $profileInfo.Imports | Select-Object -First 1
    if ($existing) {
        Write-Verbose "Profile '$Path' already imports PowerStub on line $($existing.Extent.StartLineNumber)"
        return [PSCustomObject]@{ Path = $Path; Line = $existing.Extent.Text; Added = $false }
    }

    $text = $profileInfo.Text
    $newline = if ($text -match "`r`n") { "`r`n" } elseif ($text -match "`n") { "`n" } else { [Environment]::NewLine }
    $prefix = ''
    if ($text) {
        $prefix = if ($text.EndsWith("`n")) { $newline } else { $newline + $newline }
    }
    $addition = "$prefix# PowerStub$newline$importLine$newline"

    # The existing text parsed cleanly, but check the result too: the new line must stand
    # as the profile's last statement, not be absorbed into something before it.
    $tokens = $null
    $errors = $null
    $newAst = [System.Management.Automation.Language.Parser]::ParseInput($text + $addition, [ref]$tokens, [ref]$errors)
    $lastStatement = $newAst.EndBlock.Statements | Select-Object -Last 1
    if ($errors -or -not $lastStatement -or $lastStatement.Extent.Text -ne $importLine) {
        throw "Adding '$importLine' to profile '$Path' would not produce a separate statement. Add it by hand. Nothing was changed."
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Add '$importLine'")) {
        return
    }

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    if ($profileInfo.Encoding) {
        [System.IO.File]::AppendAllText($Path, $addition, $profileInfo.Encoding)
    }
    else {
        [System.IO.File]::AppendAllText($Path, $addition)
    }

    Write-Verbose "Added '$importLine' to profile '$Path'. It takes effect in new sessions."
    [PSCustomObject]@{ Path = $Path; Line = $importLine; Added = $true }
}
