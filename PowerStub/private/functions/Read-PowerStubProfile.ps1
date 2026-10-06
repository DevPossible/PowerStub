<#
.SYNOPSIS
  Reads a profile file and finds the commands in it that import PowerStub.

.DESCRIPTION
  Returns the text, the encoding detected from its BOM ($null when the file does not exist),
  the parsed AST, any parse errors, and every Import-Module/ipmo CommandAst whose arguments
  name PowerStub or a path to its manifest or module file. A missing file reads as empty.
#>
function Read-PowerStubProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $text = ''
    $encoding = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $reader = [System.IO.StreamReader]::new($Path, $true)
        try {
            $text = $reader.ReadToEnd()
            $encoding = $reader.CurrentEncoding
        }
        finally {
            $reader.Dispose()
        }
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)

    $imports = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in 'Import-Module', 'ipmo' -and
                @($node.CommandElements | Select-Object -Skip 1 | Where-Object {
                        ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                        $_ -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                        $_.Value -match '(^|[\\/])PowerStub(\.psd1|\.psm1)?$'
                    }).Count -gt 0
            }, $true))

    [PSCustomObject]@{
        Text     = $text
        Encoding = $encoding
        Ast      = $ast
        Errors   = $errors
        Imports  = $imports
    }
}
