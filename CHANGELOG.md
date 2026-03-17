# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Homebrew formula for easy installation on macOS
- npm package for installation via `npx cc-account-switcher`
- Makefile with install, uninstall, test, lint, and release targets
- GitHub Actions CI workflow (shellcheck, bats, syntax check)
- GitHub Actions release workflow with SHA256 checksums
- CONTRIBUTING.md with development setup guide

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

[Unreleased]: https://github.com/ming86/cc-account-switcher/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ming86/cc-account-switcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ming86/cc-account-switcher/releases/tag/v0.1.0
