# Conversation handoff on account switch (fork-resume)

**Date:** 2026-06-25
**Status:** design
**Related:** #15, #20, #29 (session/token account-binding context)

## Background

When `ccs` switches accounts it rewrites the global credential store and **the whole
`~/.claude/.claude.json`**. Claude Code keeps a per-cwd pointer to the most recent
conversation in that file: `.projects["<cwd>"].lastSessionId` (verified present for 39
projects on a real machine). The conversation transcript itself lives separately and
account-agnostically in `~/.claude/projects/<cwd-hash>/*.jsonl` and is **not** touched
by a switch.

So after a switch + restart the conversation appears "lost" not because the transcript
is gone, but because `ccs` swapped in the **new account's** `.claude.json`, whose
`lastSessionId` for this cwd points elsewhere (or nowhere). `restart_claude_code`
currently relaunches a **fresh** `claude` (detached `nohup claude`), compounding this.

Resuming the *original* session id under the new account is assumed to fail (the session
is likely account-bound server-side, mirroring the credential binding found in #29).
Rather than resume the bound session, we **fork** it: `claude --resume <id> --fork-session`
creates a **new session id owned by the now-active account** from the old transcript,
sidestepping the binding.

## Goal

Add an opt-in way to switch accounts and land back in the *same conversation* under the
new account: capture the outgoing account's `lastSessionId` for the current cwd, switch,
then relaunch Claude Code fork-resuming that conversation. Fall back to a fresh launch
when there is nothing to resume or the relaunch can't run — never worse than today.

## Non-goals

- **Headless / orchestrator handoff** (Paperclip/Multica spawning the next agent): that
  is the orchestrator's responsibility — it controls how it spawns `claude -p` and can
  pass `--resume`/`--fork-session` itself. Out of scope here.
- Changing the existing fresh-restart behaviour (`-r`/`--restart`) — that stays.
- Locating/copying transcript files: `claude --resume <id>` resolves the transcript
  itself, so `ccs` only needs to carry the **session id**.

## User-facing behaviour

A new opt-in flag on the switch commands:

```
ccs sw --resume          # rotate to next account, then fork-resume this cwd's conversation
ccs to <n|email|profile> --resume
```

- `--resume` is distinct from the existing `-r`/`--restart` (which relaunches a fresh
  session). `--resume` implies a restart, but a fork-resuming one.
- After a successful switch, `ccs` `exec`s `claude --resume <sid> --fork-session` in the
  **foreground** (replacing the `ccs` process), so the user lands directly in the forked
  conversation running as the new account.
- `--dry-run` prints what would happen (switch + the exact relaunch command) without
  doing it.

## Components

All in `ccswitch.sh`.

### 1. `capture_resume_session_id` — read the outgoing pointer

```
capture_resume_session_id() {
    # Echo the lastSessionId for the current working directory from the
    # (outgoing) .claude.json, or empty if none.
    local cfg cwd
    cfg=$(get_claude_config_path)
    cwd="$PWD"
    jq -r --arg c "$cwd" '.projects[$c].lastSessionId // empty' "$cfg" 2>/dev/null || true
}
```

- Must be called **before** the switch mutates `.claude.json`.
- Uses `$PWD` as the project key — the conversation the user means is the Claude Code
  session for the directory they invoked `ccs` from. Documented limitation: if invoked
  from an unrelated cwd, there is nothing to resume → fresh launch.

### 2. `build_resume_command` — construct the relaunch argv (pure, testable)

```
build_resume_command() {
    # Args: <claude_bin> <session_id>
    # Echo the relaunch command. With a session id -> fork-resume; without -> fresh.
    local bin="$1" sid="$2"
    if [[ -n "$sid" ]]; then
        printf '%s --resume %s --fork-session' "$bin" "$sid"
    else
        printf '%s' "$bin"
    fi
}
```

Pure string function so the argv can be unit-tested without launching anything.

### 3. `restart_claude_code_resume` — foreground fork-resume relaunch

```
restart_claude_code_resume() {
    # Args: <session_id>
    local sid="$1" bin
    bin=$(command -v claude 2>/dev/null || echo "")
    if [[ -z "$bin" ]]; then
        echo "Switched. 'claude' not found in PATH — resume manually:"
        echo "  claude --resume ${sid:-<session-id>} --fork-session"
        return 0
    fi
    kill_claude_processes
    if [[ -n "$sid" ]]; then
        echo "Resuming conversation under the new account (forked session)..."
        exec claude --resume "$sid" --fork-session
    else
        echo "No previous conversation found for this directory — starting fresh."
        exec claude
    fi
}
```

- `exec` replaces the `ccs` process so Claude runs in the user's terminal (foreground,
  interactive) — unlike the existing detached `nohup` restart.
- If `exec` somehow returns (it shouldn't), the function ends and `ccs` exits normally.

### 4. Wiring into the switch flow

- `main()`'s flag parsing learns `--resume` for `to`/`sw` (sets e.g. `RESUME_AFTER=1`).
  Keep `-r`/`--restart` and `--no-restart` working unchanged.
- In the switch command path, **before** calling `perform_switch`, capture
  `resume_sid=$(capture_resume_session_id)` when `RESUME_AFTER=1`.
- After `perform_switch` succeeds (and the lock is released — already happens before the
  restart prompt), if `RESUME_AFTER=1`: call `restart_claude_code_resume "$resume_sid"`
  instead of the normal restart prompt.
- `--dry-run` with `--resume`: print
  `[DRY RUN] Would switch ... then run: <build_resume_command output>` and return.

## Data flow

```
ccs sw --resume
  └─ capture_resume_session_id            # read .projects[$PWD].lastSessionId (OLD .claude.json)
  └─ perform_switch                       # swaps creds + .claude.json (lock-protected, #30)
  └─ restart_claude_code_resume "$sid"    # exec claude --resume $sid --fork-session  (new account)
        → Claude forks the transcript into a new session owned by the new account
```

## Error handling / fallback

- No `lastSessionId` for `$PWD` (empty) → relaunch fresh `claude` (no worse than today).
- `claude` not in `PATH` → print the exact resume command for the user; don't fail the switch.
- Switch itself fails → existing rollback; no relaunch.
- **Cross-account fork unverified:** whether `claude --resume <id> --fork-session`
  authenticates under the *new* account needs two live-logged-in accounts to confirm
  (same blocker as the Paperclip E2E). If it 401s, the user can rerun `claude` fresh;
  the switch already succeeded. This is recorded as a live-verify item, and the design's
  graceful fallback means a failure degrades to "fresh session", never to a broken state.

## Testing (bats)

New `test/test_resume_handoff.bats` (+ helpers as needed). Follow
`test_<action>_<condition>_<expected_result>`.

- **`build_resume_command`:**
  - with a session id → `<bin> --resume <id> --fork-session`.
  - with empty id → `<bin>` (fresh).
- **`capture_resume_session_id`:**
  - reads `lastSessionId` for the current cwd from a fake `.claude.json` `projects` map.
  - returns empty when the cwd has no entry / no `lastSessionId` / file missing.
- **Relaunch wiring (mock `claude` in `$MOCK_BIN` that records its argv to a file):**
  - `ccs to <n> --resume` with a captured id → mock claude invoked with
    `--resume <id> --fork-session`.
  - `ccs to <n> --resume` with no prior session → mock claude invoked with no `--resume`.
  - To make `exec` testable, the relaunch must be reachable via the mock; assert on the
    recorded argv. (If `exec` replaces the process, run `ccs` itself under `run` and have
    the mock `claude` write argv before exiting 0.)
- **`--dry-run --resume`:** prints the switch plan and the resume command; performs no
  switch (active account unchanged) and does not invoke `claude`.
- Pre-existing switch/restart tests stay green; `-r`/`--restart`/`--no-restart` unchanged.

`shellcheck` clean; full suite green.

## Files touched

- `ccswitch.sh` — `capture_resume_session_id`, `build_resume_command`,
  `restart_claude_code_resume`; `--resume` flag parsing; wiring in the `to`/`sw` path;
  dry-run handling; help text + usage examples.
- `test/test_resume_handoff.bats` (new); possibly a `claude` mock helper in
  `test/test_helper.bash`.
- `README.md` / `README.ja.md` / `CHANGELOG.md` — document `--resume` and the
  fork-resume behaviour + the macOS cross-account caveat.
