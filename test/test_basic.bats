#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "test_help_flag_shows_usage_information" {
    run run_ccswitch --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Multi-Account Switcher for Claude Code"* ]]
    [[ "$output" == *"add"* ]]
    [[ "$output" == *"sw"* ]]
    [[ "$output" == *"ls"* ]]
}

@test "test_no_args_shows_usage_information" {
    run run_ccswitch
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "test_unknown_command_shows_error_and_usage" {
    run run_ccswitch --bogus-command
    [ "$status" -eq 1 ]
    [[ "$output" == *"Error: Unknown command"* ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "test_dependency_check_with_jq_available_succeeds" {
    run run_ccswitch --help
    [ "$status" -eq 0 ]
}

@test "test_dependency_check_without_jq_shows_error" {
    # Directly test check_dependencies by sourcing and calling
    source_ccswitch_functions

    # Remove any jq from MOCK_BIN before restricting PATH
    rm -f "$MOCK_BIN/jq"

    # Temporarily override PATH to hide jq
    local saved_path="$PATH"
    export PATH="$MOCK_BIN"

    run check_dependencies
    export PATH="$saved_path"

    [ "$status" -eq 1 ]
    [[ "$output" == *"Required command 'jq' not found"* ]]
}

@test "test_bash_version_check_passes_with_mock" {
    # Our mock bash reports 5.2, so version check should pass
    run run_ccswitch --help
    [ "$status" -eq 0 ]
}

@test "test_bash_version_check_fails_with_old_bash" {
    # Create a mock bash that reports an old version
    cat > "$MOCK_BIN/bash" << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "GNU bash, version 3.1.0(1)-release (x86_64-pc-linux-gnu)"
    exit 0
fi
exec /bin/bash "$@"
EOF
    chmod +x "$MOCK_BIN/bash"

    run run_ccswitch --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"Bash 4.0+ required"* ]]
}
