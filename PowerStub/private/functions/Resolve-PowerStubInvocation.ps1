<#
.SYNOPSIS
  Works out which tokens of a pstb call are the stub, the command and the target's arguments.

.DESCRIPTION
  Invoke-PowerStubCommand declares no parameters, so that nothing meant for the target
  command is ever bound to pstb itself. This function does the little parsing pstb needs:
  the stub and command are the first two tokens, and everything after them belongs to
  the target, untouched.

  For backward compatibility the stub and command can also be given by name, but only
  with the full names -Stub and -Command and only before the target's arguments:

      Invoke-PowerStubCommand -Stub DevOps -Command deploy -Environment prod

  Used for both execution and tab completion, so they always agree.

.PARAMETER Tokens
  The arguments of the call ($args, or the text of each command element when completing).

.PARAMETER StubIsKnown
  Set for direct aliases, where the stub is fixed and the first token is the command.

.INPUTS
None. You cannot pipe objects to this function.

.OUTPUTS
PSCustomObject with StubIndex, CommandIndex and RestStart. An index is -1 when that part
was not given, and may equal Tokens.Count when a name was given without its value yet.
#>


function Resolve-PowerStubInvocation {
    [CmdletBinding()]
    param (
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Tokens = @(),

        [switch] $StubIsKnown
    )

    $stubIndex = -1
    $commandIndex = -1
    $haveStub = [bool]$StubIsKnown
    $haveCommand = $false

    $i = 0
    while ($i -lt $Tokens.Count -and -not ($haveStub -and $haveCommand)) {
        $token = $Tokens[$i]

        if ($token -is [string] -and $token -ieq '-Stub' -and -not $haveStub) {
            $stubIndex = $i + 1
            $haveStub = $true
            $i += 2
        }
        elseif ($token -is [string] -and $token -ieq '-Command' -and -not $haveCommand) {
            $commandIndex = $i + 1
            $haveCommand = $true
            $i += 2
        }
        elseif (-not $haveStub) {
            $stubIndex = $i
            $haveStub = $true
            $i++
        }
        else {
            $commandIndex = $i
            $haveCommand = $true
            $i++
        }
    }

    [PSCustomObject]@{
        StubIndex    = $stubIndex
        CommandIndex = $commandIndex
        RestStart    = $i
    }
}
