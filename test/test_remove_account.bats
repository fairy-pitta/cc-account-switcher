#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_remove_account_by_number_removes_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"

    # Pipe "y" to confirm removal
    run bash -c "echo 'y' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"has been removed"* ]]

    # Verify account is gone from sequence.json
    local count
    count=$(jq '.accounts | keys | length' "$SEQUENCE_FILE")
    [ "$count" -eq 1 ]
}

@test "test_remove_account_by_email_removes_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"

    run bash -c "echo 'y' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account user1@example.com"
    [ "$status" -eq 0 ]
    [[ "$output" == *"has been removed"* ]]
    [[ "$output" == *"user1@example.com"* ]]
}

@test "test_remove_account_nonexistent_number_shows_error" {
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch --remove-account 99
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "test_remove_account_cleans_up_backup_files" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"

    # Verify backup files exist before removal
    [ -f "$BACKUP_DIR/configs/.claude-config-1-user1@example.com.json" ]

    run bash -c "echo 'y' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account 1"
    [ "$status" -eq 0 ]

    # Verify backup config is removed
    [ ! -f "$BACKUP_DIR/configs/.claude-config-1-user1@example.com.json" ]

    # Verify keychain entry is removed (mock)
    run security find-generic-password -s "Claude Code-Account-1-user1@example.com" -w
    [ "$status" -ne 0 ]
}

@test "test_remove_account_updates_sequence_json_correctly" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"
    add_account_to_sequence "3" "user3@example.com" "uuid-3" "false"

    run bash -c "echo 'y' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account 2"
    [ "$status" -eq 0 ]

    # Verify sequence no longer contains 2
    local seq
    seq=$(jq '.sequence' "$SEQUENCE_FILE")
    [[ "$seq" != *"2"* ]]

    # Verify remaining accounts
    local remaining
    remaining=$(jq '.accounts | keys | length' "$SEQUENCE_FILE")
    [ "$remaining" -eq 2 ]
}

@test "test_remove_account_active_account_shows_warning" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Pipe "n" to cancel
    run bash -c "echo 'n' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Warning"* ]]
    [[ "$output" == *"currently active"* ]]
}

@test "test_remove_account_without_argument_shows_usage" {
    run run_ccswitch --remove-account
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "test_remove_account_cancelled_by_user_preserves_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run bash -c "echo 'n' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$PATH' bash '$CCSWITCH_SCRIPT' --remove-account 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]

    # Account should still exist
    local count
    count=$(jq '.accounts | keys | length' "$SEQUENCE_FILE")
    [ "$count" -eq 1 ]
}
