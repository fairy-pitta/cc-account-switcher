# `ccs run` Reactive Auto-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ccs run -- <command...>` — run a command (typically `claude -p`) on the active account, and when it fails because the account is rate-limited, switch account and retry.

**Architecture:** Extend `perform_switch` with a compare-and-swap precondition (no new locks). Extract the rate-check rotate/verify core into a shared four-value helper. Add `cmd_run`: grep-primary rate-limit detection over buffered failure output, spool-first stdin replay, buffered stdout (only the winning attempt emitted), bounded internal retries via env, INT/TERM trap + `--timeout` watchdog, machine-readable exhaustion line.

**Tech Stack:** Bash (must run on macOS `/bin/bash` 3.2), `jq`, `bats` tests with mocks in `$MOCK_BIN`.

**Spec:** `docs/superpowers/specs/2026-08-19-ccs-run-reactive-auto-switch-design.md`. Honor the four implementation pins in spec §14 — **pin 3 (re-read `expected_active` before every spawn) is checked first in review.**

**Ground rules:**
- All work on branch `feature/ccs-run`.
- Run the full suite with `bats test/` — the existing count (260) must never drop; new tests add to it.
- Match existing style: `local` decls, `CCS_SILENT` guards, `write_json`, `>&2` for diagnostics.

---

## File structure

- Modify `ccswitch.sh`:
  - `perform_switch()` (~line 1731) — optional `expected_active` CAS param.
  - `cmd_rate_check()` (~line 2513) — call the new helper; keep caller-side messaging.
  - New `_rotate_to_healthy_next_account()` — extracted rotate+verify.
  - New `cmd_run()` + its private helpers `_run_detect_rate_limit`, `_run_proactive_precheck`.
  - `main()` dispatch (~line 3101) — add `run)`.
  - `show_usage()` — document `run`.
- Modify `completions/ccswitch.bash`, `completions/ccswitch.zsh`, `completions/ccswitch.fish` — add `run`.
- Create `test/test_run.bats` — all new behavior, with a mock `claude`.
- Modify `README.md`, `README.ja.md`, `CHANGELOG.md`.

---

## Task 1: `perform_switch` compare-and-swap (`expected_active`)

**Files:**
- Modify: `ccswitch.sh` `perform_switch()` — signature + insert CAS at line 1808 (after the reconcile `fi` at 1807, before the no-op guard comment at 1809).
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Create `test/test_run.bats`:

```bash
#!/usr/bin/env bats
#
# ccs run — reactive rate-limit auto-switch, and the perform_switch CAS /
# rotate helper it is built on.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# --- perform_switch compare-and-swap (expected_active) ------------------------

@test "perform_switch with matching expected_active performs the switch" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    run bash -c '
        source '"$CCSWITCH_SCRIPT"' --source-only 2>/dev/null || true
    '
    # Switch 1 -> 2, asserting we are still on 1.
    run run_ccswitch_perform_switch 2 1
    [ "$status" -eq 0 ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "perform_switch with mismatching expected_active returns 3 and does not switch" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    # We claim to expect account 9 (not the live 1) -> lost race -> return 3.
    run run_ccswitch_perform_switch 2 9
    [ "$status" -eq 3 ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}
```

Add this helper to `test/test_helper.bash` (near `run_ccswitch_at`):

```bash
# Invoke perform_switch directly with args, in a subshell, capturing its return
# code (perform_switch fails via `exit 1`, so it must run in a subshell).
run_ccswitch_perform_switch() {
    HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash -c '
        set -e
        CCS_TEST_FUNC=1
        source "'"$CCSWITCH_SCRIPT"'"
        CCS_SILENT=1 perform_switch "$@"
    ' _ "$@"
}
```

> Note: sourcing works because `ccswitch.sh` guards its `main "$@"` call. Verify in Step 3.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_run.bats -f "perform_switch"`
Expected: FAIL — either `perform_switch: command not found`-style (script runs `main` instead of sourcing) or the mismatch test switches anyway (status 0, active 2).

- [ ] **Step 3: Make the script sourceable for tests (if not already)**

Check the bottom of `ccswitch.sh`:

Run: `tail -5 ccswitch.sh`

If it calls `main "$@"` unconditionally, guard it so tests can source without executing:

```bash
# Only run main when executed directly, not when sourced by the test harness.
if [[ "${CCS_TEST_FUNC:-}" != "1" ]]; then
    main "$@"
fi
```

If the file already supports sourcing (some suites do `source`), keep the existing mechanism and adjust the helper in Step 1 to match it. Do not add a second guard.

- [ ] **Step 4: Add the `expected_active` parameter and CAS**

In `perform_switch()`, change the signature line:

```bash
perform_switch() {
    local target_account="$1"
    local expected_active="${2:-}"
```

Insert the CAS block at line 1808 — i.e. immediately after the reconcile block's closing `fi` (currently line 1807) and before the `# No-op guard` comment (currently line 1809):

```bash
    # Compare-and-swap precondition (used by `ccs run`): only switch if the
    # reconciled active account is still the one the caller expected. Under
    # concurrency another switch may have already rotated the shared account;
    # signal that with a distinct status so the caller retries without rotating.
    # Placed AFTER reconcile (so drift can't give a false verdict) and BEFORE the
    # no-op guard (so a concurrent switch onto our target isn't misread as our
    # success). Release the lock first, like every other post-acquire early exit.
    if [[ -n "$expected_active" && "$current_account" != "$expected_active" ]]; then
        release_switch_lock
        return 3
    fi
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/test_run.bats -f "perform_switch"`
Expected: PASS (both).

- [ ] **Step 6: Verify no regression**

Run: `bats test/`
Expected: previous count + 2, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add ccswitch.sh test/test_run.bats test/test_helper.bash
git commit -m "feat: perform_switch compare-and-swap via optional expected_active"
```

---

## Task 2: Extract `_rotate_to_healthy_next_account()` (four-value contract)

**Files:**
- Modify: `ccswitch.sh` — add helper before `cmd_rate_check()`; rewire `cmd_rate_check`'s auto-switch loop to call it.
- Test: `test/test_run.bats`

The helper encapsulates ONLY: pick next account → `perform_switch(next, expected)` in a subshell with `rc=$?` → verify health. It returns **0** switched-healthy, **1** all-exhausted, **2** switch-error, **3** lost-race. It emits nothing user-facing (that stays in `cmd_rate_check`).

- [ ] **Step 1: Write the failing tests**

Append to `test/test_run.bats`:

```bash
# --- _rotate_to_healthy_next_account ------------------------------------------

run_ccswitch_rotate() {
    HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash -c '
        CCS_TEST_FUNC=1
        source "'"$CCSWITCH_SCRIPT"'"
        _rotate_to_healthy_next_account "$@"
    ' _ "$@"
}

@test "rotate helper returns 0 and lands on a healthy next account" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # Next account reports plenty of headroom.
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":10.0,"limit":100,"used":10}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch_rotate 1
    [ "$status" -eq 0 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 2 ]
}

@test "rotate helper returns 3 when the active account already moved (lost race)" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    # Expect account 9; live is 1 -> perform_switch returns 3 -> helper 3.
    run run_ccswitch_rotate 9
    [ "$status" -eq 3 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
}

@test "rotate helper returns 1 when every other account is over threshold" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # The candidate always reports over-threshold usage.
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":99.0,"limit":100,"used":99}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    # threshold 80 in config
    local u; u=$(jq '.rateLimit = {enabled:true, threshold:80}' "$SEQUENCE_FILE"); echo "$u" > "$SEQUENCE_FILE"

    run run_ccswitch_rotate 1
    [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_run.bats -f "rotate helper"`
Expected: FAIL — `_rotate_to_healthy_next_account: command not found`.

- [ ] **Step 3: Add the helper**

Insert immediately before `cmd_rate_check()`:

```bash
# Rotate the shared active account to the next healthy one in the sequence.
# Silent, no restart, no hook messaging — those stay with the caller.
# Arg 1: expected_active — the account number the caller believes is live; the
#        first hop is a compare-and-swap against it (see perform_switch).
# Returns: 0 switched to a healthy account; 1 all others exhausted;
#          2 switch error; 3 lost race (someone else already rotated).
_rotate_to_healthy_next_account() {
    local expected_active="$1"
    local total_accounts
    total_accounts=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    [[ "$total_accounts" -lt 2 ]] && return 1

    local threshold cache_file
    threshold=$(_rate_threshold)
    cache_file=$(usage_cache_file)

    local attempts=0 max_attempts=$((total_accounts - 1))
    local first_hop="$expected_active"
    while [[ $attempts -lt $max_attempts ]]; do
        local active_account next_account
        active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        next_account=$(jq -r --argjson active "$active_account" '
            .sequence as $seq |
            ($seq | index($active) // 0) as $idx |
            $seq[($idx + 1) % ($seq | length)]
        ' "$SEQUENCE_FILE")

        # Only the first hop carries the CAS; subsequent hops within this call
        # already own the account, so pass no expectation.
        local rc
        rc=$( (CCS_SILENT=1 perform_switch "$next_account" "$first_hop") >/dev/null 2>&1; echo $? )
        first_hop=""
        case "$rc" in
            0) : ;;      # switched, verify health below
            3) return 3 ;;   # lost race
            *) return 2 ;;   # switch error (perform_switch exit 1)
        esac

        # Verify the candidate by type: probe endpoints, usage-check oauth.
        local healthy=false
        if is_endpoint_account "$next_account"; then
            if probe_endpoint_health "$next_account"; then healthy=true; fi
        else
            rm -f "$cache_file"
            if fetch_usage_data; then
                local new_usage new_usage_int
                new_usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
                if new_usage_int=$(usage_to_int "$new_usage"); then
                    [[ "$new_usage_int" -lt "$threshold" ]] && healthy=true
                else
                    healthy=true   # unreadable usage: assume OK (matches prior behavior)
                fi
            else
                healthy=true       # can't verify: assume OK (matches prior behavior)
            fi
        fi

        [[ "$healthy" == true ]] && return 0
        attempts=$((attempts + 1))
    done
    return 1
}
```

Add the small threshold accessor near `usage_cache_file()` if one does not already exist (check first with `grep -n 'rateLimit.threshold' ccswitch.sh`; if the logic is only inlined in `cmd_rate_check`, extract it):

```bash
# The configured rate-limit threshold, or 80.
_rate_threshold() {
    local t=""
    if [[ -f "$SEQUENCE_FILE" ]]; then
        t=$(jq -r '.rateLimit.threshold // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    fi
    echo "${t:-80}"
}
```

- [ ] **Step 4: Run the new tests to verify they pass**

Run: `bats test/test_run.bats -f "rotate helper"`
Expected: PASS (all three).

- [ ] **Step 5: Rewire `cmd_rate_check` onto the helper (preserve behavior)**

In `cmd_rate_check`'s auto-switch block, replace the inline `while [[ $attempts -lt $max_attempts ]]` loop (currently ~2547–2603) with a call to the helper, keeping ALL caller-side messaging. The `resume_sid` capture stays above. Replace the loop body with:

```bash
        local hrc
        _rotate_to_healthy_next_account "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
        hrc=$?

        case "$hrc" in
            0)
                local next_account next_email
                next_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
                next_email=$(account_display_id "$next_account")
                if [[ "$hook_mode" == true ]]; then
                    local next_step="Please restart Claude Code."
                    if [[ -n "$resume_sid" ]]; then
                        next_step="Exit and run: $(build_resume_command claude "$resume_sid")"
                    fi
                    _rate_hook_deny "Switched to Account-$next_account ($next_email). $next_step"
                    exit 0
                fi
                echo "Switched to Account-$next_account ($next_email)"
                handle_restart_after_switch
                exit 1
                ;;
            2)
                if [[ "$hook_mode" == true ]]; then exit 0; fi
                echo "Error: Failed to switch accounts" >&2
                exit 2
                ;;
            *)  # 1 (all exhausted) or 3 (lost race, nothing left to do here)
                if [[ "$hook_mode" == true ]]; then
                    _rate_hook_deny "Rate limit exceeded on all accounts (${usage_int}%). Please wait for limits to reset."
                    exit 0
                fi
                echo "All accounts are above the threshold" >&2
                exit 3
                ;;
        esac
```

> Note: `cmd_rate_check` never passes an `expected_active` (it holds no cross-process expectation), so the helper's first hop gets the live active number and status 3 cannot occur here in practice; the `*)` arm handles it defensively as "exhausted".

- [ ] **Step 6: Verify the existing rate-check tests are unchanged**

Run: `bats test/test_rate_check.bats test/test_endpoint_rate_check.bats test/test_concurrency_rotation.bats`
Expected: PASS, same counts as before.

Run: `bats test/`
Expected: prior total + 3 (Task 2 tests), 0 failures.

- [ ] **Step 7: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "refactor: extract _rotate_to_healthy_next_account with a four-value contract"
```

---

## Task 3: `cmd_run` skeleton — arg parsing, dispatch, success passthrough

**Files:**
- Modify: `ccswitch.sh` — add `cmd_run()`; add `run)` to `main()` dispatch; add a `run` line to `show_usage()`.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_run.bats`:

```bash
# --- cmd_run: basic passthrough ----------------------------------------------

# A mock "claude" whose behavior is driven by env the test sets:
#   CLAUDE_MOCK_EXIT   — exit code (default 0)
#   CLAUDE_MOCK_STDOUT — printed to stdout
#   CLAUDE_MOCK_STDERR — printed to stderr
install_mock_claude() {
    cat > "$MOCK_BIN/claude" << 'M'
#!/bin/bash
[[ -n "${CLAUDE_MOCK_STDOUT:-}" ]] && printf '%s\n' "$CLAUDE_MOCK_STDOUT"
[[ -n "${CLAUDE_MOCK_STDERR:-}" ]] && printf '%s\n' "$CLAUDE_MOCK_STDERR" >&2
exit "${CLAUDE_MOCK_EXIT:-0}"
M
    chmod +x "$MOCK_BIN/claude"
}

@test "run executes the command and passes through its stdout on success" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    create_fake_credentials "a@example.com"
    install_mock_claude

    CLAUDE_MOCK_STDOUT="hello-from-claude" run run_ccswitch run -- claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello-from-claude"* ]]
}

@test "run errors when no command is given" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    run run_ccswitch run --
    [ "$status" -eq 2 ]
    [[ "$output" == *"Usage: ccs run"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "run executes\|run errors when no command"`
Expected: FAIL — `unknown command` / status mismatch.

- [ ] **Step 3: Add `cmd_run` (skeleton: parse, run once, emit on success)**

Add `cmd_run()` after `cmd_exec()`:

```bash
# Run a command (typically `claude -p ...`) on the active account, switching to
# another account and retrying when it fails because of a rate limit.
# Usage: ccs run [--max-attempts N] [--limit-threshold N] [--timeout SEC]
#                [--no-proactive] -- <command...>
cmd_run() {
    local max_attempts="" limit_threshold="95" timeout_sec="" proactive=true
    local -a cmd=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-attempts)   max_attempts="$2"; shift 2 ;;
            --limit-threshold) limit_threshold="$2"; shift 2 ;;
            --timeout)        timeout_sec="$2"; shift 2 ;;
            --no-proactive)   proactive=false; shift ;;
            --)               shift; cmd=("$@"); break ;;
            *)  echo "Error: unknown option '$1' (put the command after --)" >&2; exit 2 ;;
        esac
    done

    if [[ ${#cmd[@]} -eq 0 ]]; then
        echo "Usage: ccs run [--max-attempts N] [--limit-threshold N] [--timeout SEC] [--no-proactive] -- <command...>" >&2
        exit 2
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: no accounts are managed yet" >&2
        exit 2
    fi
    setup_directories

    local total
    total=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    [[ -z "$max_attempts" ]] && max_attempts="$total"
    [[ "$max_attempts" -lt 1 ]] && max_attempts=1

    # Buffers (cleaned up by the trap installed in Task 8).
    local out_buf
    out_buf=$(mktemp "${TMPDIR:-/tmp}/ccs-run-out.XXXXXX")

    "${cmd[@]}" >"$out_buf" 2>&1
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        cat "$out_buf"; rm -f "$out_buf"; return 0
    fi
    cat "$out_buf"; rm -f "$out_buf"
    return "$rc"
}
```

> This skeleton runs once and passes through. Detection/retry/stdin/signals are added in Tasks 4–8. `2>&1` here is temporary; Task 6/8 separate stderr streaming.

- [ ] **Step 4: Wire dispatch and help**

In `main()`, after the `resume-mode)` case (~line 3101), add:

```bash
        run)
            shift
            cmd_run "$@"
            ;;
```

In `show_usage()`, under the appropriate section, add:

```bash
    echo "  run [opts] -- <command...>       Run a command, auto-switch + retry on rate limit"
```

- [ ] **Step 5: Run to verify passing**

Run: `bats test/test_run.bats -f "run executes\|run errors when no command"`
Expected: PASS.

- [ ] **Step 6: Full suite**

Run: `bats test/`
Expected: prior total + 2, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run skeleton (parse, run, passthrough) + dispatch"
```

---

## Task 4: Rate-limit detection (grep primary, usage secondary)

**Files:**
- Modify: `ccswitch.sh` — add `_run_detect_rate_limit()`.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# --- detection ---------------------------------------------------------------

run_ccswitch_detect() {
    # args: <stdout-content> <stderr-content>; prints nothing, returns 0 if rate-limited
    local so="$1" se="$2"
    HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash -c '
        CCS_TEST_FUNC=1
        source "'"$CCSWITCH_SCRIPT"'"
        obuf=$(mktemp); ebuf=$(mktemp)
        printf "%s\n" "$1" > "$obuf"; printf "%s\n" "$2" > "$ebuf"
        _run_detect_rate_limit "$obuf" "$ebuf" "" "95"
        rc=$?; rm -f "$obuf" "$ebuf"; exit $rc
    ' _ "$so" "$se"
}

@test "detect: 429 API error on stderr is a rate limit" {
    run run_ccswitch_detect "" "API Error: Request rejected (429) rate_limit"
    [ "$status" -eq 0 ]
}

@test "detect: overloaded on stderr is a rate limit" {
    run run_ccswitch_detect "" "Error: overloaded"
    [ "$status" -eq 0 ]
}

@test "detect: an ordinary error is not a rate limit" {
    run run_ccswitch_detect "" "Error: ENOENT no such file"
    [ "$status" -ne 0 ]
}

@test "detect: the word 429 buried in stdout body does not fire" {
    # A payload merely discussing 429 (not on the final line) must not trigger.
    run run_ccswitch_detect "line one mentions http 429 in passing
final result line: all good" ""
    [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "detect:"`
Expected: FAIL — `_run_detect_rate_limit: command not found`.

- [ ] **Step 3: Implement detection**

Add before `cmd_run()`:

```bash
# Rate-limit markers, anchored on Claude Code's documented shapes. Extend freely.
readonly CCS_RATE_LIMIT_RE='API Error:.*\(429\)|Request rejected \(429\)|Retrying in .*attempt|rate.limit|overloaded|usage limit'

# Decide whether a failed run failed because of a rate limit.
# Args: <stdout-buffer> <stderr-buffer> <active-account-num> <limit-threshold>
# Returns 0 (rate-limited) or 1 (not).
_run_detect_rate_limit() {
    local out_buf="$1" err_buf="$2" account="$3" threshold="$4"

    # PRIMARY (grep): all of stderr, plus only the final result/error line(s) of
    # stdout — not the whole body — so a payload that merely discusses 429 does
    # not trigger.
    if grep -qiE "$CCS_RATE_LIMIT_RE" "$err_buf" 2>/dev/null; then
        return 0
    fi
    if tail -n 3 "$out_buf" 2>/dev/null | grep -qiE "$CCS_RATE_LIMIT_RE"; then
        return 0
    fi

    # SECONDARY (usage/health): only reached when the grep was inconclusive.
    if [[ -n "$account" ]] && is_endpoint_account "$account"; then
        probe_endpoint_health "$account" || return 0   # unhealthy endpoint = limited
        return 1
    fi
    local cache_file util util_int
    cache_file=$(usage_cache_file)
    rm -f "$cache_file"
    if fetch_usage_data; then
        # Weekly window matters: take the max of 5h and 7d utilization.
        util=$(jq -r '[(.five_hour.utilization // 0), (.seven_day.utilization // 0)] | max' \
                 "$cache_file" 2>/dev/null || echo "0")
        if util_int=$(usage_to_int "$util"); then
            [[ "$util_int" -ge "$threshold" ]] && return 0
        fi
    fi
    return 1
}
```

- [ ] **Step 4: Run to verify passing**

Run: `bats test/test_run.bats -f "detect:"`
Expected: PASS (all four). The "buried 429" test passes because the marker is on line 1 of a 2-line stdout, and `tail -n 3` still includes it — adjust the test payload to have >3 trailing clean lines, OR tighten the assertion. Use this payload instead so the marker is clearly outside the final lines:

```bash
@test "detect: the word 429 buried early in stdout body does not fire" {
    run run_ccswitch_detect "http 429 appears here in a log excerpt
clean line 2
clean line 3
clean line 4
final result: ok" ""
    [ "$status" -ne 0 ]
}
```

Re-run and confirm PASS.

- [ ] **Step 5: Full suite**

Run: `bats test/`
Expected: prior total + 4, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run rate-limit detection (grep primary, usage secondary)"
```

---

## Task 5: Retry loop with rotation (pins 2, 3, 4) + exhaustion contract

**Files:**
- Modify: `ccswitch.sh` `cmd_run()` — replace the single-shot body with the bounded retry loop.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# --- retry + rotation --------------------------------------------------------

# A mock claude that fails with a rate-limit marker while active account is 1,
# and succeeds once the active account is 2. Reads active from sequence.json.
install_mock_claude_switch_aware() {
    cat > "$MOCK_BIN/claude" << M
#!/bin/bash
active=\$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
if [[ "\$active" == "1" ]]; then
    echo "API Error: Request rejected (429) rate_limit" >&2
    exit 1
fi
echo "ok-on-account-\$active"
exit 0
M
    chmod +x "$MOCK_BIN/claude"
}

@test "run rotates on a rate limit and succeeds on the next account" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":10.0,"limit":100,"used":10}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    install_mock_claude_switch_aware

    run run_ccswitch run --no-proactive -- claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok-on-account-2"* ]]
    # The failed attempt's stdout must not leak.
    [[ "$output" != *"429"* ]]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 2 ]
}

@test "run passes a non-rate-limit failure straight through without switching" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    install_mock_claude
    CLAUDE_MOCK_EXIT=7 CLAUDE_MOCK_STDERR="Error: bad input" run run_ccswitch run --no-proactive -- claude -p "hi"
    [ "$status" -eq 7 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
}

@test "run exits 3 with a machine-readable line when all accounts are exhausted" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # Candidate always over threshold -> no healthy account.
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":99.0,"limit":100,"used":99}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    # claude always rate-limits.
    cat > "$MOCK_BIN/claude" << 'M'
#!/bin/bash
echo "API Error: Request rejected (429)" >&2
exit 1
M
    chmod +x "$MOCK_BIN/claude"

    run run_ccswitch run --no-proactive -- claude -p "hi"
    [ "$status" -eq 3 ]
    [[ "$output" == *"ccs-run: exhausted"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "run rotates\|run passes a non-rate\|run exits 3"`
Expected: FAIL — skeleton neither rotates nor prints the machine line.

- [ ] **Step 3: Replace the `cmd_run` body with the retry loop**

Replace the run-once block (from `local out_buf` through `return "$rc"`) with:

```bash
    local out_buf err_buf
    out_buf=$(mktemp "${TMPDIR:-/tmp}/ccs-run-out.XXXXXX")
    err_buf=$(mktemp "${TMPDIR:-/tmp}/ccs-run-err.XXXXXX")

    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))

        # PIN 3 + PIN 4: re-read the expected-active account (endpoint-aware view)
        # before EVERY spawn. A stale value would make the CAS fail forever after
        # the first rotation and spin without progress.
        local started_account
        started_account=$(effective_active_account_num)

        : > "$out_buf"; : > "$err_buf"
        "${cmd[@]}" >"$out_buf" 2> >(tee "$err_buf" >&2)
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            cat "$out_buf"; rm -f "$out_buf" "$err_buf"; return 0
        fi

        if ! _run_detect_rate_limit "$out_buf" "$err_buf" "$started_account" "$limit_threshold"; then
            # Genuine non-rate-limit failure: pass it straight through.
            cat "$out_buf"; rm -f "$out_buf" "$err_buf"; return "$rc"
        fi

        # PIN 2: subshell + rc capture (perform_switch fails via `exit 1`).
        local hrc
        hrc=$( _rotate_to_healthy_next_account "$started_account" >/dev/null 2>&1; echo $? )
        case "$hrc" in
            0|3) : ;;   # switched-healthy, or someone-else-rotated: retry either way
            2)  echo "ccs-run: switch-error attempts=$attempt" >&2
                cat "$out_buf"; rm -f "$out_buf" "$err_buf"; return 2 ;;
            *)  # 1 = all exhausted
                echo "ccs-run: exhausted accounts=$total attempts=$attempt" >&2
                cat "$out_buf"; rm -f "$out_buf" "$err_buf"; return 3 ;;
        esac
    done

    echo "ccs-run: exhausted accounts=$total attempts=$attempt" >&2
    cat "$out_buf"; rm -f "$out_buf" "$err_buf"; return 3
```

- [ ] **Step 4: Run to verify passing**

Run: `bats test/test_run.bats -f "run rotates\|run passes a non-rate\|run exits 3"`
Expected: PASS (all three).

- [ ] **Step 5: Full suite**

Run: `bats test/`
Expected: prior total + 3, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run retry loop with CAS rotation and exhaustion contract"
```

---

## Task 6: Spool-first stdin replay

**Files:**
- Modify: `ccswitch.sh` `cmd_run()` — spool non-tty stdin before the loop; feed each attempt from it.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing test**

Append:

```bash
# --- stdin replay ------------------------------------------------------------

@test "run replays stdin byte-identically on the retry" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":10.0,"limit":100,"used":10}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    # Fail (429) on account 1, but on account 2 echo back the stdin it received.
    cat > "$MOCK_BIN/claude" << M
#!/bin/bash
active=\$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
input=\$(cat)
if [[ "\$active" == "1" ]]; then echo "429 rate_limit" >&2; exit 1; fi
echo "GOT:\$input"
M
    chmod +x "$MOCK_BIN/claude"

    run bash -c 'printf "%s" "the-secret-prompt" | HOME="'"$TEST_HOME"'" PATH="'"$MOCK_BIN:$ORIGINAL_PATH"'" /bin/bash "'"$CCSWITCH_SCRIPT"'" run --no-proactive -- claude -p'
    [ "$status" -eq 0 ]
    [[ "$output" == *"GOT:the-secret-prompt"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "replays stdin"`
Expected: FAIL — attempt 2 gets empty stdin (`GOT:`), not the prompt.

- [ ] **Step 3: Add spool-first stdin**

In `cmd_run()`, after computing `max_attempts` and before creating `out_buf`, add:

```bash
    # Spool non-tty stdin so every attempt replays byte-identical input. A live
    # pipe would be drained by attempt 1; a concurrent tee could truncate on
    # SIGPIPE if attempt 1 exits early. Read it fully up front instead.
    local stdin_spool=""
    if [[ ! -t 0 ]]; then
        stdin_spool=$(mktemp "${TMPDIR:-/tmp}/ccs-run-stdin.XXXXXX")
        chmod 600 "$stdin_spool"
        cat > "$stdin_spool"
    fi
```

Change the child invocation inside the loop to redirect stdin from the spool when present:

```bash
        if [[ -n "$stdin_spool" ]]; then
            "${cmd[@]}" <"$stdin_spool" >"$out_buf" 2> >(tee "$err_buf" >&2)
        else
            "${cmd[@]}" >"$out_buf" 2> >(tee "$err_buf" >&2)
        fi
        local rc=$?
```

Add `rm -f ${stdin_spool:+"$stdin_spool"}` to every `rm -f "$out_buf" "$err_buf"` line in the loop (4 sites) and the final one. (Task 8 replaces these scattered `rm`s with a single trap-based cleanup; for now keep them consistent.)

- [ ] **Step 4: Run to verify passing**

Run: `bats test/test_run.bats -f "replays stdin"`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `bats test/`
Expected: prior total + 1, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run spool-first stdin replay across attempts"
```

---

## Task 7: Internal-retry env + proactive pre-check

**Files:**
- Modify: `ccswitch.sh` `cmd_run()` — export bounded-retry env for the child; add `_run_proactive_precheck` and call it on attempt 1.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# --- retry env + proactive ---------------------------------------------------

@test "run bounds the child's internal retries via env by default" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/claude" << 'M'
#!/bin/bash
echo "MAX=${CLAUDE_CODE_MAX_RETRIES:-unset} WD=${CLAUDE_CODE_RETRY_WATCHDOG:-unset}"
exit 0
M
    chmod +x "$MOCK_BIN/claude"

    run run_ccswitch run --no-proactive -- claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MAX=3 WD=0"* ]]
}

@test "run respects a caller-provided CLAUDE_CODE_MAX_RETRIES" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/claude" << 'M'
#!/bin/bash
echo "MAX=${CLAUDE_CODE_MAX_RETRIES:-unset}"
exit 0
M
    chmod +x "$MOCK_BIN/claude"

    CLAUDE_CODE_MAX_RETRIES=9 run run_ccswitch run --no-proactive -- claude -p "hi"
    [[ "$output" == *"MAX=9"* ]]
}

@test "run proactively rotates before attempt 1 when the active account is over threshold" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # Cache says active account 1 is at 99% (over the proactive threshold 80).
    create_fake_usage_cache "a@example.com" "99.0"
    local u; u=$(jq '.rateLimit={enabled:true,threshold:80}' "$SEQUENCE_FILE"); echo "$u" > "$SEQUENCE_FILE"
    # Candidate healthy; claude just echoes the active account.
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":10.0,"limit":100,"used":10}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    cat > "$MOCK_BIN/claude" << M
#!/bin/bash
echo "ran-on-\$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")"
M
    chmod +x "$MOCK_BIN/claude"

    run run_ccswitch run -- claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ran-on-2"* ]]
}
```

> Check `create_fake_usage_cache`'s signature with `grep -n 'create_fake_usage_cache' test/test_helper.bash` and match its argument order; adjust the call if needed.

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "bounds the child\|respects a caller\|proactively rotates"`
Expected: FAIL — env not exported (`MAX=unset`); no proactive rotation (`ran-on-1`).

- [ ] **Step 3: Export retry env for the child**

Wrap the child invocation in a subshell that exports the env (respecting caller overrides). Replace the invocation block from Task 6 with:

```bash
        if [[ -n "$stdin_spool" ]]; then
            (
                export CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-3}"
                export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-0}"
                exec "${cmd[@]}" <"$stdin_spool"
            ) >"$out_buf" 2> >(tee "$err_buf" >&2)
        else
            (
                export CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-3}"
                export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-0}"
                exec "${cmd[@]}"
            ) >"$out_buf" 2> >(tee "$err_buf" >&2)
        fi
        local rc=$?
```

- [ ] **Step 4: Add and call the proactive pre-check**

Add before `cmd_run()`:

```bash
# Before the first attempt, if the active account is already over the proactive
# threshold per the (fresh-enough) cache, rotate off it so we don't burn an
# attempt on a known-exhausted account. Best-effort: silent on any failure.
_run_proactive_precheck() {
    local active="$1"
    local cache_file threshold util util_int
    cache_file=$(usage_cache_file)
    threshold=$(_rate_threshold)
    [[ -f "$cache_file" ]] || return 0
    # Reuse cache_freshness (handles TTL + account-email match).
    local email
    email=$(account_display_id "$active" 2>/dev/null || true)
    if [[ "$(cache_freshness "$cache_file" "$DEFAULT_CACHE_TTL" "$email" 2>/dev/null)" != "fresh" ]]; then
        return 0
    fi
    util=$(jq -r '[(.five_hour.utilization // 0), (.seven_day.utilization // 0)] | max' \
             "$cache_file" 2>/dev/null || echo "0")
    util_int=$(usage_to_int "$util") || return 0
    if [[ "$util_int" -ge "$threshold" ]]; then
        _rotate_to_healthy_next_account "$active" >/dev/null 2>&1 || true
    fi
}
```

In the loop, after reading `started_account`, add the attempt-1 pre-check:

```bash
        if [[ $attempt -eq 1 && "$proactive" == true ]]; then
            _run_proactive_precheck "$started_account"
            started_account=$(effective_active_account_num)
        fi
```

> Confirm `cache_freshness`'s exact argument order with `grep -n 'cache_freshness()' ccswitch.sh` and match it. If its signature differs, adapt the call.

- [ ] **Step 5: Run to verify passing**

Run: `bats test/test_run.bats -f "bounds the child\|respects a caller\|proactively rotates"`
Expected: PASS (all three).

- [ ] **Step 6: Full suite**

Run: `bats test/`
Expected: prior total + 3, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run bounded-retry env + proactive pre-check"
```

---

## Task 8: Signals, `--timeout` watchdog, grep-on-timeout, unified cleanup

**Files:**
- Modify: `ccswitch.sh` `cmd_run()` — trap INT/TERM, background watchdog, single cleanup function.
- Test: `test/test_run.bats`

- [ ] **Step 1: Write the failing tests**

Append:

```bash
# --- timeout + signals -------------------------------------------------------

@test "run kills a child that exceeds --timeout and passes 124 through" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    create_fake_credentials "a@example.com"
    # A claude that hangs, with no rate-limit output.
    cat > "$MOCK_BIN/claude" << 'M'
#!/bin/bash
sleep 30
M
    chmod +x "$MOCK_BIN/claude"

    run run_ccswitch run --no-proactive --timeout 1 -- claude -p "hi"
    [ "$status" -eq 124 ]
}

@test "run treats a timed-out child that was mid-rate-limit as a rate limit" {
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    setup_fake_account "b@example.com" "uuid-b"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":10.0,"limit":100,"used":10}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    # On account 1: print a retry/backoff line then hang (killed by timeout).
    # On account 2: succeed fast.
    cat > "$MOCK_BIN/claude" << M
#!/bin/bash
active=\$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
if [[ "\$active" == "1" ]]; then echo "Retrying in 2s attempt 1/3" >&2; sleep 30; fi
echo "ok-on-\$active"
M
    chmod +x "$MOCK_BIN/claude"

    run run_ccswitch run --no-proactive --timeout 1 -- claude -p "hi"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok-on-2"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats test/test_run.bats -f "exceeds --timeout\|timed-out child that was mid-rate"`
Expected: FAIL — no watchdog; first test hangs ~30s then fails, second doesn't rotate.

- [ ] **Step 3: Add cleanup + trap + watchdog + timeout-aware classification**

At the top of `cmd_run` (after the buffers are created), add cleanup state and traps:

```bash
    local child_pid="" watchdog_pid=""
    _ccs_run_cleanup() {
        [[ -n "$watchdog_pid" ]] && kill "$watchdog_pid" 2>/dev/null
        [[ -n "$child_pid" ]] && kill -TERM "$child_pid" 2>/dev/null
        rm -f "$out_buf" "$err_buf" ${stdin_spool:+"$stdin_spool"}
    }
    trap '_ccs_run_cleanup; trap - INT TERM; exit 130' INT
    trap '_ccs_run_cleanup; trap - INT TERM; exit 143' TERM
```

Replace the child invocation + `rc` capture with a backgrounded run + watchdog:

```bash
        (
            export CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-3}"
            export CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-0}"
            if [[ -n "$stdin_spool" ]]; then exec "${cmd[@]}" <"$stdin_spool"
            else exec "${cmd[@]}"; fi
        ) >"$out_buf" 2> >(tee "$err_buf" >&2) &
        child_pid=$!

        local timed_out=0
        if [[ -n "$timeout_sec" ]]; then
            ( sleep "$timeout_sec"; kill -TERM "$child_pid" 2>/dev/null ) &
            watchdog_pid=$!
        fi
        wait "$child_pid"; local rc=$?
        child_pid=""
        if [[ -n "$watchdog_pid" ]]; then
            if kill -0 "$watchdog_pid" 2>/dev/null; then
                kill "$watchdog_pid" 2>/dev/null   # child finished first
            else
                timed_out=1                          # watchdog fired
            fi
            wait "$watchdog_pid" 2>/dev/null; watchdog_pid=""
        fi
```

After the `rc -eq 0` success branch, insert timeout handling BEFORE the detection call:

```bash
        if [[ $timed_out -eq 1 ]]; then
            # A child killed mid-backoff is a paradigm rate-limit case: still
            # consult the buffered output before giving up.
            if ! _run_detect_rate_limit "$out_buf" "$err_buf" "$started_account" "$limit_threshold"; then
                echo "ccs-run: timeout attempts=$attempt" >&2
                _ccs_run_cleanup; trap - INT TERM; return 124
            fi
            # fall through to rotation below (treat as rate-limited)
        elif ! _run_detect_rate_limit "$out_buf" "$err_buf" "$started_account" "$limit_threshold"; then
            cat "$out_buf"; _ccs_run_cleanup; trap - INT TERM; return "$rc"
        fi
```

Replace the earlier scattered `rm -f ...; return N` sites in the rotation `case` and the final line with `_ccs_run_cleanup; trap - INT TERM; return N` (cleanup now owns temp removal). Remove the now-redundant per-branch `cat "$out_buf"; rm -f ...` lines except the `cat "$out_buf"` where output must still be emitted (exhaustion + non-limit passthrough).

- [ ] **Step 4: Run to verify passing**

Run: `bats test/test_run.bats -f "exceeds --timeout\|timed-out child that was mid-rate"`
Expected: PASS (first returns 124 in ~1s; second rotates to account 2).

- [ ] **Step 5: Full suite (watch for leaked temp files / hangs)**

Run: `bats test/`
Expected: prior total + 2, 0 failures. Then:
Run: `ls "${TMPDIR:-/tmp}"/ccs-run-* 2>/dev/null | wc -l`
Expected: `0` (no leaked buffers).

- [ ] **Step 6: Commit**

```bash
git add ccswitch.sh test/test_run.bats
git commit -m "feat: ccs run --timeout watchdog, signal traps, grep-on-timeout, unified cleanup"
```

---

## Task 9: Completions, help, README, CHANGELOG

**Files:**
- Modify: `completions/ccswitch.bash`, `completions/ccswitch.zsh`, `completions/ccswitch.fish`, `README.md`, `README.ja.md`, `CHANGELOG.md`.
- Test: manual + `bats test/` regression.

- [ ] **Step 1: bash completion**

In `completions/ccswitch.bash`, add `run` to the top-level `commands` string and add option completion:

```bash
        run)
            COMPREPLY=($(compgen -W "--max-attempts --limit-threshold --timeout --no-proactive --" -- "$cur"))
            return 0
            ;;
```

- [ ] **Step 2: zsh completion**

In `completions/ccswitch.zsh`, add `run` alongside the other subcommands in the `_describe`/`commands` list with a description `'run:Run a command, auto-switch + retry on rate limit'`.

- [ ] **Step 3: fish completion**

In `completions/ccswitch.fish`, add:

```fish
complete -c ccs -n '__ccs_needs_command' -a 'run' -d 'Run a command, auto-switch + retry on rate limit'
```

And add `'run'` to the `__ccs_needs_command` subcommand `case` list.

- [ ] **Step 4: help text**

Confirm the `show_usage()` line from Task 3 exists and add the option lines under the OPTIONS section:

```bash
    echo "  --max-attempts N                 ccs run: cap attempts (default: number of accounts)"
    echo "  --limit-threshold N              ccs run: usage%% for the secondary limit check (default 95)"
    echo "  --timeout SEC                    ccs run: per-attempt deadline"
    echo "  --no-proactive                   ccs run: skip the pre-run usage check"
```

And an example:

```bash
    echo "  ccs run -- claude -p \"summarize\"           # Auto-switch + retry on rate limit"
```

- [ ] **Step 5: README (both languages)**

Add a "Reactive auto-switch (`ccs run`)" subsection to `README.md` and `README.ja.md` near the rate-limit section. Cover: purpose (headless orchestrators), the grep-primary detection, `--max-attempts`/`--limit-threshold`/`--timeout`/`--no-proactive`, the machine-readable `ccs-run: exhausted …` line and exit codes (0 / child / 3 / 2 / 124), and the two documented caveats:
- **Idempotency:** a rate-limited attempt may have partially run side-effecting tool calls; the default retry re-runs the command, so side effects can duplicate.
- **Buffered stdout:** loses `stream-json` liveness and may trip an orchestrator's inactivity timeout.

- [ ] **Step 6: CHANGELOG**

Add under `## [Unreleased]`:

```markdown
### Added

- `ccs run -- <command...>` runs a command (typically `claude -p`) on the active account and, when it fails because the account is rate-limited, switches to the next healthy account and retries. Detection is format-agnostic (greps the failed run's output for `429`/`rate_limit`/`overloaded`/`usage limit`, with a usage-API check as a fallback), so it complements the proactive PreToolUse hook — which structurally cannot see a mid-turn 429 — for headless orchestrators. stdin is replayed per attempt, only the successful attempt's stdout is emitted, internal Claude retries are bounded, and an exhaustion prints a machine-readable `ccs-run: exhausted …` line (exit 3). Note: retries can duplicate side effects of a partially-run command.
```

- [ ] **Step 7: Lint + full suite**

Run: `shellcheck ccswitch.sh` → Expected: clean (0 warnings).
Run: `bats test/` → Expected: all green, count = prior + all Task-1..8 additions.

- [ ] **Step 8: Commit**

```bash
git add completions README.md README.ja.md CHANGELOG.md ccswitch.sh
git commit -m "docs: ccs run completions, help, README, CHANGELOG"
```

---

## Final verification

- [ ] `bats test/` — all green, no dropped tests.
- [ ] `shellcheck ccswitch.sh hooks/*.sh statusline/*.sh` — clean.
- [ ] `ls "${TMPDIR:-/tmp}"/ccs-run-* 2>/dev/null | wc -l` → `0` after a run.
- [ ] Review pin 3 first: `grep -n 'started_account=\$(effective_active_account_num)' ccswitch.sh` shows the read INSIDE the loop.
- [ ] Open a PR from `feature/ccs-run`.

## Notes on the pins (spec §14)

1. `return 3` releases the lock first — verified in Task 1 Step 4.
2. Helper + `cmd_run` call `perform_switch`/helper in a subshell with `rc=$?` capture, never `if !` — Tasks 2 & 5.
3. `expected_active`/`started_account` re-read before every spawn (inside the loop) — Task 5 Step 3; final-check above.
4. The account number comes from `effective_active_account_num` — Task 5 Step 3.
