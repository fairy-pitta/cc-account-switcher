# Multi-Account Switcher for Claude Code

[![CI](https://github.com/ming86/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/ming86/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/ming86/cc-account-switcher)](https://github.com/ming86/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Quick switching**: Switch between accounts with simple commands
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged

## Installation

### curl (quickest)

```bash
curl -fsSL https://raw.githubusercontent.com/ming86/cc-account-switcher/main/ccswitch.sh -o /usr/local/bin/ccswitch
chmod +x /usr/local/bin/ccswitch
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

Download `ccswitch.sh` from the [latest release](https://github.com/ming86/cc-account-switcher/releases) and place it in your `$PATH`.

## Usage

### Basic Commands

```bash
# Add current account to managed accounts
ccswitch --add-account

# List all managed accounts
ccswitch --list

# Switch to next account in sequence
ccswitch --switch

# Switch to specific account by number or email
ccswitch --switch-to 2
ccswitch --switch-to user2@example.com

# Remove an account
ccswitch --remove-account user2@example.com

# Show help
ccswitch --help
```

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `ccswitch --add-account` to add it to managed accounts
3. **Log out** and log into Claude Code with your second account
4. Run `ccswitch --add-account` again
5. Now you can switch between accounts with `ccswitch --switch`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials change. Your themes, settings, preferences, and chat history remain exactly the same.

### Shell Integration

Add to your shell profile to enable completions and aliases:

**Bash** (`~/.bashrc`):

```bash
source "$(command -v ccswitch)" --shell-init bash 2>/dev/null
```

**Zsh** (`~/.zshrc`):

```bash
source "$(command -v ccswitch)" --shell-init zsh 2>/dev/null
```

**Fish** (`~/.config/fish/config.fish`):

```fish
source "$(command -v ccswitch)" --shell-init fish 2>/dev/null
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

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `ccswitch --list`
- Verify Claude Code is closed before switching
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Claude Code first
- Check that you have `jq` installed
- Verify you have write permissions to your home directory

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `ccswitch --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `ccswitch --list`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Uninstall:
   - **make**: `sudo make uninstall`
   - **npm**: `npm uninstall -g cc-account-switcher`
   - **manual**: `rm /usr/local/bin/ccswitch`

Your current Claude Code login will remain active.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Claude Code to be closed during account switches

## License

MIT License - see [LICENSE](LICENSE) file for details.
