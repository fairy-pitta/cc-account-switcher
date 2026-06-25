#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Regression: macOS `security -w` hex-encodes any value containing newlines,
# and Claude (which reads the raw global item) cannot decode hex -> 401.
# ccs must normalize credentials to single-line JSON before storing them.
# The mock `security` stores -w verbatim, so a single-line store proves the
# normalization happened (real `security` would then keep it as plain text).

_kc_file() { echo "$TEST_HOME/.mock-keychain/$(echo "$1" | tr ' /' '__')"; }

@test "test_write_credentials_stores_multiline_json_as_single_line" {
    source_ccswitch_functions
    local multiline=$'{\n  "access_token": "at-x",\n  "refresh_token": "rt-x"\n}'
    write_credentials "$multiline"
    local stored; stored=$(cat "$(_kc_file 'Claude Code-credentials')")
    [ "$(printf '%s' "$stored" | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(printf '%s' "$stored" | jq -r '.access_token')" = "at-x" ]
}

@test "test_write_account_credentials_stores_multiline_json_as_single_line" {
    source_ccswitch_functions
    local multiline=$'{\n  "access_token": "at-y",\n  "refresh_token": "rt-y"\n}'
    write_account_credentials 1 "user1@example.com" "$multiline"
    local stored; stored=$(cat "$(_kc_file 'Claude Code-Account-1-user1@example.com')")
    [ "$(printf '%s' "$stored" | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(printf '%s' "$stored" | jq -r '.refresh_token')" = "rt-y" ]
}

@test "test_write_credentials_preserves_non_json_value_as_is" {
    source_ccswitch_functions
    write_credentials "not-json-blob"
    local stored; stored=$(cat "$(_kc_file 'Claude Code-credentials')")
    [ "$stored" = "not-json-blob" ]
}
