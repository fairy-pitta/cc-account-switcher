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
