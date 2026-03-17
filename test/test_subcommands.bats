#!/usr/bin/env bats

# Tests for short subcommand syntax (ccs add, ccs ls, ccs sw, ccs to, etc.)

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# --- help / version ---

@test "test_help_subcommand_shows_usage_with_subcommand_syntax" {
    run run_ccswitch help
    [ "$status" -eq 0 ]
    [[ "$output" == *"ccs [OPTIONS] <command>"* ]]
    [[ "$output" == *"add"* ]]
    [[ "$output" == *"sw"* ]]
    [[ "$output" == *"ls"* ]]
}

@test "test_version_subcommand_shows_version" {
    run run_ccswitch version
    [ "$status" -eq 0 ]
    [[ "$output" == *"ccs v"* ]]
}

# --- ls ---

@test "test_ls_subcommand_lists_accounts" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"

    run run_ccswitch ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com"* ]]
    [[ "$output" == *"user2@example.com"* ]]
}

@test "test_ls_subcommand_with_no_accounts_shows_message" {
    run run_ccswitch ls
    [[ "$output" == *"No accounts"* ]]
}

# --- add ---

@test "test_add_subcommand_adds_current_account" {
    setup_fake_account "newuser@example.com" "uuid-new"

    run run_ccswitch add
    [ "$status" -eq 0 ]
    [[ "$output" == *"Added Account"* ]]
    [[ "$output" == *"newuser@example.com"* ]]
}

@test "test_add_subcommand_with_no_login_shows_error" {
    run run_ccswitch add
    [ "$status" -eq 1 ]
    [[ "$output" == *"No active Claude Code login found"* ]] || [[ "$output" == *"not logged in"* ]] || [[ "$output" == *"Error"* ]]
}

# --- sw ---

@test "test_sw_subcommand_rotates_to_next_account" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch sw
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_sw_subcommand_wraps_around" {
    setup_fake_account "user2@example.com" "uuid-2"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"
    create_fake_credentials "user2@example.com"

    run run_ccswitch sw
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-1 (user1@example.com)"* ]]
}

@test "test_sw_subcommand_with_no_accounts_shows_error" {
    run run_ccswitch sw
    [ "$status" -eq 1 ]
    [[ "$output" == *"No accounts are managed yet"* ]]
}

# --- to ---

@test "test_to_subcommand_switches_by_number" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch to 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_to_subcommand_switches_by_email" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch to user2@example.com
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2 (user2@example.com)"* ]]
}

@test "test_to_subcommand_nonexistent_number_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch to 99
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "test_to_subcommand_nonexistent_email_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch to nobody@example.com
    [ "$status" -eq 1 ]
    [[ "$output" == *"No account found with email"* ]]
}

@test "test_to_subcommand_invalid_format_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch to "not-an-email"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid email format"* ]]
}

@test "test_to_subcommand_without_argument_shows_usage" {
    run run_ccswitch to
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

# --- rm ---

@test "test_rm_subcommand_removes_account_by_number" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "true"

    run bash -c "echo 'y' | HOME='$TEST_HOME' PATH='$MOCK_BIN:$ORIGINAL_PATH' bash '$CCSWITCH_SCRIPT' rm 1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"has been removed"* ]]
}

@test "test_rm_subcommand_nonexistent_shows_error" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch rm 99
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
}

@test "test_rm_subcommand_without_argument_shows_usage" {
    run run_ccswitch rm
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

# --- dry-run flag -n ---

@test "test_short_dry_run_flag_with_sw_shows_preview" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch -n sw
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
}

@test "test_short_dry_run_flag_with_to_shows_preview" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch -n to 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
}

# --- unknown subcommand ---

@test "test_unknown_subcommand_shows_error" {
    run run_ccswitch foobar
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: Unknown command"* ]]
}

# --- backward compatibility ---

@test "test_legacy_switch_flag_still_works" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2"* ]]
}

@test "test_legacy_list_flag_still_works" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    run run_ccswitch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com"* ]]
}

@test "test_legacy_switch_to_flag_still_works" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch --switch-to 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"Switched to Account-2"* ]]
}
