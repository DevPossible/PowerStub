# PowerStub

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/PowerStub?label=PSGallery&color=blue)](https://www.powershellgallery.com/packages/PowerStub)
[![PowerShell Gallery Downloads](https://img.shields.io/powershellgallery/dt/PowerStub?label=Downloads&color=green)](https://www.powershellgallery.com/packages/PowerStub)
[![GitHub](https://img.shields.io/github/license/DevPossible/power-stub)](https://github.com/DevPossible/power-stub/blob/main/LICENSE.txt)

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
- **Transparent Arguments**: Everything after the command is passed to the target exactly as typed, so tool flags like `-c`, `-o` or `-v` always reach it
- **Multi-format Support**: Works with `.ps1` scripts and `.exe` executables
- **Lifecycle Prefixes**: Built-in support for `alpha.*` and `beta.*` command stages
- **Zero PATH Pollution**: Single alias (`pstb`) provides access to all your tools
- **Built-in Commands**: Search across stubs and get help for any command
- **Direct Aliases**: Create shortcut aliases for frequently used stubs
- **Git Integration**: Automatic detection and updates for Git-based stub repositories

## Installation

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

### Option 2: From GitHub Release

Download a specific release from [GitHub Releases](https://github.com/DevPossible/power-stub/releases):

1. Download the latest release `.zip` file
2. Extract to a folder (e.g., `C:\Modules\PowerStub`)
3. Import the module:

```powershell
# Import from extracted location
Import-Module C:\Modules\PowerStub\PowerStub.psd1

# Add to your PowerShell profile for persistent use
Add-Content $PROFILE "`nImport-Module 'C:\Modules\PowerStub\PowerStub.psd1'"
```

### Option 3: From Source (Development)

Clone the repository for development or to get the latest changes:

```powershell
# Clone the repository
git clone https://github.com/DevPossible/power-stub.git

# Import the module from source
Import-Module ./power-stub/PowerStub/PowerStub.psm1

# Add to your PowerShell profile for persistent use
Add-Content $PROFILE "`nImport-Module 'C:\path\to\power-stub\PowerStub\PowerStub.psm1'"
```

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
| `pstb <stub>` (no command) | | List commands in the stub |

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

Create shortcut aliases for frequently used stubs:

| Command | Description |
|---------|-------------|
| `New-PowerStubDirectAlias -AliasName <alias> -Stub <stub>` | Create a direct alias for a stub |
| `Remove-PowerStubDirectAlias -AliasName <alias>` | Remove a direct alias |

```powershell
# Create a short alias for your DevOps stub
New-PowerStubDirectAlias -AliasName "do" -Stub "DevOps"

# Now use the shorter syntax
do deploy-app -Environment prod    # Same as: pstb DevOps deploy-app -Environment prod
do                                 # List commands in DevOps

# Remove the alias when no longer needed
Remove-PowerStubDirectAlias -AliasName "do"
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

PowerStub stores its configuration in `PowerStub.json`, located in the module directory (alongside `PowerStub.psm1`):

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
| `GitEnabled` | Boolean | `true` | Enable Git integration (auto-detected on load) |

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

### Update Notifications

When the PowerStub module loads, it checks each Git-tracked stub to see if it's behind the remote repository:

```text
Stub 'DevOps' is 5 commit(s) behind the remote repo. Run 'pstb update DevOps' to update.
```

### Updating Repositories

Use the `update` command to pull the latest changes:

```powershell
# Update all Git-tracked stubs
pstb update

# Update a specific stub
pstb update DevOps
```

### Configuration

Git integration is enabled by default when Git is available. You can disable it:

```powershell
# Disable Git integration
Set-PowerStubConfigurationKey 'GitEnabled' $false

# Re-enable Git integration
Set-PowerStubConfigurationKey 'GitEnabled' $true
```

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
│   ├── PowerStub.psd1              # Module manifest
│   └── PowerStub.json              # Legacy config placeholder (the live config is %APPDATA%/PowerStub/config.json)
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

- PowerShell 5.1 or later
- [Pester](https://pester.dev/) v5.x or later for running tests

```powershell
# Install Pester if not already installed
Install-Module Pester -Force -SkipPublisherCheck
```

### Local Development Workflow

#### 1. Clone and Set Up

```powershell
git clone https://github.com/DevPossible/power-stub.git
cd power-stub
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
# Run all tests with detailed output
.\dev-test.ps1

# Run specific tests by name filter
.\dev-test.ps1 -Filter "*Alpha*"

# Run with minimal output
.\dev-test.ps1 -Output Normal

# Skip module reload (if already loaded)
.\dev-test.ps1 -SkipReload
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

The `tests/sample_stub_root/` folder contains a pre-configured stub with various command types for integration testing.

### Adding New Features

1. **New public function**: Create in `PowerStub/public/functions/Verb-PowerStub*.ps1` (lowercase `public` - the loader is case-sensitive on Linux)
2. **New private function**: Create in `PowerStub/private/functions/*.ps1`
3. **Add tests**: Add to the matching file in `tests/`
4. **Update documentation**: Update README.md and CLAUDE.md

Functions are automatically loaded by the module - no manifest changes needed.

### Code Style

- Use approved PowerShell verbs (`Get-`, `Set-`, `New-`, etc.)
- Prefix public functions with `PowerStub`
- Include `[CmdletBinding()]` on all functions
- Use `$Script:` scope for module-level variables

## Requirements

- PowerShell 5.1 or later
- Windows (primary support)

## License

Apache License 2.0 - See [LICENSE.txt](LICENSE.txt)

## Author

DevPossible LLC

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

See the [Development](#development) section above for local setup, testing, and code style guidelines.
