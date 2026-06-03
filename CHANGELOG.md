# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Rate-limit auto-switch now works in headless `claude -p` runs: the PreToolUse hook refreshes the usage cache on demand (TTL-aware) instead of silently no-op'ing when no statusline is keeping it warm ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- `ccs rate-check --max-age SECONDS` and a `.rateLimit.cacheTtl` config key to tune how long a cached usage reading is considered fresh (default 60s)
- `ccs statusline-setup` — optional statusline that shows the active account and 5-hour usage and keeps the usage cache warm for interactive sessions (`statusline/ccs-statusline.sh`) ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- npm package now ships the `hooks/` and `statusline/` directories so `ccs rate-setup` / `ccs statusline-setup` work after an npm install

### Fixed

- Concurrent account switches are now serialized with an exclusive lock (`mkdir`-based, portable to macOS which lacks `flock`), so orchestrator heartbeats crossing the threshold at once can no longer race or thrash accounts ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- Switching to the already-active account is now a fast no-op instead of redundantly rewriting the credential store

## [0.3.1] - 2026-06-03

### Fixed

- Rate-limit auto-switch hook was installed with a non-conforming settings schema and never fired; `ccs rate-setup` now writes Claude Code's nested hook schema, and `--disable` cleans up both the new and legacy shapes ([#21](https://github.com/fairy-pitta/cc-account-switcher/pull/21))

### Changed

- npm package is now published under the scoped name `@fairy-pitta/cc-account-switcher` ([#16](https://github.com/fairy-pitta/cc-account-switcher/pull/16))

### Added

- Automated release pipeline — pushing a `vX.Y.Z` tag now fans out to a GitHub Release, npm publish, and a Homebrew tap bump, gated by a version-consistency check ([#19](https://github.com/fairy-pitta/cc-account-switcher/issues/19))

## [0.3.0] - 2026-06-02

### Added

- `--allow-root` flag and `CCSWITCH_ALLOW_ROOT=1` environment variable to opt out of the root-execution guard for sandbox/testing use ([#13](https://github.com/fairy-pitta/cc-account-switcher/issues/13))
- **Rate limit auto-switch** — Automatically detect when 5-hour usage exceeds a threshold and switch to the next account via Claude Code's PreToolUse hook system ([#8](https://github.com/fairy-pitta/cc-account-switcher/issues/8))
  - `ccs rate-setup` — Install the PreToolUse hook for automatic switching
  - `ccs rate-setup --threshold N` — Set a custom usage threshold (default: 80%)
  - `ccs rate-setup --disable` — Remove the hook and disable auto-switch
  - `ccs rate-check` — Manually check current usage against the threshold
  - `ccs rate-check --auto-switch` — Check and switch if threshold exceeded
  - `hooks/ccs-rate-hook.sh` — Fail-open hook script for Claude Code integration
- Homebrew formula for easy installation on macOS
- npm package for installation via `npx @fairy-pitta/cc-account-switcher`
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

[Unreleased]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/fairy-pitta/cc-account-switcher/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/fairy-pitta/cc-account-switcher/releases/tag/v0.1.0
