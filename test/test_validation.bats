#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    source_ccswitch_functions
}

teardown() {
    teardown_test_env
}

@test "test_validate_email_with_valid_standard_email_returns_success" {
    run validate_email "user@example.com"
    [ "$status" -eq 0 ]
}

@test "test_validate_email_with_valid_plus_addressing_returns_success" {
    run validate_email "user+tag@example.com"
    [ "$status" -eq 0 ]
}

@test "test_validate_email_with_valid_dotted_local_returns_success" {
    run validate_email "first.last@example.com"
    [ "$status" -eq 0 ]
}

@test "test_validate_email_with_valid_subdomain_returns_success" {
    run validate_email "user@sub.domain.example.com"
    [ "$status" -eq 0 ]
}

@test "test_validate_email_with_missing_at_sign_returns_failure" {
    run validate_email "userexample.com"
    [ "$status" -eq 1 ]
}

@test "test_validate_email_with_missing_domain_returns_failure" {
    run validate_email "user@"
    [ "$status" -eq 1 ]
}

@test "test_validate_email_with_missing_tld_returns_failure" {
    run validate_email "user@example"
    [ "$status" -eq 1 ]
}

@test "test_validate_email_with_empty_string_returns_failure" {
    run validate_email ""
    [ "$status" -eq 1 ]
}

@test "test_validate_email_with_spaces_returns_failure" {
    run validate_email "user @example.com"
    [ "$status" -eq 1 ]
}

@test "test_validate_json_with_valid_json_file_returns_success" {
    local test_file="$TEST_HOME/valid.json"
    echo '{"key": "value"}' > "$test_file"

    run validate_json "$test_file"
    [ "$status" -eq 0 ]
}

@test "test_validate_json_with_invalid_json_file_returns_failure" {
    local test_file="$TEST_HOME/invalid.json"
    echo '{broken json' > "$test_file"

    run validate_json "$test_file"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid JSON"* ]]
}

@test "test_write_json_with_valid_content_creates_file_with_correct_permissions" {
    local test_file="$TEST_HOME/output.json"
    local content='{"hello": "world"}'

    run write_json "$test_file" "$content"
    [ "$status" -eq 0 ]
    [ -f "$test_file" ]

    # Verify content is valid JSON
    run jq . "$test_file"
    [ "$status" -eq 0 ]

    # Verify permissions are 600 (try GNU stat first, then BSD stat)
    local perms
    perms=$(stat -c '%a' "$test_file" 2>/dev/null) || perms=$(stat -f '%A' "$test_file" 2>/dev/null)
    [ "$perms" = "600" ]
}

@test "test_write_json_with_invalid_content_returns_error" {
    local test_file="$TEST_HOME/bad_output.json"

    run write_json "$test_file" '{this is not valid json'
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid JSON"* ]] || [[ "$output" == *"Invalid JSON"* ]]

    # File should not exist
    [ ! -f "$test_file" ]
}
