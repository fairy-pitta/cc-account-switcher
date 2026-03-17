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
