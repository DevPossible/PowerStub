# Audited native argument mismatches. Keep the original equality assertions; this
# file only opts these exact inputs out of the default release gate with KnownIssue.
# Remove a record (and update the audited-ID guard) when its assertion is fixed.
@{
    Cases = @(
        @{
            Id = 'E-032'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = '-k:value'
            Reason = 'Colon-style native option is rebound as a PowerShell parameter value.'
        }
        @{
            Id = 'E-034'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = '--'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'E-035'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = '-- -v'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'E-076'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'a,b,c'
            Reason = 'Unquoted comma expression is split before the native target receives it.'
        }
        @{
            Id = 'R-010'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'diff HEAD~1 -- ''src/file with space.cs'''
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-017'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'grep -n -e ''TODO|FIXME'' -- ''*.ps1'''
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-020'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'stash push -m ''wip: before merge'' -- src/'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-048'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'get pods -l app=web,tier=frontend'
            Reason = 'Unquoted comma expression is split before the native target receives it.'
        }
        @{
            Id = 'R-052'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'exec -it pod-name -- /bin/sh -c ''env | grep PATH'''
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-059'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'run --project src/App -- --port 5000 --verbose'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-065'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'run build -- --watch --mode=production'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-066'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'run test -- --grep ''should handle "quotes"'''
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-067'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'exec -- eslint ''src/**/*.ts'' --fix'
            Reason = 'Bare -- separator is consumed before the native target receives it.'
        }
        @{
            Id = 'R-085'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = '-i ''in file.mp4'' -vf ''scale=1280:-1,fps=30'' -c:v libx264 -crf 23 ''out file.mp4'''
            Reason = 'Colon-style native option is rebound as a PowerShell parameter value.'
        }
        @{
            Id = 'R-093'
            Group = 'ExeRealWorld'
            Command = 'echoargs'
            Platform = 'All'
            ArgText = 'issue list --label ''help wanted'' --json number,title --jq ''.[].title'''
            Reason = 'Unquoted comma expression is split before the native target receives it.'
        }
        # Linux's native binder expands these formerly quoted patterns after splatting.
        # Matching fixture files make both failures independent of the caller's cwd.
        @{
            Id = 'E-071'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'Linux'
            ArgText = '''*.txt'''
            Reason = 'Quoted wildcard expands to matching files through pstb on Linux.'
        }
        @{
            Id = 'E-072'
            Group = 'ExeGeneric'
            Command = 'echoargs'
            Platform = 'Linux'
            ArgText = '''file?.log'''
            Reason = 'Quoted question-mark wildcard expands to matching files through pstb on Linux.'
        }
    )
}
