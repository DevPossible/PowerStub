# Get-Command has no LiteralPath parameter and may prefer a wildcard lookalike.
# Accept only a CommandInfo for the file already selected by literal discovery.
function Resolve-PowerStubFileCommand {
    param([Parameter(Mandatory)][string]$Path)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $resolved = Get-Command -Name $Path -CommandType ExternalScript,Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.Equals($Path, $comparison) } |
        Select-Object -First 1
    if ($resolved) { return $resolved }

    # An escaped exact name alone bypasses pattern discovery. Force that discovery
    # with a singleton character class on the final extension character (.ps[1] or
    # .ex[e]), without a trailing '*' that could also select a prefix sibling.
    # PowerShell consumes filename escapes twice, but directory escapes only once.
    $directory = [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetDirectoryName($Path))
    $leaf = [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetFileName($Path)).Replace('`', '``')
    $pattern = Join-Path $directory ($leaf.Substring(0, $leaf.Length - 1) + '[' + $leaf.Substring($leaf.Length - 1) + ']')
    Get-Command -Name $pattern -CommandType ExternalScript,Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.Equals($Path, $comparison) } |
        Select-Object -First 1
}
