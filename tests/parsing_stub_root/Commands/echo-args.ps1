# echo-args.ps1 - script fixture for the parsing matrix (tests/ParsingMatrix.tests.ps1).
#
# A plain script with no param block: everything arrives in $args. Prints one line of JSON
# describing each argument with its type, so an argument that changed type, was split,
# merged or dropped on the way through the proxy is visible.
#
#   {"Count":2,"Args":[{"Type":"String","Value":"hello"},{"Type":"Int32","Value":"42"}]}

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

$described = foreach ($arg in $args) { Format-EchoValue $arg }

[ordered]@{
    Count = $args.Count
    Args  = @($described)
} | ConvertTo-Json -Compress -Depth 20
