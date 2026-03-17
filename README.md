# Multi-Account Switcher for Claude Code

[![CI](https://github.com/ming86/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/ming86/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/ming86/cc-account-switcher?style=flat&color=blue)](https://github.com/ming86/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-brightgreen)](https://github.com/ming86/cc-account-switcher)
[![Shell](https://img.shields.io/badge/shell-bash%204.4%2B-89e051)](https://github.com/ming86/cc-account-switcher)
[![Tests](https://img.shields.io/badge/tests-85%20passing-success)](https://github.com/ming86/cc-account-switcher/actions)

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Features

- **Multi-account management** — Add, remove, and list Claude Code accounts
- **Quick switching** — Rotate accounts or switch to a specific one by number, email, or profile name
- **Named profiles** — Give accounts friendly names like `work` or `personal`
- **Directory-based auto-switching** — Map directories to accounts and auto-switch when you `cd`
- **Dry-run mode** — Preview what a switch would do without making changes
- **Rollback** — Automatic rollback if a switch fails mid-way
- **Diagnostics** — Health checks, status, and per-account usage statistics
- **Cross-platform** — Works on macOS, Linux, and WSL
- **Secure storage** — Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation** — Only switches authentication; themes, settings, and preferences stay unchanged

## Installation

### curl (quickest)

```bash
curl -fsSL https://raw.githubusercontent.com/ming86/cc-account-switcher/main/ccswitch.sh -o /usr/local/bin/ccs
chmod +x /usr/local/bin/ccs
```

### Homebrew (macOS)

```bash
brew install ming86/tap/ccswitch
```

### npm / npx

```bash
# Install globally
npm install -g cc-account-switcher

# Or run without installing
npx cc-account-switcher --help
```

### Make

```bash
git clone https://github.com/ming86/cc-account-switcher.git
cd cc-account-switcher
sudo make install
```

### Manual

Download `ccswitch.sh` from the [latest release](https://github.com/ming86/cc-account-switcher/releases) and place it in your `$PATH` as `ccs`.

## Quick Start

1. Log into Claude Code with your first account
2. `ccs add` — save current credentials
3. Log out, log into your second account
4. `ccs add` — save the second set of credentials
5. `ccs sw` — rotate between accounts
6. Restart Claude Code after each switch

> **What gets switched:** Only authentication credentials. Your themes, settings, preferences, and chat history remain unchanged.

## Usage

### Account Management

```bash
ccs add                          # Add current account
ccs ls                           # List all managed accounts
ccs rm 2                         # Remove account by number
ccs rm user@example.com          # Remove account by email
```

### Switching

```bash
ccs sw                           # Rotate to next account
ccs to 2                         # Switch to account #2
ccs to user@example.com          # Switch by email
ccs to work                      # Switch by profile name
ccs -n sw                        # Dry-run: preview what would happen
ccs sw -r                        # Switch and restart Claude Code
ccs sw --no-restart              # Switch without restart prompt
```

### Profiles

```bash
ccs profile 1 work               # Name account 1 "work"
ccs profile 2 personal           # Name account 2 "personal"
ccs to work                      # Then switch by profile name
```

### Directory-based Auto-switching

```bash
ccs dir ~/work 1                 # Map ~/work to account 1
ccs dir ~/personal 2             # Map ~/personal to account 2
ccs auto                         # Switch based on current directory
```

### Diagnostics

```bash
ccs check                        # Verify backup integrity (JSON, permissions, keychain)
ccs status                       # Current account, token expiry, last switch
ccs stats                        # Per-account usage statistics
```

### Other

```bash
ccs version                      # Show version
ccs help                         # Show help
```

### Shell Integration

Add to your shell profile to enable completions and the `ccs` alias:

**Bash** (`~/.bashrc`):

```bash
source "$(command -v ccs)" --shell-init bash 2>/dev/null
```

**Zsh** (`~/.zshrc`):

```bash
source "$(command -v ccs)" --shell-init zsh 2>/dev/null
```

**Fish** (`~/.config/fish/config.fish`):

```fish
source "$(command -v ccs)" --shell-init fish 2>/dev/null
```

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files
4. Automatically rolls back if any step fails

## Troubleshooting

Run `ccs check` first — it verifies JSON validity, file permissions, and keychain entries.

### Common Issues

| Problem | Solution |
|---------|----------|
| Switch fails | Run `ccs check` to diagnose. Ensure Claude Code is closed. |
| Can't add account | Ensure you're logged into Claude Code. Verify `jq` is installed. |
| Claude Code doesn't recognize new account | Restart Claude Code after switching, or use `ccs sw -r`. |
| Not sure which account is active | Run `ccs ls` — the active account is marked. |

## Cleanup / Uninstall

1. Note your current active account: `ccs ls`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Uninstall:
   - **make**: `sudo make uninstall`
   - **npm**: `npm uninstall -g cc-account-switcher`
   - **manual**: `rm /usr/local/bin/ccs`

Your current Claude Code login will remain active.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

- macOS credentials stored in system Keychain
- All backup files use `600` permissions (owner-only read/write)
- Integrity checks via `ccs check`

## License

MIT License — see [LICENSE](LICENSE) file for details.
