#!/usr/bin/env bash

# Common test helper for ccswitch.sh bats tests
# Provides isolated temp environments and mocks for all external dependencies

# Path to the script under test
CCSWITCH_SCRIPT="${BATS_TEST_DIRNAME}/../ccswitch.sh"

# Save original PATH so we can always access system tools
ORIGINAL_PATH="$PATH"

# Setup a fully isolated test environment
setup_test_env() {
    # Create isolated temp HOME
    TEST_HOME="$(mktemp -d "${BATS_TMPDIR}/ccswitch-test-XXXXXX")"
    export HOME="$TEST_HOME"

    # Recalculate paths that depend on HOME (mirroring the script's readonly vars)
    export BACKUP_DIR="$HOME/.claude-switch-backup"
    export SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

    # Create .claude directory for config files
    mkdir -p "$HOME/.claude"

    # Create mock bin directory and prepend to PATH
    MOCK_BIN="$TEST_HOME/.mock-bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$ORIGINAL_PATH"

    # Mock the security command (macOS Keychain) to use flat files
    create_security_mock

    # Mock ps to never find Claude running
    create_ps_mock

    # Mock uname to return consistent platform
    create_uname_mock "Darwin"

    # Mock bash --version to report 5.2 (system bash is 3.2)
    create_bash_mock
}

# Teardown: remove temp directory
teardown_test_env() {
    if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi
}

# Create a mock `security` command that stores/retrieves passwords from files
create_security_mock() {
    local keychain_dir="$TEST_HOME/.mock-keychain"
    mkdir -p "$keychain_dir"

    cat > "$MOCK_BIN/security" << 'MOCK_EOF'
#!/bin/bash
KEYCHAIN_DIR="$HOME/.mock-keychain"
mkdir -p "$KEYCHAIN_DIR"

_sanitize_service() {
    echo "$1" | tr ' /' '__'
}

cmd="$1"
shift

case "$cmd" in
    add-generic-password)
        service=""
        account=""
        password=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -U) shift ;;
                -s) service="$2"; shift 2 ;;
                -a) account="$2"; shift 2 ;;
                -w) password="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [[ -n "$service" && -n "$password" ]]; then
            printf '%s' "$password" > "$KEYCHAIN_DIR/$(_sanitize_service "$service")"
        fi
        ;;
    find-generic-password)
        service=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -s) service="$2"; shift 2 ;;
                -w) shift ;;
                *) shift ;;
            esac
        done
        file="$KEYCHAIN_DIR/$(_sanitize_service "$service")"
        if [[ -f "$file" ]]; then
            cat "$file"
        else
            exit 44
        fi
        ;;
    delete-generic-password)
        service=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -s) service="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        file="$KEYCHAIN_DIR/$(_sanitize_service "$service")"
        rm -f "$file"
        ;;
    *)
        exit 1
        ;;
esac
MOCK_EOF
    chmod +x "$MOCK_BIN/security"
}

# Mock bash --version to report 5.2 but otherwise delegate to real /bin/bash
create_bash_mock() {
    cat > "$MOCK_BIN/bash" << 'MOCK_EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "GNU bash, version 5.2.0(1)-release (aarch64-apple-darwin)"
    exit 0
fi
exec /bin/bash "$@"
MOCK_EOF
    chmod +x "$MOCK_BIN/bash"
}

# Mock ps so is_claude_running always returns false
create_ps_mock() {
    cat > "$MOCK_BIN/ps" << 'MOCK_EOF'
#!/bin/bash
echo "  PID COMM             ARGS"
MOCK_EOF
    chmod +x "$MOCK_BIN/ps"
}

# Mock uname for platform detection
create_uname_mock() {
    local platform="${1:-Darwin}"
    cat > "$MOCK_BIN/uname" << MOCK_EOF
#!/bin/bash
case "\$1" in
    -s) echo "$platform" ;;
    *)  echo "$platform" ;;
esac
MOCK_EOF
    chmod +x "$MOCK_BIN/uname"
}

# Helper: create a fake Claude config file (.claude.json) with oauthAccount
create_fake_claude_config() {
    local email="${1:-test@example.com}"
    local uuid="${2:-uuid-abcd1234}"
    local config_path="$HOME/.claude/.claude.json"

    cat > "$config_path" << EOF
{
  "oauthAccount": {
    "emailAddress": "$email",
    "accountUuid": "$uuid",
    "accessToken": "token-for-$email"
  },
  "someOtherSetting": true
}
EOF
    chmod 600 "$config_path"
}

# Helper: create fake credentials in mock keychain
create_fake_credentials() {
    local email="${1:-test@example.com}"
    local creds='{"access_token":"at-'"$email"'","refresh_token":"rt-'"$email"'"}'

    # Write to mock keychain via mock security command
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$creds"
}

# Helper: set up a complete fake account (config + credentials)
setup_fake_account() {
    local email="${1:-test@example.com}"
    local uuid="${2:-uuid-abcd1234}"
    create_fake_claude_config "$email" "$uuid"
    create_fake_credentials "$email"
}

# Helper: add an account to sequence.json directly (for test setup)
add_account_to_sequence() {
    local account_num="$1"
    local email="$2"
    local uuid="${3:-uuid-$account_num}"
    local make_active="${4:-false}"

    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR" "$BACKUP_DIR/configs" "$BACKUP_DIR/credentials"

    # Initialize sequence file if needed
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        cat > "$SEQUENCE_FILE" << EOF
{
  "activeAccountNumber": null,
  "lastUpdated": "2024-01-01T00:00:00Z",
  "sequence": [],
  "accounts": {}
}
EOF
        chmod 600 "$SEQUENCE_FILE"
    fi

    # Add account to sequence.json
    local active_val="null"
    if [[ "$make_active" == "true" ]]; then
        active_val="$account_num"
    fi

    local updated
    updated=$(jq --arg num "$account_num" \
                 --arg email "$email" \
                 --arg uuid "$uuid" \
                 --argjson active_val "$active_val" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: "2024-01-01T00:00:00Z"
        } |
        .sequence += [$num | tonumber] |
        (if $active_val != null then .activeAccountNumber = $active_val else . end)
    ' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"

    # Create backup config and credentials
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    cat > "$config_file" << EOF
{
  "oauthAccount": {
    "emailAddress": "$email",
    "accountUuid": "$uuid",
    "accessToken": "token-for-$email"
  },
  "someOtherSetting": true
}
EOF
    chmod 600 "$config_file"

    # Store credentials in mock keychain
    local creds='{"access_token":"at-'"$email"'","refresh_token":"rt-'"$email"'"}'
    security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$creds"
}

# Helper: create a fake usage cache at /tmp/claude-usage-cache.json
create_fake_usage_cache() {
    local utilization="${1:-50}"
    local email="${2:-user1@example.com}"
    cat > /tmp/claude-usage-cache.json <<EOF
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

# Source ccswitch.sh functions for direct function testing
source_ccswitch_functions() {
    # Source with set +e to avoid early exit from set -euo pipefail in script
    # The script's readonly vars will bind to our test HOME
    set +e
    # shellcheck disable=SC1090
    source "$CCSWITCH_SCRIPT"
    set -e
}

# Run ccswitch.sh as a subprocess with our mocked environment
# Uses /bin/bash directly; our mock bash in MOCK_BIN handles --version checks
run_ccswitch() {
    HOME="$TEST_HOME" PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash "$CCSWITCH_SCRIPT" "$@"
}
