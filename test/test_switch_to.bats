#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_switch_to_by_account_number_switches_correctly" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch-to 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_switch_to_by_email_switches_correctly" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch-to user2@example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_switch_to_nonexistent_number_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch --switch-to 99
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "test_switch_to_nonexistent_email_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch --switch-to nobody@example.com
    [ "$status" -eq 1 ]
    [[ "$output" == *"No account found with email"* ]]
}

@test "test_switch_to_invalid_email_format_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch --switch-to "not-an-email"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid email format"* ]]
}

@test "test_switch_to_without_argument_shows_usage" {
    run run_ccswitch --switch-to
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "test_switch_to_with_no_managed_accounts_shows_error" {
    run run_ccswitch --switch-to 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"No accounts are managed yet"* ]]
}

# --- Regression: sequence.json activeAccountNumber drifted from reality ---
# If the stored active number disagrees with the credential actually live
# (.claude.json email), perform_switch must NOT misfile the live credential
# under the wrong slot or restore a stale one. The email is the source of truth.

@test "test_switch_to_stale_active_number_preserves_live_credential" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    # Reality: we are really on account 1 (user1). Distinct LIVE global credential.
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" \
        -w '{"access_token":"LIVE-user1","refresh_token":"rt-user1"}'
    # Account 1's backup is STALE/different (a buggy restore would clobber global with this)
    security add-generic-password -U -s "Claude Code-Account-1-user1@example.com" -a "$USER" \
        -w '{"access_token":"STALE-user1","refresh_token":"rt-user1"}'
    # Inconsistency: stored active number says 2, but we're really on 1
    local updated
    updated=$(jq '.activeAccountNumber = 2' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    # Switch to the account we are really on
    run run_ccswitch --switch-to 1

    # Live credential must be preserved, never overwritten with the stale backup
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    [[ "$creds" == *"LIVE-user1"* ]]
    # No spurious backup misfiled under account 2 with account 1's email
    run security find-generic-password -s "Claude Code-Account-2-user1@example.com" -w
    [ "$status" -ne 0 ]
}

@test "test_switch_to_stale_active_number_backs_up_under_real_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    # Reality: really on account 1 (user1) with a distinct LIVE credential
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" \
        -w '{"access_token":"LIVE-user1","refresh_token":"rt-user1"}'
    # Inconsistency: stored active number says 2
    local updated
    updated=$(jq '.activeAccountNumber = 2' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    # A genuine switch to account 2 must proceed (not wrongly no-op) and back up
    # the live credential under account 1 (the REAL current), not a wrong slot.
    run run_ccswitch --switch-to 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]

    # Account 1's backup now holds the live credential we were on
    local acct1
    acct1=$(security find-generic-password -s "Claude Code-Account-1-user1@example.com" -w 2>/dev/null)
    [[ "$acct1" == *"LIVE-user1"* ]]
    # No spurious misfiled item
    run security find-generic-password -s "Claude Code-Account-2-user1@example.com" -w
    [ "$status" -ne 0 ]
}
