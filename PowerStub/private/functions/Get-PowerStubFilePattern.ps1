# Command/help discovery consumes filename escapes twice, directory escapes once.
# A singleton class on the final .ps1/.exe extension character enables pattern
# discovery without a trailing '*' that could select similarly prefixed files.
function Get-PowerStubFilePattern {
    param([Parameter(Mandatory)][string]$Path)

    $directory = [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetDirectoryName($Path))
    $leaf = [System.Management.Automation.WildcardPattern]::Escape([IO.Path]::GetFileName($Path)).Replace('`', '``')
    Join-Path $directory ($leaf.Substring(0, $leaf.Length - 1) + '[' + $leaf.Substring($leaf.Length - 1) + ']')
}
