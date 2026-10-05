# PowerStub

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PowerStub?label=PSGallery&color=blue)](https://www.powershellgallery.com/packages/PowerStub)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/PowerStub?label=Downloads&color=green)](https://www.powershellgallery.com/packages/PowerStub)
[![GitHub](https://img.shields.io/github/license/DevPossible/PowerStub)](https://github.com/DevPossible/PowerStub/blob/main/LICENSE.txt)

A PowerShell module for organizing scripts, executables, and CLI tools using command proxies. Stop cluttering your PATH - organize your tools into logical namespaces and access them through a single entry point.

## The Problem

As your collection of PowerShell scripts and CLI tools grows, you face a common challenge:

- Scripts scattered across multiple directories
- Adding every folder to PATH becomes unmanageable
- No logical organization for related tools
- Difficult to remember where each tool lives

## The Solution

PowerStub creates **command proxies** (called "stubs") that serve as namespaced entry points to your organized tools:

```powershell
# Instead of remembering paths or adding to PATH:
C:\Tools\DevOps\Scripts\Deployment\deploy-app.ps1 -Environment prod

# Use a simple, organized command:
pstb DevOps deploy-app -Environment prod
```

## Features

- **Namespace Organization**: Group related tools under logical stub names
- **Tab Completion**: Full IntelliSense for stub names, commands, and parameters
- **Argument Forwarding**: Pass target arguments and tool flags such as `-c`, `-o`, and `-v` through a namespaced command. See [Argument behavior](#argument-behavior) for quoting and automation guidance
- **Multi-format Support**: Works with `.ps1` scripts and `.exe` executables
- **Lifecycle Prefixes**: Built-in support for `alpha.*` and `beta.*` command stages
- **Zero PATH Pollution**: Single alias (`pstb`) provides access to all your tools
- **Built-in Commands**: Search across stubs and get help for any command
- **Direct Aliases**: Create shortcut aliases for frequently used stubs
- **Git Integration**: Detect Git-based stub repositories, get notified in the background when one is behind, and check or pull updates

## Installation

Requires **PowerShell 7.0 or later** (`pwsh`), not Windows PowerShell 5.1. Git is optional and is required only for Git-backed stub features.

### Option 1: From PowerShell Gallery (Recommended)

The easiest way to install PowerStub:

```powershell
# Install from PowerShell Gallery
Install-Module -Name PowerStub -Scope CurrentUser

# Import the module
Import-Module PowerStub

# Add to your PowerShell profile for persistent use
Add-Content $PROFILE "`nImport-Module PowerStub"
```

### Option 2: From a GitHub Source Archive

[GitHub Releases](https://github.com/DevPossible/PowerStub/releases) provides automatic **Source code (zip)** archives. These are source snapshots, not separately built module ZIP assets.

1. Select the release tag you want and download **Source code (zip)**.
2. Extract it. For example, a `v2.0.0` archive extracts to `PowerStub-2.0.0/`.
3. Import the manifest in the **nested** `PowerStub/` module directory:

```powershell
Import-Module 'C:\Modules\PowerStub-2.0.0\PowerStub\PowerStub.psd1'
```

Replace `2.0.0` with the archive's actual tag. The source manifest has a development baseline version; CI stamps the Gallery package separately. Record the selected tag (or commit for a Git checkout) as the source identity. Use the Gallery package if you need `Get-Module PowerStub` to report the published release version.

### Option 3: From Source (Development)

Clone the repository for development or to get the latest changes:

```powershell
git clone https://github.com/DevPossible/PowerStub.git
Import-Module ./PowerStub/PowerStub/PowerStub.psd1

# Record the exact source revision
git -C ./PowerStub rev-parse HEAD
```

Use the manifest for ordinary imports so the PowerShell requirement and public export list are enforced.

### Making PowerStub Available in Every Session

After installing the module, you need to add it to your PowerShell profile so it loads automatically. If you haven't already done so during installation:

```powershell
# Add PowerStub to your profile (PSGallery install)
Add-Content -Path $PROFILE -Value "`nImport-Module PowerStub"

# Or for a custom path (GitHub/Source install)
Add-Content -Path $PROFILE -Value "`nImport-Module 'C:\path\to\PowerStub\PowerStub.psd1'"
```

Then reload your profile to apply the changes without restarting PowerShell:

```powershell
. $PROFILE
```

Verify the module is loaded and the `pstb` alias is available:

```powershell
pstb
```

You should see the PowerStub overview with any registered stubs and built-in commands.

> **Note:** If `$PROFILE` doesn't exist yet, create it first with:
>
> ```powershell
> New-Item -Path $PROFILE -ItemType File -Force
> ```

## Quick Start

### 1. Create a New Stub

```powershell
# Register a stub for your DevOps tools
New-PowerStub -Name "DevOps" -Path "C:\Tools\DevOps"
```

This creates the following folder structure:

```text
C:\Tools\DevOps\
├── Commands\       # Your commands go here
└── .tests\         # Test files
```

### 2. Add Commands

Place your scripts or executables in the `Commands` folder:

```powershell
# C:\Tools\DevOps\Commands\deploy-app.ps1
param(
    [Parameter(Mandatory)]
    [string]$Environment,

    [string]$Version = "latest"
)

Write-Host "Deploying to $Environment with version $Version"
```

#### Complex Commands with Supporting Files

For commands that need helper scripts, data files, or executables, create a subfolder with the command name. Only the file matching the folder name is exposed as a command:

```text
Commands/
├── simple-task.ps1              # Exposed as "simple-task"
├── quick-deploy.exe             # Exposed as "quick-deploy"
└── complex-deploy/              # Subfolder for complex command
    ├── complex-deploy.ps1       # Exposed as "complex-deploy"
    ├── deploy-helper.ps1        # NOT exposed (helper script)
    ├── config.json              # NOT exposed (data file)
    └── validator.exe            # NOT exposed (helper executable)
```

This prevents helper scripts from appearing in tab completion or being accidentally invoked as commands.

### 3. Use Your Commands

```powershell
# Tab completion works for stub names
pstb Dev<TAB>  # Completes to "DevOps"

# Tab completion works for commands
pstb DevOps dep<TAB>  # Completes to "deploy-app"

# Tab completion works for parameters
pstb DevOps deploy-app -Env<TAB>  # Completes to "-Environment"

# Execute the command
pstb DevOps deploy-app -Environment prod -Version 2.0.1
```

### Argument behavior

For ordinary script parameters and native flags, use `pstb DevOps deploy-app -Environment prod` or a direct alias. Proxy calls run through a PowerShell function boundary, so native parsing is not identical in every case:

- A bare `--` is removed before the proxy sees it; quote it as `'--'` when you need that argument.
- Quote native colon-form flags and comma-containing values, for example `'-c:v'` and `'a,b,c'`.
- On Linux, quoted native globs can still expand through a proxy when matching files exist. Caller-local `$PSNativeCommandArgumentPassing` preferences can also differ inside a module proxy.

When exact native parsing matters, resolve the command and invoke it directly in your caller scope. This preserves the original native argument processing, output streams, and exit status:

```powershell
# Resolve a registered native tool, then call it directly
& (Get-PowerStubCommand -Stub DevOps -Command terraform).Path plan -out=tfplan
```

Use that form for the edge cases above or native tools sensitive to argument-passing modes. The regression suite retains 15 shared native mismatches and two additional Linux quoted-glob mismatches as explicit known issues; the resolved-path form is tested against all 17 inputs. These limitations apply to both `pstb` and direct aliases.

Proxy failure status is covered by tests for `$?`, `&&`, `||`, and `$LASTEXITCODE`. As with a direct native command, use the tool's documented exit codes to decide whether to continue automation. An explicit string array splat such as `@('-Name', 'x')` stays ordinary string values; use PowerShell's normal named-argument syntax for script parameters.

## Core Commands

### Stub Management

| Command | Description |
|---------|-------------|
| `New-PowerStub -Name <name> -Path <path>` | Register a new stub and create folder structure |
| `Remove-PowerStub -Name <name>` | Unregister a stub (files remain) |
| `Get-PowerStubs` | List all registered stubs |
| `Get-PowerStubCommand -Stub <name> -Command <cmd>` | Get command object details |

### Invocation

| Command | Alias | Description |
|---------|-------|-------------|
| `Invoke-PowerStubCommand -Stub <name> -Command <cmd>` | `pstb` | Execute a command from a stub |
| `pstb` (no args) | | Show overview with stubs and built-in commands |
| `pstb <stub>` (no command) | | Show commands sorted by name with summaries from their `.SYNOPSIS` headers |

Direct aliases without arguments show the same command table. Commands without help
headers show `-` for their synopsis; executables use their metadata file's synopsis.

### Built-in Commands

These virtual commands work across all stubs without needing script files:

| Command | Description |
|---------|-------------|
| `pstb search <query>` | Search commands by name or help text across all stubs |
| `pstb help <stub> <command>` | Display PowerShell help for a specific command |
| `pstb update [stub]` | Update Git repositories for stubs |

```powershell
# Find all commands related to "deploy"
pstb search "deploy"

# Get detailed help for a command
pstb help DevOps deploy-app

# Update all Git-tracked stubs
pstb update

# Update a specific stub's Git repository
pstb update DevOps
```

### Direct Aliases

Direct alias names must be unused. PowerShell keywords, existing aliases, functions,
cmdlets, native commands, and already saved direct aliases are rejected case-insensitively.
`-Force` is retained for compatibility but never bypasses this check. To change a saved
shortcut, remove it explicitly and create it again. Rejected adds leave commands and
configuration unchanged.

**Upgrading to 2.0:** `-Force` no longer refreshes or retargets an existing shortcut.
Create each direct alias once; your profile should import PowerStub rather than rerun
`New-PowerStubDirectAlias -Force` on every startup. To retarget an alias you own, use
`Remove-PowerStubDirectAlias` first, then add the desired shortcut with an unused name.

Saved shortcuts are restored only into free names when a session or profile loads the
module. Legacy `ForcedDirectAliases` entries cannot override another command. Removing
an alias, stub, or the module removes only the exact proxy function PowerStub created;
a function the user replaced it with is left alone.

A configured `InvokeAlias` that is reserved or already taken is skipped with a warning.
PowerStub uses `pstb` only if that name is free; otherwise call `Invoke-PowerStubCommand`
directly. Startup does not rewrite the saved configuration.

Create shortcut aliases for frequently used stubs:

| Command | Description |
|---------|-------------|
| `New-PowerStubDirectAlias -AliasName <alias> -Stub <stub>` | Create a direct alias for a stub |
| `Remove-PowerStubDirectAlias -AliasName <alias>` | Remove a direct alias |

```powershell
# Create a short alias for your DevOps stub
New-PowerStubDirectAlias -AliasName "dv" -Stub "DevOps"

# Now use the shorter syntax
dv deploy-app -Environment prod    # Same as: pstb DevOps deploy-app -Environment prod
dv                                 # List commands in DevOps

# Remove the alias when no longer needed
Remove-PowerStubDirectAlias -AliasName "dv"
```

Direct aliases are persisted and automatically restored when the module loads.

### Configuration Commands

| Command | Description |
|---------|-------------|
| `Get-PowerStubConfiguration` | View current configuration |
| `Import-PowerStubConfiguration` | Reload configuration from file |
| `Import-PowerStubConfiguration -Reset` | Reset to defaults |

### Feature Toggles

| Command | Description |
|---------|-------------|
| `Enable-PowerStubAlphaCommands` | Show `alpha.*` prefixed commands |
| `Disable-PowerStubAlphaCommands` | Hide alpha commands |
| `Enable-PowerStubBetaCommands` | Show `beta.*` prefixed commands |
| `Disable-PowerStubBetaCommands` | Hide beta commands |
| `Set-PowerStubCommandVisibility -Stub <s> -Command <c> -Visibility <v>` | Change command lifecycle stage |

```powershell
# Promote a command from production to alpha (work-in-progress)
Set-PowerStubCommandVisibility -Stub DevOps -Command deploy -Visibility Alpha

# Promote to beta testing
Set-PowerStubCommandVisibility -Stub DevOps -Command deploy -Visibility Beta

# Release to production
Set-PowerStubCommandVisibility -Stub DevOps -Command deploy -Visibility Production
```

## Configuration File

PowerStub stores registrations and settings in a version-independent `config.json`:

- `$env:POWERSTUB_CONFIG_DIR/config.json` when that override is set before import
- `$env:APPDATA/PowerStub/config.json` when `APPDATA` is set (normally Windows)
- `$HOME/.config/powerstub/config.json` otherwise

Use the exported command to find the actual file:

```powershell
$configPath = Get-PowerStubConfiguration -Key ConfigFile
$configPath
# A file is created when you first save a registration or setting.
if (Test-Path -LiteralPath $configPath) {
    Copy-Item -LiteralPath $configPath -Destination "$configPath.backup"
}
```

Back up this file before resetting or manually changing it. `Import-PowerStubConfiguration -Reset` saves defaults and clears registrations, direct aliases, and customized settings; it does not delete your tool folders. Start a new PowerShell session after a reset so restored shortcuts and module-load settings match the file. When no current file exists, an older module-local `PowerStub.json` with registrations can be migrated automatically; the legacy source is retained. Configuration is not stored beside the installed module.

The persisted JSON looks like this (Git-backed stubs can instead store a `Path` and `GitRepoUrl` object):

```json
{
  "Stubs": {
    "DevOps": "C:\\Tools\\DevOps\\",
    "Database": "C:\\Tools\\Database\\"
  },
  "InvokeAlias": "pstb",
  "EnablePrefix:Alpha": false,
  "EnablePrefix:Beta": false
}
```

### Configuration Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `Stubs` | Object | `{}` | Map of stub names to root paths (or config objects with GitRepoUrl) |
| `InvokeAlias` | String | `pstb` | Alias for `Invoke-PowerStubCommand` |
| `EnablePrefix:Alpha` | Boolean | `false` | Include `alpha.*` prefixed commands |
| `EnablePrefix:Beta` | Boolean | `false` | Include `beta.*` prefixed commands |
| `GitEnabled` | Boolean | `true` | Allow Git integration when Git is installed; loaded when the module imports |
| `UpdateCheckIntervalHours` | Number | `4` | How often running a command checks its stub's repository for updates in the background; `0` turns the check off |

## Command Lifecycle

PowerStub supports organizing commands by development stage using filename prefixes:

```text
YourStub/Commands/
├── alpha.new-feature.ps1   # Work in progress (Enable-PowerStubAlphaCommands)
├── beta.deploy-v2.ps1      # Beta testing (Enable-PowerStubBetaCommands)
├── deploy.ps1              # Production-ready (always visible)
└── complex-task/           # Subfolder for complex command
    ├── alpha.complex-task.ps1   # Alpha version (file matches folder name)
    └── complex-task.ps1         # Production version
```

**Prefix conventions:**

- `alpha.*` - Work-in-progress commands (developer mode)
- `beta.*` - Beta/experimental commands (tester mode)
- No prefix - Production-ready commands

**Workflow:**

1. Create new commands with `alpha.` prefix (e.g., `alpha.my-feature.ps1`)
2. Rename to `beta.` prefix when ready for testing
3. Remove prefix for production use

**Resolution precedence:** `alpha.*` → `beta.*` → production (no prefix)

When multiple versions exist (e.g., `alpha.deploy.ps1`, `beta.deploy.ps1`, `deploy.ps1`),
the command resolves in precedence order based on enabled modes. This applies to both direct files and files in subfolders.

## Git Integration

PowerStub integrates with Git to help you keep your stub repositories up to date.

### Automatic Detection

When you register a new stub with `New-PowerStub`, PowerStub automatically detects if the path is part of a Git repository and saves the remote URL in the configuration.

```powershell
# If C:\Tools\DevOps is a Git repo, the remote URL is saved automatically
New-PowerStub -Name "DevOps" -Path "C:\Tools\DevOps"
```

### Automatic Update Notices

When you run a command from a stub in a Git repository, PowerStub tells you if the repository is behind its remote:

```text
You do not have the latest version of 'DevOps' (3 commit(s) behind). Run 'pstb update DevOps' to get the latest version.
```

The check never slows the command down. The command only reads the result of the last check. When that result is older than `UpdateCheckIntervalHours` (4 hours by default), a new `git fetch` runs in a hidden background process, so its result appears on a later run. The notice is shown once per repository per PowerShell session, through `Write-Host`, so it never mixes with a command's output. `pstb update` clears it.

Checks are per stub, so stubs inside and outside Git repositories can be mixed. Nothing is checked or shown when:

- Git is not installed, or `GitEnabled` is `false`
- the stub is not in a Git repository, or its branch has no upstream
- `UpdateCheckIntervalHours` is `0`
- the `POWERSTUB_NO_UPDATE_CHECK` environment variable is set (to anything but `0` or `false`)
- the session is not interactive: a CI job (`CI` or `TF_BUILD` is set) or `pwsh -NonInteractive`

A fetch that fails, for example offline or when the remote needs credentials, shows nothing. The background check never prompts for credentials. Results are kept in an `update-check` folder next to `config.json`, never in `config.json` itself.

### Checking for Updates

Importing PowerStub does **not** fetch or check repositories. To check right away, run:

```powershell
# Check all Git-tracked stubs without pulling
pstb update --check

# Check one stub
pstb update DevOps --check
```

These commands contact the configured remotes. An unsuccessful fetch cannot establish whether a repository is current.

### Updating Repositories

Use the `update` command to pull the latest changes:

```powershell
# Update all Git-tracked stubs
pstb update

# Update a specific stub
pstb update DevOps
```

### Configuration

Git integration is enabled by default when Git is available. There is no exported generic setting-change command. To disable it, close other PowerShell sessions that may write the shared config, then run this in the remaining session:

<!-- smoke:git-setting:start -->
```powershell
$configPath = Get-PowerStubConfiguration -Key ConfigFile
$moduleManifest = Join-Path (Get-Module PowerStub).ModuleBase 'PowerStub.psd1'
$config = @{}
if (Test-Path -LiteralPath $configPath) {
    Copy-Item -LiteralPath $configPath -Destination "$configPath.backup" -Force
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
}
$config['GitEnabled'] = $false
$config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $configPath
Remove-Module PowerStub
Import-Module $moduleManifest
```
<!-- smoke:git-setting:end -->

To re-enable it, repeat with `$config['GitEnabled'] = $true`. Reimport is required because Git availability/enabled flags are initialized at module load. Prefer public registration and feature-toggle commands for normal changes; they use the module's cross-session locking rather than replacing the whole file.

## Examples

### Register Multiple Stubs

```powershell
New-PowerStub -Name "DevOps" -Path "C:\Tools\DevOps"
New-PowerStub -Name "Database" -Path "C:\Tools\Database"
New-PowerStub -Name "Azure" -Path "C:\Tools\Azure"

# View all stubs
Get-PowerStubs
# Output:
# Name                           Value
# ----                           -----
# DevOps                         C:\Tools\DevOps\
# Database                       C:\Tools\Database\
# Azure                          C:\Tools\Azure\
```

### Work with Alpha Commands

```powershell
# Enable alpha visibility
Enable-PowerStubAlphaCommands

# Now alpha.* prefixed commands appear in completion
pstb DevOps <TAB>  # Shows both production and alpha commands

# Run an alpha command (no need to type the prefix)
pstb DevOps my-feature  # Executes alpha.my-feature.ps1

# Disable when done developing
Disable-PowerStubAlphaCommands
```

### Use with Executables

PowerStub works with `.exe` files too:

```powershell
# Place terraform.exe in your stub folder
# C:\Tools\DevOps\Commands\terraform.exe

# Use it through PowerStub
pstb DevOps terraform init
pstb DevOps terraform plan -out=tfplan
```

## Architecture

```text
PowerStub/                          # Repository root
├── PowerStub/                      # Module folder (publishable to PSGallery)
│   ├── public/functions/           # Exported user-facing functions (folder names are lowercase)
│   ├── private/functions/          # Internal helper functions
│   ├── Templates/                  # Command templates
│   ├── PowerStub.psm1              # Module loader
│   └── PowerStub.psd1              # Module manifest (live config is stored separately)
├── tests/                          # Pester test files
│   ├── PowerStub.tests.ps1         # Main test suite
│   ├── ConfigSafety.tests.ps1      # Config persistence, concurrency and alias safety
│   ├── ExecutionStatus.tests.ps1   # Success/failure status, chains, streams, and process exits
│   └── sample_stub_root/           # Sample stub for integration tests
├── dev-reload.ps1                  # Reload module for local testing
├── dev-test.ps1                    # Run Pester test suite
├── README.md
├── CLAUDE.md                       # Development guide for Claude Code
└── LICENSE.txt                     # Apache 2.0
```

## Development

This section covers local development and testing of the PowerStub module.

### Prerequisites

- PowerShell 7.0 or later (`pwsh`)
- [Pester](https://pester.dev/) v5.x or later for running tests
- On Linux, `sh` and `jq` for offline release API tests; a C compiler and headers for the full native parsing matrix (CI installs these)

```powershell
# Install Pester if not already installed
Install-Module Pester -Force -SkipPublisherCheck
```

### Local Development Workflow

#### 1. Clone and Set Up

```powershell
git clone https://github.com/DevPossible/PowerStub.git
cd PowerStub
```

#### 2. Load the Module for Testing

Use the `dev-reload.ps1` script to import the module from source:

```powershell
# Load/reload the module
.\dev-reload.ps1

# Load and reset configuration to defaults
.\dev-reload.ps1 -Reset
```

This script:

- Removes any existing PowerStub module from the session
- Imports the module from local source (`PowerStub/PowerStub.psm1`)
- Shows module info and current configuration

#### 3. Make Changes

Edit files in the `PowerStub/` folder:

- **Public functions**: `PowerStub/public/functions/` - Exported to users
- **Private functions**: `PowerStub/private/functions/` - Internal helpers

After making changes, reload the module to test:

```powershell
.\dev-reload.ps1
```

#### 4. Run Tests

Use the `dev-test.ps1` script to run the Pester test suite:

```powershell
# Run the release gate (all tests except explicitly tagged known defects)
.\dev-test.ps1

# Run specific tests by name filter
.\dev-test.ps1 -Filter "*Alpha*"

# Run with minimal output
.\dev-test.ps1 -Output Normal

# Skip module reload (if already loaded)
.\dev-test.ps1 -SkipReload

# Run passing parsing-matrix cases and metadata guards
.\dev-test.ps1 -Tag ParsingMatrix

# Audit the entire matrix, including known failing equivalence assertions
.\dev-test.ps1 -Tag ParsingMatrix -IncludeKnownIssues

# Run only explicitly tagged known defects
.\dev-test.ps1 -Tag KnownIssue
```

#### 5. Interactive Testing

Test your changes interactively using the sample stub:

```powershell
# Reload module
.\dev-reload.ps1 -Reset

# Register the sample stub from tests
New-PowerStub -Name "Sample" -Path ".\tests\sample_stub_root" -Force

# Test command discovery
Get-PowerStubCommand -Stub "Sample" -Command "deploy"

# Test command execution
pstb Sample deploy -Environment "test"

# Test alpha/beta features
Enable-PowerStubAlphaCommands
pstb Sample new-feature -Name "MyFeature"
Disable-PowerStubAlphaCommands
```

### Test Structure

Tests are located in `tests/*.tests.ps1`. They run against a throwaway config folder (via the `POWERSTUB_CONFIG_DIR` environment variable), never your real configuration. They cover:

| Area | Description |
|------|-------------|
| Module Loading | Exports, aliases, private function isolation |
| Configuration | Get/set/reset configuration values |
| Stub Management | Register, remove, list stubs |
| Command Discovery | Direct files, subfolders, helper isolation |
| Alpha/Beta Prefixes | Enable/disable, precedence order |
| Command Execution | Parameter passing, output capture |
| Direct Aliases | Create, remove, tab completion for aliases |
| Virtual Verbs | Search and help built-in commands |

`tests/ExecutionStatus.tests.ps1` verifies `$?`, `&&`, `||`, `$LASTEXITCODE`, output streams, and fresh `pwsh -Command` process exits for scripts and native commands through both `pstb` and direct aliases. These regressions run in the regular test suite and CI.

`tests/ParsingMatrix.tests.ps1` compares 300 identical direct/`pstb`/direct-alias inputs. The default gate includes every passing case, with only the exact inputs in `tests/ParsingMatrix.KnownIssues.psd1` tagged `KnownIssue`: 15 shared native mismatches plus two Linux-only quoted-glob mismatches (`E-071`, `E-072`). The original equivalence assertions remain active when explicitly requested. It also gates 17 direct resolved-path workarounds and three caller-local native preference cases, for 322 total tests including two metadata guards. The Linux matrix gate passes 305 tests with 17 known issues excluded; the expected Windows gate is 307 with 15 excluded and requires a Windows run to verify. Metadata guards pin the audited IDs, argument text, platforms, and exclusion counts; matching temporary files make glob checks independent of your working directory.

The native matrix compiles a temporary executable using .NET Framework `csc.exe` on Windows, or `cc`, `gcc`, or `clang` with C development headers on Linux. The Linux fixture checks actual argv; Windows also checks the raw command line. Without a supported compiler, local runs warn and skip native cases. GitLab CI installs the Linux compiler and sets `POWERSTUB_REQUIRE_NATIVE_MATRIX=1`, so missing native coverage fails the release gate. Matrix tests restore the original working directory and environment overrides.

The `tests/sample_stub_root/` folder contains a pre-configured stub with various command types for integration testing.

### Adding New Features

1. **New public function**: Create in `PowerStub/public/functions/Verb-PowerStub*.ps1` (lowercase `public` - the loader is case-sensitive on Linux)
2. **New private function**: Create in `PowerStub/private/functions/*.ps1`
3. **Add tests**: Add to the matching file in `tests/`
4. **Update documentation**: Update README.md and CLAUDE.md

Functions are automatically loaded by the module, but a new public function must also be added to `FunctionsToExport` in `PowerStub/PowerStub.psd1`. Test the manifest import, not just the `.psm1`, to catch missing exports. Private helpers must stay out of the manifest export list.

### Code Style

- Use approved PowerShell verbs (`Get-`, `Set-`, `New-`, etc.)
- Prefix public functions with `PowerStub`
- Use `[CmdletBinding()]` for ordinary advanced functions when appropriate. Keep `Invoke-PowerStubCommand` and generated transparent proxy functions simple, without a parameter block or common parameters, so target flags are not consumed by the proxy
- Use `$Script:` scope for module-level variables

## Requirements

- PowerShell 7.0 or later (`pwsh`)
- Windows (primary platform) and Linux
- CI currently gates Linux. Windows release validation must be run separately; the old Azure pipeline is disabled

## License

Apache License 2.0 - See [LICENSE.txt](LICENSE.txt)

## Author

DevPossible LLC

## Contributing

Contributions are welcome through [GitHub issues and pull requests](https://github.com/DevPossible/PowerStub). GitHub is the public mirror; the authoritative repository and release pipeline run in private GitLab. Maintainers review public contributions and import accepted changes there, then the release pipeline mirrors them back to GitHub. Public GitHub activity alone does not establish the private pipeline's status.

For a reproducible bug report, include your OS, `$PSVersionTable.PSVersion`, module version and install method, a minimal command, and its direct-versus-proxy output. Remove credentials and private paths before posting.

See the [Development](#development) section above for local setup, testing, and code style guidelines.
