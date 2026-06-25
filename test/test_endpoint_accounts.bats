#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Seed a sequence.json with one oauth and one endpoint account.
seed_mixed_accounts() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    cat > "$SEQUENCE_FILE" <<'EOF'
{
  "activeAccountNumber": 1,
  "lastUpdated": "2024-01-01T00:00:00Z",
  "sequence": [1, 2],
  "accounts": {
    "1": { "email": "user1@example.com", "uuid": "uuid-1", "added": "2024-01-01T00:00:00Z" },
    "2": { "authType": "endpoint", "label": "openrouter",
           "baseUrl": "https://openrouter.ai/api/v1", "tokenHeader": "api_key",
           "added": "2024-01-01T00:00:00Z" }
  }
}
EOF
    chmod 600 "$SEQUENCE_FILE"
}

@test "test_is_endpoint_account_with_endpoint_returns_0" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; is_endpoint_account 2; echo rc=\$?"
    [[ "$output" == *"rc=0"* ]]
}

@test "test_is_endpoint_account_with_oauth_returns_1" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; is_endpoint_account 1; echo result=\$?"
    [[ "$output" == *"result=1"* ]]
}

@test "test_account_auth_type_defaults_to_oauth" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; account_auth_type 1"
    [ "$status" -eq 0 ]
    [[ "$output" == "oauth" ]]
}

@test "test_account_display_id_returns_label_for_endpoint" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; account_display_id 2"
    [[ "$output" == "openrouter" ]]
}

@test "test_account_display_id_returns_email_for_oauth" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; account_display_id 1"
    [[ "$output" == "user1@example.com" ]]
}

@test "test_write_endpoint_env_sets_base_url_and_api_key" {
    mkdir -p "$HOME/.claude"
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; write_endpoint_env 'https://x.test/v1' 'api_key' 'sk-secret' 'model-x'"
    [ "$status" -eq 0 ]
    run jq -r '.env.ANTHROPIC_BASE_URL' "$HOME/.claude/settings.json"
    [[ "$output" == "https://x.test/v1" ]]
    run jq -r '.env.ANTHROPIC_API_KEY' "$HOME/.claude/settings.json"
    [[ "$output" == "sk-secret" ]]
    run jq -r '.env.ANTHROPIC_MODEL' "$HOME/.claude/settings.json"
    [[ "$output" == "model-x" ]]
    run jq -r '.env | has("ANTHROPIC_AUTH_TOKEN")' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
}

@test "test_write_endpoint_env_auth_token_sets_bearer_var" {
    mkdir -p "$HOME/.claude"
    /bin/bash -c "source '$CCSWITCH_SCRIPT'; write_endpoint_env 'https://x.test/v1' 'auth_token' 'tok-123' ''"
    run jq -r '.env.ANTHROPIC_AUTH_TOKEN' "$HOME/.claude/settings.json"
    [[ "$output" == "tok-123" ]]
    run jq -r '.env | has("ANTHROPIC_API_KEY")' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
    run jq -r '.env | has("ANTHROPIC_MODEL")' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
}

@test "test_write_endpoint_env_preserves_user_env_keys" {
    mkdir -p "$HOME/.claude"
    echo '{"env":{"FOO":"bar"},"theme":"dark"}' > "$HOME/.claude/settings.json"
    /bin/bash -c "source '$CCSWITCH_SCRIPT'; write_endpoint_env 'https://x.test/v1' 'api_key' 'sk' ''"
    run jq -r '.env.FOO' "$HOME/.claude/settings.json"
    [[ "$output" == "bar" ]]
    run jq -r '.theme' "$HOME/.claude/settings.json"
    [[ "$output" == "dark" ]]
}

@test "test_clear_endpoint_env_removes_only_owned_keys" {
    mkdir -p "$HOME/.claude"
    echo '{"env":{"FOO":"bar","ANTHROPIC_BASE_URL":"u","ANTHROPIC_API_KEY":"k","ANTHROPIC_MODEL":"m"}}' \
        > "$HOME/.claude/settings.json"
    /bin/bash -c "source '$CCSWITCH_SCRIPT'; clear_endpoint_env"
    run jq -r '.env.FOO' "$HOME/.claude/settings.json"
    [[ "$output" == "bar" ]]
    run jq -r '.env | has("ANTHROPIC_BASE_URL") or has("ANTHROPIC_API_KEY") or has("ANTHROPIC_MODEL")' \
        "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
}

@test "test_clear_endpoint_env_no_settings_file_is_noop" {
    mkdir -p "$HOME/.claude"
    rm -f "$HOME/.claude/settings.json"
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; clear_endpoint_env"
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.claude/settings.json" ]
}
