<#
.SYNOPSIS
  Tests whether the live function is still the exact direct proxy we installed.
#>
function Test-PowerStubDirectAliasFunction {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$AliasName)

    if (-not $Script:RegisteredDirectAliasFunctions -or
        -not $Script:RegisteredDirectAliasFunctions.ContainsKey($AliasName)) { return $false }
    $current = Get-Item -LiteralPath "function:$AliasName" -ErrorAction SilentlyContinue
    return $current -and [object]::ReferenceEquals(
        $current.ScriptBlock, $Script:RegisteredDirectAliasFunctions[$AliasName])
}
