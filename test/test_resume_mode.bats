#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() {
    rm -f "$TEST_HOME/claude-argv" 2>/dev/null || true
    teardown_test_env
}

# --- resume_mode resolution -------------------------------------------------

@test "test_resume_mode_defaults_to_fork_without_config" {
    source_ccswitch_functions
    [ "$(resume_mode)" = "fork" ]
}

@test "test_resume_mode_reads_configured_mode" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    _set_configured_resume_mode "same"

    source_ccswitch_functions
    [ "$(resume_mode)" = "same" ]
}

@test "test_resume_mode_flag_overrides_configured_mode" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    _set_configured_resume_mode "same"

    source_ccswitch_functions
    RESUME_MODE="fork"
    [ "$(resume_mode)" = "fork" ]
}

@test "test_resume_mode_falls_back_to_fork_on_unknown_config" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    _set_configured_resume_mode "bogus"

    source_ccswitch_functions
    [ "$(resume_mode)" = "fork" ]
}

# --- build_resume_command with an explicit mode -----------------------------

@test "test_build_resume_command_same_mode_omits_fork_session" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "sid-123" same)" = "claude --resume sid-123" ]
}

@test "test_build_resume_command_fork_mode_adds_fork_session" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "sid-123" fork)" = "claude --resume sid-123 --fork-session" ]
}

@test "test_build_resume_command_same_mode_without_session_is_fresh" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "" same)" = "claude" ]
}

# --- ccs resume-mode --------------------------------------------------------

@test "test_resume_mode_command_prints_current_mode" {
    run run_ccswitch resume-mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resume mode: fork"* ]]
}

@test "test_resume_mode_command_persists_same" {
    run run_ccswitch resume-mode same
    [ "$status" -eq 0 ]
    [ "$(jq -r '.resume.mode' "$SEQUENCE_FILE")" = "same" ]

    run run_ccswitch resume-mode
    [[ "$output" == *"Resume mode: same"* ]]
}

@test "test_resume_mode_command_persists_fork" {
    run run_ccswitch resume-mode same
    run run_ccswitch resume-mode fork
    [ "$status" -eq 0 ]
    [ "$(jq -r '.resume.mode' "$SEQUENCE_FILE")" = "fork" ]
}

@test "test_resume_mode_command_rejects_invalid_mode" {
    run run_ccswitch resume-mode bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid resume mode"* ]]
}

@test "test_resume_mode_command_keeps_other_sequence_keys" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch resume-mode same
    [ "$status" -eq 0 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
    [ "$(jq -r '.accounts["1"].email' "$SEQUENCE_FILE")" = "user1@example.com" ]
}

# --- switching with a mode --------------------------------------------------

# Mock `claude` that records the argv it was exec'd with, then exits 0.
_install_claude_mock() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/bin/bash
printf '%s' "\$*" > "$TEST_HOME/claude-argv"
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
}

_set_configured_resume_mode() {
    local mode="$1" updated
    mkdir -p "$(dirname "$SEQUENCE_FILE")"
    [[ -f "$SEQUENCE_FILE" ]] || echo '{}' > "$SEQUENCE_FILE"
    updated=$(jq --arg m "$mode" '.resume = {mode: $m}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
}

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

@test "test_to_with_resume_no_fork_session_keeps_the_session" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch to 2 --resume --no-fork-session
    [ -f "$TEST_HOME/claude-argv" ]
    [ "$(cat "$TEST_HOME/claude-argv")" = "--resume sess-xyz" ]
}

@test "test_to_with_resume_uses_configured_same_mode" {
    _setup_two_accounts_with_session
    _set_configured_resume_mode "same"
    _install_claude_mock

    run run_ccswitch to 2 --resume
    [ -f "$TEST_HOME/claude-argv" ]
    [ "$(cat "$TEST_HOME/claude-argv")" = "--resume sess-xyz" ]
}

@test "test_to_with_resume_fork_session_flag_beats_configured_same_mode" {
    _setup_two_accounts_with_session
    _set_configured_resume_mode "same"
    _install_claude_mock

    run run_ccswitch to 2 --resume --fork-session
    [ -f "$TEST_HOME/claude-argv" ]
    grep -q -- "--resume sess-xyz --fork-session" "$TEST_HOME/claude-argv"
}

@test "test_sw_with_resume_no_fork_session_keeps_the_session" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch sw --resume --no-fork-session
    [ -f "$TEST_HOME/claude-argv" ]
    [ "$(cat "$TEST_HOME/claude-argv")" = "--resume sess-xyz" ]
}

@test "test_dry_run_with_resume_no_fork_session_shows_same_session_plan" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch -n to 2 --resume --no-fork-session
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --resume sess-xyz"* ]]
    [[ "$output" != *"--fork-session"* ]]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
    [ ! -f "$TEST_HOME/claude-argv" ]
}
