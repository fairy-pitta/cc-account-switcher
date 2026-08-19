#!/usr/bin/env bats
#
# Tests for the statusline script and `ccs statusline-setup`.

load test_helper

STATUSLINE_SCRIPT=""
SETTINGS_FILE=""
LEGACY_SETTINGS_FILE=""

setup() {
    setup_test_env
    STATUSLINE_SCRIPT="${BATS_TEST_DIRNAME}/../statusline/ccs-statusline.sh"
    SETTINGS_FILE="$HOME/.claude/settings.json"
    LEGACY_SETTINGS_FILE="$HOME/.claude/settings.local.json"
    # Offline: any background refresh must not hit the network.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
exit 1
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    rm -f "$CCS_USAGE_CACHE"
}

teardown() {
    rm -f "$CCS_USAGE_CACHE"
    teardown_test_env
}

# Run the statusline script with our isolated env and JSON on stdin.
run_statusline() {
    echo '{}' | HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" \
        /bin/bash "$STATUSLINE_SCRIPT"
}

# --- statusline script output -------------------------------------------------

@test "statusline prints account and usage from a fresh cache" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_usage_cache 42 "user1@example.com"

    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" == *"user1@example.com"* ]]
    [[ "$output" == *"42%"* ]]
}

@test "statusline reports when no usage data is cached" {
    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" == *"no usage data"* ]]
}

@test "statusline appends a marker when usage is at/over threshold" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    # Set threshold 80 in config; usage 90 should trip the marker.
    local updated
    updated=$(jq '.rateLimit = {enabled: true, threshold: 80}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
    create_fake_usage_cache 90 "user1@example.com"

    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" == *"(!)"* ]]
}

@test "statusline does not show the marker when under threshold" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_usage_cache 30 "user1@example.com"

    run run_statusline
    [ "$status" -eq 0 ]
    [[ "$output" != *"(!)"* ]]
}

# --- statusline-setup ---------------------------------------------------------

@test "statusline-setup installs a command statusLine" {
    run run_ccswitch statusline-setup
    [ "$status" -eq 0 ]
    [ -f "$SETTINGS_FILE" ]
    local type cmd
    type=$(jq -r '.statusLine.type' "$SETTINGS_FILE")
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [ "$type" = "command" ]
    [[ "$cmd" == *"ccs-statusline.sh"* ]]
    [[ "$cmd" == *"CCS_PATH="* ]]
}

@test "statusline-setup is idempotent" {
    run_ccswitch statusline-setup
    run_ccswitch statusline-setup
    # statusLine is a single object, so re-running just overwrites it.
    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [[ "$cmd" == *"ccs-statusline.sh"* ]]
}

@test "statusline-setup finds the script when only the binary is in bin/ (make install layout)" {
    # `make install` puts ccs in <prefix>/bin and the shipped scripts in
    # <prefix>/share/ccswitch — the statusline is not next to the binary.
    local prefix="$TEST_HOME/prefix" ccs
    ccs="$(install_ccs_prefix "$prefix" share)"

    run run_ccswitch_at "$ccs" statusline-setup
    [ "$status" -eq 0 ]

    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [[ "$cmd" == *"$prefix/share/ccswitch/statusline/ccs-statusline.sh"* ]]
}

@test "statusline-setup does not report its own entry as a foreign statusline" {
    run_ccswitch statusline-setup
    run run_ccswitch statusline-setup
    [ "$status" -eq 0 ]
    [[ "$output" != *"replacing an existing statusLine"* ]]
}

@test "statusline-setup --disable leaves a similarly named third-party statusline intact" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/home/u/bin/my-ccs-statusline.sh"}}' \
        > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup --disable
    [ "$status" -eq 0 ]
    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [ "$cmd" = "/home/u/bin/my-ccs-statusline.sh" ]
}

@test "statusline-setup --disable removes our statusLine" {
    run_ccswitch statusline-setup
    run run_ccswitch statusline-setup --disable
    [ "$status" -eq 0 ]
    local has
    has=$(jq 'has("statusLine")' "$SETTINGS_FILE")
    [ "$has" = "false" ]
}

@test "statusline-setup --disable leaves a foreign statusLine intact" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/usr/local/bin/my-own-line"}}' > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup --disable
    [ "$status" -eq 0 ]
    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [ "$cmd" = "/usr/local/bin/my-own-line" ]
}

@test "statusline-setup refuses to replace a foreign statusline without --force" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/usr/local/bin/my-own-line"}}' > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup
    [ "$status" -eq 1 ]
    [[ "$output" == *"--force"* ]]
    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [ "$cmd" = "/usr/local/bin/my-own-line" ]
}

@test "statusline-setup --force replaces a foreign statusline" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/usr/local/bin/my-own-line"}}' > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"my-own-line"* ]]
    local cmd
    cmd=$(jq -r '.statusLine.command' "$SETTINGS_FILE")
    [[ "$cmd" == *"ccs-statusline.sh"* ]]
}

@test "statusline-setup keeps unrelated user settings" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo '{"model":"opus","env":{"ANTHROPIC_MODEL":"sonnet"}}' > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup
    [ "$status" -eq 0 ]
    run jq -e '.model == "opus" and .env.ANTHROPIC_MODEL == "sonnet"' "$SETTINGS_FILE"
    [ "$status" -eq 0 ]
}

@test "statusline-setup fails without writing when settings.json is malformed" {
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    echo 'not json' > "$SETTINGS_FILE"

    run run_ccswitch statusline-setup
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid settings file"* ]]
    [ "$(cat "$SETTINGS_FILE")" = "not json" ]
}

@test "statusline-setup clears the entry an earlier version left in settings.local.json" {
    mkdir -p "$(dirname "$LEGACY_SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/old/statusline/ccs-statusline.sh"}}' \
        > "$LEGACY_SETTINGS_FILE"

    run run_ccswitch statusline-setup
    [ "$status" -eq 0 ]
    run jq 'has("statusLine")' "$LEGACY_SETTINGS_FILE"
    [ "$output" = "false" ]
}

@test "statusline-setup --disable clears the legacy settings.local.json entry" {
    mkdir -p "$(dirname "$LEGACY_SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/old/statusline/ccs-statusline.sh"}}' \
        > "$LEGACY_SETTINGS_FILE"

    run run_ccswitch statusline-setup --disable
    [ "$status" -eq 0 ]
    run jq 'has("statusLine")' "$LEGACY_SETTINGS_FILE"
    [ "$output" = "false" ]
}

@test "statusline-setup leaves a third-party statusline in settings.local.json alone" {
    mkdir -p "$(dirname "$LEGACY_SETTINGS_FILE")"
    echo '{"statusLine":{"type":"command","command":"/home/u/bin/my-ccs-statusline.sh"}}' \
        > "$LEGACY_SETTINGS_FILE"

    run run_ccswitch statusline-setup
    [ "$status" -eq 0 ]
    local cmd
    cmd=$(jq -r '.statusLine.command' "$LEGACY_SETTINGS_FILE")
    [ "$cmd" = "/home/u/bin/my-ccs-statusline.sh" ]
}
