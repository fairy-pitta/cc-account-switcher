#!/usr/bin/env bash
# Demo environment setup for VHS recording
# Creates a fully isolated mock environment so ccs commands produce realistic output

set -euo pipefail

# When sourced from VHS, BASH_SOURCE may not be set; fall back to PWD
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elif [[ -f "./ccswitch.sh" ]]; then
    SCRIPT_DIR="$(pwd)"
elif [[ -f "./assets/demo-setup.sh" ]]; then
    SCRIPT_DIR="$(pwd)"
else
    echo "Error: Cannot determine script directory. Run from project root." >&2
    return 1
fi
DEMO_HOME="$(mktemp -d /tmp/ccs-demo-XXXXXX)"

export HOME="$DEMO_HOME"

# Create mock bin directory
MOCK_BIN="$DEMO_HOME/.mock-bin"
mkdir -p "$MOCK_BIN"
export PATH="$MOCK_BIN:$PATH"

# Install ccs to mock bin
cp "$SCRIPT_DIR/ccswitch.sh" "$MOCK_BIN/ccs"
chmod +x "$MOCK_BIN/ccs"

# Mock security command (macOS Keychain → flat files)
KEYCHAIN_DIR="$DEMO_HOME/.mock-keychain"
mkdir -p "$KEYCHAIN_DIR"
cat > "$MOCK_BIN/security" << 'EOF'
#!/bin/bash
KEYCHAIN_DIR="$HOME/.mock-keychain"
mkdir -p "$KEYCHAIN_DIR"
_sanitize() { echo "$1" | tr ' /' '__'; }
cmd="$1"; shift
case "$cmd" in
    add-generic-password)
        s=""; p=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -U) shift ;; -s) s="$2"; shift 2 ;; -a) shift 2 ;; -w) p="$2"; shift 2 ;; *) shift ;; esac
        done
        [[ -n "$s" && -n "$p" ]] && printf '%s' "$p" > "$KEYCHAIN_DIR/$(_sanitize "$s")"
        ;;
    find-generic-password)
        s=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -s) s="$2"; shift 2 ;; -w) shift ;; *) shift ;; esac
        done
        f="$KEYCHAIN_DIR/$(_sanitize "$s")"
        [[ -f "$f" ]] && cat "$f" || exit 44
        ;;
    delete-generic-password)
        s=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -s) s="$2"; shift 2 ;; *) shift ;; esac
        done
        rm -f "$KEYCHAIN_DIR/$(_sanitize "$s")"
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$MOCK_BIN/security"

# Mock ps (Claude not running)
cat > "$MOCK_BIN/ps" << 'EOF'
#!/bin/bash
echo "  PID COMM             ARGS"
EOF
chmod +x "$MOCK_BIN/ps"

# Mock uname (Darwin)
cat > "$MOCK_BIN/uname" << 'EOF'
#!/bin/bash
echo "Darwin"
EOF
chmod +x "$MOCK_BIN/uname"

# Mock bash --version (report 5.2)
cat > "$MOCK_BIN/bash" << 'EOF'
#!/bin/bash
if [[ "$1" == "--version" ]]; then
    echo "GNU bash, version 5.2.0(1)-release (aarch64-apple-darwin)"
    exit 0
fi
exec /bin/bash "$@"
EOF
chmod +x "$MOCK_BIN/bash"

# Create Claude config directory
mkdir -p "$HOME/.claude"

# Helper: set up a fake Claude login
_set_claude_login() {
    local email="$1" uuid="$2"
    cat > "$HOME/.claude/.claude.json" << CONF
{
  "oauthAccount": {
    "emailAddress": "$email",
    "accountUuid": "$uuid",
    "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxNzc0MzAwODAwfQ.fakesig"
  },
  "someOtherSetting": true
}
CONF
    chmod 600 "$HOME/.claude/.claude.json"

    local fake_jwt="eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwiZXhwIjoxNzc0MzAwODAwfQ.fakesig"
    local creds="{\"access_token\":\"$fake_jwt\",\"refresh_token\":\"rt-$email\"}"
    "$MOCK_BIN/security" add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$creds"
}

# Helper: switch to a different login (simulates re-login)
_switch_to_bob() {
    _set_claude_login "bob@personal.dev" "uuid-bob-002"
}

# Set up first account login
_set_claude_login "alice@company.com" "uuid-alice-001"
