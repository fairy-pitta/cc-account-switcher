#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    source_ccswitch_functions
}

teardown() {
    teardown_test_env
}

@test "test_detect_platform_on_darwin_returns_macos" {
    create_uname_mock "Darwin"
    run detect_platform
    [ "$status" -eq 0 ]
    [ "$output" = "macos" ]
}

@test "test_detect_platform_on_linux_returns_linux" {
    create_uname_mock "Linux"
    unset WSL_DISTRO_NAME
    run detect_platform
    [ "$status" -eq 0 ]
    [ "$output" = "linux" ]
}

@test "test_detect_platform_on_unknown_os_returns_unknown" {
    create_uname_mock "FreeBSD"
    run detect_platform
    [ "$status" -eq 0 ]
    [ "$output" = "unknown" ]
}

@test "test_credential_read_write_on_linux_uses_file_storage" {
    create_uname_mock "Linux"

    local test_creds='{"access_token":"linux-test-token"}'
    write_credentials "$test_creds"

    [ -f "$HOME/.claude/.credentials.json" ]

    local read_back
    read_back=$(read_credentials)
    [ "$read_back" = "$test_creds" ]

    local perms
    perms=$(stat -f '%A' "$HOME/.claude/.credentials.json" 2>/dev/null || stat -c '%a' "$HOME/.claude/.credentials.json" 2>/dev/null)
    [ "$perms" = "600" ]
}

@test "test_credential_read_write_on_macos_uses_keychain" {
    create_uname_mock "Darwin"

    local test_creds='{"access_token":"macos-test-token"}'
    write_credentials "$test_creds"

    local read_back
    read_back=$(read_credentials)
    [ "$read_back" = "$test_creds" ]
}

@test "test_get_claude_config_path_with_primary_config_returns_primary" {
    create_fake_claude_config "user@example.com"

    run get_claude_config_path
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.claude/.claude.json" ]
}

@test "test_get_claude_config_path_without_primary_returns_fallback" {
    run get_claude_config_path
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.claude.json" ]
}

@test "test_get_claude_config_path_with_invalid_primary_returns_fallback" {
    mkdir -p "$HOME/.claude"
    echo '{"someOtherKey": true}' > "$HOME/.claude/.claude.json"

    run get_claude_config_path
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.claude.json" ]
}
