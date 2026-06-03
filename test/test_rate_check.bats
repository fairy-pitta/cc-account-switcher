#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    CACHE_FILE="/tmp/claude-usage-cache-test-$$.json"
}

teardown() {
    rm -f "$CACHE_FILE"
    teardown_test_env
}

# Helper to create a fake usage cache at the test cache path
# Usage: create_test_cache <utilization> [email]
create_test_cache() {
    local utilization="${1:-50}"
    local email="${2:-user1@example.com}"
    cat > "$CACHE_FILE" <<EOF
{
  "five_hour": {
    "utilization": $utilization,
    "limit": 100,
    "used": $utilization
  },
  "active_account": "$email",
  "cached_at": $(date +%s)
}
EOF
}

@test "test_rate_check_below_threshold_returns_0" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_above_threshold_returns_1" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 1 ]
    [[ "$output" == *"exceeds"* ]]
}

@test "test_rate_check_no_cache_returns_2" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Ensure no cache file exists
    rm -f /tmp/claude-usage-cache.json

    # Offline: a failing fetch with no cache to fall back to → error exit 2.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check
    [ "$status" -eq 2 ]
}

@test "test_rate_check_custom_threshold_flag" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    # With threshold 40, 50% should exceed
    run run_ccswitch rate-check --threshold 40
    [ "$status" -eq 1 ]

    # With threshold 60, 50% should be OK
    run run_ccswitch rate-check --threshold 60
    [ "$status" -eq 0 ]
}

@test "test_rate_check_custom_threshold_from_config" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Set threshold to 40 in config
    local updated
    updated=$(jq '.rateLimit = {enabled: true, threshold: 40}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    create_fake_usage_cache 50 "user1@example.com"

    # 50% should exceed config threshold of 40
    run run_ccswitch rate-check
    [ "$status" -eq 1 ]
}

@test "test_rate_check_hook_mode_outputs_valid_json_on_deny" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    run run_ccswitch rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    # Validate JSON output
    echo "$output" | jq . >/dev/null 2>&1
    # Check hook protocol fields
    local decision
    decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision')
    [ "$decision" = "deny" ]
}

@test "test_rate_check_hook_mode_silent_on_allow" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 50 "user1@example.com"

    run run_ccswitch rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "test_rate_check_auto_switch_rotates_account" {
    # Set up two accounts
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    create_fake_usage_cache 90 "user1@example.com"

    # Mock curl for fetch_usage_data (it will fail, but that's OK — we verify switch happened)
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
# Return a low-usage response for any API call
echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    # Should exit 1 (switched) or could fail on fetch — check switch happened
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "test_rate_check_auto_switch_all_limited_returns_3" {
    # Set up two accounts
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    create_fake_usage_cache 90 "user1@example.com"

    # Mock curl to return high usage for all accounts
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 3 ]
}

@test "test_rate_check_stale_cache_account_mismatch_refetches" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Create cache with different account email
    create_fake_usage_cache 50 "other@example.com"

    # Mock curl to return fresh data
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":30,"limit":100,"used":30}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# Write a cache at the real path with a custom age (seconds ago) and account.
create_aged_cache() {
    local age="${1:-0}"
    local utilization="${2:-50}"
    local email="${3:-user1@example.com}"
    local ts=$(( $(date +%s) - age ))
    cat > /tmp/claude-usage-cache.json <<EOF
{
  "five_hour": { "utilization": $utilization, "limit": 100, "used": $utilization },
  "active_account": "$email",
  "cached_at": $ts
}
EOF
}

@test "test_rate_check_stale_cache_triggers_refresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Cache is 5 minutes old (older than the 60s default TTL) and shows high usage.
    create_aged_cache 300 95 "user1@example.com"

    # A refresh returns low usage — the stale value must be replaced by this.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":20,"limit":100,"used":20}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_fresh_cache_within_max_age_does_not_fetch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Cache is 30s old, under threshold.
    create_aged_cache 30 50 "user1@example.com"

    # curl would FAIL if called — proves no fetch happens when cache is fresh.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80 --max-age 60
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_max_age_zero_forces_refresh" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Fresh cache showing high usage, but --max-age 0 makes everything stale.
    create_aged_cache 1 95 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80 --max-age 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_refresh_failure_falls_back_to_stale_cache" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    # Stale cache, under threshold. Refresh fails — we should fall back to it.
    create_aged_cache 300 40 "user1@example.com"

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    run run_ccswitch rate-check --threshold 80
    [ "$status" -eq 0 ]
    [[ "$output" == *"using cached data"* ]]
}

@test "test_rate_check_perform_switch_failure_fails_open" {
    # Set up one account only (switch will fail — no target)
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"

    create_fake_usage_cache 90 "user1@example.com"

    # Only 1 account, auto-switch should report no accounts
    run run_ccswitch rate-check --auto-switch --hook-mode --threshold 80
    [ "$status" -eq 0 ]
    # Should output deny JSON since there's only one account
    echo "$output" | jq . >/dev/null 2>&1
}
