#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

NESTED='{"claudeAiOauth":{"accessToken":"AT-nested","refreshToken":"RT-nested","expiresAt":9999999999000,"scopes":["user:inference"]}}'
FLAT='{"access_token":"AT-flat","refresh_token":"RT-flat"}'

@test "test_cred_access_token_reads_nested_format" {
    source_ccswitch_functions
    [ "$(cred_access_token "$NESTED")" = "AT-nested" ]
}

@test "test_cred_access_token_reads_flat_format" {
    source_ccswitch_functions
    [ "$(cred_access_token "$FLAT")" = "AT-flat" ]
}

@test "test_cred_refresh_token_reads_nested_format" {
    source_ccswitch_functions
    [ "$(cred_refresh_token "$NESTED")" = "RT-nested" ]
}

@test "test_cred_refresh_token_reads_flat_format" {
    source_ccswitch_functions
    [ "$(cred_refresh_token "$FLAT")" = "RT-flat" ]
}

@test "test_cred_expiry_epoch_from_nested_expiresat_converts_ms_to_seconds" {
    source_ccswitch_functions
    [ "$(cred_expiry_epoch "$NESTED")" = "9999999999" ]
}

@test "test_cred_expiry_epoch_from_flat_jwt_reads_exp_claim" {
    source_ccswitch_functions
    local payload jwt flat
    payload=$(printf '{"exp":9999999999}' | base64 | tr '+/' '-_' | tr -d '=')
    jwt="header.${payload}.sig"
    flat=$(jq -nc --arg t "$jwt" '{access_token:$t, refresh_token:"r"}')
    [ "$(cred_expiry_epoch "$flat")" = "9999999999" ]
}

@test "test_cred_expiry_epoch_returns_empty_when_undeterminable" {
    source_ccswitch_functions
    [ -z "$(cred_expiry_epoch '{"access_token":"not-a-jwt","refresh_token":"r"}')" ]
}

@test "test_cred_set_tokens_updates_nested_path_single_line" {
    source_ccswitch_functions
    local out
    out=$(cred_set_tokens "$NESTED" "NEW-AT" "NEW-RT")
    [ "$(printf '%s' "$out" | wc -l | tr -d ' ')" -eq 0 ]
    [ "$(printf '%s' "$out" | jq -r '.claudeAiOauth.accessToken')" = "NEW-AT" ]
    [ "$(printf '%s' "$out" | jq -r '.claudeAiOauth.refreshToken')" = "NEW-RT" ]
    [ "$(printf '%s' "$out" | jq -r '.claudeAiOauth.scopes[0]')" = "user:inference" ]
    [ "$(printf '%s' "$out" | jq -r '.claudeAiOauth.expiresAt')" = "9999999999000" ]
}

@test "test_cred_set_tokens_updates_flat_keys_for_flat_cred" {
    source_ccswitch_functions
    local out
    out=$(cred_set_tokens "$FLAT" "NEW-AT" "NEW-RT")
    [ "$(printf '%s' "$out" | jq -r '.access_token')" = "NEW-AT" ]
    [ "$(printf '%s' "$out" | jq -r '.refresh_token')" = "NEW-RT" ]
}

@test "test_cred_set_tokens_refuses_invalid_json" {
    source_ccswitch_functions
    run cred_set_tokens "not json at all" "AT" "RT"
    [ "$status" -ne 0 ]
}

@test "test_cred_expiry_epoch_handles_null_expiresat" {
    source_ccswitch_functions
    [ -z "$(cred_expiry_epoch '{"claudeAiOauth":{"expiresAt":null,"accessToken":"not-a-jwt"}}')" ]
}

@test "test_status_shows_expiry_from_nested_credential" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    # Future expiry, ~10 days out, in epoch ms
    local future_ms=$(( ( $(date +%s) + 864000 ) * 1000 ))
    create_fake_credentials_nested "AT-x" "RT-x" "$future_ms"

    run run_ccswitch status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Expires in"* ]]
    [[ "$output" != *"Unable to determine"* ]]
    [[ "$output" != *"No access token"* ]]
}
