#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_switch_rotates_to_next_account_in_sequence" {
    # Set up two accounts, first is active
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    # Current credentials for user1
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_switch_wraps_around_from_last_to_first" {
    # Set up two accounts, second is active
    setup_fake_account "user2@example.com" "uuid-2"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"

    # Current credentials for user2
    create_fake_credentials "user2@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-1 (user1@example.com)"* ]]
}

@test "test_switch_updates_active_account_number_in_sequence_json" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]

    local active
    active=$(jq '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_switch_restores_correct_credentials" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]

    # Check that active credentials are now for user2
    local current_creds
    current_creds=$(security find-generic-password -s "Claude Code-credentials" -w)
    [[ "$current_creds" == *"user2@example.com"* ]]
}

@test "test_switch_restores_correct_oauth_config" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]

    # Check that config now has user2's email
    local config_email
    config_email=$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude/.claude.json")
    [ "$config_email" = "user2@example.com" ]
}

@test "test_switch_with_single_account_stays_on_same" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-1 (user1@example.com)"* ]]
}

@test "test_switch_with_unmanaged_active_account_auto_adds_it" {
    # Create a sequence file with one account, but the active config is different
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Set up a DIFFERENT account as active in .claude.json
    setup_fake_account "unmanaged@example.com" "uuid-unmanaged"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"was not managed"* ]]
    [[ "$output" == *"automatically added"* ]]
}

@test "test_switch_with_no_managed_accounts_shows_error" {
    # No sequence file at all
    run run_ccswitch --switch
    [ "$status" -eq 1 ]
    [[ "$output" == *"No accounts are managed yet"* ]]
}
