<#
.SYNOPSIS
    Runs the parsing matrix and summarizes where pstb and a direct call disagree.

.DESCRIPTION
    Runs tests/ParsingMatrix.tests.ps1 quietly, then prints the agreement rate per group and
    category and, for every disagreement, the argument text with both results.

.PARAMETER Group
    Only report these groups (Script, ExeGeneric, ExeRealWorld).

.PARAMETER SummaryOnly
    Print the tables but not the per-call details.

.PARAMETER PassThru
    Return the result objects (Id, Group, Category, Command, ArgText, Match, Direct, Proxied)
    instead of printing the report.

.EXAMPLE
    ./tests/Show-ParsingMatrix.ps1 -SummaryOnly

.EXAMPLE
    ./tests/Show-ParsingMatrix.ps1 -PassThru | Where-Object { -not $_.Match } | Export-Csv .aitemp/matrix.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('Script', 'ExeGeneric', 'ExeRealWorld')]
    [string[]] $Group,
    [switch] $SummaryOnly,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'

$global:PSTBMatrixResults = [System.Collections.Generic.List[object]]::new()
try {
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $PSScriptRoot 'ParsingMatrix.tests.ps1'
    $config.Output.Verbosity = 'None'
    Invoke-Pester -Configuration $config 6>$null

    $results = @($global:PSTBMatrixResults)
}
finally {
    Remove-Variable -Name PSTBMatrixResults -Scope Global -ErrorAction SilentlyContinue
}

if ($Group) {
    $results = @($results | Where-Object Group -in $Group)
}

if ($PassThru) {
    return $results
}

$results | Group-Object Group | ForEach-Object {
    [PSCustomObject]@{
        Group    = $_.Name
        Calls    = $_.Count
        Agree    = @($_.Group | Where-Object Match).Count
        Disagree = @($_.Group | Where-Object { -not $_.Match }).Count
    }
} | Format-Table -AutoSize

$results | Group-Object Group, Category | ForEach-Object {
    [PSCustomObject]@{
        Group    = $_.Group[0].Group
        Category = $_.Group[0].Category
        Calls    = $_.Count
        Disagree = @($_.Group | Where-Object { -not $_.Match }).Count
    }
} | Where-Object Disagree -gt 0 | Sort-Object Group, @{ Expression = 'Disagree'; Descending = $true } | Format-Table -AutoSize

if (-not $SummaryOnly) {
    foreach ($result in ($results | Where-Object { -not $_.Match })) {
        "{0} [{1}/{2}] {3} {4}" -f $result.Id, $result.Group, $result.Category, $result.Command, $result.ArgText
        "    direct : $($result.Direct)"
        "    proxied: $($result.Proxied)"
    }
}
