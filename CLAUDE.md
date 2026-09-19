# CLAUDE.md - PowerStub Development Guide

This file provides context for Claude Code when working on the PowerStub project.

## Project Overview

PowerStub is a PowerShell module that creates command proxies ("stubs") for organizing scripts and CLI tools. Instead of adding multiple directories to PATH, users register "stubs" that serve as namespaced entry points to their tools.

**Core concept:** `pstb <StubName> <CommandName> [arguments]`

## Repository Structure

```text
PowerStub/                        # Repository root
├── PowerStub/                    # Module directory (publishable to PSGallery)
│   ├── public/functions/         # Exported user-facing functions (folder names are LOWERCASE)
│   ├── private/functions/        # Internal helper functions
│   ├── Templates/                # Command templates
│   ├── PowerStub.psm1            # Module loader (dot-sources all functions)
│   ├── PowerStub.psd1            # Module manifest (version is stamped by CI from git tags)
│   └── PowerStub.json            # Legacy config placeholder (live config: %APPDATA%/PowerStub/config.json)
├── .gitlab-ci.yml                # ACTIVE release pipeline (GitLab CI)
├── pipelines/                    # Azure DevOps Pipelines
│   └── release.yml               # DISABLED - kept for reference
├── scripts/                      # Build and deployment scripts
│   └── get-version.ps1           # Calculates version from conventional commits
├── tests/                        # Pester test files (at repo root)
├── .claude/commands/             # Claude Code slash commands
├── README.md                     # User documentation
├── CLAUDE.md                     # This file
└── LICENSE.txt                   # Apache 2.0
```

## Key Files and Their Purposes

### Public Functions (User API)

| File | Function | Purpose |
|------|----------|---------|
| `Invoke-PowerStubCommand.ps1` | Main entry point | Executes commands via `pstb` alias |
| `New-PowerStub.ps1` | Registration | Creates new stub with folder structure |
| `Remove-PowerStub.ps1` | Cleanup | Unregisters a stub from config |
| `Get-PowerStubs.ps1` | Discovery | Lists all registered stubs |
| `Get-PowerStubCommand.ps1` | Introspection | Gets command object details |
| `Get-PowerStubCommandHelp.ps1` | Help | Displays help for a stub command |
| `Search-PowerStubCommands.ps1` | Search | Searches commands across all stubs |
| `New-PowerStubDirectAlias.ps1` | Alias creation | Creates shortcut alias for a stub |
| `Remove-PowerStubDirectAlias.ps1` | Alias removal | Removes a direct alias |
| `Set-PowerStubCommandVisibility.ps1` | Lifecycle | Changes command visibility (alpha/beta/production) |
| `Get-PowerStubConfiguration.ps1` | Config read | Returns current configuration |
| `Import-PowerStubConfiguration.ps1` | Config load | Loads/resets config from JSON |
| `Enable-PowerStubBetaCommands.ps1` | Toggle | Shows beta.* prefixed commands |
| `Disable-PowerStubBetaCommands.ps1` | Toggle | Hides beta.* prefixed commands |
| `Enable-PowerStubAlphaCommands.ps1` | Toggle | Shows alpha.* prefixed commands |
| `Disable-PowerStubAlphaCommands.ps1` | Toggle | Hides alpha.* prefixed commands |

### Private Functions (Internal)

| File | Function | Purpose |
|------|----------|---------|
| `Find-PowerStubCommands.ps1` | Discovery | Finds .ps1/.exe files, filters by alpha./beta. prefix |
| `Get-PowerStubCompletion.ps1` | Completion | Tab completion for pstb lines, called by the TabExpansion2 wrapper |
| `Invoke-CheckedCommand.ps1` | Execution | Core command runner: arguments in by splat, out by splat, untouched |
| `Invoke-PowerStubUpdate.ps1` | Git | Handles the 'pstb update' virtual verb |
| `Resolve-PowerStubInvocation.ps1` | Parsing | Finds the stub, command and target arguments in a pstb call |
| `ConvertTo-Hashtable.ps1` | Utility | Converts PSObjects to hashtables |
| `Show-PowerStubOverview.ps1` | Display | Shows overview when pstb runs without args |
| `Get-PowerStubConfigurationDefaults.ps1` | Config | Returns default config structure |
| `Get-PowerStubConfigurationKey.ps1` | Config | Gets single config value |
| `Set-PowerStubConfigurationKey.ps1` | Config | Sets single config key |
| `Set-PowerStubConfiguration.ps1` | Config | Sets entire config object |
| `Export-PowerStubConfiguration.ps1` | Config | Saves config to PowerStub.json |
| `Get-PowerStubGitInfo.ps1` | Git | Gets git repo info for a path |
| `Update-PowerStubGitRepo.ps1` | Git | Updates a git repo (git pull) |
| `Get-PowerStubPath.ps1` | Utility | Extracts path from stub config (string or hashtable) |
| `Sync-PowerStubConfiguration.ps1` | Config | Reloads the config when another session changed the file |
| `Update-PowerStubConfiguration.ps1` | Config | Lock, reload, apply one change, write - the ONLY safe way to change persisted settings |
| `Enter-PowerStubConfigurationLock.ps1` | Config | Acquires the cross-process config mutex |
| `Exit-PowerStubConfigurationLock.ps1` | Config | Releases the config mutex |
| `Test-PowerStubReservedName.ps1` | Utility | Names that aliases must never shadow (git, cd, ...) |
| `Get-PowerStubCommandMetadata.ps1` | Display | Reads metadata for executable commands |
| `Show-PowerStubCommands.ps1` | Display | Lists the commands in a stub |

## Architecture Patterns

### Module Loading (PowerStub.psm1)

1. Discovers all `.ps1` files in `public/functions/` and `private/functions/` (lowercase - this matters on Linux)
2. Dot-sources each file to load functions into module scope
3. Loads configuration defaults, then imports `PowerStub.json`
4. Exports only public functions
5. Creates `pstb` alias for `Invoke-PowerStubCommand`
6. Registers ArgumentCompleters for `-Stub` and `-Command` parameters
7. Re-registers saved direct aliases from configuration

### Virtual Verbs

Virtual verbs are built-in commands that don't map to script files:

- `pstb search <query>` - Searches all stubs for commands matching query
- `pstb help <stub> <command>` - Displays PowerShell help for a command
- `pstb update [stub]` - Updates git repositories for stubs

Virtual verbs are intercepted in `Invoke-PowerStubCommand` before stub resolution.

### Git Integration

PowerStub integrates with Git to track and update stub repositories:

**Module-scoped flags:**

- `$Script:GitAvailable` - Set on module load by checking `Get-Command git`
- `$Script:GitEnabled` - Defaults to `$true` if git is available; can be disabled via config

**Stub registration:**
When creating a new stub with `New-PowerStub`, if git is enabled and the path is part of a git repository, the remote URL is automatically saved in the configuration.

**Module load behavior:**
On module load, each stub's git repo is checked. If the repo is behind the remote, a warning is displayed:

```text
Stub 'DevOps' is 5 commit(s) behind the remote repo. Run 'pstb update DevOps' to update.
```

**Update command:**

- `pstb update` - Updates all unique git repos across all stubs
- `pstb update <stub>` - Updates the specific stub's git repo

**Stub configuration format:**
Stubs can be stored in two formats:

- **Legacy (string):** Just the path: `"C:\MyStub"`
- **New (hashtable):** Path with git info: `@{ Path = "C:\MyStub"; GitRepoUrl = "https://..." }`

The `Get-PowerStubPath` helper function handles both formats transparently.

### Direct Aliases

Direct aliases provide shortcut access to frequently used stubs:

```powershell
New-PowerStubDirectAlias -AliasName "do" -Stub "DevOps"
do deploy  # Same as: pstb DevOps deploy
```

- Aliases are stored in `DirectAliases` config key
- Re-registered automatically on module load
- Support full tab completion for commands and parameters

### Argument Pass-Through (read this before touching parsing)

`Invoke-PowerStubCommand` and the generated direct-alias functions are **simple functions with no `param` block and no `[CmdletBinding()]`**. This is deliberate and must stay that way:

- An advanced function always has the common parameters, and PowerShell prefix-matches every `-flag` against them and against the function's own parameters *before any of our code runs*. As a proxy that made `dotnet build -c Release` bind `-c` to `-Command`, `curl -o file` fail as ambiguous, and `-v`/`-d`/`-e`/`-i`/`-p`/`-w` get swallowed or rejected. It cannot be switched off.
- With no parameters, every argument arrives in `$args` and is forwarded with an array splat. PowerShell keeps a hidden marker on `$args` elements that were parameter names, so `-Name x`, `-Count:5` and `-Force` still bind on script targets.
- That marker survives **slicing** (`$args[2..$n]`) and array `+`, but NOT copying elements one at a time (`$list.Add($args[$i])`), NOT a declared `[object[]]` parameter (a one-element array gets reshaped), and NOT `$x = if (...) { $slice }` (unrolls a one-element array). `Invoke-CheckedCommand` therefore takes its arguments by splat: `Invoke-CheckedCommand $path @targetArgs`.
- `-Switch:$false` is the one form a splat cannot carry; `Invoke-CheckedCommand` moves those pairs into a named splat.
- `Resolve-PowerStubInvocation` decides which tokens are the stub and command (positional, or the full names `-Stub`/`-Command` before the target's arguments). Execution and completion both use it.

`tests/ParsingMatrix.tests.ps1` runs 300 calls directly and through `pstb` and compares them. Any change here must not lower its agreement count (currently 285/300; the rest are PowerShell changing the call before pstb sees it: a bare `--` is removed, and for executables `-x:value` is split and an unquoted `a,b,c` becomes three arguments - quoting works around all three).

### Tab Completion

Because `pstb` declares no parameters, PowerShell has nothing to complete from, and `Register-ArgumentCompleter` cannot fill the gap (it is not consulted for a partly typed `-Name` on a function). The module therefore **wraps `TabExpansion2`**, the function every host calls for completion (`PowerStub.psm1` installs it, `Get-PowerStubCompletion` does the work):

- Stub position: stub names and virtual verbs. Command position: command names with alpha/beta prefixes stripped (stub names after `help`/`update`).
- After that, the line is rewritten to the direct call `& '<target path>' ...` and handed to PowerShell's original completion, so the user gets exactly what a direct call offers: parameters, partly typed names, `ValidateSet`/enum values, paths.
- The wrapper only answers for `pstb`, `Invoke-PowerStubCommand` and direct aliases. For anything else, or if it throws, it calls the original unchanged. Removing the module restores the original.
- Test completion by calling `TabExpansion2`, not `[CommandCompletion]::CompleteInput(text, pos, $null)` - that static overload bypasses the function. See `tests/Completion.tests.ps1`.

### Configuration Management

- Config stored in `$Script:PSTBSettings` hashtable
- Persisted to `%APPDATA%/PowerStub/config.json` (excludes internal keys); `POWERSTUB_CONFIG_DIR` overrides the folder
- Many sessions share this file. Rules that keep it from being wiped or overwritten:
  - Module load must NEVER write the config file
  - Change persisted settings only through `Update-PowerStubConfiguration` (lock, reload, change one entry, write). Never modify a copy of `Stubs`/`DirectAliases` and save the whole thing - that erases other sessions' changes
  - Writes replace the file in one step with `[System.IO.File]::Move(temp, file, $true)`. Do not use `Move-Item -Force`: it deletes the destination first
  - A blank or corrupt file is copied to `config.json.corrupt-<timestamp>` and ignored; it never stops the module loading
- Internal keys: `ModulePath`, `ConfigFile`, `LegacyConfigFile`, `InternalConfigKeys`, `GitAvailable`
- Config key validation warns on unknown keys to prevent typos
- `Set-PowerStubConfiguration` preserves internal keys when replacing config

### Command Discovery

Commands are discovered in the `Commands` folder within each stub. Discovery rules:

1. **Direct files**: Any `.ps1` or `.exe` file directly in `Commands/` is exposed
2. **Subfolders**: Only files matching the folder name are exposed (prevents helper scripts from appearing)

```text
Commands/
├── deploy.ps1              # EXPOSED as "deploy"
├── backup.exe              # EXPOSED as "backup"
└── complex-task/           # Subfolder
    ├── complex-task.ps1    # EXPOSED as "complex-task" (matches folder name)
    ├── helper.ps1          # NOT exposed (doesn't match folder name)
    └── data.json           # NOT exposed (not .ps1/.exe)
```

This design allows complex commands to have supporting files without polluting the command namespace.

### Command Prefix System

Commands use filename prefixes for lifecycle management:

- `alpha.my-command.ps1` - Work-in-progress (requires `EnablePrefix:Alpha`)
- `beta.my-command.ps1` - Beta testing (requires `EnablePrefix:Beta`)
- `my-command.ps1` - Production (always visible)

**Resolution precedence:** `alpha.*` → `beta.*` → production (no prefix)

When user types `pstb MyStub my-command`, the system searches in order:

1. `Commands/alpha.my-command.ps1` or `Commands/my-command/alpha.my-command.ps1` (if alpha enabled)
2. `Commands/beta.my-command.ps1` or `Commands/my-command/beta.my-command.ps1` (if beta enabled)
3. `Commands/my-command.ps1` or `Commands/my-command/my-command.ps1` (always)

The prefix is transparent to the user - they always type the unprefixed name.

## Build & Test Commands

```powershell
# Import module for development
Import-Module ./PowerStub/PowerStub.psm1 -Force

# Run Pester tests
Invoke-Pester ./tests/

# Or use the dev script
./dev-test.ps1

# View current configuration
Get-PowerStubConfiguration

# Reset configuration to defaults
Import-PowerStubConfiguration -Reset
```

## CI/CD

**Primary:** GitLab CI (`.gitlab-ci.yml`) on gitlab.devpossible.com
**Mirror:** GitHub (public mirror at DevPossible/power-stub)
**Disabled:** `pipelines/release.yml` (Azure DevOps) is kept for reference only

| Pipeline | Trigger | Purpose |
|----------|---------|---------|
| `.gitlab-ci.yml` | Push to main | Test, version, tag, mirror to GitHub, publish to PSGallery, create GitHub release |

### Pipeline Stages (in order)

1. **validate** - Verify GitHub PAT has access to the mirror repo
2. **test** - Run Pester tests in a Linux container (Windows-only EXE tests are skipped there; `KnownIssue` tests are excluded)
3. **version** - Calculate next version from git tags + conventional commits (`scripts/get-version.ps1`)
4. **mirror** - Tag the release, push the tag to GitLab, push code and tag to GitHub
5. **publish** - Stamp the version into the manifest and publish a clean copy to PowerShell Gallery
6. **release** - Create GitHub release with changelog

The version comes ONLY from git tags and commit messages. `ModuleVersion` in `PowerStub.psd1` is overwritten by CI at publish time and is never committed back, so it just records the last release.

### Required Secrets

GitLab CI/CD variables (masked and protected):

| Variable | Purpose |
|----------|---------|
| `GITHUB_PAT` | GitHub PAT for mirroring and releases |
| `GITLAB_PUSH_TOKEN` | Token with write_repository scope, for pushing release tags |
| `PSGALLERY_API_KEY` | PowerShell Gallery API key |

### Creating a Release

Releases are automatic on push to main. Version is calculated from commits:
- `feat:` commits bump MINOR version
- `fix:` commits bump PATCH version
- `!` or `BREAKING CHANGE:` bumps MAJOR version

### Claude Code Rules

**Do NOT push to main.** The user handles all releases manually using `create-release.ps1`. Claude should:

1. Make commits on the current branch (usually `develop`)
2. Never run `git push origin main` or `create-release.ps1`
3. Let the user decide when to trigger a release

## Conventional Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org/) for automated versioning and changelog generation.

### Commit Format

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### Types

| Type | Use For | Version Bump |
|------|---------|--------------|
| `feat` | New feature | MINOR |
| `fix` | Bug fix | PATCH |
| `docs` | Documentation | PATCH |
| `style` | Formatting (no code change) | PATCH |
| `refactor` | Code change (no feature/fix) | PATCH |
| `perf` | Performance | PATCH |
| `test` | Tests | PATCH |
| `build` | Build/dependencies | PATCH |
| `ci` | CI/CD config | PATCH |
| `chore` | Maintenance | PATCH |

### Breaking Changes

Add `!` after the type or include `BREAKING CHANGE:` in footer:

```
feat!: remove deprecated API endpoint

BREAKING CHANGE: The /v1/users endpoint has been removed
```

### Examples

```
feat(alias): add support for multiple aliases per stub
fix(config): prevent null reference when config file missing
docs: update README with new installation steps
refactor(commands): simplify command discovery logic
ci: add PSGallery publish stage to pipeline
```

### Scopes (optional)

Common scopes for this project: `config`, `commands`, `alias`, `completion`, `git`

## Common Development Tasks

### Adding a New Public Function

1. Create file in `PowerStub/public/functions/` (lowercase)
2. Follow naming convention: `Verb-PowerStub*.ps1`
3. Function is auto-exported via module loader

### Adding a New Private Function

1. Create file in `PowerStub/private/functions/` (lowercase)
2. Function is auto-loaded but not exported

### Adding New Configuration Keys

1. Add default value in `Get-PowerStubConfigurationDefaults.ps1`
2. If internal-only, add to `InternalConfigKeys` array
3. Use `Set-PowerStubConfigurationKey` to modify at runtime

## Known Issues / TODO

Command parsing is delicate: change it deliberately, and check the parsing matrix (see Argument Pass-Through).

- `$?`, `&&` and `||` see success after a failed command; only `$LASTEXITCODE` is reliable. Expected-to-fail tests are in `tests/KnownIssues.tests.ps1`.
- The 15 parsing-matrix calls that still differ from a direct call: a bare `--` is removed by PowerShell before pstb sees it, and for executables `-x:value` is split and an unquoted `a,b,c` becomes three arguments. Quoting (`'--'`, `'-c:v'`, `'a,b,c'`) works around all three.
- By design, an explicit string array splat such as `@('-Name', 'x')` is passed as plain values, exactly as in a direct call. (pstb used to re-parse it into named parameters.) Forwarding the automatic `$args` with `@args` still carries parameter names.

## Code Style Guidelines

- Use approved PowerShell verbs (Get-, Set-, New-, Remove-, Enable-, Disable-, Invoke-, Import-, Export-)
- Prefix all public functions with `PowerStub` (e.g., `Get-PowerStubs`)
- Use `$Script:` scope for module-level variables
- Include `[CmdletBinding()]` on all functions
- Use argument completers for better UX

## Testing Approach

Tests use Pester framework (`tests/*.tests.ps1`). Every test file sets `POWERSTUB_CONFIG_DIR` to a throwaway folder before importing the module, so tests never touch the real config - keep that in any new test file. `tests/KnownIssues.tests.ps1` holds expected-to-fail tests for unfixed bugs (tag `KnownIssue`, excluded from `dev-test.ps1` and CI; run with `./dev-test.ps1 -Tag KnownIssue`). `tests/ParsingMatrix.tests.ps1` runs 300 sample calls (`ParsingMatrix.cases.ps1`: scripts, a generic EXE group and real-world CLI command lines) both directly and through `pstb` and requires identical results; it is tagged `ParsingMatrix`, also excluded by default, and `./tests/Show-ParsingMatrix.ps1` summarizes the disagreements. Any change to argument parsing must not lower its agreement count. Key test areas:

- Configuration loading/saving
- Stub registration/removal
- Alias creation
- Module exports
- Folder structure creation
- Alpha/beta prefix precedence
- Command discovery (direct files and subfolders)
- Dynamic parameters and tab completion (using TabExpansion2)
- Smart parameter filtering (filters already-bound positional params)
- Direct aliases (create, remove, persistence, tab completion)
- Virtual verbs (search, help commands)
- Command visibility changes (alpha/beta/production lifecycle)
- Private function unit tests (ConvertTo-Hashtable, Get-PowerStubPath, etc.)
- Error paths (unregistered stubs, missing commands, invalid config)
- WhatIf/ShouldProcess support
- Subfolder command visibility changes

## Claude Commands

Custom slash commands available in `.claude/commands/`:

| Command | Purpose |
|---------|---------|
| `/new-command <stub> <name> [desc]` | Create a new command script in a stub |
| `/test` | Run Pester tests for the module |
| `/debug-config` | Diagnose configuration issues |
| `/add-function <scope> <name> [desc]` | Add a new module function (public/private) |
| `/list-commands [stub]` | List all commands in a stub |

## Recommended Sub-Agents

When working on this codebase, consider using these specialized agents:

### For Exploration Tasks

Use the **Explore** agent for:

- Understanding how dynamic parameters flow through the system
- Finding all places where configuration is read/written
- Tracing command execution path from `pstb` to actual script

### For Implementation Planning

Use the **Plan** agent for:

- Adding new features like additional file type support (.bat, .cmd)
- Centralizing supported file extensions into a configuration constant
- Adding new virtual verbs (currently hardcoded in a data structure)

## PowerShell-Specific Tips

### Testing Commands Interactively

```powershell
# Reload module after changes
Import-Module ./PowerStub/PowerStub.psm1 -Force

# Test tab completion
pstb <Tab>                    # Should list stubs
pstb DevOps <Tab>            # Should list commands in DevOps
pstb DevOps deploy -<Tab>    # Should list command parameters
```

### Debugging Dynamic Parameters

```powershell
# Get the command object to inspect parameters
$cmd = Get-PowerStubCommand -Stub "StubName" -Command "CommandName"
$cmd.Parameters.Keys

# Or inspect directly
Get-Command "path/to/script.ps1" | Select-Object -ExpandProperty Parameters
```

### Common Pitfalls

1. **Module scope variables**: Use `$Script:` prefix for module-level state
2. **Completion**: comes from the `TabExpansion2` wrapper, not from parameters or `Register-ArgumentCompleter`
3. **Never add a `param` block or `[CmdletBinding()]` to `Invoke-PowerStubCommand`**: see Argument Pass-Through
4. **Exit code handling**: `.exe` files set `$LASTEXITCODE`, scripts may not
