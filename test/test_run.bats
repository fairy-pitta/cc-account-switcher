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
