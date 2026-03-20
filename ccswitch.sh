#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Version
readonly VERSION="0.3.0"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly DIR_ACCOUNTS_FILE="$BACKUP_DIR/dir-accounts.json"

# Global flags (set during argument parsing)
DRY_RUN=false
RESTART_FLAG=""  # "", "restart", or "no-restart"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi

    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi

    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi

    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"

    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi

    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Account identifier resolution function
# Accepts: account number, email, or profile name
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Try email first
        local account_num
        account_num=$(jq -r --arg email "$identifier" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
            return
        fi
        # Try profile name
        account_num=$(jq -r --arg profile "$identifier" '.accounts | to_entries[] | select(.value.profile == $profile) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$account_num" && "$account_num" != "null" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")

    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi

    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check dependencies
check_dependencies() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: Required command 'jq' not found"
        echo "Install with: apt install jq (Linux) or brew install jq (macOS)"
        exit 1
    fi
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi

    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."

    while is_claude_running; do
        sleep 1
    done

    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi

    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi

    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local email="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-Account-${account_num}-${email}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                echo ""
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local email="$2"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo ""
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content
        init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi

    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Base64url decode (portable)
base64url_decode() {
    local input="$1"
    # Add padding
    local pad=$(( 4 - ${#input} % 4 ))
    if [[ $pad -ne 4 ]]; then
        input="${input}$(printf '%0.s=' $(seq 1 "$pad"))"
    fi
    # Replace URL-safe chars and decode
    echo "$input" | tr '_-' '/+' | base64 -d 2>/dev/null || true
}

# Decode JWT and return payload as JSON
decode_jwt_payload() {
    local token="$1"
    local payload
    payload=$(echo "$token" | cut -d. -f2)
    if [[ -z "$payload" ]]; then
        echo ""
        return
    fi
    base64url_decode "$payload" | jq . 2>/dev/null || echo ""
}

# Kill Claude Code processes
kill_claude_processes() {
    local pids
    pids=$(ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {print $1}')
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill 2>/dev/null || true
        sleep 1
        # Force kill if still running
        local remaining
        remaining=$(ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {print $1}')
        if [[ -n "$remaining" ]]; then
            echo "$remaining" | xargs kill -9 2>/dev/null || true
        fi
    fi
}

# Restart Claude Code
restart_claude_code() {
    echo "Restarting Claude Code..."
    kill_claude_processes
    sleep 1
    if command -v claude >/dev/null 2>&1; then
        nohup claude </dev/null >/dev/null 2>&1 &
        echo "Claude Code restarted."
    else
        echo "Warning: 'claude' command not found in PATH. Please start Claude Code manually."
    fi
}

# Handle restart logic after a switch
handle_restart_after_switch() {
    case "$RESTART_FLAG" in
        restart)
            restart_claude_code
            ;;
        no-restart)
            echo "Please restart Claude Code to use the new authentication."
            ;;
        *)
            # Default: ask user (skip if non-interactive)
            if [[ -t 0 ]]; then
                echo -n "Restart Claude Code now? [Y/n] "
                read -r response
                if [[ "$response" == "n" || "$response" == "N" ]]; then
                    echo "Please restart Claude Code to use the new authentication."
                else
                    restart_claude_code
                fi
            else
                echo "Please restart Claude Code to use the new authentication."
            fi
            ;;
    esac
}

# Backup integrity check
cmd_check() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet. Nothing to check."
        exit 0
    fi

    local issues=0
    local platform
    platform=$(detect_platform)

    echo "Backup Integrity Check"
    echo "======================"
    echo ""

    # Check sequence.json itself
    if jq . "$SEQUENCE_FILE" >/dev/null 2>&1; then
        echo "[OK] sequence.json is valid JSON"
    else
        echo "[FAIL] sequence.json is invalid JSON"
        issues=$((issues + 1))
    fi

    # Check each account
    local accounts
    accounts=$(jq -r '.accounts | to_entries[] | "\(.key)|\(.value.email)"' "$SEQUENCE_FILE")

    while IFS='|' read -r num email; do
        [[ -z "$num" ]] && continue
        echo ""
        echo "Account-$num ($email):"

        # Check config backup
        local config_file="$BACKUP_DIR/configs/.claude-config-${num}-${email}.json"
        if [[ -f "$config_file" ]]; then
            if jq . "$config_file" >/dev/null 2>&1; then
                echo "  [OK] Config backup is valid JSON"
            else
                echo "  [FAIL] Config backup is invalid JSON: $config_file"
                issues=$((issues + 1))
            fi
            # Check file permissions
            local perms
            perms=$(stat -f "%Lp" "$config_file" 2>/dev/null || stat -c "%a" "$config_file" 2>/dev/null)
            if [[ "$perms" == "600" ]]; then
                echo "  [OK] Config file permissions: $perms"
            else
                echo "  [WARN] Config file permissions: $perms (expected 600)"
                issues=$((issues + 1))
            fi
        else
            echo "  [FAIL] Config backup missing: $config_file"
            issues=$((issues + 1))
        fi

        # Check credentials backup
        case "$platform" in
            macos)
                if security find-generic-password -s "Claude Code-Account-${num}-${email}" -w >/dev/null 2>&1; then
                    echo "  [OK] Keychain entry exists"
                    # Validate it's valid JSON
                    local kc_creds
                    kc_creds=$(security find-generic-password -s "Claude Code-Account-${num}-${email}" -w 2>/dev/null)
                    if echo "$kc_creds" | jq . >/dev/null 2>&1; then
                        echo "  [OK] Keychain credentials are valid JSON"
                    else
                        echo "  [FAIL] Keychain credentials are invalid JSON"
                        issues=$((issues + 1))
                    fi
                else
                    echo "  [FAIL] Keychain entry missing for Account-$num"
                    issues=$((issues + 1))
                fi
                ;;
            linux|wsl)
                local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${num}-${email}.json"
                if [[ -f "$cred_file" ]]; then
                    if jq . "$cred_file" >/dev/null 2>&1; then
                        echo "  [OK] Credentials backup is valid JSON"
                    else
                        echo "  [FAIL] Credentials backup is invalid JSON: $cred_file"
                        issues=$((issues + 1))
                    fi
                    local cperms
                    cperms=$(stat -f "%Lp" "$cred_file" 2>/dev/null || stat -c "%a" "$cred_file" 2>/dev/null)
                    if [[ "$cperms" == "600" ]]; then
                        echo "  [OK] Credentials file permissions: $cperms"
                    else
                        echo "  [WARN] Credentials file permissions: $cperms (expected 600)"
                        issues=$((issues + 1))
                    fi
                else
                    echo "  [FAIL] Credentials backup missing: $cred_file"
                    issues=$((issues + 1))
                fi
                ;;
        esac
    done <<< "$accounts"

    # Check backup directory permissions
    echo ""
    local dir_perms
    dir_perms=$(stat -f "%Lp" "$BACKUP_DIR" 2>/dev/null || stat -c "%a" "$BACKUP_DIR" 2>/dev/null)
    if [[ "$dir_perms" == "700" ]]; then
        echo "[OK] Backup directory permissions: $dir_perms"
    else
        echo "[WARN] Backup directory permissions: $dir_perms (expected 700)"
        issues=$((issues + 1))
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        echo "All checks passed."
    else
        echo "$issues issue(s) found."
        exit 1
    fi
}

# Token expiry monitoring and status display
cmd_status() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        exit 0
    fi

    local current_email
    current_email=$(get_current_account)

    local active_num=""
    local profile_name=""
    if [[ "$current_email" != "none" ]]; then
        active_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        if [[ -n "$active_num" ]]; then
            profile_name=$(jq -r --arg num "$active_num" '.accounts[$num].profile // empty' "$SEQUENCE_FILE" 2>/dev/null)
        fi
    fi

    echo "Account Status"
    echo "=============="
    echo ""
    echo "Current account: ${current_email}"
    if [[ -n "$active_num" ]]; then
        echo "Account number:  $active_num"
    fi
    if [[ -n "$profile_name" ]]; then
        echo "Profile name:    $profile_name"
    fi

    # Last switch timestamp
    local last_updated
    last_updated=$(jq -r '.lastUpdated // empty' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$last_updated" ]]; then
        echo "Last switch:     $last_updated"
    fi

    # Token expiry check
    echo ""
    local creds
    creds=$(read_credentials)
    if [[ -n "$creds" ]]; then
        # Try to extract access_token or the token field
        local token
        token=$(echo "$creds" | jq -r '.access_token // .token // empty' 2>/dev/null)
        if [[ -n "$token" ]]; then
            local payload
            payload=$(decode_jwt_payload "$token")
            if [[ -n "$payload" ]]; then
                local exp
                exp=$(echo "$payload" | jq -r '.exp // empty' 2>/dev/null)
                if [[ -n "$exp" ]]; then
                    local now
                    now=$(date +%s)
                    local diff=$((exp - now))
                    if [[ $diff -le 0 ]]; then
                        echo "Token status:    EXPIRED ($(( -diff / 3600 )) hours ago)"
                    elif [[ $diff -lt 3600 ]]; then
                        echo "Token status:    Expires in $((diff / 60)) minutes"
                    elif [[ $diff -lt 86400 ]]; then
                        echo "Token status:    Expires in $((diff / 3600)) hours"
                    else
                        echo "Token status:    Expires in $((diff / 86400)) days"
                    fi
                else
                    echo "Token status:    Unable to determine expiry (no exp claim)"
                fi
            else
                echo "Token status:    Unable to decode token (not a JWT)"
            fi
        else
            echo "Token status:    No access token found in credentials"
        fi
    else
        echo "Token status:    No credentials found"
    fi
}

# Usage statistics
cmd_stats() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        exit 0
    fi

    echo "Usage Statistics"
    echo "================"
    echo ""
    printf "%-6s %-30s %-8s %-15s %s\n" "Acct" "Email" "Switches" "Total Time" "Last Used"
    printf "%-6s %-30s %-8s %-15s %s\n" "----" "-----" "--------" "----------" "---------"

    local accounts
    accounts=$(jq -r '.accounts | to_entries[] | "\(.key)|\(.value.email)|\(.value.switchCount // 0)|\(.value.totalSeconds // 0)|\(.value.lastUsed // "never")"' "$SEQUENCE_FILE")

    while IFS='|' read -r num email switches total_secs last_used; do
        [[ -z "$num" ]] && continue
        # Format total time
        local time_str
        if [[ "$total_secs" -eq 0 ]]; then
            time_str="-"
        elif [[ "$total_secs" -lt 3600 ]]; then
            time_str="${total_secs}s"
        elif [[ "$total_secs" -lt 86400 ]]; then
            time_str="$((total_secs / 3600))h $((total_secs % 3600 / 60))m"
        else
            time_str="$((total_secs / 86400))d $((total_secs % 86400 / 3600))h"
        fi

        # Truncate email if too long
        local display_email="$email"
        if [[ ${#email} -gt 28 ]]; then
            display_email="${email:0:25}..."
        fi

        # Format last_used
        local display_last="$last_used"
        if [[ "$last_used" != "never" && ${#last_used} -gt 15 ]]; then
            display_last="${last_used:0:16}"
        fi

        printf "%-6s %-30s %-8s %-15s %s\n" "$num" "$display_email" "$switches" "$time_str" "$display_last"
    done <<< "$accounts"
}

# Set profile name for an account
cmd_set_profile() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: ccs profile <account_number|email> <profile_name>"
        exit 1
    fi

    local identifier="$1"
    local profile_name="$2"

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local account_num
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$identifier' not found"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    # Check for duplicate profile names
    local existing
    existing=$(jq -r --arg profile "$profile_name" --arg num "$account_num" '.accounts | to_entries[] | select(.value.profile == $profile and .key != $num) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        echo "Error: Profile name '$profile_name' is already used by Account-$existing"
        exit 1
    fi

    local updated
    updated=$(jq --arg num "$account_num" --arg profile "$profile_name" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num].profile = $profile |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated"

    local email
    email=$(echo "$account_info" | jq -r '.email')
    echo "Set profile name for Account-$account_num ($email): $profile_name"
}

# Directory-based auto-switch: set mapping
cmd_set_dir_account() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ccs dir [directory] <account_number|email|profile>"
        exit 1
    fi

    local dir account_id

    if [[ $# -ge 2 ]]; then
        dir="$1"
        account_id="$2"
    else
        dir="$(pwd)"
        account_id="$1"
    fi

    # Resolve to absolute path
    dir="$(cd "$dir" 2>/dev/null && pwd)" || {
        echo "Error: Directory '$dir' does not exist"
        exit 1
    }

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local account_num
    account_num=$(resolve_account_identifier "$account_id")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$account_id' not found"
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")
    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    setup_directories

    # Initialize dir-accounts.json if needed
    if [[ ! -f "$DIR_ACCOUNTS_FILE" ]]; then
        write_json "$DIR_ACCOUNTS_FILE" '{}'
    fi

    local updated
    updated=$(jq --arg dir "$dir" --arg num "$account_num" '
        .[$dir] = ($num | tonumber)
    ' "$DIR_ACCOUNTS_FILE")

    write_json "$DIR_ACCOUNTS_FILE" "$updated"

    local email
    email=$(echo "$account_info" | jq -r '.email')
    echo "Directory '$dir' mapped to Account-$account_num ($email)"
}

# Directory-based auto-switch: check and switch
cmd_auto_switch() {
    if [[ ! -f "$DIR_ACCOUNTS_FILE" ]]; then
        echo "No directory-account mappings configured."
        echo "Use 'ccs dir' to create mappings."
        exit 0
    fi

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_dir
    current_dir="$(pwd)"

    # Check current directory and parent directories for a mapping
    local check_dir="$current_dir"
    local target_account=""

    while true; do
        target_account=$(jq -r --arg dir "$check_dir" '.[$dir] // empty' "$DIR_ACCOUNTS_FILE" 2>/dev/null)
        if [[ -n "$target_account" ]]; then
            break
        fi
        local parent
        parent="$(dirname "$check_dir")"
        if [[ "$parent" == "$check_dir" ]]; then
            break  # Reached root
        fi
        check_dir="$parent"
    done

    if [[ -z "$target_account" ]]; then
        echo "No account mapping found for $current_dir (or any parent directory)."
        exit 0
    fi

    # Check if already on the right account
    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    if [[ "$active_account" == "$target_account" ]]; then
        local email
        email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
        echo "Already on Account-$target_account ($email) for this directory."
        exit 0
    fi

    local email
    email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    echo "Directory mapping found: switching to Account-$target_account ($email)"
    perform_switch "$target_account"
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    if account_exists "$current_email"; then
        echo "Account $current_email is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    # Store backups
    write_account_credentials "$account_num" "$current_email" "$current_creds"
    write_account_config "$account_num" "$current_email" "$current_config"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Added Account $account_num: $current_email"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ccs rm <account_number|email>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Validate email format
        if ! validate_email "$identifier"; then
            echo "Error: Invalid email format: $identifier"
            exit 1
        fi

        # Resolve email to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with email: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email
    email=$(echo "$account_info" | jq -r '.email')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($email)? [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    # Remove backup files
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${email}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Account-$account_num ($email) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi

    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response

    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run 'ccs add' later."
        return 1
    fi

    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null)
    fi

    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        (if .profile then " [\(.profile)]" else "" end) as $prof |
        if "\($num)" == $active then
            "  \($num): \(.email)\($prof) (active)"
        else
            "  \($num): \(.email)\($prof)"
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi

    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi

    # wait_for_claude_close

    local active_account next_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    next_account=$(jq -r --argjson active "$active_account" '
        .sequence as $seq |
        ($seq | index($active) // 0) as $idx |
        $seq[($idx + 1) % ($seq | length)]
    ' "$SEQUENCE_FILE")

    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ccs to <account_number|email|profile>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Resolve identifier (number, email, or profile name)
    target_account=$(resolve_account_identifier "$identifier")
    if [[ -z "$target_account" ]]; then
        # Provide specific error for email-like input vs invalid format
        if [[ "$identifier" =~ @ ]]; then
            echo "Error: No account found with email: $identifier"
        elif [[ ! "$identifier" =~ ^[0-9]+$ ]]; then
            if validate_email "$identifier" 2>/dev/null; then
                echo "Error: No account found matching: $identifier"
            else
                echo "Error: Invalid email format: $identifier"
            fi
        else
            echo "Error: No account found matching: $identifier"
        fi
        exit 1
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"

    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # Dry-run mode: show what would happen and return
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would switch from Account-$current_account ($current_email) to Account-$target_account ($target_email)"
        echo "[DRY RUN] Steps that would be performed:"
        echo "  1. Backup current credentials and config for Account-$current_account"
        echo "  2. Restore credentials and config from Account-$target_account backup"
        echo "  3. Update active account in sequence.json"
        echo "  4. Update usage statistics"
        return
    fi

    # Save pre-switch state for rollback
    local rollback_creds rollback_config rollback_sequence
    rollback_creds=$(read_credentials)
    rollback_config=$(cat "$(get_claude_config_path)")
    rollback_sequence=$(cat "$SEQUENCE_FILE")

    # Rollback function
    rollback() {
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo ""
            echo "Error: Switch failed. Rolling back to previous state..."
        else
            echo "Error: Switch failed. Rolling back..." >&2
        fi
        write_credentials "$rollback_creds" 2>/dev/null || true
        write_json "$(get_claude_config_path)" "$rollback_config" 2>/dev/null || true
        write_json "$SEQUENCE_FILE" "$rollback_sequence" 2>/dev/null || true
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Rollback complete. Account-$current_account ($current_email) is still active."
        else
            echo "Rollback complete." >&2
        fi
    }

    # Step 1: Backup current account
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if ! write_account_credentials "$current_account" "$current_email" "$current_creds"; then
        rollback
        exit 1
    fi
    if ! write_account_config "$current_account" "$current_email" "$current_config"; then
        rollback
        exit 1
    fi

    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_email")
    target_config=$(read_account_config "$target_account" "$target_email")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        rollback
        exit 1
    fi

    # Step 3: Activate target account
    if ! write_credentials "$target_creds"; then
        rollback
        exit 1
    fi

    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        rollback
        exit 1
    fi

    # Merge with current config and validate
    local merged_config
    if ! merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null); then
        echo "Error: Failed to merge config"
        rollback
        exit 1
    fi

    if ! write_json "$(get_claude_config_path)" "$merged_config"; then
        rollback
        exit 1
    fi

    # Step 4: Update state and usage statistics
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local now_epoch
    now_epoch=$(date +%s)

    # Calculate time spent on the old account (since last switch)
    local last_updated_str elapsed_seconds=0
    last_updated_str=$(jq -r '.lastUpdated // empty' "$SEQUENCE_FILE" 2>/dev/null)
    if [[ -n "$last_updated_str" ]]; then
        local last_epoch
        # Portable date parsing (macOS vs Linux)
        if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated_str" +%s >/dev/null 2>&1; then
            last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_updated_str" +%s 2>/dev/null || echo "0")
        else
            last_epoch=$(date -d "$last_updated_str" +%s 2>/dev/null || echo "0")
        fi
        if [[ "$last_epoch" -gt 0 ]]; then
            elapsed_seconds=$((now_epoch - last_epoch))
            if [[ $elapsed_seconds -lt 0 ]]; then
                elapsed_seconds=0
            fi
        fi
    fi

    local updated_sequence
    updated_sequence=$(jq \
        --arg num "$target_account" \
        --arg cur "$current_account" \
        --arg now "$now" \
        --argjson elapsed "$elapsed_seconds" '
        # Update time on old account
        .accounts[$cur].totalSeconds = ((.accounts[$cur].totalSeconds // 0) + $elapsed) |
        .accounts[$cur].lastUsed = $now |
        # Increment switch count on target
        .accounts[$num].switchCount = ((.accounts[$num].switchCount // 0) + 1) |
        .accounts[$num].lastUsed = $now |
        # Update active account
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    if ! write_json "$SEQUENCE_FILE" "$updated_sequence"; then
        rollback
        exit 1
    fi

    if [[ "${CCS_SILENT:-}" != "1" ]]; then
        echo "Switched to Account-$target_account ($target_email)"
        # Display updated account list
        cmd_list
        echo ""

        # Handle restart
        handle_restart_after_switch
    fi
}

# Fetch usage data from Anthropic OAuth Usage API
# Writes to /tmp/claude-usage-cache.json with active_account field
# Returns 0 on success, 1 on failure
fetch_usage_data() {
    local cache_file="/tmp/claude-usage-cache.json"
    local current_email
    current_email=$(get_current_account)

    # Read credentials and extract access token
    local creds access_token
    creds=$(read_credentials)
    if [[ -z "$creds" ]]; then
        return 1
    fi

    access_token=$(echo "$creds" | jq -r '.access_token // empty' 2>/dev/null)
    if [[ -z "$access_token" ]]; then
        return 1
    fi

    # Call the usage API
    local response http_code
    response=$(curl -sS -w "\n%{http_code}" \
        -H "Authorization: Bearer $access_token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    # Handle token refresh on 401
    if [[ "$http_code" == "401" ]]; then
        local refresh_token client_id
        refresh_token=$(echo "$creds" | jq -r '.refresh_token // empty' 2>/dev/null)
        client_id="9d1c250a-e61b-44d9-88ed-5944d1962f5e"

        if [[ -z "$refresh_token" ]]; then
            return 1
        fi

        local refresh_response refresh_code
        refresh_response=$(curl -sS -w "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh_token\",\"client_id\":\"$client_id\"}" \
            "https://console.anthropic.com/v1/oauth/token" 2>/dev/null) || return 1

        refresh_code=$(echo "$refresh_response" | tail -n1)
        local refresh_body
        refresh_body=$(echo "$refresh_response" | sed '$d')

        if [[ "$refresh_code" != "200" ]]; then
            return 1
        fi

        # Update stored credentials with new tokens
        local new_access new_refresh updated_creds
        new_access=$(echo "$refresh_body" | jq -r '.access_token // empty' 2>/dev/null)
        new_refresh=$(echo "$refresh_body" | jq -r '.refresh_token // empty' 2>/dev/null)

        if [[ -z "$new_access" ]]; then
            return 1
        fi

        updated_creds=$(echo "$creds" | jq \
            --arg at "$new_access" \
            --arg rt "${new_refresh:-$refresh_token}" \
            '.access_token = $at | .refresh_token = $rt' 2>/dev/null)
        write_credentials "$updated_creds"

        # Retry the usage API with new token
        response=$(curl -sS -w "\n%{http_code}" \
            -H "Authorization: Bearer $new_access" \
            -H "anthropic-beta: oauth-2025-04-20" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
    fi

    if [[ "$http_code" != "200" ]]; then
        return 1
    fi

    # Validate response JSON
    if ! echo "$body" | jq . >/dev/null 2>&1; then
        return 1
    fi

    # Write cache with active_account and timestamp
    local cache_content
    cache_content=$(echo "$body" | jq \
        --arg email "$current_email" \
        --arg ts "$(date +%s)" \
        '. + {active_account: $email, cached_at: ($ts | tonumber)}' 2>/dev/null) || return 1

    echo "$cache_content" > "$cache_file"
    return 0
}

# Rate limit check command
# Usage: ccs rate-check [--threshold N] [--auto-switch] [--hook-mode] [--refresh]
# Exit codes: 0=ok, 1=exceeded (switched if --auto-switch), 2=error, 3=all accounts limited
cmd_rate_check() {
    local threshold=""
    local auto_switch=false
    local hook_mode=false
    local refresh=false
    local cache_file="/tmp/claude-usage-cache.json"

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --auto-switch)
                auto_switch=true
                shift
                ;;
            --hook-mode)
                hook_mode=true
                shift
                ;;
            --refresh)
                refresh=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Read threshold from config if not explicitly passed via --threshold
    if [[ -z "$threshold" ]]; then
        if [[ -f "$SEQUENCE_FILE" ]]; then
            local cfg_threshold
            cfg_threshold=$(jq -r '.rateLimit.threshold // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
            if [[ -n "$cfg_threshold" ]]; then
                threshold="$cfg_threshold"
            fi
        fi
        # Default if neither flag nor config provided
        threshold="${threshold:-80}"
    fi

    # Force refresh if requested
    if [[ "$refresh" == true ]]; then
        fetch_usage_data || {
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            echo "Error: Failed to fetch usage data" >&2
            exit 2
        }
    fi

    # Check cache exists
    if [[ ! -f "$cache_file" ]]; then
        if [[ "$hook_mode" == true ]]; then
            exit 0  # Fail open
        fi
        echo "Error: No usage cache found at $cache_file" >&2
        exit 2
    fi

    # Validate active_account matches current account
    local current_email cached_account
    current_email=$(get_current_account)
    cached_account=$(jq -r '.active_account // empty' "$cache_file" 2>/dev/null || true)

    if [[ -n "$cached_account" && "$cached_account" != "$current_email" ]]; then
        # Cache is stale (different account), try to refresh
        if fetch_usage_data; then
            : # Cache refreshed successfully
        else
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            echo "Error: Cache account mismatch and refresh failed" >&2
            exit 2
        fi
    fi

    # Read utilization
    local usage usage_int
    usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
    usage_int=$(printf "%.0f" "$usage" 2>/dev/null || echo "0")

    # Below threshold — all good
    if [[ "$usage_int" -lt "$threshold" ]]; then
        if [[ "$hook_mode" != true ]]; then
            echo "Usage: ${usage_int}% (threshold: ${threshold}%) — OK"
        fi
        exit 0
    fi

    # Above threshold
    if [[ "$hook_mode" != true ]]; then
        echo "Usage: ${usage_int}% exceeds threshold ${threshold}%"
    fi

    if [[ "$auto_switch" == true ]]; then
        if [[ ! -f "$SEQUENCE_FILE" ]]; then
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            echo "Error: No accounts configured" >&2
            exit 2
        fi

        local total_accounts
        total_accounts=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")

        if [[ "$total_accounts" -lt 2 ]]; then
            if [[ "$hook_mode" == true ]]; then
                _rate_hook_deny "Rate limit exceeded (${usage_int}%). No other accounts to switch to."
                exit 0
            fi
            echo "Only one account configured, cannot auto-switch" >&2
            exit 3
        fi

        # Try switching to next accounts (up to N-1 attempts)
        local attempts=0
        local max_attempts=$((total_accounts - 1))

        while [[ $attempts -lt $max_attempts ]]; do
            local active_account next_account next_email
            active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
            next_account=$(jq -r --argjson active "$active_account" '
                .sequence as $seq |
                ($seq | index($active) // 0) as $idx |
                $seq[($idx + 1) % ($seq | length)]
            ' "$SEQUENCE_FILE")
            next_email=$(jq -r --arg num "$next_account" '.accounts[$num].email' "$SEQUENCE_FILE")

            # Perform switch in subshell to catch exit 1 from perform_switch
            if ! (CCS_SILENT=1 perform_switch "$next_account"); then
                # Switch failed — fail open in hook mode
                if [[ "$hook_mode" == true ]]; then
                    exit 0
                fi
                echo "Error: Failed to switch to Account-$next_account ($next_email)" >&2
                exit 2
            fi

            # Invalidate cache and re-fetch for new account
            rm -f "$cache_file"
            if fetch_usage_data; then
                local new_usage new_usage_int
                new_usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
                new_usage_int=$(printf "%.0f" "$new_usage" 2>/dev/null || echo "0")

                if [[ "$new_usage_int" -lt "$threshold" ]]; then
                    # Successfully switched to an account under the threshold
                    if [[ "$hook_mode" == true ]]; then
                        _rate_hook_deny "Rate limit exceeded. Switched to Account-$next_account ($next_email). Please restart Claude Code."
                        exit 0
                    fi
                    echo "Switched to Account-$next_account ($next_email) — usage: ${new_usage_int}%"
                    handle_restart_after_switch
                    exit 1
                fi
            else
                # Can't verify new account's usage, assume it's OK
                if [[ "$hook_mode" == true ]]; then
                    _rate_hook_deny "Rate limit exceeded. Switched to Account-$next_account ($next_email). Please restart Claude Code."
                    exit 0
                fi
                echo "Switched to Account-$next_account ($next_email) — could not verify usage"
                handle_restart_after_switch
                exit 1
            fi

            attempts=$((attempts + 1))
        done

        # All accounts are limited
        if [[ "$hook_mode" == true ]]; then
            _rate_hook_deny "Rate limit exceeded on all accounts (${usage_int}%). Please wait for limits to reset."
            exit 0
        fi
        echo "All accounts are above the threshold" >&2
        exit 3
    fi

    # No auto-switch, just report
    if [[ "$hook_mode" == true ]]; then
        _rate_hook_deny "Rate limit exceeded (${usage_int}%). Run 'ccs sw' to switch accounts."
        exit 0
    fi
    exit 1
}

# Output hook-protocol JSON to deny a tool call
_rate_hook_deny() {
    local reason="$1"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"$reason"}}
EOF
}

# Rate limit auto-switch setup
# Usage: ccs rate-setup [--threshold N] [--disable]
cmd_rate_setup() {
    local threshold=80
    local disable=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)
                threshold="$2"
                shift 2
                ;;
            --disable)
                disable=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    setup_directories
    init_sequence_file

    local settings_file="$HOME/.claude/settings.local.json"

    # Determine hook script path
    local hook_script
    hook_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks/ccs-rate-hook.sh"

    if [[ "$disable" == true ]]; then
        # Disable: update config and remove hook
        local updated
        updated=$(jq '.rateLimit = {enabled: false}' "$SEQUENCE_FILE" 2>/dev/null)
        write_json "$SEQUENCE_FILE" "$updated"

        # Remove hook from settings.local.json if present (match by hook script path)
        if [[ -f "$settings_file" ]]; then
            local cleaned
            cleaned=$(jq --arg hook "$hook_script" '
                if .hooks and .hooks.PreToolUse then
                    .hooks.PreToolUse = [.hooks.PreToolUse[] | select(.command | contains($hook) | not)]
                else . end
            ' "$settings_file" 2>/dev/null)
            if [[ -n "$cleaned" ]]; then
                echo "$cleaned" | jq . > "$settings_file"
            fi
        fi

        echo "Rate limit auto-switch disabled."
        echo "Hook removed from $settings_file"
        return
    fi

    # Enable: update config
    local updated
    updated=$(jq --argjson thresh "$threshold" '
        .rateLimit = {enabled: true, threshold: $thresh}
    ' "$SEQUENCE_FILE" 2>/dev/null)
    write_json "$SEQUENCE_FILE" "$updated"

    # Check hook script exists
    if [[ ! -f "$hook_script" ]]; then
        echo "Warning: Hook script not found at $hook_script"
        echo "Make sure you have the hooks/ccs-rate-hook.sh file installed."
        return 1
    fi

    # Install hook into settings.local.json
    mkdir -p "$(dirname "$settings_file")"
    if [[ ! -f "$settings_file" ]]; then
        echo '{}' > "$settings_file"
    fi

    # Resolve absolute path to this script (ccs binary) for CCS_PATH
    local ccs_bin
    ccs_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Build hook command with CCS_PATH so the hook can reliably find ccs
    local hook_command="CCS_PATH=${ccs_bin} ${hook_script}"

    # Check if hook already exists (idempotent) — match by hook script path
    local hook_exists
    hook_exists=$(jq --arg hook "$hook_script" '
        .hooks.PreToolUse // [] | map(select(.command | contains($hook))) | length
    ' "$settings_file" 2>/dev/null || echo "0")

    if [[ "$hook_exists" == "0" ]]; then
        local with_hook
        with_hook=$(jq --arg hook "$hook_command" '
            .hooks.PreToolUse = (.hooks.PreToolUse // []) + [
                {
                    "matcher": "",
                    "command": $hook
                }
            ]
        ' "$settings_file" 2>/dev/null)
        echo "$with_hook" | jq . > "$settings_file"
    fi

    echo "Rate limit auto-switch enabled."
    echo "  Threshold: ${threshold}%"
    echo "  Hook script: $hook_script"
    echo "  Settings: $settings_file"
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code v${VERSION}"
    echo "Usage: ccs [OPTIONS] <command> [args]"
    echo ""
    echo "Account Management:"
    echo "  add                              Add current account to managed accounts"
    echo "  rm <num|email>                   Remove account by number or email"
    echo "  ls                               List all managed accounts"
    echo ""
    echo "Switching:"
    echo "  sw                               Rotate to next account in sequence"
    echo "  to <num|email|profile>           Switch to specific account"
    echo ""
    echo "Profile Management:"
    echo "  profile <num|email> <name>       Set a friendly profile name for an account"
    echo ""
    echo "Directory-based Switching:"
    echo "  dir [dir] <num|email|profile>    Associate a directory with an account"
    echo "  auto                             Switch based on current directory mapping"
    echo ""
    echo "Rate Limiting:"
    echo "  rate-check [--threshold N]       Check if usage exceeds threshold"
    echo "  rate-setup [--threshold N]       Install PreToolUse hook for auto-switch"
    echo "  rate-setup --disable             Remove hook and disable auto-switch"
    echo ""
    echo "Diagnostics:"
    echo "  check                            Verify backup integrity (JSON, permissions, keychain)"
    echo "  status                           Show current account, token expiry, last switch"
    echo "  stats                            Show per-account usage statistics"
    echo ""
    echo "Options:"
    echo "  -n, --dry-run                    Show what would happen without making changes"
    echo "  -r, --restart                    Restart Claude Code after switching"
    echo "  --no-restart                     Skip restart prompt after switching"
    echo "  version                          Show version number"
    echo "  help                             Show this help message"
    echo ""
    echo "Examples:"
    echo "  ccs add                                    # Add current account"
    echo "  ccs ls                                     # List accounts"
    echo "  ccs sw                                     # Rotate to next account"
    echo "  ccs to 2                                   # Switch to account 2"
    echo "  ccs to user@example.com                    # Switch by email"
    echo "  ccs to work                                # Switch by profile name"
    echo "  ccs -n sw                                  # Preview switch"
    echo "  ccs sw -r                                  # Switch and restart Claude Code"
    echo "  ccs profile 1 work                         # Name account 1 'work'"
    echo "  ccs dir ~/work 1                           # Map ~/work to account 1"
    echo "  ccs auto                                   # Switch based on current directory"
    echo "  ccs rm user@example.com                    # Remove account"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi

    check_dependencies

    # Parse global flags first, collect remaining args
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                DRY_RUN=true
                shift
                ;;
            --restart|-r)
                RESTART_FLAG="restart"
                shift
                ;;
            --no-restart)
                RESTART_FLAG="no-restart"
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Restore positional parameters from remaining args
    set -- "${args[@]+"${args[@]}"}"

    case "${1:-}" in
        add|--add-account)
            cmd_add_account
            ;;
        rm|--remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        ls|--list)
            cmd_list
            ;;
        sw|--switch)
            cmd_switch
            ;;
        to|--switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        profile|--set-profile)
            shift
            cmd_set_profile "$@"
            ;;
        dir|--set-dir-account)
            shift
            cmd_set_dir_account "$@"
            ;;
        auto|--auto-switch)
            cmd_auto_switch
            ;;
        rate-check)
            shift
            cmd_rate_check "$@"
            ;;
        rate-setup)
            shift
            cmd_rate_setup "$@"
            ;;
        check|--check)
            cmd_check
            ;;
        status|--status)
            cmd_status
            ;;
        stats|--stats)
            cmd_stats
            ;;
        version|--version)
            echo "ccs v${VERSION}"
            ;;
        help|--help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
