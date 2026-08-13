# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Usage percentages are no longer read ten times too high under a locale whose decimal separator is a comma (`es_CL.UTF-8`, and most of Europe / Latin America). `printf "%.0f"` honors `LC_NUMERIC`: given the cache's dot-decimal `15.0` it printed `15` and then failed, and the `|| echo "0"` fallback — folded into the same command substitution — appended to that partial output, so 15% read as 150% and 100% as 1000%. The rate-limit hook consequently rotated through every account and denied tool calls with "Rate limit exceeded on all accounts (1000%)" on an account with plenty of headroom, and the statusline showed the same inflated number. The conversion now pins `LC_ALL=C`, keeps the fallback out of the substitution, and validates the result before comparing it against the threshold. A value that still can't be read is reported as unreadable rather than as 0% — `rate-check` exits 2 (fails open in hook mode) and the statusline renders `5h ?%`, so nothing acts on a number it can't trust ([#47](https://github.com/fairy-pitta/cc-account-switcher/issues/47))

## [0.5.0] - 2026-07-30

### Added

- Custom endpoint accounts: `ccs add-endpoint <label> --base-url <url> --token-header <api_key|auth_token>` registers an account backed by a custom `ANTHROPIC_BASE_URL` and API key / auth token (OpenRouter, gateways, proxies, self-hosted) alongside the existing OAuth accounts. Switching, `status`, `exec`, and `config-dir` all understand endpoint accounts — a switch writes the endpoint env block into `~/.claude/settings.json` and clears it when switching back to an OAuth account ([#36](https://github.com/fairy-pitta/cc-account-switcher/issues/36))
- Reactive fallback for endpoint accounts: `ccs rate-check` health-probes the active endpoint over HTTP and rotates to the next account in the sequence when it's unhealthy or rate-limited ([#36](https://github.com/fairy-pitta/cc-account-switcher/issues/36))

### Changed

- The usage cache path now resolves via `$TMPDIR` / `$TMP` / `$TEMP` (falling back to `/tmp`, overridable with `$CCS_USAGE_CACHE`) instead of a hardcoded `/tmp`, so macOS, WSL, and Git Bash all use their real temp directory. The statusline (writer) and rate hook (reader) resolve the same way ([#40](https://github.com/fairy-pitta/cc-account-switcher/pull/40))

## [0.4.1] - 2026-06-25

### Added

- `ccs sw --resume` / `ccs to <account> --resume` — switch accounts and relaunch Claude Code fork-resuming the current directory's conversation under the new account (`claude --resume <id> --fork-session`). Falls back to a fresh launch when there's no prior conversation for the directory. On macOS, whether the forked session authenticates under the new account depends on Claude Code's session model — if it can't, the switch still succeeds and you land in a fresh session ([#15](https://github.com/fairy-pitta/cc-account-switcher/issues/15))

## [0.4.0] - 2026-06-25

### Added

- Rate-limit auto-switch now works in headless `claude -p` runs: the PreToolUse hook refreshes the usage cache on demand (TTL-aware) instead of silently no-op'ing when no statusline is keeping it warm ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- `ccs rate-check --max-age SECONDS` and a `.rateLimit.cacheTtl` config key to tune how long a cached usage reading is considered fresh (default 60s)
- `ccs statusline-setup` — optional statusline that shows the active account and 5-hour usage and keeps the usage cache warm for interactive sessions (`statusline/ccs-statusline.sh`) ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- `ccs exec <account> -- <command>` and `ccs config-dir <account>` — run commands as a specific account isolated in their own `CLAUDE_CONFIG_DIR`, so multiple Claude Code processes can run as different accounts in parallel without touching the global credential store ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20)). Works on Linux/WSL (file-based credentials). On macOS this does **not** work on Claude Code 2.1.x — the OAuth token is session-bound, so a copied token is rejected with `401` in an isolated dir; use `claude auth login` per dir there ([#29](https://github.com/fairy-pitta/cc-account-switcher/issues/29)). The sequential rate-limit auto-switch is unaffected and works on macOS.
- npm package now ships the `hooks/` and `statusline/` directories so `ccs rate-setup` / `ccs statusline-setup` work after an npm install

### Fixed

- macOS Keychain credentials are now decoded correctly. Newer Claude Code stores the credential as binary data, so `security -w` returns a hex dump (`7b22…`) rather than JSON; this broke `ccs exec`/`config-dir` (empty, unauthenticated isolated dirs) and could corrupt credentials on a multi-account switch. `read_credentials` now decodes the hex form back to JSON ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- Concurrent account switches are now serialized with an exclusive lock (`mkdir`-based, portable to macOS which lacks `flock`), so orchestrator heartbeats crossing the threshold at once can no longer race or thrash accounts ([#20](https://github.com/fairy-pitta/cc-account-switcher/issues/20))
- Switching to the already-active account is now a fast no-op instead of redundantly rewriting the credential store
- Token introspection now reads Claude Code 2.1.x's nested credential format (`claudeAiOauth.accessToken` / `expiresAt`) with a fallback to the legacy flat shape. Previously the usage API read and `ccs status` expiry read a flat `access_token` that does not exist on current macOS, so rate-limit auto-switch could not fetch usage and `ccs status` could not show token expiry on macOS ([#31](https://github.com/fairy-pitta/cc-account-switcher/issues/31))
- Refreshed tokens are written back in the credential's own shape (nested or flat), as single-line JSON
- When an account's refresh token is revoked, `ccs` now prints a clear "needs re-login — run: claude /login" hint instead of failing silently

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
