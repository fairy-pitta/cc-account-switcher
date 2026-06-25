# Conversation handoff on account switch (fork-resume) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `ccs sw/to --resume` that switches accounts then relaunches Claude Code fork-resuming the current directory's conversation under the new account, falling back to a fresh launch when there's nothing to resume.

**Architecture:** Capture the outgoing account's `.claude.json` `projects[$PWD].lastSessionId` before the switch, perform the existing switch, then `exec claude --resume <id> --fork-session` (foreground). Two pure helpers (`build_resume_command`, `capture_resume_session_id`) are unit-tested; the wiring is covered end-to-end with a mock `claude` that records its argv.

**Tech Stack:** Bash 3.2+ (macOS), `jq`, `bats`, `shellcheck`.

Spec: `docs/superpowers/specs/2026-06-25-conversation-handoff-on-switch-design.md`

---

## File Structure

- `ccswitch.sh`:
  - New globals `RESUME_AFTER=false` / `RESUME_SID=""` near the other globals (lines 26-27).
  - New helpers `build_resume_command`, `capture_resume_session_id`, `restart_claude_code_resume` near `restart_claude_code` (~line 556).
  - `--resume` flag parsing in `main` (~line 2254, next to `--restart`).
  - Capture call + dry-run line in `perform_switch` (~lines 1276/1279).
  - Resume branch in `handle_restart_after_switch` (~line 569).
  - Help text + examples (~line 2219).
- `test/test_resume_handoff.bats` (new).
- `README.md`, `README.ja.md`, `CHANGELOG.md`.

Implementer notes:
- Run one file: `bats test/test_resume_handoff.bats`; whole suite `bats test/`. `shellcheck ccswitch.sh` must stay clean (pre-commit enforces it).
- Helpers in `test/test_helper.bash`: `setup_test_env`, `teardown_test_env`, `run_ccswitch <args>` (subprocess under temp `$HOME`, mocked `security`/`curl`/`uname`/`ps`; **inherits the current `$PWD`**), `source_ccswitch_functions`, `setup_fake_account`, `add_account_to_sequence`, `create_fake_credentials`, `$MOCK_BIN` (put a `claude` mock here), `$SEQUENCE_FILE`.
- Existing facts: `claude --resume [id]` resumes by session id; `--fork-session` makes a new session id when resuming. `ccs`'s own `-r` is `--restart` (fresh) — do **not** give `--resume` a `-r` short form. `get_claude_config_path` returns `$HOME/.claude/.claude.json`. `handle_restart_after_switch` is called at the end of `perform_switch` (after the lock is released).

---

## Task 1: `build_resume_command` (pure helper)

**Files:**
- Modify: `ccswitch.sh` — add function near `restart_claude_code` (~line 556)
- Test: `test/test_resume_handoff.bats` (create)

- [ ] **Step 1: Write the failing tests**

Create `test/test_resume_handoff.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() {
    rm -f "$TEST_HOME/claude-argv" 2>/dev/null || true
    teardown_test_env
}

@test "test_build_resume_command_with_session_id_forks" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "sid-123")" = "claude --resume sid-123 --fork-session" ]
}

@test "test_build_resume_command_without_session_id_is_fresh" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "")" = "claude" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_resume_handoff.bats`
Expected: FAIL — `build_resume_command: command not found`.

- [ ] **Step 3: Implement `build_resume_command`**

In `ccswitch.sh`, immediately above `restart_claude_code()` (line 556), add:

```bash
# Build the relaunch command for a fork-resume restart.
# Args: <claude_bin> <session_id>. With a session id -> resume+fork; without -> fresh.
build_resume_command() {
    local bin="$1" sid="$2"
    if [[ -n "$sid" ]]; then
        printf '%s --resume %s --fork-session' "$bin" "$sid"
    else
        printf '%s' "$bin"
    fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_resume_handoff.bats`
Expected: both PASS.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_resume_handoff.bats
git commit -m "feat: add build_resume_command helper (#15)"
```

---

## Task 2: `capture_resume_session_id`

**Files:**
- Modify: `ccswitch.sh` — add function near `restart_claude_code` (after `build_resume_command`)
- Test: `test/test_resume_handoff.bats` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/test_resume_handoff.bats`:

```bash
@test "test_capture_resume_session_id_reads_lastsessionid_for_cwd" {
    create_fake_claude_config "user1@example.com" "uuid-1"
    # Add a projects entry for the current working directory
    local cwd cfg updated
    cwd="$PWD"
    cfg="$HOME/.claude/.claude.json"
    updated=$(jq --arg c "$cwd" '.projects[$c] = {lastSessionId: "sess-abc"}' "$cfg")
    echo "$updated" > "$cfg"

    source_ccswitch_functions
    [ "$(capture_resume_session_id)" = "sess-abc" ]
}

@test "test_capture_resume_session_id_empty_when_no_entry" {
    create_fake_claude_config "user1@example.com" "uuid-1"
    source_ccswitch_functions
    [ -z "$(capture_resume_session_id)" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_resume_handoff.bats -f "capture_resume"`
Expected: FAIL — `capture_resume_session_id: command not found`.

- [ ] **Step 3: Implement `capture_resume_session_id`**

In `ccswitch.sh`, right after `build_resume_command` (before `restart_claude_code`), add:

```bash
# Echo the lastSessionId for the current working directory from the (outgoing)
# .claude.json, or empty if none. MUST be called before a switch swaps the file.
capture_resume_session_id() {
    local cfg
    cfg=$(get_claude_config_path)
    [[ -f "$cfg" ]] || return 0
    jq -r --arg c "$PWD" '.projects[$c].lastSessionId // empty' "$cfg" 2>/dev/null || true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_resume_handoff.bats`
Expected: all 4 PASS.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_resume_handoff.bats
git commit -m "feat: capture lastSessionId before switch (#15)"
```

---

## Task 3: `--resume` flag, relaunch, and wiring (end-to-end)

**Files:**
- Modify: `ccswitch.sh` — globals (26-27), `restart_claude_code_resume` (near 556), flag parse (~2254), `perform_switch` capture + dry-run (~1276/1279), `handle_restart_after_switch` (~569)
- Test: `test/test_resume_handoff.bats` (extend)

- [ ] **Step 1: Write the failing end-to-end tests**

Append to `test/test_resume_handoff.bats`:

```bash
# Mock `claude` that records the argv it was exec'd with, then exits 0.
_install_claude_mock() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/bin/bash
printf '%s' "\$*" > "$TEST_HOME/claude-argv"
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

# Set up two managed accounts plus a lastSessionId for the current cwd.
_setup_two_accounts_with_session() {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    local cfg updated
    cfg="$HOME/.claude/.claude.json"
    updated=$(jq --arg c "$PWD" '.projects[$c] = {lastSessionId: "sess-xyz"}' "$cfg")
    echo "$updated" > "$cfg"
}

@test "test_to_with_resume_relaunches_with_fork_session" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch to 2 --resume
    [ -f "$TEST_HOME/claude-argv" ]
    grep -q -- "--resume sess-xyz --fork-session" "$TEST_HOME/claude-argv"
}

@test "test_to_with_resume_no_session_relaunches_fresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    # No projects entry -> no session to resume
    _install_claude_mock

    run run_ccswitch to 2 --resume
    [ -f "$TEST_HOME/claude-argv" ]
    run cat "$TEST_HOME/claude-argv"
    [[ "$output" != *"--resume"* ]]
}

@test "test_dry_run_with_resume_shows_plan_and_does_not_switch" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch -n to 2 --resume
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"--resume sess-xyz --fork-session"* ]]
    # No switch happened
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
    # claude was not launched
    [ ! -f "$TEST_HOME/claude-argv" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_resume_handoff.bats -f "resume_relaunches\|dry_run_with_resume\|resume_no_session"`
Expected: FAIL — `--resume` is an unknown flag / no relaunch happens.

- [ ] **Step 3: Add the globals**

In `ccswitch.sh`, next to the existing globals (after `RESTART_FLAG=""` on line 27), add:

```bash
RESUME_AFTER=false  # true when --resume: fork-resume the conversation after switching
RESUME_SID=""       # captured lastSessionId for $PWD, set before the switch
```

- [ ] **Step 4: Add `restart_claude_code_resume`**

In `ccswitch.sh`, after `capture_resume_session_id` (added in Task 2), add:

```bash
# Foreground relaunch that fork-resumes the captured conversation under the
# now-active account. Falls back to a fresh launch when there is no session id.
restart_claude_code_resume() {
    local sid="$1" bin
    bin=$(command -v claude 2>/dev/null || echo "")
    if [[ -z "$bin" ]]; then
        echo "Switched. 'claude' not found in PATH — resume manually:"
        echo "  $(build_resume_command claude "$sid")"
        return 0
    fi
    kill_claude_processes
    if [[ -n "$sid" ]]; then
        echo "Resuming conversation under the new account (forked session)..."
        exec "$bin" --resume "$sid" --fork-session
    else
        echo "No previous conversation found for this directory — starting fresh."
        exec "$bin"
    fi
}
```

- [ ] **Step 5: Parse the `--resume` flag**

In `main`'s flag loop, next to the `--restart|-r)` case (~line 2254), add a new case:

```bash
            --resume)
                RESUME_AFTER=true
                shift
                ;;
```

(Long form only — do not add `-r`, which is already `--restart`.)

- [ ] **Step 6: Capture the session id in `perform_switch` before the swap**

In `perform_switch`, right after `current_email=$(get_current_account)` (line 1276) and BEFORE the `if [[ "$DRY_RUN" == true ]]` block (line 1279), insert:

```bash
    # Capture the conversation pointer from the OUTGOING .claude.json (before the
    # swap) so we can fork-resume it under the new account.
    if [[ "$RESUME_AFTER" == true ]]; then
        RESUME_SID=$(capture_resume_session_id)
    fi
```

- [ ] **Step 7: Add the resume line to the dry-run block**

Inside the `if [[ "$DRY_RUN" == true ]]` block in `perform_switch`, after the existing
`echo "  3. Update active account in sequence.json"` line, add:

```bash
        if [[ "$RESUME_AFTER" == true ]]; then
            echo "  4. Relaunch: $(build_resume_command claude "$RESUME_SID")"
        fi
```

- [ ] **Step 8: Branch `handle_restart_after_switch` for resume**

At the very top of `handle_restart_after_switch` (line 569, before `case "$RESTART_FLAG"`), add:

```bash
    if [[ "$RESUME_AFTER" == true ]]; then
        restart_claude_code_resume "$RESUME_SID"
        return
    fi
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `bats test/test_resume_handoff.bats`
Expected: all PASS (the 3 e2e tests plus the 4 unit tests).

Then run the full suite for regressions:

Run: `bats test/`
Expected: all green. In particular `test_switch*.bats` and rate-check switch tests still pass (RESUME_AFTER defaults false → unchanged path).

- [ ] **Step 10: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_resume_handoff.bats
git commit -m "feat: ccs --resume fork-resumes conversation after switch (#15)"
```

---

## Task 4: Help text + documentation

**Files:**
- Modify: `ccswitch.sh` (usage/examples ~2219), `README.md`, `README.ja.md`, `CHANGELOG.md`

- [ ] **Step 1: Add `--resume` to the usage/help text**

In `show_usage` (the `Options:` block, after the `--no-restart` line ~2221), add:

```bash
    echo "      --resume                     Switch, then fork-resume this directory's conversation"
```

And in the `Examples:` block, add:

```bash
    echo "  ccs sw --resume                            # Rotate and resume the conversation"
    echo "  ccs to 2 --resume                          # Switch to account 2 and resume here"
```

- [ ] **Step 2: Run a quick smoke check of help output**

Run: `bash ccswitch.sh help | grep -A1 -- "--resume"`
Expected: the new lines appear.

- [ ] **Step 3: Update CHANGELOG.md**

Read `CHANGELOG.md`; under `## [Unreleased]` (add the section/headers if absent), add an `### Added` bullet:

```markdown
- `ccs sw --resume` / `ccs to <account> --resume` — switch accounts and relaunch Claude Code fork-resuming the current directory's conversation under the new account (`claude --resume <id> --fork-session`). Falls back to a fresh launch when there's no prior conversation for the directory. On macOS, whether the forked session authenticates under the new account depends on Claude Code's session model — if it can't, the switch still succeeds and you land in a fresh session ([#15](https://github.com/fairy-pitta/cc-account-switcher/issues/15)).
```

- [ ] **Step 4: Update README.md and README.ja.md**

In the switching section of `README.md`, add a short subsection:

```markdown
### Resume your conversation after switching

`ccs sw` / `ccs to` normally relaunch a fresh Claude Code session. Add `--resume` to
carry your current conversation across the switch:

    ccs to 2 --resume

This captures the current directory's most recent session and relaunches with
`claude --resume <id> --fork-session`, so you continue the same conversation as the new
account (in a freshly-forked session). If there's no prior conversation for the
directory, it starts fresh.
```

Mirror the same in `README.ja.md` in natural Japanese, matching the file's style.

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh README.md README.ja.md CHANGELOG.md
git commit -m "docs: document ccs --resume conversation handoff (#15)"
```

---

## Done criteria

- `build_resume_command` and `capture_resume_session_id` are unit-tested for both the
  has-session and no-session cases.
- `ccs to/sw --resume` relaunches with `--resume <id> --fork-session` when a session
  exists, fresh when it doesn't; `--dry-run --resume` shows the plan and switches nothing.
- `-r`/`--restart`/`--no-restart` and all existing switch tests are unchanged/green.
- `bats test/` fully green; `shellcheck ccswitch.sh` clean.
- Docs (`--resume` help, README, CHANGELOG) updated, including the macOS cross-account caveat.
- Out of scope (do not implement): headless/orchestrator handoff; verifying cross-account
  fork (needs two live-logged-in accounts — left as a live-verify item).
