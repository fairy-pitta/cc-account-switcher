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

@test "test_capture_resume_session_id_reads_lastsessionid_for_cwd" {
    create_fake_claude_config "user1@example.com" "uuid-1"
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

# Mock `claude` that records the argv it was exec'd with, then exits 0.
_install_claude_mock() {
    cat > "$MOCK_BIN/claude" <<EOF
#!/bin/bash
printf '%s' "\$*" > "$TEST_HOME/claude-argv"
exit 0
EOF
    chmod +x "$MOCK_BIN/claude"
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
    _install_claude_mock

    run run_ccswitch to 2 --resume
    [ -f "$TEST_HOME/claude-argv" ]
    [ ! -s "$TEST_HOME/claude-argv" ]   # no args passed -> fresh launch
}

@test "test_sw_with_resume_relaunches_with_fork_session" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch sw --resume
    [ -f "$TEST_HOME/claude-argv" ]
    grep -q -- "--resume sess-xyz --fork-session" "$TEST_HOME/claude-argv"
}

@test "test_to_already_active_with_resume_still_relaunches" {
    _setup_two_accounts_with_session
    _install_claude_mock
    run run_ccswitch to 1 --resume
    [ -f "$TEST_HOME/claude-argv" ]
    grep -q -- "--resume sess-xyz --fork-session" "$TEST_HOME/claude-argv"
}

@test "test_dry_run_with_resume_shows_plan_and_does_not_switch" {
    _setup_two_accounts_with_session
    _install_claude_mock

    run run_ccswitch -n to 2 --resume
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"--resume sess-xyz --fork-session"* ]]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
    [ ! -f "$TEST_HOME/claude-argv" ]
}
