# echo-params.ps1 - script fixture for the parsing matrix (tests/ParsingMatrix.tests.ps1).
#
# A script with a declared param block. pstb reads these parameters to build its dynamic
# parameters, so this is the path where named-parameter binding gets tested. Prints one
# line of JSON with every bound parameter and its type:
#
#   {"Bound":[{"Name":"Count","Type":"Int32","Value":"5"},{"Name":"Name","Type":"String","Value":"a"}]}
#
# No parameter is mandatory: a missing mandatory parameter would prompt and hang the tests.

[CmdletBinding()]
param(
    [string] $Name,
    [int] $Count,
    [switch] $Force,
    [string[]] $Tags,
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,
    [hashtable] $Options,
    [bool] $Enabled,
    [double] $Ratio,
    [Parameter(ValueFromRemainingArguments)]
    [object[]] $Rest
)

function Format-EchoValue {
    param($Value)

    if ($null -eq $Value) {
        return [ordered]@{ Type = 'null' }
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $entries = foreach ($key in ($Value.Keys | Sort-Object { "$_" })) {
            [ordered]@{ Key = "$key"; Value = Format-EchoValue $Value[$key] }
        }
        return [ordered]@{ Type = $Value.GetType().Name; Entries = @($entries) }
    }
    if ($Value -is [System.Collections.IList]) {
        $items = foreach ($item in $Value) { Format-EchoValue $item }
        return [ordered]@{ Type = $Value.GetType().Name; Items = @($items) }
    }
    return [ordered]@{ Type = $Value.GetType().Name; Value = "$Value" }
}

$bound = foreach ($key in ($PSBoundParameters.Keys | Sort-Object)) {
    $entry = [ordered]@{ Name = $key }
    foreach ($pair in (Format-EchoValue $PSBoundParameters[$key]).GetEnumerator()) {
        $entry[$pair.Key] = $pair.Value
    }
    $entry
}

[ordered]@{ Bound = @($bound) } | ConvertTo-Json -Compress -Depth 20
