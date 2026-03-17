#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_add_account_with_valid_login_initializes_sequence_json" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added Account 1: user1@example.com"* ]]

    # Verify sequence.json exists and is valid JSON
    [ -f "$SEQUENCE_FILE" ]
    run jq . "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]
}

@test "test_add_account_with_valid_login_stores_credentials_and_config" {
    setup_fake_account "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Verify backup config exists
    [ -f "$BACKUP_DIR/configs/.claude-config-1-user1@example.com.json" ]

    # Verify credentials stored in mock keychain
    local stored_creds
    stored_creds=$(security find-generic-password -s "Claude Code-Account-1-user1@example.com" -w)
    [ -n "$stored_creds" ]
}

@test "test_add_account_with_duplicate_email_shows_already_managed" {
    setup_fake_account "user1@example.com" "uuid-1"

    # Add first time
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Add again - should be idempotent
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]
    [[ "$output" == *"already managed"* ]]
}

@test "test_add_account_with_no_active_login_shows_error" {
    # No config file created = no active login
    run run_ccswitch --add-account
    [ "$status" -eq 1 ]
    [[ "$output" == *"No active Claude account found"* ]]
}

@test "test_add_account_with_no_credentials_shows_error" {
    # Create config but no credentials
    create_fake_claude_config "user1@example.com" "uuid-1"

    run run_ccswitch --add-account
    [ "$status" -eq 1 ]
    [[ "$output" == *"No credentials found"* ]]
}

@test "test_add_account_multiple_accounts_builds_correct_sequence" {
    # Add first account
    setup_fake_account "user1@example.com" "uuid-1"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Switch to second account
    setup_fake_account "user2@example.com" "uuid-2"
    run run_ccswitch --add-account
    [ "$status" -eq 0 ]

    # Verify sequence.json structure
    local count
    count=$(jq '.sequence | length' "$SEQUENCE_FILE")
    [ "$count" -eq 2 ]

    local first_email second_email
    first_email=$(jq -r '.accounts["1"].email' "$SEQUENCE_FILE")
    second_email=$(jq -r '.accounts["2"].email' "$SEQUENCE_FILE")
    [ "$first_email" = "user1@example.com" ]
    [ "$second_email" = "user2@example.com" ]

    # Active should be the last added
    local active
    active=$(jq '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}
