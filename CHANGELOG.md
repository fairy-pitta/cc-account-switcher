# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Rate limit auto-switch** — Automatically detect when 5-hour usage exceeds a threshold and switch to the next account via Claude Code's PreToolUse hook system ([#8](https://github.com/fairy-pitta/cc-account-switcher/issues/8))
  - `ccs rate-setup` — Install the PreToolUse hook for automatic switching
  - `ccs rate-setup --threshold N` — Set a custom usage threshold (default: 80%)
  - `ccs rate-setup --disable` — Remove the hook and disable auto-switch
  - `ccs rate-check` — Manually check current usage against the threshold
  - `ccs rate-check --auto-switch` — Check and switch if threshold exceeded
  - `hooks/ccs-rate-hook.sh` — Fail-open hook script for Claude Code integration
- Homebrew formula for easy installation on macOS
- npm package for installation via `npx cc-account-switcher`
- Makefile with install, uninstall, test, lint, and release targets
- GitHub Actions CI workflow (shellcheck, bats, syntax check)
- GitHub Actions release workflow with SHA256 checksums
- CONTRIBUTING.md with development setup guide

### Changed

- `perform_switch()` now supports silent mode (`CCS_SILENT=1`) for non-interactive use by hooks and automation

## [0.2.0] - 2025-12-01

### Added

- Multi-account management (add, remove, list accounts)
- Account switching by number or email
- Round-robin account rotation with `--switch`
- Cross-platform support (macOS, Linux, WSL)
- Secure credential storage (Keychain on macOS, protected files on Linux)
- Container detection for Docker/LXC environments
- First-run setup wizard
- Account identifier resolution (number, email, or profile name)
- JSON validation for all file writes

## [0.1.0] - 2025-11-01

### Added

- Initial release
- Basic account switching functionality
- macOS Keychain integration
- Linux credential file support

[Unreleased]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fairy-pitta/cc-account-switcher/releases/tag/v0.1.0
