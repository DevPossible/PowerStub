# Get-Command has no LiteralPath parameter and may prefer a wildcard lookalike.
# Accept only a CommandInfo for the file already selected by literal discovery.
function Resolve-PowerStubFileCommand {
    param([Parameter(Mandatory)][string]$Path)

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $resolved = Get-Command -Name $Path -CommandType ExternalScript,Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.Equals($Path, $comparison) } |
        Select-Object -First 1
    if ($resolved) { return $resolved }

    $pattern = Get-PowerStubFilePattern -Path $Path
    Get-Command -Name $pattern -CommandType ExternalScript,Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.Equals($Path, $comparison) } |
        Select-Object -First 1
}
