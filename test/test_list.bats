#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_list_with_no_accounts_shows_no_accounts_message" {
    # No sequence file exists, no config either
    # first_run_setup finds no active account and returns 1, which
    # causes exit under set -e, so status is non-zero
    run run_ccswitch --list
    [[ "$output" == *"No accounts are managed yet"* ]]
}

@test "test_list_with_accounts_shows_all_accounts" {
    # Set up two accounts directly
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com"* ]]
    [[ "$output" == *"user2@example.com"* ]]
}

@test "test_list_marks_active_account_correctly" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com (active)"* ]]
    # user2 should NOT be marked active
    [[ "$output" != *"user2@example.com (active)"* ]]
}

@test "test_list_ordering_matches_sequence" {
    setup_fake_account "alpha@example.com" "uuid-a"
    add_account_to_sequence "1" "alpha@example.com" "uuid-a" "true"
    add_account_to_sequence "2" "bravo@example.com" "uuid-b" "false"
    add_account_to_sequence "3" "charlie@example.com" "uuid-c" "false"

    run run_ccswitch --list
    [ "$status" -eq 0 ]

    # Check ordering: alpha before bravo before charlie
    local alpha_line bravo_line charlie_line
    alpha_line=$(echo "$output" | grep -n "alpha@example.com" | cut -d: -f1)
    bravo_line=$(echo "$output" | grep -n "bravo@example.com" | cut -d: -f1)
    charlie_line=$(echo "$output" | grep -n "charlie@example.com" | cut -d: -f1)

    [ "$alpha_line" -lt "$bravo_line" ]
    [ "$bravo_line" -lt "$charlie_line" ]
}
