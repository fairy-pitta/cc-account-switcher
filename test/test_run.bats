#!/usr/bin/env bats
#
# ccs run — reactive rate-limit auto-switch, and the perform_switch CAS /
# rotate helper it is built on.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# --- perform_switch compare-and-swap (expected_active) ------------------------

@test "perform_switch with matching expected_active performs the switch" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    # add_account_to_sequence creates backup files for both accounts.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    # Switch 1 -> 2, asserting we are still on 1.
    run run_ccswitch_perform_switch 2 1
    [ "$status" -eq 0 ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "perform_switch with mismatching expected_active returns 3 and does not switch" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    # add_account_to_sequence creates backup files for both accounts.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    # We claim to expect account 9 (not the live 1) -> lost race -> return 3.
    run run_ccswitch_perform_switch 2 9
    [ "$status" -eq 3 ]
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
    # Lock must not be left stranded after a CAS miss.
    [ ! -d "$BACKUP_DIR/.switch.lock" ]
}

# --- _rotate_to_healthy_next_account ------------------------------------------

run_ccswitch_rotate() {
    HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash -c '
        CCS_TEST_FUNC=1
        source "'"$CCSWITCH_SCRIPT"'"
        _rotate_to_healthy_next_account "$@"
    ' _ "$@"
}

@test "rotate helper returns 0 and lands on a healthy next account" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
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
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"

    run run_ccswitch_rotate 9
    [ "$status" -eq 3 ]
    [ "$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")" -eq 1 ]
}

@test "rotate helper returns 1 when every other account is over threshold" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":99.0,"limit":100,"used":99}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    local u; u=$(jq '.rateLimit = {enabled:true, threshold:80}' "$SEQUENCE_FILE"); echo "$u" > "$SEQUENCE_FILE"

    run run_ccswitch_rotate 1
    [ "$status" -eq 1 ]
}

@test "rotate helper honors threshold passed as arg 2 over config" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # Candidate reports 90% usage.
    cat > "$MOCK_BIN/curl" << 'M'
#!/bin/bash
echo '{"five_hour":{"utilization":90.0,"limit":100,"used":90}}'
echo "200"
M
    chmod +x "$MOCK_BIN/curl"
    # Config threshold 95 (90 < 95 => would be healthy), but arg 2 = 80 (90 >= 80 => exhausted).
    # Pass empty expected_active (no CAS) so perform_switch rotates unconditionally.
    local u; u=$(jq '.rateLimit = {enabled:true, threshold:95}' "$SEQUENCE_FILE"); echo "$u" > "$SEQUENCE_FILE"
    run run_ccswitch_rotate "" 80
    [ "$status" -eq 1 ]
}

@test "rotate helper returns 2 when perform_switch fails (missing target credentials)" {
    # Only setup_fake_account for the ACTIVE account so .claude.json reflects it.
    setup_fake_account "a@example.com" "uuid-a"
    add_account_to_sequence "1" "a@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "b@example.com" "uuid-b" "false"
    create_fake_credentials "a@example.com"
    # Remove account 2's backup credentials from the mock keychain so perform_switch
    # hits the "Missing backup data" branch and exits 1, causing the helper to return 2.
    local keychain_dir="$TEST_HOME/.mock-keychain"
    rm -f "$keychain_dir/Claude_Code-Account-2-b@example.com"

    run run_ccswitch_rotate ""
    [ "$status" -eq 2 ]
}

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
