#Requires -Modules Pester
# Fresh-process package/documentation checks do not import into the Pester runspace.
BeforeAll {
    $script:PackageRepo = Split-Path $PSScriptRoot -Parent
    $script:PackageRoot = Join-Path ([IO.Path]::GetTempPath()) ('powerstub-packaging-tests-' + [guid]::NewGuid())
    $script:PackageStage = Join-Path $script:PackageRoot 'PowerStub'
    $script:PackagePwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $script:PackageReadme = Get-Content -LiteralPath (Join-Path $script:PackageRepo 'README.md') -Raw
    $script:PackageCi = Get-Content -LiteralPath (Join-Path $script:PackageRepo '.gitlab-ci.yml') -Raw
    $script:SourceManifestHash = (Get-FileHash (Join-Path $script:PackageRepo 'PowerStub/PowerStub.psd1')).Hash
    & (Join-Path $script:PackageRepo 'scripts/stage-module.ps1') -DestinationPath $script:PackageStage -Version 9.8.7
}
AfterAll {
    if ($script:PackageRoot -and (Test-Path -LiteralPath $script:PackageRoot)) {
        Remove-Item -LiteralPath $script:PackageRoot -Recurse -Force
    }
}
Describe 'Package and documentation release contracts' -Tag 'Packaging' {
    It 'stages the license, README, version and exports and passes a fresh-process package smoke' {
        $output = & $script:PackagePwsh -NoProfile -File (Join-Path $script:PackageRepo 'scripts/test-staged-module.ps1') -ModulePath $script:PackageStage -ExpectedVersion 9.8.7 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $output | Out-String | Should -Match 'Package smoke passed'
        (Get-FileHash (Join-Path $script:PackageRepo 'PowerStub/PowerStub.psd1')).Hash | Should -Be $script:SourceManifestHash
        (Get-FileHash (Join-Path $script:PackageStage 'LICENSE.txt')).Hash | Should -Be (Get-FileHash (Join-Path $script:PackageRepo 'LICENSE.txt')).Hash
    }
    It 'excludes legacy user configuration and development-only inputs from staging' {
        $fixtureRepo = Join-Path $script:PackageRoot 'source-fixture'
        New-Item -ItemType Directory -Path $fixtureRepo -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:PackageRepo 'PowerStub') -Destination $fixtureRepo -Recurse
        foreach ($file in @('LICENSE.txt','README.md')) {
            Copy-Item -LiteralPath (Join-Path $script:PackageRepo $file) -Destination $fixtureRepo
        }
        '{"Stubs":{"PrivateTools":"private-path"}}' | Set-Content -LiteralPath (Join-Path $fixtureRepo 'PowerStub/PowerStub.json')
        $stage = Join-Path $script:PackageRoot 'filtered/PowerStub'
        & (Join-Path $script:PackageRepo 'scripts/stage-module.ps1') -RepositoryRoot $fixtureRepo -DestinationPath $stage -Version 9.8.7
        foreach ($file in @('PowerStub.json','.gitignore','PowerStub.pssproj')) {
            Test-Path -LiteralPath (Join-Path $stage $file) | Should -BeFalse
        }
        Test-Path -LiteralPath (Join-Path $stage 'Templates/command_template.ps1') | Should -BeTrue
    }
    It 'rejects reuse of a populated staging directory' {
        { & (Join-Path $script:PackageRepo 'scripts/stage-module.ps1') -DestinationPath $script:PackageStage -Version 9.8.7 } | Should -Throw '*must be empty*'
    }
    It 'executes the exact README GitEnabled workflow through public exports, preserving registrations and making a backup' {
        $match = [regex]::Match($script:PackageReadme, '(?s)<!-- smoke:git-setting:start -->\s*```powershell\s*\r?\n(.*?)```\s*<!-- smoke:git-setting:end -->')
        $match.Success | Should -BeTrue
        $fixture = Join-Path $script:PackageRoot 'documentation.ps1'
        @'
param($Manifest, $Root)
$ErrorActionPreference = 'Stop'
$env:POWERSTUB_CONFIG_DIR = Join-Path $Root 'doc-config'
Import-Module $Manifest -Force
New-PowerStub -Name DocsPreserved -Path (Join-Path $Root 'doc-tools')
'@ + "`n" + $match.Groups[1].Value + @'

if ((Get-PowerStubConfiguration -Key GitEnabled) -ne $false) { throw 'GitEnabled was not persisted.' }
if (-not (Get-PowerStubs).ContainsKey('DocsPreserved')) { throw 'The README workflow lost a registration.' }
if (-not (Test-Path -LiteralPath "$configPath.backup")) { throw 'The README workflow did not back up the config.' }
if (Get-Command Set-PowerStubConfigurationKey -ErrorAction SilentlyContinue) { throw 'Workflow must not depend on a private export.' }
Remove-Module PowerStub
'@ | Set-Content -LiteralPath $fixture
        $output = & $script:PackagePwsh -NoProfile -File $fixture -Manifest (Join-Path $script:PackageStage 'PowerStub.psd1') -Root $script:PackageRoot 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
    }
    It 'states the runtime floor, real config path, source archive layout, and manifest contribution contract' {
        $script:PackageReadme | Should -Match 'Requires \*\*PowerShell 7\.0 or later\*\*'
        $script:PackageReadme | Should -Not -Match '(?m)^- PowerShell 5\.1'
        $script:PackageReadme | Should -Not -Match '(?m)^Set-PowerStubConfigurationKey'
        $script:PackageReadme | Should -Not -Match 'no manifest changes needed'
        $script:PackageReadme | Should -Match 'FunctionsToExport'
        $script:PackageReadme | Should -Match 'POWERSTUB_CONFIG_DIR/config.json'
        $script:PackageReadme | Should -Match 'power-stub-2\.0\.0\\PowerStub\\PowerStub.psd1'
        $script:PackageReadme | Should -Match 'public mirror'
        $script:PackageReadme | Should -Match 'pstb update --check'
    }
}
Describe 'Release pipeline safety contracts' -Tag 'Packaging' {
    It 'retains six main-release jobs, allows branch/MR tests, and rejects tag pipelines' {
        foreach ($job in @('validate_github','test','version','mirror','publish','github_release')) {
            $script:PackageCi | Should -Match "(?m)^${job}:"
        }
        $workflow = [regex]::Match($script:PackageCi, '(?s)workflow:\s*\n(.*?)\nstages:').Groups[1].Value
        $workflow | Should -Match '(?s)\$CI_COMMIT_TAG''\s+when: never'
        $workflow | Should -Match '\$CI_PIPELINE_SOURCE == "merge_request_event"'
        $workflow | Should -Match '\$CI_COMMIT_BRANCH && \(\$CI_PIPELINE_SOURCE == "push" \|\| \$CI_PIPELINE_SOURCE == "web"\)'
        $workflow | Should -Match '\$CI_COMMIT_BRANCH != "main" && \$CI_OPEN_MERGE_REQUESTS'
        $workflow | Should -Match 'when: never\s*$'
    }
    It 'requires main push/web for every credential-dependent or release job' {
        $rules = [regex]::Match($script:PackageCi, '(?s)rules: &release_rules\s*\n(.*?)\n  stage:').Groups[1].Value
        $rules | Should -Match '\$CI_COMMIT_BRANCH == "main" && \(\$CI_PIPELINE_SOURCE == "push" \|\| \$CI_PIPELINE_SOURCE == "web"\)'
        $rules | Should -Match 'when: never\s*$'
        foreach ($job in @('version','mirror','publish','github_release')) {
            $script:PackageCi | Should -Match "(?m)^${job}:\r?\n  rules: \*release_rules"
        }
        $testJob = [regex]::Match($script:PackageCi, '(?s)\ntest:\n(.*?)\nversion:').Groups[1].Value
        $testJob | Should -Not -Match 'GITHUB_PAT|GITLAB_PUSH_TOKEN|PSGALLERY_API_KEY|release_rules'
    }
    It 'requires successful mirror before Gallery publication and package verification before upload' {
        $publish = [regex]::Match($script:PackageCi, '(?s)\npublish:\n(.*?)\ngithub_release:').Groups[1].Value
        $publish | Should -Match '(?s)needs:.*?- job: mirror\s+artifacts: false'
        $publish | Should -Match '(?s)stage-module.ps1.*?test-staged-module.ps1.*?if \(\$LASTEXITCODE -ne 0\).*?Publish-Module'
        $publish | Should -Not -Match 'Update-ModuleManifest -Path "\$env:MODULE_PATH'
    }
    It 'uses JUnit XML with GitLab and delegates API validation to the tested release script' {
        $script:PackageCi | Should -Match 'OutputFormat = "JUnitXml"'
        $script:PackageCi | Should -Not -Match 'OutputFormat = "NUnitXml"'
        $script:PackageCi | Should -Match 'junit: TestResults/testResults.xml'
        $script:PackageCi | Should -Match 'sh scripts/create-github-release.sh'
    }
}
Describe 'GitHub release API response handling' -Tag 'Packaging' -Skip:($IsWindows -or -not (Get-Command sh -ErrorAction SilentlyContinue)) {
    BeforeAll {
        if (-not (Get-Command jq -ErrorAction SilentlyContinue)) { throw 'jq is required to test the GitHub release response handling.' }
        $script:ReleaseMockRoot = Join-Path $script:PackageRoot 'release-mock'
        New-Item -ItemType Directory -Path $script:ReleaseMockRoot -Force | Out-Null
        $mock = Join-Path $script:ReleaseMockRoot 'curl'
        @'
#!/bin/sh
set -eu
out=''
method=GET
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -X) method="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$method" >> "$MOCK_CALLS"
if [ "$method" = POST ]; then
    printf '%s' "$MOCK_POST_BODY" > "$out"
    printf '%s' "$MOCK_POST_STATUS"
else
    printf '%s' "$MOCK_GET_BODY" > "$out"
    printf '%s' "$MOCK_GET_STATUS"
fi
'@ | Set-Content -LiteralPath $mock
        & chmod +x $mock
    }
    It '<Name>' -ForEach @(
        @{ Name='accepts a created release'; Post='201'; PostBody='{}'; Get=''; GetBody='{}'; Expected=0; Calls=1 },
        @{ Name='accepts an already-existing release only after exact published-tag verification'; Post='422'; PostBody='{"errors":[{"code":"already_exists","field":"tag_name"}]}'; Get='200'; GetBody='{"tag_name":"v9.8.7","draft":false,"prerelease":false}'; Expected=0; Calls=2 },
        @{ Name='rejects unrelated validation errors without pretending the release exists'; Post='422'; PostBody='{"errors":[{"code":"invalid","field":"tag_name"}]}'; Get='200'; GetBody='{}'; Expected=1; Calls=1 },
        @{ Name='rejects duplicate validation when the tagged release cannot be found'; Post='422'; PostBody='{"errors":[{"code":"already_exists","field":"tag_name"}]}'; Get='404'; GetBody='{}'; Expected=1; Calls=2 },
        @{ Name='rejects a different returned tag'; Post='422'; PostBody='{"errors":[{"code":"already_exists","field":"tag_name"}]}'; Get='200'; GetBody='{"tag_name":"v1.0.0","draft":false,"prerelease":false}'; Expected=1; Calls=2 },
        @{ Name='rejects a draft returned release'; Post='422'; PostBody='{"errors":[{"code":"already_exists","field":"tag_name"}]}'; Get='200'; GetBody='{"tag_name":"v9.8.7","draft":true,"prerelease":false}'; Expected=1; Calls=2 },
        @{ Name='rejects other API failures'; Post='500'; PostBody='{}'; Get=''; GetBody='{}'; Expected=1; Calls=1 },
        @{ Name='rejects non-main releases before contacting the API'; Branch='develop'; Post='201'; PostBody='{}'; Get=''; GetBody='{}'; Expected=1; Calls=0 },
        @{ Name='rejects tag-pipeline releases before contacting the API'; Tag='v9.8.7'; Post='201'; PostBody='{}'; Get=''; GetBody='{}'; Expected=1; Calls=0 },
        @{ Name='skips explicitly disabled releases before contacting the API'; Release='false'; Post='201'; PostBody='{}'; Get=''; GetBody='{}'; Expected=0; Calls=0 }
    ) {
        $envNames = @('PATH','CI_COMMIT_BRANCH','CI_COMMIT_TAG','SHOULD_RELEASE','VERSION','GITHUB_PAT','GITHUB_REPO','MOCK_POST_BODY','MOCK_POST_STATUS','MOCK_GET_BODY','MOCK_GET_STATUS','MOCK_CALLS')
        $saved = @{}
        foreach ($key in $envNames) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
        Push-Location $script:ReleaseMockRoot
        try {
            $env:PATH = $script:ReleaseMockRoot + [IO.Path]::PathSeparator + $env:PATH
            $env:CI_COMMIT_BRANCH=if ($Branch) { $Branch } else { 'main' }
            $env:CI_COMMIT_TAG=if ($Tag) { $Tag } else { '' }
            $env:SHOULD_RELEASE=if ($Release) { $Release } else { 'true' }
            $env:VERSION='9.8.7'
            $env:GITHUB_PAT='mock-only'; $env:GITHUB_REPO='example/mock'
            $env:MOCK_POST_STATUS=$Post; $env:MOCK_POST_BODY=$PostBody; $env:MOCK_GET_STATUS=$Get; $env:MOCK_GET_BODY=$GetBody
            $env:MOCK_CALLS=Join-Path $script:ReleaseMockRoot 'calls.txt'
            if (Test-Path $env:MOCK_CALLS) { Remove-Item $env:MOCK_CALLS }
            'Offline release fixture' | Set-Content changelog.md
            $output = & sh (Join-Path $script:PackageRepo 'scripts/create-github-release.sh') 2>&1
            $LASTEXITCODE | Should -Be $Expected -Because ($output | Out-String)
            $actualCalls = if (Test-Path $env:MOCK_CALLS) { @(Get-Content $env:MOCK_CALLS).Count } else { 0 }
            $actualCalls | Should -Be $Calls
        }
        finally {
            Pop-Location
            foreach ($key in $envNames) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
        }
    }
}
