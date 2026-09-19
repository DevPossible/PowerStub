<#
.SYNOPSIS
    The 300 sample calls for the parsing matrix (tests/ParsingMatrix.tests.ps1).

.DESCRIPTION
    Each line is:   Category ::: argument text

    The argument text is PowerShell source, exactly as a user would type it after the
    command name. The matrix runs it twice from the same text - once calling the target
    directly and once through pstb - and requires identical results.

    The lists are literal here-strings so nothing needs escaping. The variables used in the
    argument text ($str, $arr, @splatHash, ...) are defined by the test's prelude.

    Groups (100 calls each):
      Script       .ps1 targets: echo-args (plain $args), echo-params (declared param block),
                   echo-collide (parameters named like pstb's own)
      ExeGeneric   echoargs.exe with quoting, dashes, empty strings, special characters, paths
      ExeRealWorld echoargs.exe with command lines modeled on popular CLIs. The category is
                   the tool being imitated; nothing real is executed.

.OUTPUTS
    One object per call: Group, Id, Category, Command, ArgText
#>

$scriptArgs = @'
Plain :::
Plain ::: hello
Plain ::: hello world
Plain ::: one two three four five
Number ::: 42
Number ::: 3.14
Number ::: -5
Number ::: 0x10
Number ::: 1kb
Quoted ::: 'hello world'
Quoted ::: "hello world"
Quoted ::: 'it''s'
Quoted ::: 'say "hi"'
Empty ::: ''
Empty ::: ""
Empty ::: 'a' '' 'b'
Empty ::: ' '
Dash ::: -v
Dash ::: --verbose
Dash ::: --key=value
Dash ::: -k:value
Dash ::: --
Dash ::: -- -v
Dash ::: /flag
PstbName ::: -Verbose
PstbName ::: -Debug
PstbName ::: -ErrorAction Stop
PstbName ::: -Stub other
PstbName ::: -Command other
PstbName ::: -OutVariable ov
Variable ::: $str
Variable ::: $num
Variable ::: $nul
Variable ::: $flag
Variable ::: $arr
Variable ::: "$word-suffix"
Variable ::: $(1 + 1)
Variable ::: $env:PSTB_MATRIX
Typed ::: @(1,2,3)
Typed ::: a,b,c
Typed ::: @{a=1}
Typed ::: $hash
Typed ::: { 1 + 1 }
Typed ::: [datetime]'2024-01-02'
Splat ::: @splatArr
'@

$scriptParams = @'
Named ::: -Name alpha
Named ::: -Name 'hello world'
Named ::: -Name:alpha
Named ::: -Name "$word"
Named ::: -Count 5
Named ::: -Count:5
Named ::: -Count '5'
Named ::: -Count -3
Switch ::: -Force
Switch ::: -Force:$true
Switch ::: -Force:$false
Bool ::: -Enabled $true
Bool ::: -Enabled:$false
Double ::: -Ratio 2.5
Abbrev ::: -N alpha
Abbrev ::: -name alpha
Abbrev ::: -F
Abbrev ::: -Env dev
Abbrev ::: -E dev
Positional ::: alpha
Positional ::: alpha 5
Positional ::: alpha 5 extra1 extra2
Positional ::: alpha -Count 5
Positional ::: -Force alpha 5
Array ::: -Tags a
Array ::: -Tags a,b,c
Array ::: -Tags 'a b','c d'
Array ::: -Tags $arr
Array ::: -Tags @()
Array ::: -Tags:a,b
ValidateSet ::: -Environment PROD
ValidateSet ::: -Environment staging
Hashtable ::: -Options @{a=1}
Hashtable ::: -Options $hash
Convert ::: -Count abc
Convert ::: -Count 5.7
Convert ::: -Name 42
Convert ::: -Name $nul
Splat ::: @splatHash
Splat ::: @splatHash -Force
Splat ::: @namedArr
Splat ::: @tagsArr
Rest ::: a 1 'rest with space'
Rest ::: a 1 -- -Force
Rest ::: a 1 ''
Common ::: -Name a -Verbose
Error ::: -Bogus x
'@

$scriptCollide = @'
Collide ::: -Path 'C:\temp'
Collide ::: -Filter *.txt
Collide ::: -Command build
Collide ::: -Stub other
Collide ::: -Command build -Path 'C:\temp'
Collide ::: build
Collide ::: -Path 'C:\temp' extra
Collide ::: -Comm build
'@

$exeGeneric = @'
Plain :::
Plain ::: hello
Plain ::: hello world
Plain ::: one two three four five
Plain ::: UPPER lower MiXeD
Plain ::: a b c d e f g h i j k l m n o p q r s t
Number ::: 42
Number ::: 3.14
Number ::: -5
Number ::: 0
Number ::: 1e3
Quoted ::: 'hello world'
Quoted ::: "hello world"
Quoted ::: 'it''s'
Quoted ::: "it's"
Quoted ::: 'say "hi"'
Quoted ::: "say ""hi"""
Quoted ::: '"'
Quoted ::: '""'
Quoted ::: 'a "b c" d'
Quoted ::: '"fully quoted"'
Empty ::: ''
Empty ::: ""
Empty ::: 'a' '' 'b'
Empty ::: ' '
Empty ::: '  padded  '
Empty ::: $empty
Dash ::: -v
Dash ::: --verbose
Dash ::: --key=value
Dash ::: --key value
Dash ::: -k:value
Dash ::: -
Dash ::: --
Dash ::: -- -v
Dash ::: /flag
Dash ::: /p:Configuration=Release
Dash ::: -Dprop=val
Dash ::: --no-cache --force
PstbName ::: -Verbose
PstbName ::: -Debug
PstbName ::: -ErrorAction Stop
PstbName ::: -WhatIf
PstbName ::: -Confirm
PstbName ::: -OutVariable ov
PstbName ::: -Stub other
PstbName ::: -Command other
PstbName ::: -RemainingArgs x
PstbName ::: -Comm x
Variable ::: $str
Variable ::: $num
Variable ::: $dbl
Variable ::: $nul
Variable ::: $flag
Variable ::: $arr
Variable ::: "$word-suffix"
Variable ::: "value: $($num + 1)"
Variable ::: $env:PSTB_MATRIX
Variable ::: $(1 + 1)
Splat ::: @splatArr
Splat ::: @namedArr
Splat ::: @splatArr extra
Special ::: 'a;b'
Special ::: 'a|b'
Special ::: 'a&b'
Special ::: 'a<b>c'
Special ::: '$notvar'
Special ::: 'back`tick'
Special ::: "tab`there"
Special ::: "line1`nline2"
Special ::: '*.txt'
Special ::: 'file?.log'
Special ::: '50%'
Special ::: '%PATH%'
Special ::: 'a,b,c'
Special ::: a,b,c
Special ::: '(parens)'
Special ::: '#notcomment'
Special ::: '@notsplat'
Special ::: 'ünïcödé ✓'
Backslash ::: 'C:\dir\'
Backslash ::: 'C:\dir with space\'
Backslash ::: 'a\b'
Backslash ::: 'a\\b'
Backslash ::: 'a\"b'
Backslash ::: '\'
Backslash ::: '\\'
Backslash ::: 'trailing\\ '
Path ::: 'C:\Program Files\App\tool.exe'
Path ::: $path
Path ::: '\\server\share\file.txt'
Path ::: './relative/path'
Path ::: '..\..\up'
Path ::: 'C:/forward/slash'
Structured ::: '{"a":1,"b":"two"}'
Structured ::: '<xml attr="1"/>'
Structured ::: 'key=value;other=thing'
Structured ::: 'SELECT * FROM t WHERE x = ''y'''
Long ::: ('x' * 5000)
Long ::: (1..50)
'@

$exeRealWorld = @'
git ::: status
git ::: status --short --branch
git ::: add -A
git ::: commit -m 'fix: handle "quoted" text'
git ::: commit -m "feat: add thing" -m "longer body text"
git ::: commit --amend --no-edit
git ::: log --oneline -n 5
git ::: log --pretty=format:'%h %an %s' --since='2 weeks ago'
git ::: log --graph --decorate --all
git ::: diff HEAD~1 -- 'src/file with space.cs'
git ::: checkout -b feature/new-thing
git ::: push -u origin HEAD
git ::: push --force-with-lease origin main
git ::: config --global user.name 'Jane Doe'
git ::: -c core.autocrlf=false -c user.email=a@b.com status
git ::: rebase -i HEAD~3
git ::: grep -n -e 'TODO|FIXME' -- '*.ps1'
git ::: tag -a v1.2.3 -m 'Release v1.2.3'
git ::: clone --depth 1 https://github.com/org/repo.git 'C:\src\my repo'
git ::: stash push -m 'wip: before merge' -- src/
az ::: login --use-device-code
az ::: account set --subscription 'My Subscription'
az ::: group create --name rg-demo --location eastus
az ::: vm list --query "[?location=='eastus'].name" -o tsv
az ::: vm list --query '[].{name:name, rg:resourceGroup}' --output table
az ::: storage blob upload --account-name acct --container-name c --file 'C:\data\my file.txt' --name 'folder/my file.txt'
az ::: keyvault secret set --vault-name kv --name secret --value 'p@ss w0rd!&'
az ::: deployment group create -g rg -f main.bicep -p env=prod location=eastus
az ::: resource list --tag 'owner=team a'
az ::: webapp config appsettings set -g rg -n app --settings KEY1=value1 'KEY2=value two'
az ::: ad sp create-for-rbac --name sp --role contributor --scopes /subscriptions/0000/resourceGroups/rg
az ::: rest --method get --url 'https://management.azure.com/subscriptions?api-version=2020-01-01'
az ::: devops configure --defaults organization=https://dev.azure.com/org project='My Project'
az ::: monitor metrics list --resource $str --interval PT1H
docker ::: ps -a
docker ::: run --rm -it ubuntu:22.04 bash
docker ::: run -d -p 8080:80 --name web nginx
docker ::: run --rm -v "${PWD}:/app" -w /app node:20 npm test
docker ::: run -e KEY=value -e 'OTHER=two words' image:tag
docker ::: build -t myimage:1.0 -f Dockerfile.prod .
docker ::: build --build-arg VERSION=1.2.3 --no-cache .
docker ::: exec -it container sh -c 'echo $HOME && ls -la'
docker ::: logs --tail 100 -f container
docker ::: compose -f docker-compose.yml -f docker-compose.override.yml up -d
docker ::: images --format '{{.Repository}}:{{.Tag}}'
docker ::: inspect --format='{{json .State}}' container
kubectl ::: get pods -n kube-system -o wide
kubectl ::: get pods -l app=web,tier=frontend
kubectl ::: get pods -o jsonpath='{.items[*].metadata.name}'
kubectl ::: apply -f deployment.yaml --dry-run=client
kubectl ::: logs -f deploy/web --since=1h
kubectl ::: exec -it pod-name -- /bin/sh -c 'env | grep PATH'
kubectl ::: patch deploy web -p '{"spec":{"replicas":3}}'
kubectl ::: config set-context --current --namespace=dev
dotnet ::: build -c Release
dotnet ::: build -c Release /p:Version=1.2.3 /p:DefineConstants="A;B"
dotnet ::: test --filter 'FullyQualifiedName~MyNamespace&Category!=Slow'
dotnet ::: test --logger 'trx;LogFileName=results.trx' --collect:'XPlat Code Coverage'
dotnet ::: run --project src/App -- --port 5000 --verbose
dotnet ::: publish -r win-x64 --self-contained true -o 'C:\out dir'
dotnet ::: add package Newtonsoft.Json --version 13.0.3
dotnet ::: ef migrations add 'Initial Create'
npm ::: install
npm ::: install --save-dev typescript@5.4.0
npm ::: run build -- --watch --mode=production
npm ::: run test -- --grep 'should handle "quotes"'
npm ::: exec -- eslint 'src/**/*.ts' --fix
npm ::: config set registry https://registry.example.com/
node ::: -e "console.log(process.argv.slice(2))" a b
msbuild ::: App.sln /t:Rebuild /p:Configuration=Release /m
msbuild ::: App.sln '/p:Platform=Any CPU' /v:minimal
msbuild ::: '/t:Build;Publish' /p:OutDir='C:\out dir\'
msbuild ::: /nologo /clp:ErrorsOnly /bl:'logs\build.binlog'
curl ::: -s https://example.com
curl ::: -X POST -H 'Content-Type: application/json' -d '{"a":1,"b":"two"}' https://api.example.com/items
curl ::: -u user:pass -o 'out file.json' 'https://example.com/a?b=1&c=2'
curl ::: -H "Authorization: Bearer $str" https://api.example.com
curl ::: --data-urlencode 'q=hello world&x' -G https://example.com/search
curl ::: -L --retry 3 --max-time 30 -w '%{http_code}\n' https://example.com
robocopy ::: 'C:\src' 'D:\dst' /E /XD node_modules .git /R:1 /W:1
robocopy ::: 'C:\src dir\' 'D:\dst dir\' *.txt /S
cmd ::: /c 'dir "C:\Program Files" /b'
rmdir ::: /s /q 'C:\temp\old dir'
taskkill ::: /f /im notepad.exe /t
ffmpeg ::: -i 'in file.mp4' -vf 'scale=1280:-1,fps=30' -c:v libx264 -crf 23 'out file.mp4'
ffmpeg ::: -y -ss 00:00:10 -t 5 -i in.mp4 -an out.gif
ffmpeg ::: -i in.mp4 -filter_complex '[0:v]split=2[a][b];[a]scale=640:-1[x]' -map '[x]' out.mp4
terraform ::: plan -var 'region=us east' -var-file=prod.tfvars -out=tfplan
terraform ::: apply -auto-approve -target='module.app.aws_instance.web[0]'
terraform ::: state mv 'aws_instance.a["x"]' 'aws_instance.b["x"]'
gh ::: pr create --title 'Fix: parsing' --body 'Closes #12' --base main
gh ::: api repos/org/repo/issues -f title='New issue' -F labels[]=bug
gh ::: issue list --label 'help wanted' --json number,title --jq '.[].title'
ssh ::: user@host 'cd /var/www && ls -la'
ssh ::: -i 'C:\keys\id rsa' -p 2222 user@host
python ::: -c "import sys; print(sys.argv[1:])" 'arg one' two
python ::: -m pip install 'requests>=2.31,<3'
winget ::: install --id Microsoft.PowerShell -e --source winget --accept-package-agreements
7z ::: a -t7z -mx=9 'archive name.7z' 'C:\data\*' -xr!node_modules
pwsh ::: -NoProfile -Command "Write-Output 'nested quotes'"
'@

function ConvertTo-MatrixCase {
    param([string]$Group, [string]$Prefix, [string]$Command, [string]$Lines, [int]$StartAt = 1)

    $number = $StartAt
    foreach ($line in ($Lines -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        $category, $argText = $line -split ' :::', 2
        [PSCustomObject]@{
            Group    = $Group
            Id       = '{0}-{1:d3}' -f $Prefix, $number
            Category = $category.Trim()
            Command  = $Command
            ArgText  = "$argText".Trim()
        }
        $number++
    }
}

ConvertTo-MatrixCase -Group 'Script' -Prefix 'S' -Command 'echo-args' -Lines $scriptArgs
ConvertTo-MatrixCase -Group 'Script' -Prefix 'S' -Command 'echo-params' -Lines $scriptParams -StartAt 46
ConvertTo-MatrixCase -Group 'Script' -Prefix 'S' -Command 'echo-collide' -Lines $scriptCollide -StartAt 93
ConvertTo-MatrixCase -Group 'ExeGeneric' -Prefix 'E' -Command 'echoargs' -Lines $exeGeneric
ConvertTo-MatrixCase -Group 'ExeRealWorld' -Prefix 'R' -Command 'echoargs' -Lines $exeRealWorld
