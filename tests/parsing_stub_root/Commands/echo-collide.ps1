# echo-collide.ps1 - script fixture for the parsing matrix (tests/ParsingMatrix.tests.ps1).
#
# Same idea as echo-params.ps1, but its parameters have the names pstb uses for itself
# (-Stub, -Command) plus a few that real tools commonly use. A proxy has to keep its own
# parameters apart from the target's, and this is where that gets tested.

[CmdletBinding()]
param(
    [string] $Command,
    [string] $Stub,
    [string] $Path,
    [string] $Filter,
    [Parameter(ValueFromRemainingArguments)]
    [object[]] $Rest
)

$bound = foreach ($key in ($PSBoundParameters.Keys | Sort-Object)) {
    $value = $PSBoundParameters[$key]
    [ordered]@{
        Name  = $key
        Type  = if ($null -eq $value) { 'null' } else { $value.GetType().Name }
        Value = if ($value -is [array]) { @($value | ForEach-Object { "$_" }) } else { "$value" }
    }
}

[ordered]@{ Bound = @($bound) } | ConvertTo-Json -Compress -Depth 20
