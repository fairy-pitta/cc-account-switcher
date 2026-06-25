#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    cat > "$SEQUENCE_FILE" <<'EOF'
{
  "activeAccountNumber": 1,
  "lastUpdated": "2024-01-01T00:00:00Z",
  "sequence": [1],
  "accounts": {
    "1": { "authType": "endpoint", "label": "ep",
           "baseUrl": "https://ep.test/v1", "tokenHeader": "api_key",
           "added": "2024-01-01T00:00:00Z" }
  }
}
EOF
    chmod 600 "$SEQUENCE_FILE"
    # Store the endpoint secret in the mock keychain.
    security add-generic-password -U -s "Claude Code-Account-1-ep" -a "$USER" \
        -w '{"endpointKey":"sk-ep"}'
}
teardown() { teardown_test_env; }

# Mock curl that echoes a status code chosen per URL path.
# MODELS_CODE governs /models, MESSAGES_CODE governs /messages.
mock_curl() {
    cat > "$MOCK_BIN/curl" <<MOCK_EOF
#!/bin/bash
url="\$*"
if [[ "\$url" == *"/models"* ]]; then echo "${1:-200}"; else echo "${2:-200}"; fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
}

@test "test_probe_returns_healthy_on_models_200" {
    mock_curl 200 000
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=0"* ]]
}

@test "test_probe_returns_unhealthy_on_429" {
    mock_curl 429 429
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "test_probe_returns_unhealthy_on_401" {
    mock_curl 401 401
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "test_probe_returns_unhealthy_on_5xx" {
    mock_curl 503 503
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "test_probe_returns_unhealthy_on_timeout_000" {
    mock_curl 000 000
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "test_probe_falls_back_to_messages_when_models_404" {
    # /models 404 (unknown) -> probe /messages, which is healthy (200).
    mock_curl 404 200
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=0"* ]]
}

# Mock curl that mimics REAL curl on connection failure: it prints the
# %{http_code} "000" to stdout AND exits non-zero. Guards against the
# double-"000" bug where the code became "000000" and misclassified as healthy.
@test "test_probe_unhealthy_when_curl_fails_like_real_timeout" {
    cat > "$MOCK_BIN/curl" <<'MOCK_EOF'
#!/bin/bash
echo -n "000"
exit 28
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=1"* ]]
}

@test "test_probe_auth_token_endpoint_sends_bearer_and_is_healthy" {
    # Switch the fixture account to auth_token; verify the Bearer branch works.
    jq '.accounts["1"].tokenHeader = "auth_token"' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" \
        && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    # Mock curl asserts it received an Authorization: Bearer header, then 200.
    cat > "$MOCK_BIN/curl" <<'MOCK_EOF'
#!/bin/bash
args="$*"
if [[ "$args" == *"Authorization: Bearer sk-ep"* ]]; then echo "200"; else echo "401"; fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; probe_endpoint_health 1; echo rc=\$?"
    [[ "$output" == *"rc=0"* ]]
}
