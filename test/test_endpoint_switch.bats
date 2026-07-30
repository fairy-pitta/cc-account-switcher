#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export RESTART_FLAG="no-restart"
}
teardown() { teardown_test_env; }

# OAuth account 1 (active) + endpoint account 2.
seed() {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
}

@test "test_switch_to_endpoint_writes_env_block" {
    seed
    run run_ccswitch --no-restart to ep
    [ "$status" -eq 0 ]
    run jq -r '.env.ANTHROPIC_BASE_URL' "$HOME/.claude/settings.json"
    [[ "$output" == "https://ep.test/v1" ]]
    run jq -r '.env.ANTHROPIC_API_KEY' "$HOME/.claude/settings.json"
    [[ "$output" == "sk-ep" ]]
    # activeAccountNumber updated to the endpoint.
    ep_num=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    run jq -r '.activeAccountNumber' "$SEQUENCE_FILE"
    [[ "$output" == "$ep_num" ]]
}

@test "test_switch_endpoint_then_back_to_oauth_clears_env" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch --no-restart to 1
    [ "$status" -eq 0 ]
    run jq -r '.env | has("ANTHROPIC_BASE_URL") or has("ANTHROPIC_API_KEY")' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
    run jq -r '.activeAccountNumber' "$SEQUENCE_FILE"
    [[ "$output" == "1" ]]
}

@test "test_list_marks_endpoint_active" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch ls
    [[ "$output" == *"ep [endpoint] (active)"* ]]
}

@test "test_status_shows_endpoint_base_url_when_active" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch status
    [ "$status" -eq 0 ]
    [[ "$output" == *"ep"* ]]
    [[ "$output" == *"https://ep.test/v1"* ]]
    # Secret never printed.
    [[ "$output" != *"sk-ep"* ]]
}

@test "test_exec_endpoint_exports_env_vars" {
    seed
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    # Assert the secret inside the subprocess and emit only a sentinel so the
    # API key never reaches stdout.
    run run_ccswitch exec "$ep" -- /bin/bash -c '
        [[ "$ANTHROPIC_BASE_URL" == "https://ep.test/v1" ]] &&
        [[ "$ANTHROPIC_API_KEY" == "sk-ep" ]] &&
        echo ok
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
    # The secret must never reach stdout/stderr.
    [[ "$output" != *"sk-ep"* ]]
}
