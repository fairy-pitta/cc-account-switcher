#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export RESTART_FLAG="no-restart"
}
teardown() {
    rm -f /tmp/claude-usage-cache.json
    teardown_test_env
}

# Mock curl: /models and /messages return per-arg codes; usage API returns 200
# with a utilization body so oauth candidates look healthy.
mock_curl() {
    local models="${1:-200}" usage_util="${2:-10}"
    cat > "$MOCK_BIN/curl" <<MOCK_EOF
#!/bin/bash
args="\$*"
if [[ "\$args" == *"/models"* ]]; then echo "$models"; exit 0; fi
if [[ "\$args" == *"oauth/usage"* ]]; then
    echo '{"five_hour":{"utilization":$usage_util}}'
    echo "200"
    exit 0
fi
echo "$models"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
}

@test "test_rate_check_endpoint_active_healthy_returns_0" {
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    mock_curl 200
    run run_ccswitch rate-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_endpoint_active_429_switches_to_oauth" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    mock_curl 429 10
    run run_ccswitch --no-restart rate-check --auto-switch
    [ "$status" -eq 1 ]
    [[ "$output" == *"Switched to Account-1"* ]]
}

@test "test_rate_check_endpoint_unhealthy_hook_mode_denies_with_switch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    mock_curl 503 10
    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"permissionDecision"* ]]
}
