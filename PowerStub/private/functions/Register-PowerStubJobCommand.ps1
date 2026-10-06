<#
.SYNOPSIS
  Creates the global Start-PowerStubJob command and its Start-PstbJob alias.

.DESCRIPTION
  A background job is a new process without the user's profile, so PowerStub and its direct
  aliases are missing there. Start-PowerStubJob is Start-Job with an initialization script
  that first imports this exact PowerStub module (by path, so a job never loads a different
  installed version), with the background update check turned off.

  It is a global function created at import rather than an exported module function, for the
  same reason as direct aliases: a module function runs in the module's session state, and
  Start-Job resolves $using: variables from the session state it is called in, so $using: of
  a caller's local variable would fail. This function's script block is not bound to the
  module, so it runs in the caller's session state exactly like Start-Job.

  Its parameters are generated from Start-Job on this PowerShell version, so they always
  match. Nothing here may depend on module state: the module path is written into the text.

  Like direct aliases, an existing command with either name is never replaced.
#>

function Register-PowerStubJobCommand {
    [CmdletBinding()]
    param()

    $Script:JobCommandFunction = $null
    $Script:JobCommandAlias = $false

    if (Get-PowerStubAliasConflict 'Start-PowerStubJob') {
        Write-Warning "PowerStub: 'Start-PowerStubJob' is already an existing command and was not replaced."
        return
    }

    $startJob = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Core\Start-Job', [System.Management.Automation.CommandTypes]::Cmdlet)
    $metadata = [System.Management.Automation.CommandMetadata]::new($startJob)
    $manifest = (Join-Path $Script:ModulePath 'PowerStub.psd1').Replace("'", "''")

    $template = @'
<#
.SYNOPSIS
    Starts a background job in which PowerStub commands work.

.DESCRIPTION
    Start-PowerStubJob takes exactly the same parameters as Start-Job, and starts the job the
    same way. Before the job's script block runs, it imports the PowerStub module this session
    is using, so pstb, Invoke-PowerStubCommand and every direct alias work inside the job,
    including from scripts the job runs. Settings, stubs and aliases come from the same
    config.json (POWERSTUB_CONFIG_DIR is inherited by the job).

    A job never runs your profile, which is why Start-Job alone cannot see direct aliases.

    If you pass -InitializationScript, it still runs, after PowerStub has been imported.
    The background update check is turned off inside the job.

    A Windows PowerShell job (-PSVersion 5.1) cannot load PowerStub, which needs PowerShell 7.

.EXAMPLE
    Start-PowerStubJob { rdeploy Test-BasicUrl $using:url -quiet -details } | Receive-Job -Wait -AutoRemoveJob

    Runs a direct alias in a background job.

.EXAMPLE
    $jobs = foreach ($url in $urls) { Start-PstbJob { param($u) pstb Deploy Test-BasicUrl $u } -ArgumentList $url }

    Starts one job per URL with the Start-PstbJob alias.

.LINK
    Start-Job
#>
__CMDLETBINDING__
param(__PARAMS__)

begin {
    # A Windows PowerShell job cannot load PowerStub, which needs PowerShell 7.
    if ($PSBoundParameters.ContainsKey('PSVersion') -and $PSVersion -and $PSVersion.Major -lt 7) {
        throw "Start-PowerStubJob cannot run PowerStub in a Windows PowerShell $PSVersion job: PowerStub needs PowerShell 7. Use Start-Job instead."
    }

    # Start-Job -DefinitionName starts a scheduled job definition, which has no initialization script.
    if ($PSCmdlet.ParameterSetName -ne 'DefinitionName') {
        $manifest = '__MANIFEST__'
        $initialization = "`$env:POWERSTUB_NO_UPDATE_CHECK = '1'`nImport-Module -Name '" + $manifest.Replace("'", "''") + "' -ErrorAction Stop"
        if ($InitializationScript) {
            # Dot-sourced, so functions and variables it defines are visible to the job, as with Start-Job.
            $initialization += "`n. {`n" + $InitializationScript.ToString() + "`n}"
        }
        $PSBoundParameters['InitializationScript'] = [scriptblock]::Create($initialization)
    }

    $outBuffer = $null
    if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
        $PSBoundParameters['OutBuffer'] = 1
    }
    $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Core\Start-Job', [System.Management.Automation.CommandTypes]::Cmdlet)
    $steppablePipeline = { & $wrappedCmd @PSBoundParameters }.GetSteppablePipeline($MyInvocation.CommandOrigin)
    $steppablePipeline.Begin($PSCmdlet)
}

process {
    $steppablePipeline.Process($_)
}

end {
    $steppablePipeline.End()
}
'@

    $text = $template.
        Replace('__CMDLETBINDING__', [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($metadata)).
        Replace('__PARAMS__', [System.Management.Automation.ProxyCommand]::GetParamBlock($metadata)).
        Replace('__MANIFEST__', $manifest)

    # [scriptblock]::Create leaves the block unbound, so the function runs in its caller's session state.
    Set-Item -Path 'function:global:Start-PowerStubJob' -Value ([scriptblock]::Create($text)) -ErrorAction Stop
    $Script:JobCommandFunction = (Get-Item -LiteralPath 'function:Start-PowerStubJob').ScriptBlock

    if (Get-PowerStubAliasConflict 'Start-PstbJob') {
        Write-Warning "PowerStub: 'Start-PstbJob' is already an existing command and was not replaced. Use Start-PowerStubJob."
        return
    }
    Set-Alias -Name 'Start-PstbJob' -Value 'Start-PowerStubJob' -Scope Global -ErrorAction Stop
    $Script:JobCommandAlias = $true
}
