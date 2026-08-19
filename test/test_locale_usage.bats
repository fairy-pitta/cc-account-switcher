#!/usr/bin/env bats
#
# The usage cache stores percentages as dot-decimal numbers ("15.4"), but
# printf's %f honors LC_NUMERIC: under a locale whose decimal separator is a
# comma it prints a partial result and then fails. These tests pin that down for
# all three readers — `ccs rate-check`, the rate hook's fast path, and the
# statusline — and cover the unreadable-value path, which must never be reported
# as 0%.
#
# The comma-decimal tests skip when no such locale is installed (CI runners
# usually ship C/POSIX only); the unreadable-value tests need no locale at all.

load test_helper

STATUSLINE_SCRIPT=""
HOOK_SCRIPT=""
COMMA_LOCALE=""

setup() {
    setup_test_env
    STATUSLINE_SCRIPT="${BATS_TEST_DIRNAME}/../statusline/ccs-statusline.sh"
    HOOK_SCRIPT="${BATS_TEST_DIRNAME}/../hooks/ccs-rate-hook.sh"
    # Offline: no test here may hit the network.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
}

teardown() {
    teardown_test_env
}

# Skip unless the host has a locale whose decimal separator is a comma, and
# leave its name in $COMMA_LOCALE. An uninstalled locale falls back to C, whose
# separator is a dot, so this both finds and validates the candidate.
require_comma_locale() {
    local loc
    for loc in es_CL.UTF-8 es_ES.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 pt_BR.UTF-8 it_IT.UTF-8; do
        if [[ "$(LC_ALL="$loc" locale decimal_point 2>/dev/null)" == "," ]]; then
            COMMA_LOCALE="$loc"
            return 0
        fi
    done
    skip "no comma-decimal locale installed"
}

# Write a usage cache with a raw JSON utilization value, so a test can store a
# fractional number or a non-numeric one. create_fake_usage_cache() always
# interpolates a number.
write_usage_cache() {
    local utilization="$1"
    local email="${2:-user1@example.com}"
    cat > "$CCS_USAGE_CACHE" <<EOF
{
  "five_hour": {
    "utilization": $utilization,
    "limit": 100,
    "used": 0
  },
  "active_account": "$email",
  "cached_at": $(date +%s)
}
EOF
}

run_statusline() {
    echo '{}' | HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" \
        /bin/bash "$STATUSLINE_SCRIPT"
}

# Run the hook with a stub in place of ccs, so anything the hook delegates shows
# up as output: a taken fast path prints nothing at all.
run_hook_with_stub_ccs() {
    cat > "$MOCK_BIN/ccs-stub" << 'MOCK_EOF'
#!/bin/bash
echo "DELEGATED"
MOCK_EOF
    chmod +x "$MOCK_BIN/ccs-stub"
    echo '{}' | HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" \
        CCS_PATH="$MOCK_BIN/ccs-stub" CCS_USAGE_CACHE="$CCS_USAGE_CACHE" \
        /bin/bash "$HOOK_SCRIPT"
}

# --- rate-check ---------------------------------------------------------------

@test "rate-check reads a fractional percentage under a comma-decimal locale" {
    require_comma_locale
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    write_usage_cache "15.4"

    export LC_NUMERIC="$COMMA_LOCALE"
    run run_ccswitch rate-check --threshold 99
    [ "$status" -eq 0 ]
    [[ "$output" == *"15%"* ]]
    [[ "$output" != *"150"* ]]
    [[ "$output" == *"OK"* ]]
}

@test "rate-check still detects over threshold under a comma-decimal locale" {
    require_comma_locale
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    write_usage_cache "99.5"

    export LC_NUMERIC="$COMMA_LOCALE"
    run run_ccswitch rate-check --threshold 99
    [ "$status" -eq 1 ]
    [[ "$output" == *"100%"* ]]
    [[ "$output" == *"exceeds"* ]]
}

@test "rate-check auto-switch rotates under a comma-decimal locale" {
    require_comma_locale
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    write_usage_cache "99.5"

    # The account we rotate to reports plenty of headroom.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":10.5,"limit":100,"used":10}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    export LC_NUMERIC="$COMMA_LOCALE"
    run run_ccswitch rate-check --auto-switch --threshold 99
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 2 ]
}

@test "rate-check refuses to act on an unreadable usage value" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"
    write_usage_cache '"not-a-number"'

    run run_ccswitch rate-check --auto-switch --threshold 80
    [ "$status" -eq 2 ]
    [[ "$output" == *"Unreadable usage"* ]]
    # An unreadable reading is not 0% and not 100% — nothing rotates.
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [ "$active" -eq 1 ]
}

@test "rate-check hook mode fails open on an unreadable usage value" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    write_usage_cache '"not-a-number"'

    run run_ccswitch rate-check --hook-mode --auto-switch --threshold 80
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- rate hook ----------------------------------------------------------------

@test "rate hook takes the fast path on a fresh under-threshold cache under a comma-decimal locale" {
    require_comma_locale
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    local updated
    updated=$(jq '.rateLimit = {enabled: true, threshold: 99}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
    write_usage_cache "15.4"

    export LC_NUMERIC="$COMMA_LOCALE"
    run run_hook_with_stub_ccs
    [ "$status" -eq 0 ]
    [[ "$output" != *"DELEGATED"* ]]
}

# --- statusline ---------------------------------------------------------------

@test "statusline renders a fractional percentage under a comma-decimal locale" {
    require_comma_locale
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    write_usage_cache "15.4"

    export LC_NUMERIC="$COMMA_LOCALE"
    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" == *"15%"* ]]
    [[ "$output" != *"150"* ]]
    [[ "$output" != *"(!)"* ]]
}

@test "statusline shows no number when the usage value is unreadable" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    write_usage_cache '"not-a-number"'

    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" == *"?%"* ]]
    [[ "$output" != *"(!)"* ]]
}
