#!/usr/bin/env bats
#
# Tests for per-agent isolation: `ccs exec`, `ccs config-dir`, and the
# materialize_config_dir helper (CLAUDE_CONFIG_DIR sandboxes).

load test_helper

setup() {
    setup_test_env
    # Two accounts: 1 active, 2 inactive.
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
}

teardown() {
    teardown_test_env
}

# --- materialize_config_dir (direct) ------------------------------------------

@test "materialize_config_dir writes valid config and credentials for a backup account" {
    source_ccswitch_functions
    local dest="$TEST_HOME/iso2"
    run materialize_config_dir "2" "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest/.claude.json" ]
    [ -f "$dest/.credentials.json" ]
    # Config carries account 2's oauth email
    local email
    email=$(jq -r '.oauthAccount.emailAddress' "$dest/.claude.json")
    [ "$email" = "user2@example.com" ]
    # Credentials are valid JSON with an access token
    jq -e '.access_token' "$dest/.credentials.json" >/dev/null
}

@test "materialize_config_dir uses the live global store for the active account" {
    source_ccswitch_functions
    local dest="$TEST_HOME/iso1"
    run materialize_config_dir "1" "$dest"
    [ "$status" -eq 0 ]
    local email
    email=$(jq -r '.oauthAccount.emailAddress' "$dest/.claude.json")
    [ "$email" = "user1@example.com" ]
}

@test "materialize_config_dir fails for an unknown account" {
    source_ccswitch_functions
    run materialize_config_dir "99" "$TEST_HOME/nope"
    [ "$status" -ne 0 ]
}

# --- macOS Keychain hex-dump credentials (regression) -------------------------
# Newer Claude Code stores the credential as binary data, so macOS `security -w`
# returns a hex dump ("7b22…") instead of JSON. Without decoding, every jq on the
# credential fails and the isolated dir gets an empty, unauthenticated creds file.

@test "keychain_read decodes a hex-dump secret back to JSON" {
    export MOCK_SECURITY_HEX=1
    source_ccswitch_functions
    run keychain_read "Claude Code-credentials"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.access_token' >/dev/null
}

@test "materialize decodes hex Keychain credentials for the active account" {
    export MOCK_SECURITY_HEX=1
    source_ccswitch_functions
    local dest="$TEST_HOME/iso-hex1"
    run materialize_config_dir "1" "$dest"
    [ "$status" -eq 0 ]
    run jq -e '.access_token' "$dest/.credentials.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.access_token' "$dest/.credentials.json")" = "at-user1@example.com" ]
}

@test "materialize decodes hex Keychain credentials for a backup account" {
    export MOCK_SECURITY_HEX=1
    source_ccswitch_functions
    local dest="$TEST_HOME/iso-hex2"
    run materialize_config_dir "2" "$dest"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.access_token' "$dest/.credentials.json")" = "at-user2@example.com" ]
}

# --- ccs config-dir -----------------------------------------------------------

@test "config-dir materializes and prints the dir and export line" {
    run run_ccswitch config-dir 2
    [ "$status" -eq 0 ]
    [[ "$output" == *"isolated/2-user2@example.com"* ]]
    [[ "$output" == *"export CLAUDE_CONFIG_DIR="* ]]
    [ -f "$HOME/.claude-switch-backup/isolated/2-user2@example.com/.claude.json" ]
}

@test "config-dir errors on an unknown account" {
    run run_ccswitch config-dir nobody@example.com
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}

# --- ccs exec -----------------------------------------------------------------

@test "exec runs the command with CLAUDE_CONFIG_DIR pointed at the isolated dir" {
    run run_ccswitch exec 2 -- bash -c 'echo "DIR=$CLAUDE_CONFIG_DIR"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"DIR="*"isolated/2-user2@example.com"* ]]
}

@test "exec materializes the account's files before running" {
    run_ccswitch exec 2 -- true
    [ -f "$HOME/.claude-switch-backup/isolated/2-user2@example.com/.claude.json" ]
    [ -f "$HOME/.claude-switch-backup/isolated/2-user2@example.com/.credentials.json" ]
}

@test "exec preserves the command's exit code" {
    run run_ccswitch exec 2 -- bash -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "exec accepts a --dir override" {
    local custom="$TEST_HOME/custom-cfg"
    run run_ccswitch exec 2 --dir "$custom" -- bash -c 'echo "$CLAUDE_CONFIG_DIR"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"$custom"* ]]
    [ -f "$custom/.claude.json" ]
}

@test "exec works without an explicit -- separator" {
    run run_ccswitch exec 2 bash -c 'echo ok-$CLAUDE_CONFIG_DIR'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok-"*"isolated/2-user2@example.com"* ]]
}

@test "exec passes ccs-looking flags through to the command verbatim" {
    # --no-restart would normally be eaten by ccs's global flag parser; after
    # `exec` it must reach the wrapped command instead.
    run run_ccswitch exec 2 -- bash -c 'echo "args=$*"' _ --no-restart --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-restart"* ]]
    [[ "$output" == *"--dry-run"* ]]
}

@test "exec errors when no command is given" {
    run run_ccswitch exec 2
    [ "$status" -ne 0 ]
    [[ "$output" == *"no command"* ]]
}

@test "exec errors on an unknown account" {
    run run_ccswitch exec 99 -- true
    [ "$status" -ne 0 ]
    [[ "$output" == *"not found"* ]]
}
