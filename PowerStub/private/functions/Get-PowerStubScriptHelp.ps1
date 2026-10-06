<#
.SYNOPSIS
  Reads a script's comment-based help straight from the file.

.DESCRIPTION
  Command listings and search only need the synopsis and description. Parsing the file
  is far cheaper than Get-Help (about 6 ms against 44 ms per script, or several hundred
  when Get-Help is given a wildcard pattern), takes a literal path, and returns nothing
  for a script without help instead of a generated syntax line.

.PARAMETER Path
  The literal path of the .ps1 file.

.OUTPUTS
  System.Management.Automation.Language.CommentHelpInfo, or $null when the script has no
  comment-based help or cannot be read.
#>

function Get-PowerStubScriptHelp {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        return $ast.GetHelpContent()
    }
    catch {
        Write-Verbose "Could not read help from ${Path}: $_"
        return $null
    }
}
