<#
.SYNOPSIS
  Removes only a direct proxy still owned by this module and forgets its registration.
#>
function Unregister-PowerStubDirectAliasFunction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AliasName)

    if (Test-PowerStubDirectAliasFunction $AliasName) {
        # Remove-Item does not remove functions via a function:global: path.
        Remove-Item -LiteralPath "function:$AliasName" -Force -ErrorAction Stop
    }
    $Script:RegisteredDirectAliases = @($Script:RegisteredDirectAliases | Where-Object { $_ -ine $AliasName })
    if ($Script:RegisteredDirectAliasFunctions) {
        $Script:RegisteredDirectAliasFunctions.Remove($AliasName)
    }
}
