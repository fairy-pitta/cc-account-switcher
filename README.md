# Multi-Account Switcher for Claude Code

**[日本語版はこちら](README.ja.md)**

[![CI](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/fairy-pitta/cc-account-switcher/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/fairy-pitta/cc-account-switcher?style=flat&color=blue)](https://github.com/fairy-pitta/cc-account-switcher/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-brightgreen)](https://github.com/fairy-pitta/cc-account-switcher)
[![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-89e051)](https://github.com/fairy-pitta/cc-account-switcher)
[![Tests](https://img.shields.io/badge/tests-85%20passing-success)](https://github.com/fairy-pitta/cc-account-switcher/actions)

> Forked from [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher) — thank you for the original work!

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Demo

![demo](assets/demo.gif)

## Features

- **Multi-account management** — Add, remove, and list Claude Code accounts
- **Quick switching** — Rotate accounts or switch to a specific one by number, email, or profile name
- **Named profiles** — Give accounts friendly names like `work` or `personal`
- **Directory-based auto-switching** — Map directories to accounts and auto-switch when you `cd`
- **Dry-run mode** — Preview what a switch would do without making changes
- **Rollback** — Automatic rollback if a switch fails mid-way
- **Rate limit auto-switch** — Automatically switch accounts when usage limits are hit, via Claude Code hooks
- **Custom endpoints** — Add `ANTHROPIC_BASE_URL` + API key/token providers (OpenRouter, gateways, proxies, self-hosted) as switchable accounts via `ccs add-endpoint`
- **Conversation handoff** — `--resume` carries your current conversation across a switch, forking it or continuing the same session (`ccs resume-mode`)
- **Parallel isolation** — Run commands as a specific account in their own `CLAUDE_CONFIG_DIR` (`ccs exec` / `config-dir`; Linux/WSL)
- **Diagnostics** — Health checks, status, and per-account usage statistics
- **Cross-platform** — Works on macOS, Linux, and WSL
- **Secure storage** — Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation** — Only switches authentication; themes, settings, and preferences stay unchanged

## Installation

![install](assets/install.gif)

### curl (quickest)

```bash
curl -fsSL https://raw.githubusercontent.com/fairy-pitta/cc-account-switcher/main/ccswitch.sh -o /usr/local/bin/ccs
chmod +x /usr/local/bin/ccs
```

### Homebrew (macOS)

```bash
brew install fairy-pitta/tap/ccswitch
```

### npm / npx

```bash
# Install globally
npm install -g @fairy-pitta/cc-account-switcher

# Or run without installing
npx @fairy-pitta/cc-account-switcher --help
```

### Make

```bash
git clone https://github.com/fairy-pitta/cc-account-switcher.git
cd cc-account-switcher
sudo make install
```

### Manual

Download `ccswitch.sh` from the [latest release](https://github.com/fairy-pitta/cc-account-switcher/releases) and place it in your `$PATH` as `ccs`.

## Quick Start

![quickstart](assets/quickstart.gif)

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
ccs to 2 --resume                # Switch to account 2 and resume the conversation
ccs to 2 --resume --no-fork-session   # Resume without forking (keeps the session id)
```

#### Resume your conversation after switching

`ccs sw` / `ccs to` normally relaunch a fresh Claude Code session. Add `--resume` to
carry your current conversation across the switch:

```bash
ccs to 2 --resume
```

This captures the current directory's most recent session and relaunches Claude Code
resuming it, so you continue the same conversation as the new account. If there's no
prior conversation for the directory, it starts fresh.

**Fork or same session.** There are two ways to come back into a conversation, and
`--resume` can do either:

| Mode | Relaunches with | Use it when |
|------|-----------------|-------------|
| `fork` (default) | `claude --resume <id> --fork-session` | You want the switched account to own a clean, isolated session. The fork gets a **new session id**. |
| `same` | `claude --resume <id>` | You want to stay on one session id — so transcript watchers, orchestrators, and anything else keyed on the session keep following the same work trail. |

Pick per switch, or set a default:

```bash
ccs to 2 --resume --fork-session      # force a fork for this switch
ccs to 2 --resume --no-fork-session   # force same-session for this switch

ccs resume-mode                       # show the current default
ccs resume-mode same                  # default to same-session from now on
ccs resume-mode fork                  # back to forking (the shipped default)
```

The default is stored as `.resume.mode` in `~/.claude-switch-backup/sequence.json`.
Precedence is flag → stored default → `fork`. The same setting drives the message the
rate-limit hook prints when it auto-switches (below).

> **macOS note:** whether the resumed session authenticates under the new account depends
> on Claude Code's session model. If it can't, the switch still succeeds and you land in
> a fresh session. Forking sidesteps this by creating a session the new account owns, so
> `same` is the mode more likely to hit it.

### Custom endpoints

Add an Anthropic-compatible endpoint as a switchable account:

```bash
# API-key (x-api-key) provider, key read from a prompt (not shell history)
ccs add-endpoint openrouter --base-url https://openrouter.ai/api/v1 --token-header api_key

# Bearer-token provider, key piped in
echo "$MY_TOKEN" | ccs add-endpoint gateway --base-url https://gw.corp/v1 --token-header auth_token --key-stdin --model claude-3-5-sonnet

ccs to openrouter        # switch (writes ANTHROPIC_* into ~/.claude/settings.json env)
ccs to 1                 # switch back to an OAuth account (removes those env vars)
```

Switching to/from an endpoint changes Claude Code's `settings.json` `env`, which
is read at startup — **restart Claude Code** (or use `-r` / `--resume`) for the
change to take effect.

Endpoints also participate in rate-limit auto-switch: because they have no usage
API, `ccs` probes the endpoint (`/models`, then `/messages`) and falls back to the
next account when it returns auth, rate-limit, server, or timeout errors.

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

### Rate Limit Auto-switch

Automatically switch to the next account when your 5-hour usage exceeds a threshold. Uses Claude Code's [PreToolUse hook](https://docs.anthropic.com/en/docs/claude-code/hooks) system — no polling, no background processes.

```bash
# Set up (one-time) — installs a PreToolUse hook into ~/.claude/settings.json
ccs rate-setup                   # Enable with default 80% threshold
ccs rate-setup --threshold 70    # Custom threshold

# Manual check
ccs rate-check                   # Check current usage vs threshold
ccs rate-check --auto-switch     # Check and switch if exceeded
ccs rate-check --max-age 30      # Treat the cache as stale after 30s

# Disable
ccs rate-setup --disable         # Remove hook and disable
```

`rate-setup` looks for the hook script (`hooks/ccs-rate-hook.sh`) next to `ccswitch.sh` — source checkouts and the npm package — and then in `<prefix>/share/ccswitch/`, where `make install` and Homebrew put it. Set `$CCS_SHARE_DIR` to override the location. The same applies to the statusline script below.

**How it works:**

1. The usage cache lives at `$TMPDIR/claude-usage-cache.json` (falling back to `/tmp` when `$TMPDIR`/`$TMP`/`$TEMP` are unset; override with `$CCS_USAGE_CACHE`) with a `cached_at` timestamp.
2. Before each tool call the PreToolUse hook checks the cache. If it's fresh (younger than the TTL) and under threshold, it returns immediately (~20ms, no API call).
3. If the cache is missing, stale, or for a different account, the hook refreshes it from the [Anthropic OAuth Usage API](https://api.anthropic.com/api/oauth/usage) on demand — so it works in headless `claude -p` runs with no statusline.
4. If usage exceeds the threshold, it switches to the next account and tells Claude Code to deny the tool call with a message naming the new account. A `PreToolUse` hook runs inside the live Claude Code process, so it can't relaunch it for you — instead the message hands you the exact command to come back with, honoring your resume mode: `Exit and run: claude --resume <id> --fork-session` (or without `--fork-session` when the mode is `same`). If the directory has no conversation to resume, it falls back to "Please restart Claude Code."
5. Switches take an exclusive lock, so concurrent agents (e.g. an orchestrator's heartbeats) can't race or thrash accounts.
6. All errors fail open — a broken hook never blocks your work.

**Cache TTL:** the cache is considered fresh for `DEFAULT_CACHE_TTL` (60s) by default. Override per-install with `.rateLimit.cacheTtl` in `~/.claude-switch-backup/sequence.json`, or per-invocation with `--max-age SECONDS`. A short TTL means fresher data at the cost of more API calls; a longer TTL means fewer calls.

**Optional statusline:** for interactive sessions you can install a statusline that shows the active account and 5-hour usage while keeping the cache warm:

```bash
ccs statusline-setup             # Install (writes .statusLine into ~/.claude/settings.json)
ccs statusline-setup --force     # Same, replacing a statusline you already configured
ccs statusline-setup --disable   # Remove it (leaves any other statusline untouched)
```

If `~/.claude/settings.json` already sets a `statusLine` that isn't ours, `statusline-setup` stops and tells you — pass `--force` to replace it, or call `statusline/ccs-statusline.sh` from your own statusline script to render both.

It renders e.g. `ccs you@example.com · 5h 42%` and appends `(!)` once you cross the threshold. The cache refresh runs in the background, so it never blocks the prompt. The statusline is **not required** — headless runs refresh the cache on demand (above).

> **Note (multi-account at the same time):** `ccswitch` rewrites a single machine-global credential store, so all Claude Code processes on the machine share one account at a time. Auto-switch is built for the *sequential* case — "when this account is exhausted, rotate to the next." Running different accounts in parallel requires per-process isolation via `CLAUDE_CONFIG_DIR` — see below.

### Reactive auto-switch (`ccs run`)

For headless orchestrators (e.g. Paperclip/Multica) running `claude -p`, the PreToolUse hook described above cannot see a 429 that arrives mid-turn. `ccs run` fills that gap: it runs a command on the active account and, when the command fails because the account is rate-limited, switches to the next healthy account and retries.

```bash
ccs run -- claude -p "summarize this repo"
ccs run --max-attempts 3 --timeout 120 -- claude -p "..."
```

**Detection** is format-agnostic: `ccs run` greps the failed run's stderr and the final lines of its stdout for documented rate-limit markers (a `(429)` API error, `rate-limit`/`rate_limit`, `overloaded`, `usage limit`). When those are absent but the command still failed, it falls back to a usage-API check (max of the 5-hour and 7-day windows) to decide whether the account is actually exhausted.

**Flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--max-attempts N` | number of accounts | Maximum total attempts across all accounts |
| `--limit-threshold N` | 95 | Usage % for the secondary/reactive limit confirmation and post-switch health check |
| `--timeout SEC` | none | Per-attempt time limit; kills the child's process group. Also bounds the stdin read |
| `--no-proactive` | — | Skip the pre-run usage check |
| `--no-stdin` | — | Don't read stdin; feed the child `/dev/null` (see stdin note below) |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| command's own code | Non-rate-limit failure (no retry) |
| 124 | Attempt killed by `--timeout` (or a stdin read that timed out) |
| 3 | All accounts exhausted; a machine-readable `ccs-run: exhausted accounts=N attempts=M` line is printed to stderr |
| 4 | `--max-attempts` reached after rotating to a healthy account that wasn't retried; prints `ccs-run: max-attempts accounts=N attempts=M`. Distinct from 3 so an orchestrator doesn't park work while a usable account remains |
| 2 | Internal switch error |

**stdin** is spooled to a temp file and replayed on each attempt (so a retry sees byte-identical input). Only the successful attempt's stdout is emitted.

> **IMPORTANT — stdin can block:** because the spool is read to EOF up front, a command that never reads stdin but inherits a long-lived/open pipe (common when an orchestrator spawns children with inherited stdin) will make `ccs run` block before the first attempt. If you pass the prompt as an argument (`claude -p "..."`), use **`--no-stdin`** (or redirect `</dev/null`). `--timeout` also bounds the stdin read.

> **IMPORTANT — Idempotency:** a rate-limited attempt may have already run tool calls with side effects before the limit was hit. The default retry re-runs the command from the beginning, so side effects can duplicate. Design your commands to be idempotent, or use `--max-attempts 1` (which still rotates once to a healthy account for your *next* invocation, but does not retry in-place).

> **IMPORTANT — Buffered stdout:** only the successful attempt's stdout is emitted. This means `--output-format stream-json` events are not streamed live, which may trip an orchestrator's inactivity timeout.

### Parallel / isolated accounts (`CLAUDE_CONFIG_DIR`)

To run multiple Claude Code processes as **different** accounts at the same time (e.g. an orchestrator like Paperclip/Multica fanning out agents), give each process its own config directory instead of switching the global store:

```bash
# Run a command as a specific account, isolated in its own config dir
ccs exec 2 -- claude -p "summarize this repo"
ccs exec work -- claude            # by profile name

# Or just materialize the dir and wire the env yourself
eval "$(ccs config-dir 2 | tail -1)"   # exports CLAUDE_CONFIG_DIR
```

`ccs exec` materializes the account's `.claude.json` + credentials into `~/.claude-switch-backup/isolated/<n>-<email>/` (override with `--dir PATH`) and runs the command with `CLAUDE_CONFIG_DIR` pointed there. Because it never touches the global store, several `ccs exec` processes can run as different accounts concurrently with no locking. Put any ccs options before `exec`; everything after `--` is passed to the command verbatim.

> ⚠️ **Platform support:** parallel isolation works on **Linux/WSL** (credentials are file-based, so a copied credential just works). It does **not** work on **macOS** with current Claude Code (2.1.x): Claude binds the OAuth token to the live session, so a *copied* token — whether written as a file or into the per-dir Keychain item — is rejected with `401` in an isolated config dir, even when fresh ([#29](https://github.com/fairy-pitta/cc-account-switcher/issues/29)). The only way to run different accounts in parallel on macOS is to `claude auth login` **inside each** `CLAUDE_CONFIG_DIR` so each owns its own credentials. Note: the **rate-limit auto-switch (sequential rotation) works on macOS** — it swaps the single active account rather than running parallel copies.

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

### Running as root

By default the script refuses to run as `root`, because credentials and backups are
stored per-user (under `$HOME` and, on macOS, the user's Keychain). Running as root
targets a different home/Keychain and can leave root-owned files behind that break
your normal user.

If you understand the risks (e.g. sandbox or container testing), opt out with the
`--allow-root` flag or the `CCSWITCH_ALLOW_ROOT=1` environment variable:

```bash
ccs --allow-root ls              # Flag (can go before or after the command)
CCSWITCH_ALLOW_ROOT=1 ccs ls     # Environment variable
```

Containers are detected automatically and allowed without the flag.

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

- Bash 3.2+
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
   - **npm**: `npm uninstall -g @fairy-pitta/cc-account-switcher`
   - **manual**: `rm /usr/local/bin/ccs`

Your current Claude Code login will remain active.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

- macOS credentials stored in system Keychain
- All backup files use `600` permissions (owner-only read/write)
- Integrity checks via `ccs check`

## Acknowledgments

This project is a fork of [ming86/cc-account-switcher](https://github.com/ming86/cc-account-switcher). Thanks to the original author for building the foundation of multi-account switching for Claude Code.

## License

MIT License — see [LICENSE](LICENSE) file for details.
