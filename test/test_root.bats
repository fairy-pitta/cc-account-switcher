#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# --- should_block_root() decision logic ---------------------------------------

@test "should_block_root: non-root is never blocked" {
    source_ccswitch_functions
    run should_block_root 1000 false
    [ "$status" -eq 1 ]
}

@test "should_block_root: root without opt-out is blocked" {
    source_ccswitch_functions
    is_running_in_container() { return 1; }
    run should_block_root 0 false
    [ "$status" -eq 0 ]
}

@test "should_block_root: root with --allow-root is allowed" {
    source_ccswitch_functions
    is_running_in_container() { return 1; }
    run should_block_root 0 true
    [ "$status" -eq 1 ]
}

@test "should_block_root: root inside a container is allowed without opt-out" {
    source_ccswitch_functions
    is_running_in_container() { return 0; }
    run should_block_root 0 false
    [ "$status" -eq 1 ]
}

# --- end-to-end flag handling -------------------------------------------------

@test "test_help_lists_allow_root_option" {
    run run_ccswitch --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--allow-root"* ]]
}

@test "test_allow_root_flag_is_consumed_not_treated_as_command" {
    # As a non-root user the flag is a no-op but must be stripped before dispatch.
    run run_ccswitch --allow-root version
    [ "$status" -eq 0 ]
    [[ "$output" != *"Unknown command"* ]]
}
