#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Version
readonly VERSION="0.6.0"

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"
readonly DIR_ACCOUNTS_FILE="$BACKUP_DIR/dir-accounts.json"
# Parent dir for per-account isolated CLAUDE_CONFIG_DIR sandboxes (see `ccs exec`).
readonly ISOLATED_DIR="$BACKUP_DIR/isolated"
# Directory used as an exclusive lock for credential switches. mkdir is atomic on
# every POSIX filesystem (macOS has no flock), so it serializes concurrent switches.
readonly LOCK_DIR="$BACKUP_DIR/.switch.lock"
# How long a cached usage reading stays "fresh" (seconds). Past this the rate-limit
# check re-fetches from the usage API so headless (`claude -p`) runs aren't stale.
# Override per-install with .rateLimit.cacheTtl in sequence.json.
readonly DEFAULT_CACHE_TTL=60

# Global flags (set during argument parsing)
DRY_RUN=false
RESTART_FLAG=""  # "", "restart", or "no-restart"
RESUME_AFTER=false  # true when --resume: resume the conversation after switching
RESUME_SID=""       # captured lastSessionId for $PWD, set before the switch
RESUME_MODE=""      # "fork", "same", or "" to resolve from config (see resume_mode)
# Allow running as root. Defaults from CCSWITCH_ALLOW_ROOT (1/true to enable),
# can also be set with the --allow-root flag.
if [[ "${CCSWITCH_ALLOW_ROOT:-}" == "1" || "${CCSWITCH_ALLOW_ROOT:-}" == "true" ]]; then
    ALLOW_ROOT=true
else
    ALLOW_ROOT=false
fi

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

# Decide whether root execution should be blocked.
# Args: <euid> <allow_root (true|false)>
# Returns 0 (block) when running as root without an explicit opt-out, else 1.
should_block_root() {
    local euid="$1"
    local allow_root="$2"

    [[ "$euid" -eq 0 ]] || return 1            # not root -> never block
    [[ "$allow_root" == "true" ]] && return 1   # explicitly allowed via flag/env
    is_running_in_container && return 1         # containers are allowed by default
    return 0                                     # otherwise: block
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
            return
        fi
        # Try endpoint label
        account_num=$(jq -r --arg label "$identifier" '.accounts | to_entries[] | select(.value.label == $label) | .key' "$SEQUENCE_FILE" 2>/dev/null)
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

# Acquire an exclusive lock around a credential switch so concurrent agents
# (e.g. orchestrator heartbeats crossing the threshold at once) can't race the
# non-atomic read-modify-write of the credential store + sequence.json.
# mkdir is atomic everywhere; macOS lacks flock. Steals a lock whose owner PID
# is gone. Returns 0 on success, 1 on timeout.
acquire_switch_lock() {
    local timeout_s="${1:-10}"
    local max_iters=$(( timeout_s * 5 ))   # 0.2s per iteration
    local i=0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        # Stale-lock recovery: if the recorded owner is dead, reclaim the lock.
        local owner=""
        owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
            continue
        fi
        i=$(( i + 1 ))
        if [[ "$i" -ge "$max_iters" ]]; then
            return 1
        fi
        sleep 0.2
    done
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
    return 0
}

# Release the switch lock. Idempotent (safe to call when not held).
release_switch_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# Is the usage cache missing, account-mismatched, or older than the TTL?
# Echoes "stale" or "fresh". Used by both rate-check and the statusline.
cache_freshness() {
    local cache_file="$1"
    local ttl="$2"
    local expected_account="${3:-}"
    [[ -f "$cache_file" ]] || { echo "stale"; return; }
    local cached_at now age
    cached_at=$(jq -r '.cached_at // 0' "$cache_file" 2>/dev/null || echo 0)
    [[ "$cached_at" =~ ^[0-9]+$ ]] || cached_at=0
    now=$(date +%s)
    age=$(( now - cached_at ))
    if [[ "$cached_at" -le 0 || "$age" -ge "$ttl" ]]; then
        echo "stale"; return
    fi
    if [[ -n "$expected_account" ]]; then
        local cached_account
        cached_account=$(jq -r '.active_account // empty' "$cache_file" 2>/dev/null || true)
        if [[ -n "$cached_account" && "$cached_account" != "$expected_account" ]]; then
            echo "stale"; return
        fi
    fi
    echo "fresh"
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

# Decode a hex string (bare "7b22…" or "0x7b22…") to raw bytes. Pure Bash so we
# don't depend on xxd/perl, which may be absent (especially on Linux/WSL CI).
_hex_decode() {
    local hex="${1#0x}" i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        printf '%b' "\\x${hex:i:2}"
    done
}

# Read a generic-password secret from the macOS Keychain.
#
# When Claude Code stores the credential as binary data (newer versions do),
# `security -w` prints it as a hex dump ("7b22…" or "0x7b22…") instead of the
# JSON text. Credential JSON always contains non-hex bytes ('{', '"', …), so an
# all-hex, even-length payload is unambiguously a hex dump and is decoded back to
# JSON. Anything else (raw JSON, or empty when the item is missing) is returned
# as-is. Without this, callers get hex and every `jq` on the credential fails.
keychain_read() {
    local service="$1" raw stripped
    raw=$(security find-generic-password -s "$service" -w 2>/dev/null) || true
    stripped="${raw#0x}"
    if [[ -n "$stripped" && "$stripped" =~ ^[0-9a-fA-F]+$ && $(( ${#stripped} % 2 )) -eq 0 ]]; then
        _hex_decode "$raw"
    else
        printf '%s' "$raw"
    fi
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            keychain_read "Claude Code-credentials"
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

# Normalize a credential blob to single-line JSON. macOS `security -w`
# hex-encodes any value containing newlines, and Claude reads the raw item
# and cannot decode hex -> 401. Compacting to one line keeps it plain text.
# Non-JSON input is returned unchanged.
normalize_credential() {
    local cred="$1"
    if printf '%s' "$cred" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$cred" | jq -c .
    else
        printf '%s' "$cred"
    fi
}

# --- Credential accessors -------------------------------------------------
# Claude Code 2.1.x stores nested camelCase: {claudeAiOauth:{accessToken,
# refreshToken, expiresAt(ms)}}. Older/Linux creds may be flat snake_case
# {access_token, refresh_token}. These accessors read/write either shape so
# the rest of the tool is format-agnostic.

cred_access_token() {
    printf '%s' "$1" | jq -r '.claudeAiOauth.accessToken // .access_token // .token // empty' 2>/dev/null
}

cred_refresh_token() {
    printf '%s' "$1" | jq -r '.claudeAiOauth.refreshToken // .refresh_token // empty' 2>/dev/null
}

# Echo the token expiry as epoch SECONDS, or empty if undeterminable.
# Prefers nested expiresAt (epoch ms); else decodes a flat JWT access token.
cred_expiry_epoch() {
    local cred="$1" ms token payload exp
    ms=$(printf '%s' "$cred" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
        echo $(( ms / 1000 ))
        return
    fi
    token=$(cred_access_token "$cred")
    if [[ -n "$token" ]]; then
        payload=$(decode_jwt_payload "$token")
        exp=$(printf '%s' "$payload" | jq -r '.exp // empty' 2>/dev/null)
        if [[ "$exp" =~ ^[0-9]+$ ]]; then
            echo "$exp"
            return
        fi
    fi
    echo ""
}

# Return the credential JSON with access/refresh tokens replaced, written to
# whichever shape the input used, normalized to single-line.
cred_set_tokens() {
    local cred="$1" access="$2" refresh="$3" out
    if ! printf '%s' "$cred" | jq -e . >/dev/null 2>&1; then
        return 1   # not valid JSON; refuse to write back garbage
    fi
    if printf '%s' "$cred" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
        out=$(printf '%s' "$cred" | jq --arg a "$access" --arg r "$refresh" \
            '.claudeAiOauth.accessToken = $a | .claudeAiOauth.refreshToken = $r' 2>/dev/null)
    else
        out=$(printf '%s' "$cred" | jq --arg a "$access" --arg r "$refresh" \
            '.access_token = $a | .refresh_token = $r' 2>/dev/null)
    fi
    normalize_credential "$out"
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    credentials=$(normalize_credential "$credentials")
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
            keychain_read "Claude Code-Account-${account_num}-${email}"
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
    credentials=$(normalize_credential "$credentials")
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

# --- Account type helpers -------------------------------------------------
# Endpoint accounts (authType:"endpoint") carry a base URL + API key/token in
# the env block instead of OAuth credentials. authType is absent on legacy
# records, which therefore read as "oauth".

account_auth_type() {
    local num="$1"
    jq -r --arg n "$num" '.accounts[$n].authType // "oauth"' "$SEQUENCE_FILE" 2>/dev/null || echo "oauth"
}

is_endpoint_account() {
    [[ "$(account_auth_type "$1")" == "endpoint" ]]
}

# Read one field from an account record, with a default when absent/null.
account_field() {
    local num="$1" field="$2" default="${3:-}"
    local v
    v=$(jq -r --arg n "$num" --arg f "$field" '.accounts[$n][$f] // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -z "$v" ]]; then echo "$default"; else echo "$v"; fi
}

# Human identifier: label for endpoints, email for oauth accounts.
account_display_id() {
    local num="$1"
    if is_endpoint_account "$num"; then
        account_field "$num" "label"
    else
        account_field "$num" "email"
    fi
}

# Which account is actually live. Endpoint accounts leave .claude.json's email
# untouched, so when activeAccountNumber points at an endpoint we trust it;
# otherwise we map the live oauth email to its slot (handles external relogin).
effective_active_account_num() {
    local an
    an=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ -n "$an" ]] && is_endpoint_account "$an"; then
        echo "$an"
        return
    fi
    local email
    email=$(get_current_account)
    jq -r --arg e "$email" '(.accounts | to_entries[] | select(.value.email == $e) | .key) // empty' \
        "$SEQUENCE_FILE" 2>/dev/null || true
}

# --- Endpoint env block (settings.json) -----------------------------------
# Switching to an endpoint writes ANTHROPIC_* into the user-global settings env
# block; switching to oauth removes exactly those keys so stored OAuth creds
# take over again. settings.json env is applied at Claude Code startup, so a
# restart is required for an endpoint-crossing switch to take effect.

# Env keys ccs owns. The token var (api key vs auth token) is also in this set
# so the unused one is always cleared.
# shellcheck disable=SC2034
readonly CCS_ENV_KEYS=("ANTHROPIC_BASE_URL" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_MODEL")

ccs_settings_file() { echo "$HOME/.claude/settings.json"; }

# Where earlier versions installed the rate hook and the statusline. Claude Code
# reads user-level settings from settings.json only: a settings.local.json is a
# project-scoped file (<project>/.claude/settings.local.json), so entries written
# to the one under ~/.claude never take effect. Kept so setup and --disable can
# clear those inert entries out on the next run.
ccs_legacy_settings_file() { echo "$HOME/.claude/settings.local.json"; }

# Echo the contents of a settings file, or "{}" when it doesn't exist yet.
# Fails closed on malformed JSON: rewriting the file from {} would drop unrelated
# user settings, so the caller must abort instead.
read_settings_or_fail() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo '{}'
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        echo "Error: invalid settings file at $file" >&2
        return 1
    fi
    cat "$file"
}

# Absolute directory holding <path>. Pass --physical to resolve symlinked
# directory components as well.
_abs_dir() {
    local dir="${1%/*}"
    [[ "$dir" == "$1" ]] && dir="."
    if [[ "${2:-}" == "--physical" ]]; then
        (cd -P "$dir" && pwd)
    else
        (cd "$dir" && pwd)
    fi
}

# The path ccs was invoked through, made absolute but with symlinks left alone.
# This is the path we hand to the hook and the statusline as $CCS_PATH: an
# install is usually reached through a stable link (/opt/homebrew/bin/ccs) while
# the file behind it sits in a versioned directory that an upgrade replaces.
ccs_invoked_path() {
    printf '%s/%s\n' "$(_abs_dir "${BASH_SOURCE[0]}")" "${BASH_SOURCE[0]##*/}"
}

# The real file behind that path, symlinks resolved — the scripts we ship sit
# next to it, or next to the bin/ directory holding it.
ccs_real_path() {
    local src="${BASH_SOURCE[0]}" target
    while [[ -L "$src" ]]; do
        target="$(readlink "$src")"
        if [[ "$target" == /* ]]; then
            src="$target"
        else
            src="$(_abs_dir "$src" --physical)/$target"
        fi
    done
    printf '%s/%s\n' "$(_abs_dir "$src" --physical)" "${src##*/}"
}

# Locate a script shipped with ccs, given its path relative to the project root
# (e.g. "hooks/ccs-rate-hook.sh"). Installs lay them out one of two ways:
#   - next to ccswitch.sh (source checkout, npm package)
#   - <prefix>/share/ccswitch/ while only the binary goes in <prefix>/bin
#     (`make install`, Homebrew)
# Both are searched from the invocation path before the symlink-resolved one, so
# an install reached through a stable link yields a stable script path that
# survives an upgrade. $CCS_SHARE_DIR overrides the search for packagers.
# Echoes the path, or explains the failure on stderr and returns 1.
ccs_shipped_script() {
    local rel="$1" invoked_dir real_dir candidate
    invoked_dir="$(_abs_dir "${BASH_SOURCE[0]}")"
    real_dir="$(ccs_real_path)"
    real_dir="${real_dir%/*}"

    for candidate in \
        "${CCS_SHARE_DIR:+${CCS_SHARE_DIR%/}/$rel}" \
        "$invoked_dir/$rel" "${invoked_dir%/*}/share/ccswitch/$rel" \
        "$real_dir/$rel" "${real_dir%/*}/share/ccswitch/$rel"
    do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "Error: $rel not found." >&2
    echo "Reinstall ccs so the scripts it ships are installed with it, or set" >&2
    echo "CCS_SHARE_DIR to the directory that holds ${rel%%/*}/." >&2
    return 1
}

# jq predicate: is this hook / statusLine command one we installed? Matches the
# script name as a whole path element, so a user's own my-ccs-rate-hook.sh — or a
# wrapper that merely mentions the name — is never mistaken for ours. Matching on
# the name rather than the full path means entries stay ours across a reinstall
# at a different prefix.
# shellcheck disable=SC2016  # $name is a jq variable, not a shell one
readonly CCS_OWNED_JQ='def ccs_owned($name):
    ((. // "") | test("(^|/)" + ($name | gsub("\\."; "\\.")) + "([[:space:]]|$)"));'

# Path to the OAuth usage cache. Honors $CCS_USAGE_CACHE so tests can keep it in
# their fixture instead of a host-global temp file. Otherwise it resolves the
# system temp dir ($TMPDIR/$TMP/$TEMP, falling back to /tmp) so macOS, Linux,
# WSL, and Git Bash all agree. The statusline (writer) and rate hook (reader)
# resolve the same way — keep the three in sync.
usage_cache_file() {
    if [[ -n "${CCS_USAGE_CACHE:-}" ]]; then
        echo "$CCS_USAGE_CACHE"
        return
    fi
    local cache_dir="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
    echo "${cache_dir%/}/claude-usage-cache.json"
}

# Round a usage percentage from the cache ("15.0") to an integer.
#
# Two traps here. printf's %f honors LC_NUMERIC: under a comma-decimal locale it
# prints a partial result and *then* fails on a dot-decimal string, so the locale
# is pinned to C. The pin is a statement inside the subshell, not an `LC_ALL=C
# printf` command prefix: bash 3.2 (macOS /bin/bash) does not re-run setlocale
# for a transient assignment to a builtin, so the prefix form still fails there.
# And the fallback must stay out of the command substitution — folded in, it is
# appended to that partial output and 15.0 reads as 150.
#
# Prints nothing and returns 1 when the value can't be read, so callers can tell
# an unreadable reading from a genuine 0%. The rate hook and the statusline carry
# their own copy of this shape: they are installed as standalone scripts and
# cannot source this one — keep the three in sync.
usage_to_int() {
    local raw="$1" rounded
    rounded=$(LC_ALL=C; printf '%.0f' "$raw" 2>/dev/null) || return 1
    [[ "$rounded" =~ ^-?[0-9]+$ ]] || return 1
    printf '%s\n' "$rounded"
}

# write_endpoint_env <base_url> <token_header: api_key|auth_token> <token> <model-or-empty>
write_endpoint_env() {
    local base_url="$1" token_header="$2" token="$3" model="$4"
    local file; file="$(ccs_settings_file)"
    mkdir -p "$(dirname "$file")"

    local base
    base=$(read_settings_or_fail "$file") || return 1

    local token_var="ANTHROPIC_API_KEY"
    [[ "$token_header" == "auth_token" ]] && token_var="ANTHROPIC_AUTH_TOKEN"

    local updated
    updated=$(printf '%s' "$base" | jq \
        --arg url "$base_url" --arg tvar "$token_var" --arg tok "$token" --arg model "$model" '
        .env = (.env // {})
        # Start from a clean ccs-owned slate so a stale token var is dropped.
        | .env |= (del(.ANTHROPIC_BASE_URL, .ANTHROPIC_API_KEY, .ANTHROPIC_AUTH_TOKEN, .ANTHROPIC_MODEL))
        | .env.ANTHROPIC_BASE_URL = $url
        | .env[$tvar] = $tok
        | (if $model != "" then .env.ANTHROPIC_MODEL = $model else . end)
    ') || return 1

    write_json "$file" "$updated"
}

# Remove all ccs-owned env keys (used when switching back to an oauth account).
clear_endpoint_env() {
    local file; file="$(ccs_settings_file)"
    [[ -f "$file" ]] || return 0
    jq -e . "$file" >/dev/null 2>&1 || return 0
    local updated
    updated=$(jq '
        if (.env | type) == "object"
        then .env |= del(.ANTHROPIC_BASE_URL, .ANTHROPIC_API_KEY, .ANTHROPIC_AUTH_TOKEN, .ANTHROPIC_MODEL)
        else . end
    ' "$file") || return 0
    write_json "$file" "$updated"
}

# Endpoint secrets are stored in the same per-account credential slot used for
# OAuth, wrapped as {"endpointKey":"<token>"} so the existing Keychain/file
# path (read/write_account_credentials) is reused and the raw key never lands
# in sequence.json.
endpoint_secret() {
    local num="$1" label creds
    label=$(account_field "$num" "label")
    creds=$(read_account_credentials "$num" "$label")
    printf '%s' "$creds" | jq -r '.endpointKey // empty' 2>/dev/null
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

# Resolve how --resume relaunches: "fork" forks the conversation into a new
# session id, "same" continues the existing one (so tools that follow a session
# keep tracking it). Precedence: --fork-session/--no-fork-session flag, then
# .resume.mode in sequence.json, then "fork". An unrecognized stored value falls
# back to the default rather than failing the switch.
resume_mode() {
    if [[ "$RESUME_MODE" == "fork" || "$RESUME_MODE" == "same" ]]; then
        echo "$RESUME_MODE"
        return
    fi
    local configured=""
    if [[ -f "$SEQUENCE_FILE" ]]; then
        configured=$(jq -r '.resume.mode // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    fi
    case "$configured" in
        fork|same) echo "$configured" ;;
        *) echo "fork" ;;
    esac
}

# Build the relaunch command for a resume restart.
# Args: <claude_bin> <session_id> [mode]. With a session id -> resume, forking
# only in "fork" mode; without one -> fresh. Mode defaults to the resolved one.
build_resume_command() {
    local bin="$1" sid="$2" mode="${3:-$(resume_mode)}"
    if [[ -z "$sid" ]]; then
        printf '%s' "$bin"
    elif [[ "$mode" == "fork" ]]; then
        printf '%s --resume %s --fork-session' "$bin" "$sid"
    else
        printf '%s --resume %s' "$bin" "$sid"
    fi
}

# Echo the lastSessionId for the current working directory from the (outgoing)
# .claude.json, or empty if none. MUST be called before a switch swaps the file.
capture_resume_session_id() {
    local cfg
    cfg=$(get_claude_config_path)
    [[ -f "$cfg" ]] || return 0
    jq -r --arg c "$PWD" '.projects[$c].lastSessionId // empty' "$cfg" 2>/dev/null || true
}

# Foreground relaunch that resumes the captured conversation under the
# now-active account, forking it or continuing it in place depending on the
# resolved mode. Falls back to a fresh launch when there is no session id.
restart_claude_code_resume() {
    local sid="$1" bin mode
    mode=$(resume_mode)
    bin=$(command -v claude 2>/dev/null || echo "")
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        echo "Switched. 'claude' not found in PATH — resume manually:"
        echo "  $(build_resume_command claude "$sid" "$mode")"
        return 0
    fi
    kill_claude_processes
    # Re-check: the binary could have vanished between lookup and exec; a failed
    # exec would terminate the user's shell, so fall back to a clear message.
    if [[ ! -x "$bin" ]]; then
        echo "Error: '$bin' is no longer executable — resume manually:"
        echo "  $(build_resume_command claude "$sid" "$mode")"
        return 1
    fi
    if [[ -n "$sid" && "$mode" == "fork" ]]; then
        echo "Resuming conversation under the new account (forked session)..."
        exec "$bin" --resume "$sid" --fork-session
    elif [[ -n "$sid" ]]; then
        echo "Resuming conversation under the new account (same session)..."
        exec "$bin" --resume "$sid"
    else
        echo "No previous conversation found for this directory — starting fresh."
        exec "$bin"
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
    if [[ "$RESUME_AFTER" == true ]]; then
        if [[ -n "$RESTART_FLAG" && "${CCS_SILENT:-}" != "1" ]]; then
            echo "Note: --restart/--no-restart is ignored when --resume is given." >&2
        fi
        restart_claude_code_resume "$RESUME_SID"
        return
    fi
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
                    # Validate it's valid JSON (decoding the hex form security -w may emit)
                    local kc_creds
                    kc_creds=$(keychain_read "Claude Code-Account-${num}-${email}")
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

    local _active_num
    _active_num=$(effective_active_account_num)
    if [[ -n "$_active_num" ]] && is_endpoint_account "$_active_num"; then
        echo "Account Status"
        echo "=============="
        echo ""
        echo "Current account: $(account_display_id "$_active_num") [endpoint]"
        echo "Account number:  $_active_num"
        echo "Base URL:        $(account_field "$_active_num" baseUrl)"
        local _m; _m=$(account_field "$_active_num" model)
        [[ -n "$_m" ]] && echo "Model:           $_m"
        echo "Auth:            $(account_field "$_active_num" tokenHeader api_key) (key hidden)"
        local _lu; _lu=$(jq -r '.lastUpdated // empty' "$SEQUENCE_FILE" 2>/dev/null)
        [[ -n "$_lu" ]] && echo "Last switch:     $_lu"
        echo ""
        echo "Note: settings.json env applies on Claude Code restart."
        return 0
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
        local exp
        exp=$(cred_expiry_epoch "$creds")
        if [[ -n "$exp" ]]; then
            local now diff
            now=$(date +%s)
            diff=$((exp - now))
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
            echo "Token status:    Unable to determine expiry"
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

# Add a custom-endpoint account.
# Usage: ccs add-endpoint <label> --base-url <URL> [--model <M>]
#        [--token-header api_key|auth_token] [--key-stdin]
cmd_add_endpoint() {
    setup_directories
    init_sequence_file

    if [[ $# -eq 0 ]]; then
        echo "Usage: ccs add-endpoint <label> --base-url <URL> [--model <M>] [--token-header api_key|auth_token] [--key-stdin]"
        exit 1
    fi

    local label="$1"; shift
    if [[ -z "$label" || "$label" == --* ]]; then
        echo "Error: a non-empty label is required"
        exit 1
    fi
    # The label becomes part of the file-backed credential id on Linux/WSL
    # (.claude-credentials-<num>-<label>.json), so reject path-unsafe characters
    # to keep endpoint accounts portable across macOS and Linux/WSL.
    if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Error: label may only contain letters, numbers, dot, underscore, and hyphen"
        exit 1
    fi
    local base_url="" model="" token_header="api_key" key_stdin=false
    # Guard value-taking options so a missing value gives a clear error instead
    # of tripping `set -u` ($2: unbound variable).
    _require_value() { [[ $# -ge 2 ]] || { echo "Error: $1 requires a value"; exit 1; }; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url)     _require_value "$@"; base_url="$2"; shift 2 ;;
            --model)        _require_value "$@"; model="$2"; shift 2 ;;
            --token-header) _require_value "$@"; token_header="$2"; shift 2 ;;
            --key-stdin)    key_stdin=true; shift ;;
            *) echo "Error: unknown option '$1'"; exit 1 ;;
        esac
    done

    if [[ -z "$base_url" ]]; then
        echo "Error: --base-url is required"
        exit 1
    fi
    if [[ "$token_header" != "api_key" && "$token_header" != "auth_token" ]]; then
        echo "Error: --token-header must be 'api_key' or 'auth_token'"
        exit 1
    fi
    if [[ ! "$base_url" =~ ^https?:// ]]; then
        echo "Error: --base-url must start with http:// or https://"
        exit 1
    fi

    # Reject a duplicate label (or an email/profile collision).
    # resolve_account_identifier checks email and profile; also check endpoint labels.
    local existing_num
    existing_num=$(resolve_account_identifier "$label")
    if [[ -z "$existing_num" ]]; then
        existing_num=$(jq -r --arg lbl "$label" \
            '.accounts | to_entries[] | select(.value.label == $lbl) | .key' \
            "$SEQUENCE_FILE" 2>/dev/null)
    fi
    if [[ -n "$existing_num" ]]; then
        echo "Error: an account named '$label' already exists"
        exit 1
    fi

    # Read the secret without echoing it / leaving it in shell history.
    local token=""
    if [[ "$key_stdin" == true ]]; then
        IFS= read -r token || true
    else
        read -rs -p "API key/token for '$label': " token
        echo ""
    fi
    if [[ -z "$token" ]]; then
        echo "Error: no API key/token provided"
        exit 1
    fi

    local account_num
    account_num=$(get_next_account_number)

    # Store the secret via the existing per-account credential path.
    local cred_json
    cred_json=$(jq -nc --arg k "$token" '{endpointKey:$k}')
    write_account_credentials "$account_num" "$label" "$cred_json"

    local updated
    updated=$(jq \
        --arg num "$account_num" --arg label "$label" --arg url "$base_url" \
        --arg model "$model" --arg th "$token_header" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = ({
            authType: "endpoint",
            label: $label,
            baseUrl: $url,
            tokenHeader: $th,
            added: $now
        } + (if $model != "" then {model: $model} else {} end))
        | .sequence += [$num | tonumber]
        | .lastUpdated = $now
    ' "$SEQUENCE_FILE")
    write_json "$SEQUENCE_FILE" "$updated"

    echo "Added endpoint Account $account_num: $label ($base_url)"
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
        # Resolve email / profile / endpoint label to an account number.
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found matching: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email auth_type
    email=$(echo "$account_info" | jq -r '.label // .email')
    auth_type=$(echo "$account_info" | jq -r '.authType // "oauth"')

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

    # Removing the active account leaves the global state pointing at a deleted
    # slot. For an active endpoint account, also strip the ccs-owned ANTHROPIC_*
    # env from settings.json so status/switch don't run against stale config.
    if [[ "$active_account" == "$account_num" ]]; then
        [[ "$auth_type" == "endpoint" ]] && clear_endpoint_env
    fi

    # Update sequence.json. Reset activeAccountNumber when it pointed at the
    # account being removed so it never references a deleted slot.
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        (if (.activeAccountNumber | tostring) == $num then .activeAccountNumber = null else . end) |
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

    # Find which account number is active (endpoint-aware).
    local active_account_num=""
    active_account_num=$(effective_active_account_num)

    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] as $a |
        ($a.label // $a.email) as $id |
        (if $a.authType == "endpoint" then " [endpoint]"
         elif $a.profile then " [\($a.profile)]" else "" end) as $tag |
        if "\($num)" == $active then
            "  \($num): \($id)\($tag) (active)"
        else
            "  \($num): \($id)\($tag)"
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
    local expected_active="${2:-}"

    # Get current and target account info
    local current_account target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].label // .accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # Capture the conversation pointer from the OUTGOING .claude.json (before the
    # swap) so we can fork-resume it under the new account.
    if [[ "$RESUME_AFTER" == true ]]; then
        RESUME_SID=$(capture_resume_session_id)
    fi

    # Dry-run mode: show what would happen and return
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY RUN] Would switch from Account-$current_account ($current_email) to Account-$target_account ($target_email)"
        echo "[DRY RUN] Steps that would be performed:"
        echo "  1. Backup current credentials and config for Account-$current_account"
        echo "  2. Restore credentials and config from Account-$target_account backup"
        echo "  3. Update active account in sequence.json"
        echo "  4. Update usage statistics"
        if [[ "$RESUME_AFTER" == true ]]; then
            echo "  5. Relaunch: $(build_resume_command claude "$RESUME_SID")"
        fi
        return
    fi

    # Serialize the switch: take the lock, then RE-READ the authoritative active
    # account under it (another switch may have landed since the reads above).
    if ! acquire_switch_lock 10; then
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Error: another account switch is in progress (could not acquire lock)."
        else
            echo "Error: switch lock busy; skipping." >&2
        fi
        exit 1
    fi
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # Reconcile the active account number against reality before touching the
    # credential store. sequence.json's activeAccountNumber can drift from the
    # credential actually live (external `claude login`, a crash mid-switch).
    # The email in .claude.json is the source of truth for whose credential is
    # live; trusting a stale number would back the live credential up under the
    # wrong slot and restore a stale one, destroying the working session.
    # When the live account is an endpoint, activeAccountNumber is authoritative
    # (no oauth email to reconcile against). Only reconcile for oauth.
    local current_is_endpoint=false
    if is_endpoint_account "$current_account"; then
        current_is_endpoint=true
        current_email=$(account_display_id "$current_account")
    else
        local real_current_account
        real_current_account=$(jq -r --arg email "$current_email" '
            (.accounts | to_entries[] | select(.value.email == $email) | .key) // empty
        ' "$SEQUENCE_FILE" 2>/dev/null)

        if [[ -z "$real_current_account" ]]; then
            release_switch_lock
            if [[ "${CCS_SILENT:-}" != "1" ]]; then
                echo "Error: the active account ($current_email) is not managed by ccs."
                echo "Run 'ccs add' before switching so its credentials aren't lost."
            else
                echo "Error: active account ($current_email) unmanaged; skipping switch." >&2
            fi
            exit 1
        fi
        if [[ "$real_current_account" != "$current_account" ]]; then
            if [[ "${CCS_SILENT:-}" != "1" ]]; then
                echo "Note: corrected active account $current_account -> $real_current_account (was out of sync)."
            fi
            current_account="$real_current_account"
        fi
    fi

    # Compare-and-swap precondition (used by `ccs run`): only switch if the
    # reconciled active account is still the one the caller expected. Under
    # concurrency another switch may have already rotated the shared account;
    # signal that with a distinct status so the caller retries without rotating.
    # Placed AFTER reconcile (so drift can't give a false verdict) and BEFORE the
    # no-op guard (so a concurrent switch onto our target isn't misread as our
    # success). Release the lock first, like every other post-acquire early exit.
    if [[ -n "$expected_active" && "$current_account" != "$expected_active" ]]; then
        release_switch_lock
        return 3
    fi

    # No-op guard: if we're already on the target (e.g. a concurrent switch beat
    # us to it), release and return without thrashing the credential store.
    if [[ "$current_account" == "$target_account" ]]; then
        release_switch_lock
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Already on Account-$target_account ($target_email)."
        fi
        if [[ "$RESUME_AFTER" == true ]]; then
            restart_claude_code_resume "$RESUME_SID"
        fi
        return
    fi

    # Save pre-switch state for rollback (settings.json included for env restore).
    local rollback_creds rollback_config rollback_sequence rollback_settings
    rollback_creds=$(read_credentials)
    rollback_config=$(cat "$(get_claude_config_path)")
    rollback_sequence=$(cat "$SEQUENCE_FILE")
    rollback_settings=""
    [[ -f "$(ccs_settings_file)" ]] && rollback_settings=$(cat "$(ccs_settings_file)")

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
        if [[ -n "$rollback_settings" ]]; then
            write_json "$(ccs_settings_file)" "$rollback_settings" 2>/dev/null || true
        else
            # No settings.json existed pre-switch: strip any endpoint env we may
            # have written so a failed switch can't leave an orphaned env block.
            clear_endpoint_env 2>/dev/null || true
        fi
        release_switch_lock
        if [[ "${CCS_SILENT:-}" != "1" ]]; then
            echo "Rollback complete. Account-$current_account ($current_email) is still active."
        else
            echo "Rollback complete." >&2
        fi
    }

    # Step 1: Back up the OUTGOING account. Endpoint accounts have no live oauth
    # state to capture (their secret/metadata are static), so skip the backup.
    if [[ "$current_is_endpoint" != true ]]; then
        local current_creds current_config
        current_creds=$(read_credentials)
        current_config=$(cat "$(get_claude_config_path)")
        if ! write_account_credentials "$current_account" "$current_email" "$current_creds"; then
            rollback; exit 1
        fi
        if ! write_account_config "$current_account" "$current_email" "$current_config"; then
            rollback; exit 1
        fi
    fi

    # Step 2+3: Activate the target, branched on its auth type.
    if is_endpoint_account "$target_account"; then
        # Endpoint target: drive Claude Code via the settings env block. Leave
        # credentials / .claude.json untouched (the dormant oauth login stays).
        local ep_base ep_th ep_model ep_token
        ep_base=$(account_field "$target_account" "baseUrl")
        ep_th=$(account_field "$target_account" "tokenHeader" "api_key")
        ep_model=$(account_field "$target_account" "model")
        ep_token=$(endpoint_secret "$target_account")
        if [[ -z "$ep_base" || -z "$ep_token" ]]; then
            echo "Error: Missing endpoint config/secret for Account-$target_account"
            rollback; exit 1
        fi
        if ! write_endpoint_env "$ep_base" "$ep_th" "$ep_token" "$ep_model"; then
            rollback; exit 1
        fi
    else
        # OAuth target: restore credentials + oauthAccount, and remove any
        # endpoint env so the OAuth login takes over again.
        local target_creds target_config
        target_creds=$(read_account_credentials "$target_account" "$target_email")
        target_config=$(read_account_config "$target_account" "$target_email")
        if [[ -z "$target_creds" || -z "$target_config" ]]; then
            echo "Error: Missing backup data for Account-$target_account"
            rollback; exit 1
        fi
        if ! write_credentials "$target_creds"; then
            rollback; exit 1
        fi
        local oauth_section
        oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
        if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
            echo "Error: Invalid oauthAccount in backup"
            rollback; exit 1
        fi
        local merged_config
        if ! merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null); then
            echo "Error: Failed to merge config"
            rollback; exit 1
        fi
        if ! write_json "$(get_claude_config_path)" "$merged_config"; then
            rollback; exit 1
        fi
        clear_endpoint_env
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

    # Switch is committed; release the lock before any interactive display/restart
    # so we never hold it while waiting on the user.
    release_switch_lock

    if [[ "${CCS_SILENT:-}" != "1" ]]; then
        echo "Switched to Account-$target_account ($target_email)"
        # Display updated account list
        cmd_list
        echo ""
        if is_endpoint_account "$target_account" || [[ "$current_is_endpoint" == true ]]; then
            echo "Note: this switch changes settings.json env — restart Claude Code for it to take effect."
        fi

        # Handle restart
        handle_restart_after_switch
    fi
}

# --- Per-agent isolation (CLAUDE_CONFIG_DIR) ----------------------------------
#
# Unlike a switch (which rewrites the single machine-global credential store),
# these materialize an account into its OWN config dir so multiple Claude Code
# processes can run as DIFFERENT accounts at the same time — the parallel
# multi-account case orchestrators need. No global mutation, so no lock needed.

# Materialize <account_num> into <dest> as .claude.json + .credentials.json.
# For the currently-active account we snapshot the LIVE global store (freshest,
# may hold refreshed tokens); for others we use the per-account backup.
# Returns 0 on success, 1 on failure.
materialize_config_dir() {
    local account_num="$1"
    local dest="$2"

    local email auth
    auth=$(account_auth_type "$account_num")
    email=$(account_display_id "$account_num")
    if [[ -z "$email" ]]; then
        echo "Error: Account-$account_num not found" >&2
        return 1
    fi

    if [[ "$auth" == "endpoint" ]]; then
        # Endpoint isolation is just an env-scoped dir: write a settings.json
        # with the endpoint env so `CLAUDE_CONFIG_DIR=<dest> claude` uses it.
        local ep_base ep_th ep_model ep_token token_var
        ep_base=$(account_field "$account_num" baseUrl)
        ep_th=$(account_field "$account_num" tokenHeader api_key)
        ep_model=$(account_field "$account_num" model)
        ep_token=$(endpoint_secret "$account_num")
        # Surface credential-store corruption instead of writing a broken config
        # (mirrors the OAuth branch's missing-data guard below).
        if [[ -z "$ep_base" || -z "$ep_token" ]]; then
            echo "Error: missing endpoint base URL or secret for Account-$account_num ($email)" >&2
            return 1
        fi
        token_var="ANTHROPIC_API_KEY"; [[ "$ep_th" == "auth_token" ]] && token_var="ANTHROPIC_AUTH_TOKEN"
        mkdir -p "$dest" 2>/dev/null || true
        chmod 700 "$dest" 2>/dev/null || true
        jq -nc --arg url "$ep_base" --arg tvar "$token_var" --arg tok "$ep_token" --arg model "$ep_model" '
            {env: ({ANTHROPIC_BASE_URL:$url, ($tvar):$tok}
                   + (if $model != "" then {ANTHROPIC_MODEL:$model} else {} end))}
        ' > "$dest/settings.json" || return 1
        chmod 600 "$dest/settings.json" 2>/dev/null || true
        return 0
    fi

    local active cfg creds
    active=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    if [[ "$account_num" == "$active" ]]; then
        # Live, freshest copy from the global store.
        cfg=$(cat "$(get_claude_config_path)" 2>/dev/null || true)
        creds=$(read_credentials)
    else
        cfg=$(read_account_config "$account_num" "$email")
        creds=$(read_account_credentials "$account_num" "$email")
    fi

    if [[ -z "$cfg" || -z "$creds" ]]; then
        echo "Error: missing stored data for Account-$account_num ($email)" >&2
        return 1
    fi

    mkdir -p "$dest" || { echo "Error: cannot create $dest" >&2; return 1; }
    chmod 700 "$dest" 2>/dev/null || true

    # Write the config; Claude Code reads $CLAUDE_CONFIG_DIR/.claude.json.
    if ! printf '%s' "$cfg" | jq . > "$dest/.claude.json" 2>/dev/null; then
        echo "Error: stored config for Account-$account_num is not valid JSON" >&2
        return 1
    fi
    chmod 600 "$dest/.claude.json" 2>/dev/null || true

    # Write credentials as a file. Claude Code reads $CLAUDE_CONFIG_DIR/.credentials.json
    # here, and setting CLAUDE_CONFIG_DIR does make it bypass the shared store (an empty
    # dir reads as logged-out). read_credentials decodes the hex form `security -w`
    # returns so this stays valid JSON.
    #
    # CAVEAT (macOS, #29): per-agent isolation by COPYING credentials does not work on
    # Claude Code 2.1.x. Claude binds the OAuth token to the live session, so a duplicated
    # token — file here OR the per-dir `Claude Code-credentials-<hash>` Keychain item —
    # is rejected with 401 in an isolated CLAUDE_CONFIG_DIR even when fresh. Reliable on
    # Linux/WSL only; on macOS the only path is `claude auth login` per dir.
    if ! printf '%s' "$creds" | jq . > "$dest/.credentials.json" 2>/dev/null; then
        echo "Error: stored credentials for Account-$account_num are not valid JSON" >&2
        return 1
    fi
    chmod 600 "$dest/.credentials.json" 2>/dev/null || true

    return 0
}

# Warn on macOS: copying credentials does NOT achieve isolation on Claude Code 2.1.x —
# the OAuth token is session-bound, so a duplicated token is rejected (401) in an isolated
# dir. Reliable on Linux/WSL; on macOS use `claude auth login` per dir. See #29.
_isolation_macos_note() {
    if [[ "$(detect_platform)" == "macos" ]]; then
        echo "Warning: on macOS, copying credentials does NOT isolate accounts on current" >&2
        echo "         Claude Code — a duplicated token is rejected (401) in the isolated dir." >&2
        echo "         Reliable on Linux/WSL. For macOS, run 'claude auth login' per dir. See #29." >&2
    fi
}

# ccs config-dir <account> [path]
# Materialize an account's config dir and print it (plus an export line) so an
# orchestrator can pin a process to that account itself.
cmd_config_dir() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ccs config-dir <account_number|email|profile> [path]"
        exit 1
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local identifier="$1"
    local dest="${2:-}"
    local account_num
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$identifier' not found"
        exit 1
    fi

    local email
    email=$(account_display_id "$account_num")
    [[ -z "$dest" ]] && dest="$ISOLATED_DIR/${account_num}-${email}"

    setup_directories
    if ! materialize_config_dir "$account_num" "$dest"; then
        exit 1
    fi

    _isolation_macos_note
    echo "$dest"
    echo "export CLAUDE_CONFIG_DIR=\"$dest\""
}

# ccs exec <account> [--dir PATH] -- <command...>
# Run <command> with CLAUDE_CONFIG_DIR pointed at the account's isolated dir.
# Note: put any ccs global options (e.g. --dry-run) BEFORE `exec`; everything
# after `--` is passed to the command verbatim.
cmd_exec() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ccs exec <account_number|email|profile> [--dir PATH] -- <command> [args...]"
        exit 1
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    local identifier="$1"; shift
    local dest=""
    local -a cmd=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir)
                dest="$2"; shift 2
                ;;
            --)
                shift
                cmd=("$@")
                break
                ;;
            *)
                # Allow `ccs exec <acct> <command...>` without an explicit `--`.
                cmd=("$@")
                break
                ;;
        esac
    done

    if [[ ${#cmd[@]} -eq 0 ]]; then
        echo "Error: no command given. Usage: ccs exec <account> -- <command> [args...]"
        exit 1
    fi

    local account_num
    account_num=$(resolve_account_identifier "$identifier")
    if [[ -z "$account_num" ]]; then
        echo "Error: Account '$identifier' not found"
        exit 1
    fi

    local email
    email=$(account_display_id "$account_num")
    [[ -z "$dest" ]] && dest="$ISOLATED_DIR/${account_num}-${email}"

    setup_directories
    if ! materialize_config_dir "$account_num" "$dest"; then
        exit 1
    fi

    _isolation_macos_note
    # Replace this process with the command, scoped to the isolated config dir.
    if is_endpoint_account "$account_num"; then
        local ep_th token_var ep_base ep_model
        ep_th=$(account_field "$account_num" tokenHeader api_key)
        token_var="ANTHROPIC_API_KEY"; [[ "$ep_th" == "auth_token" ]] && token_var="ANTHROPIC_AUTH_TOKEN"
        ep_base=$(account_field "$account_num" baseUrl)
        ep_model=$(account_field "$account_num" model)
        # Start from a clean ccs-owned slate so the child never inherits the
        # caller shell's stale token/model or the opposite token var.
        unset ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL
        export ANTHROPIC_BASE_URL="$ep_base"
        # Only export a model override when one is configured, so an unset model
        # doesn't blank out Claude Code's default (mirrors materialize_config_dir).
        [[ -n "$ep_model" ]] && export ANTHROPIC_MODEL="$ep_model"
        export CLAUDE_CONFIG_DIR="$dest"
        export "$token_var=$(endpoint_secret "$account_num")"
        exec "${cmd[@]}"
    else
        CLAUDE_CONFIG_DIR="$dest" exec "${cmd[@]}"
    fi
}

# Rate-limit markers, anchored on Claude Code's documented shapes. Extend freely.
readonly CCS_RATE_LIMIT_RE='API Error:.*\(429\)|Request rejected \(429\)|Retrying in .*attempt|rate.limit|overloaded|usage limit'

# Decide whether a failed run failed because of a rate limit.
# Args: <stdout-buffer> <stderr-buffer> <active-account-num> <limit-threshold>
# Returns 0 (rate-limited) or 1 (not).
_run_detect_rate_limit() {
    local out_buf="$1" err_buf="$2" account="$3" threshold="$4"

    # PRIMARY (grep): all of stderr, plus only the final result/error line(s) of
    # stdout — not the whole body — so a payload that merely discusses 429 does
    # not trigger.
    if grep -qiE "$CCS_RATE_LIMIT_RE" "$err_buf" 2>/dev/null; then
        return 0
    fi
    if tail -n 3 "$out_buf" 2>/dev/null | grep -qiE "$CCS_RATE_LIMIT_RE"; then
        return 0
    fi

    # SECONDARY (usage/health): only reached when the grep was inconclusive.
    if [[ -n "$account" ]] && is_endpoint_account "$account"; then
        probe_endpoint_health "$account" || return 0   # unhealthy endpoint = limited
        return 1
    fi
    local cache_file util util_int
    cache_file=$(usage_cache_file)
    rm -f "$cache_file"
    if fetch_usage_data; then
        # Weekly window matters: take the max of 5h and 7d utilization.
        util=$(jq -r '[(.five_hour.utilization // 0), (.seven_day.utilization // 0)] | max' \
                 "$cache_file" 2>/dev/null || echo "0")
        if util_int=$(usage_to_int "$util"); then
            [[ "$util_int" -ge "$threshold" ]] && return 0
        fi
    fi
    return 1
}

# Run a command (typically `claude -p ...`) on the active account, switching to
# another account and retrying when it fails because of a rate limit.
# Usage: ccs run [--max-attempts N] [--limit-threshold N] [--timeout SEC]
#                [--no-proactive] -- <command...>
# shellcheck disable=SC2034  # limit_threshold/timeout_sec/proactive used in later tasks
cmd_run() {
    local max_attempts="" limit_threshold="95" timeout_sec="" proactive=true
    local -a cmd=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-attempts)    max_attempts="$2"; shift 2 ;;
            --limit-threshold) limit_threshold="$2"; shift 2 ;;
            --timeout)         timeout_sec="$2"; shift 2 ;;
            --no-proactive)    proactive=false; shift ;;
            --)                shift; cmd=("$@"); break ;;
            *)  echo "Error: unknown option '$1' (put the command after --)" >&2; exit 2 ;;
        esac
    done

    if [[ ${#cmd[@]} -eq 0 ]]; then
        echo "Usage: ccs run [--max-attempts N] [--limit-threshold N] [--timeout SEC] [--no-proactive] -- <command...>" >&2
        exit 2
    fi
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet" >&2
        exit 2
    fi
    setup_directories

    local total
    total=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    [[ -z "$max_attempts" ]] && max_attempts="$total"
    [[ "$max_attempts" -lt 1 ]] && max_attempts=1

    # Buffers (cleaned up by the trap installed in a later task).
    local out_buf
    out_buf=$(mktemp "${TMPDIR:-/tmp}/ccs-run-out.XXXXXX")

    local rc=0
    "${cmd[@]}" >"$out_buf" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        cat "$out_buf"; rm -f "$out_buf"; return 0
    fi
    cat "$out_buf"; rm -f "$out_buf"
    return "$rc"
}

# --- Endpoint health probe ------------------------------------------------
# Endpoints have no usage API; fallback is reactive. A request is "unhealthy"
# (trigger fallback) on auth failure, rate/credit limit, server error, or
# timeout; anything else means the endpoint is reachable and usable.

# Classify an HTTP status: prints "unhealthy" for 401/403/429/5xx/000, else
# "healthy".
_classify_probe_code() {
    local code="$1"
    case "$code" in
        401|403|429|000) echo "unhealthy" ;;
        5??)             echo "unhealthy" ;;
        *)               echo "healthy" ;;
    esac
}

# Issue one request and print the HTTP status code (000 on connection failure).
# curl prints %{http_code} (000 on connect/timeout failure) AND exits non-zero
# on failure, so we capture its output and never append a second code. Anything
# that isn't a clean 3-digit status normalizes to "000".
# Args: <method> <url> <extra curl args...>
_probe_http_code() {
    local method="$1" url="$2"; shift 2
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url" "$@" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    printf '%s' "$code"
}

# probe_endpoint_health <account_num> -> 0 healthy, 1 unhealthy.
probe_endpoint_health() {
    local num="$1"
    local base token_header model token
    base=$(account_field "$num" "baseUrl")
    token_header=$(account_field "$num" "tokenHeader" "api_key")
    model=$(account_field "$num" "model" "claude-3-5-haiku-20241022")
    token=$(endpoint_secret "$num")
    [[ -z "$base" ]] && return 1

    local -a auth=()
    if [[ "$token_header" == "auth_token" ]]; then
        auth=(-H "Authorization: Bearer $token")
    else
        auth=(-H "x-api-key: $token" -H "anthropic-version: 2023-06-01")
    fi

    # Step 1: GET /models.
    local code cls
    code=$(_probe_http_code GET "${base%/}/models" "${auth[@]}")
    cls=$(_classify_probe_code "$code")
    if [[ "$cls" == "unhealthy" ]]; then return 1; fi
    if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then return 0; fi

    # Step 2: /models was reachable but non-2xx (e.g. 404). Probe /messages.
    code=$(_probe_http_code POST "${base%/}/messages" \
        "${auth[@]}" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
    cls=$(_classify_probe_code "$code")
    [[ "$cls" == "healthy" ]] && return 0 || return 1
}

# Fetch usage data from Anthropic OAuth Usage API
# Writes the usage cache (see usage_cache_file) with active_account field
# Returns 0 on success, 1 on failure
fetch_usage_data() {
    local cache_file; cache_file=$(usage_cache_file)
    local current_email
    current_email=$(get_current_account)

    # Read credentials and extract access token
    local creds access_token
    creds=$(read_credentials)
    if [[ -z "$creds" ]]; then
        return 1
    fi

    access_token=$(cred_access_token "$creds")
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
        refresh_token=$(cred_refresh_token "$creds")
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
            echo "ccs: account ${current_email} needs re-login — run: claude /login" >&2
            return 1
        fi

        # Update stored credentials with new tokens
        local new_access new_refresh updated_creds
        new_access=$(echo "$refresh_body" | jq -r '.access_token // empty' 2>/dev/null)
        new_refresh=$(echo "$refresh_body" | jq -r '.refresh_token // empty' 2>/dev/null)

        if [[ -z "$new_access" ]]; then
            return 1
        fi

        updated_creds=$(cred_set_tokens "$creds" "$new_access" "${new_refresh:-$refresh_token}")
        # Never overwrite the store with an empty credential (e.g. if the
        # rewrite somehow failed) — that would wipe the active login.
        if [[ -z "$updated_creds" ]]; then
            return 1
        fi
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

# The configured rate-limit threshold, or 80.
_rate_threshold() {
    local t=""
    if [[ -f "$SEQUENCE_FILE" ]]; then
        t=$(jq -r '.rateLimit.threshold // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
    fi
    echo "${t:-80}"
}

# Rotate the shared active account to the next healthy one in the sequence.
# Silent, no restart, no hook messaging — those stay with the caller.
# Arg 1: expected_active — the account number the caller believes is live; the
#        first hop is a compare-and-swap against it (see perform_switch).
#        Pass empty to skip the CAS and rotate unconditionally (cmd_rate_check).
# Arg 2: threshold — candidate over-threshold check; empty falls back to _rate_threshold().
# Returns: 0 switched to a healthy account; 1 all others exhausted;
#          2 switch error; 3 lost race (someone else already rotated).
_rotate_to_healthy_next_account() {
    local expected_active="$1"
    local threshold="${2:-}"
    local total_accounts
    total_accounts=$(jq '.sequence | length' "$SEQUENCE_FILE" 2>/dev/null || echo "0")
    [[ "$total_accounts" -lt 2 ]] && return 1

    local cache_file
    [[ -z "$threshold" ]] && threshold="$(_rate_threshold)"
    cache_file=$(usage_cache_file)

    local attempts=0 max_attempts=$((total_accounts - 1))
    local first_hop="$expected_active"
    while [[ $attempts -lt $max_attempts ]]; do
        local active_account next_account
        active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        next_account=$(jq -r --argjson active "$active_account" '
            .sequence as $seq |
            ($seq | index($active) // 0) as $idx |
            $seq[($idx + 1) % ($seq | length)]
        ' "$SEQUENCE_FILE")

        # Only the first hop carries the CAS; subsequent hops within this call
        # already own the account, so pass no expectation.
        # Use ||rc=$? (not $()) so set -e doesn't abort on a non-zero exit.
        local rc=0
        (CCS_SILENT=1 perform_switch "$next_account" "$first_hop") >/dev/null 2>&1 || rc=$?
        first_hop=""
        case "$rc" in
            0) : ;;
            3) return 3 ;;
            *) return 2 ;;
        esac

        local healthy=false
        if is_endpoint_account "$next_account"; then
            if probe_endpoint_health "$next_account"; then healthy=true; fi
        else
            rm -f "$cache_file"
            if fetch_usage_data; then
                local new_usage new_usage_int
                new_usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
                if new_usage_int=$(usage_to_int "$new_usage"); then
                    [[ "$new_usage_int" -lt "$threshold" ]] && healthy=true
                else
                    healthy=true
                fi
            else
                healthy=true
            fi
        fi

        [[ "$healthy" == true ]] && return 0
        attempts=$((attempts + 1))
    done
    return 1
}

# Rate limit check command
# Usage: ccs rate-check [--threshold N] [--auto-switch] [--hook-mode] [--refresh] [--max-age SECONDS]
# Exit codes: 0=ok, 1=exceeded (switched if --auto-switch), 2=error, 3=all accounts limited
cmd_rate_check() {
    local threshold=""
    local auto_switch=false
    local hook_mode=false
    local refresh=false
    local max_age=""
    local cache_file; cache_file=$(usage_cache_file)

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
            --max-age)
                max_age="$2"
                shift 2
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

    # Resolve cache TTL: --max-age flag > .rateLimit.cacheTtl config > default
    if [[ -z "$max_age" ]]; then
        if [[ -f "$SEQUENCE_FILE" ]]; then
            local cfg_ttl
            cfg_ttl=$(jq -r '.rateLimit.cacheTtl // empty' "$SEQUENCE_FILE" 2>/dev/null || true)
            [[ -n "$cfg_ttl" ]] && max_age="$cfg_ttl"
        fi
        max_age="${max_age:-$DEFAULT_CACHE_TTL}"
    fi

    # Active account type decides how we judge "over threshold". Endpoints have
    # no usage API, so they are probed reactively; oauth uses the usage cache.
    local active_num over_threshold=false usage_int="n/a"
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)

    if [[ -n "$active_num" ]] && is_endpoint_account "$active_num"; then
        if probe_endpoint_health "$active_num"; then
            if [[ "$hook_mode" != true ]]; then
                echo "Endpoint $(account_display_id "$active_num") healthy — OK"
            fi
            exit 0
        fi
        over_threshold=true
        usage_int="unhealthy"
        if [[ "$hook_mode" != true ]]; then
            echo "Endpoint $(account_display_id "$active_num") is unavailable (probe failed)"
        fi
    fi

    if [[ "$over_threshold" != true ]]; then
    local current_email
    current_email=$(get_current_account)

    # Decide whether we need fresh data: forced, or the cache is missing / stale /
    # for a different account than the one currently active. This is what makes the
    # headless (`claude -p`, no statusline) path work — the cache is refreshed on
    # demand instead of silently no-oping on a missing/stale file.
    local need_fetch=false
    if [[ "$refresh" == true ]]; then
        need_fetch=true
    elif [[ "$(cache_freshness "$cache_file" "$max_age" "$current_email")" == "stale" ]]; then
        need_fetch=true
    fi

    if [[ "$need_fetch" == true ]]; then
        if ! fetch_usage_data; then
            if [[ "$hook_mode" == true ]]; then
                exit 0  # Fail open
            fi
            # If a usable (if stale) cache exists, fall back to it rather than error.
            if [[ ! -f "$cache_file" ]]; then
                echo "Error: Failed to fetch usage data and no cache available" >&2
                exit 2
            fi
            echo "Warning: usage refresh failed; using cached data" >&2
        fi
    fi

    # Cache must exist past this point
    if [[ ! -f "$cache_file" ]]; then
        if [[ "$hook_mode" == true ]]; then
            exit 0  # Fail open
        fi
        echo "Error: No usage cache found at $cache_file" >&2
        exit 2
    fi

    # Read utilization
    local usage
    usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
    if ! usage_int=$(usage_to_int "$usage"); then
        # A reading we can't parse is not 0% — treating it as one would keep us
        # silently under every threshold. Refuse to act on it instead.
        if [[ "$hook_mode" == true ]]; then
            exit 0  # Fail open
        fi
        echo "Error: Unreadable usage value in cache: $usage" >&2
        exit 2
    fi

    # Below threshold — all good
    if [[ "$usage_int" -lt "$threshold" ]]; then
        if [[ "$hook_mode" != true ]]; then
            echo "Usage: ${usage_int}% (threshold: ${threshold}%) — OK"
        fi
        exit 0
    fi

    # Above threshold
    over_threshold=true
    if [[ "$hook_mode" != true ]]; then
        echo "Usage: ${usage_int}% exceeds threshold ${threshold}%"
    fi
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

        # Capture this directory's conversation pointer BEFORE any switch rewrites
        # .claude.json. Running as a PreToolUse hook we're a child of the live
        # Claude Code process and can't relaunch it, so the deny message hands the
        # user the exact command to resume with once they exit.
        local resume_sid
        resume_sid=$(capture_resume_session_id)

        local hrc=0
        # Pass empty expected_active so perform_switch skips the CAS: cmd_rate_check
        # has no compare-and-swap semantics (that is reserved for `ccs run`).
        _rotate_to_healthy_next_account "" "$threshold" || hrc=$?

        case "$hrc" in
            0)
                local next_account next_email
                next_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
                next_email=$(account_display_id "$next_account")
                if [[ "$hook_mode" == true ]]; then
                    local next_step="Please restart Claude Code."
                    if [[ -n "$resume_sid" ]]; then
                        next_step="Exit and run: $(build_resume_command claude "$resume_sid")"
                    fi
                    _rate_hook_deny "Switched to Account-$next_account ($next_email). $next_step"
                    exit 0
                fi
                echo "Switched to Account-$next_account ($next_email)"
                handle_restart_after_switch
                exit 1
                ;;
            2)
                if [[ "$hook_mode" == true ]]; then exit 0; fi
                echo "Error: Failed to switch accounts" >&2
                exit 2
                ;;
            *)
                # 1 = all exhausted (3/lost-race can't occur: cmd_rate_check passes no CAS expectation)
                if [[ "$hook_mode" == true ]]; then
                    _rate_hook_deny "Rate limit exceeded on all accounts (${usage_int}%). Please wait for limits to reset."
                    exit 0
                fi
                echo "All accounts are above the threshold" >&2
                exit 3
                ;;
        esac
    fi

    # No auto-switch, just report
    if [[ "$hook_mode" == true ]]; then
        _rate_hook_deny "Rate limit exceeded (${usage_int}%). Run 'ccs sw' to switch accounts."
        exit 0
    fi
    exit 1
}

# Output hook-protocol JSON to deny a tool call. jq does the encoding: the reason
# carries account labels and session ids, which must not be able to break the JSON.
_rate_hook_deny() {
    jq -cn --arg reason "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $reason
        }
    }'
}

# Show or set the default resume mode used by --resume (and reported by the rate
# hook). "fork" starts a new session id from the old transcript; "same" continues
# the existing session, so tools keyed on the session id keep following the work.
# Usage: ccs resume-mode [fork|same]
cmd_resume_mode() {
    local mode="${1:-}"

    if [[ -z "$mode" ]]; then
        echo "Resume mode: $(resume_mode)"
        return
    fi

    if [[ "$mode" != "fork" && "$mode" != "same" ]]; then
        echo "Error: invalid resume mode '$mode' (expected 'fork' or 'same')" >&2
        exit 1
    fi

    setup_directories
    init_sequence_file

    local updated
    updated=$(jq --arg mode "$mode" '.resume = ((.resume // {}) | .mode = $mode)' "$SEQUENCE_FILE") || {
        echo "Error: could not update $SEQUENCE_FILE" >&2
        exit 1
    }
    write_json "$SEQUENCE_FILE" "$updated"

    if [[ "$mode" == "fork" ]]; then
        echo "Resume mode set to 'fork' — --resume forks into a new session."
    else
        echo "Resume mode set to 'same' — --resume continues the same session."
    fi
}

# Remove the PreToolUse hook we installed from a settings file, leaving any hook
# the user installed themselves alone. Handles both the legacy flat shape
# ({matcher, command}) and the nested-hooks shape, and drops matcher entries left
# with no handlers.
_rate_hook_uninstall() {
    local settings_file="$1"
    [[ -f "$settings_file" ]] || return 0

    local cleaned
    cleaned=$(jq --arg name "ccs-rate-hook.sh" "$CCS_OWNED_JQ"'
        if .hooks and .hooks.PreToolUse then
            .hooks.PreToolUse = [
                .hooks.PreToolUse[]
                # drop legacy flat entries referencing the hook
                | select((.command | ccs_owned($name)) | not)
                # strip the hook from nested handler arrays
                | (if has("hooks") then
                       .hooks = (.hooks | map(select((.command | ccs_owned($name)) | not)))
                   else . end)
                # drop entries whose nested hooks array is now empty
                | select((has("hooks") | not) or ((.hooks | length) > 0))
            ]
        else . end
    ' "$settings_file" 2>/dev/null) || return 0

    if [[ -n "$cleaned" ]]; then
        write_json "$settings_file" "$cleaned"
    fi
}

# Remove the statusLine we installed from a settings file, leaving a statusline
# the user installed themselves alone.
_statusline_uninstall() {
    local settings_file="$1"
    [[ -f "$settings_file" ]] || return 0

    local cleaned
    cleaned=$(jq --arg name "ccs-statusline.sh" "$CCS_OWNED_JQ"'
        if (.statusLine.command | ccs_owned($name))
        then del(.statusLine) else . end
    ' "$settings_file" 2>/dev/null) || return 0

    if [[ -n "$cleaned" ]]; then
        write_json "$settings_file" "$cleaned"
    fi
    return 0
}

# Clear whatever an earlier version installed into the legacy settings file, so
# an upgrade doesn't leave a second, inert definition behind. <what> is "hook" or
# "statusline". Says so once when it actually removed something.
_clear_legacy_settings() {
    local what="$1" legacy found
    legacy="$(ccs_legacy_settings_file)"
    [[ -f "$legacy" ]] || return 0

    case "$what" in
        hook)
            found=$(jq -r --arg name "ccs-rate-hook.sh" "$CCS_OWNED_JQ"'
                [ (.hooks.PreToolUse // [])[]
                  | .command, ((.hooks // [])[] | .command) ]
                | map(ccs_owned($name)) | any
            ' "$legacy" 2>/dev/null) || return 0
            [[ "$found" == "true" ]] || return 0
            _rate_hook_uninstall "$legacy"
            ;;
        statusline)
            found=$(jq -r --arg name "ccs-statusline.sh" "$CCS_OWNED_JQ"'
                .statusLine.command | ccs_owned($name)
            ' "$legacy" 2>/dev/null) || return 0
            [[ "$found" == "true" ]] || return 0
            _statusline_uninstall "$legacy"
            ;;
        *)
            return 0
            ;;
    esac

    echo "Removed the stale entry in $legacy (Claude Code doesn't read that file)."
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

    local settings_file; settings_file="$(ccs_settings_file)"

    if [[ "$disable" == true ]]; then
        # Disable: update config and remove hook
        local updated
        updated=$(jq '.rateLimit = {enabled: false}' "$SEQUENCE_FILE" 2>/dev/null)
        write_json "$SEQUENCE_FILE" "$updated"

        _rate_hook_uninstall "$settings_file"
        _clear_legacy_settings hook

        echo "Rate limit auto-switch disabled."
        echo "Hook removed from $settings_file"
        return
    fi

    # Locate the hook script before touching config, so a failed lookup doesn't
    # leave the rate limit enabled with no hook to enforce it.
    local hook_script
    hook_script="$(ccs_shipped_script "hooks/ccs-rate-hook.sh")" || return 1

    # Same reason: a settings file we can't parse is one we can't install into.
    read_settings_or_fail "$settings_file" >/dev/null || return 1

    # Enable: update config
    local updated
    updated=$(jq --argjson thresh "$threshold" '
        .rateLimit = {enabled: true, threshold: $thresh}
    ' "$SEQUENCE_FILE" 2>/dev/null)
    write_json "$SEQUENCE_FILE" "$updated"

    # Install the hook into the user settings Claude Code reads.
    mkdir -p "$(dirname "$settings_file")"
    if [[ ! -f "$settings_file" ]]; then
        echo '{}' > "$settings_file"
    fi

    # Build hook command with CCS_PATH so the hook can reliably find ccs
    local ccs_bin hook_command
    ccs_bin="$(ccs_invoked_path)"
    hook_command="CCS_PATH=${ccs_bin} ${hook_script}"

    # Drop any hook entry we installed before, then append the current one. This
    # keeps repeated runs idempotent and also repairs entries left behind by an
    # earlier install at a different path.
    _rate_hook_uninstall "$settings_file"
    _clear_legacy_settings hook

    # Write the Claude Code hook schema: a matcher entry containing a nested
    # "hooks" array of command handlers. matcher "" matches all tools.
    local with_hook
    with_hook=$(jq --arg hook "$hook_command" '
        .hooks.PreToolUse = (.hooks.PreToolUse // []) + [
            {
                "matcher": "",
                "hooks": [
                    {
                        "type": "command",
                        "command": $hook
                    }
                ]
            }
        ]
    ' "$settings_file" 2>/dev/null)
    write_json "$settings_file" "$with_hook"

    echo "Rate limit auto-switch enabled."
    echo "  Threshold: ${threshold}%"
    echo "  Hook script: $hook_script"
    echo "  Settings: $settings_file"
}

# Install (or remove) the statusline that shows usage and keeps the cache warm.
# Usage: ccs statusline-setup [--force] [--disable]
cmd_statusline_setup() {
    local disable=false force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disable)
                disable=true
                shift
                ;;
            --force)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    local settings_file; settings_file="$(ccs_settings_file)"

    if [[ "$disable" == true ]]; then
        # Only removes the statusLine if it's ours, so a user's own statusline
        # is never clobbered.
        _statusline_uninstall "$settings_file"
        _clear_legacy_settings statusline

        echo "ccs statusline disabled."
        echo "Settings: $settings_file"
        return
    fi

    local statusline_script
    statusline_script="$(ccs_shipped_script "statusline/ccs-statusline.sh")" || return 1

    read_settings_or_fail "$settings_file" >/dev/null || return 1

    mkdir -p "$(dirname "$settings_file")"
    [[ -f "$settings_file" ]] || echo '{}' > "$settings_file"

    # CCS_PATH so the statusline can find ccs.
    local ccs_bin sl_command
    ccs_bin="$(ccs_invoked_path)"
    sl_command="CCS_PATH=${ccs_bin} ${statusline_script}"

    # A statusline that isn't ours is the user's own: settings.json is where they
    # configure Claude Code, so overwriting it takes an explicit --force.
    local foreign
    foreign=$(jq -r --arg name "ccs-statusline.sh" "$CCS_OWNED_JQ"'
        if (.statusLine.command | ccs_owned($name))
        then empty else .statusLine.command // empty end
    ' "$settings_file" 2>/dev/null || true)
    if [[ -n "$foreign" && "$force" != true ]]; then
        echo "Error: $settings_file already sets a statusLine:" >&2
        echo "  $foreign" >&2
        echo "Re-run with --force to replace it, or call" >&2
        echo "$statusline_script from your own statusline script to keep both." >&2
        return 1
    fi
    if [[ -n "$foreign" ]]; then
        echo "Note: replacing an existing statusLine command:"
        echo "  was: $foreign"
    fi

    _clear_legacy_settings statusline

    local with_sl
    with_sl=$(jq --arg cmd "$sl_command" '
        .statusLine = {"type": "command", "command": $cmd}
    ' "$settings_file" 2>/dev/null)
    write_json "$settings_file" "$with_sl"

    echo "ccs statusline enabled."
    echo "  Statusline script: $statusline_script"
    echo "  Settings: $settings_file"
}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code v${VERSION}"
    echo "Usage: ccs [OPTIONS] <command> [args]"
    echo ""
    echo "Account Management:"
    echo "  add                              Add current account to managed accounts"
    echo "  add-endpoint <label> --base-url <URL> [--model M] [--token-header api_key|auth_token]"
    echo "                                   Add a custom ANTHROPIC_BASE_URL endpoint as an account"
    echo "  rm <num|email|label>             Remove account by number, email, or endpoint label"
    echo "  ls                               List all managed accounts"
    echo ""
    echo "Switching:"
    echo "  sw                               Rotate to next account in sequence"
    echo "  to <num|email|profile|label>     Switch to specific account"
    echo ""
    echo "Profile Management:"
    echo "  profile <num|email> <name>       Set a friendly profile name for an account"
    echo ""
    echo "Conversation Handoff:"
    echo "  resume-mode [fork|same]          Show or set how --resume relaunches"
    echo ""
    echo "Directory-based Switching:"
    echo "  dir [dir] <num|email|profile>    Associate a directory with an account"
    echo "  auto                             Switch based on current directory mapping"
    echo ""
    echo "Parallel / isolated accounts (CLAUDE_CONFIG_DIR):"
    echo "  exec <num|email|label> -- <cmd>  Run a command as an account, isolated"
    echo "  config-dir <num|email|label> [path]  Materialize an account's config dir, print it"
    echo "  run [opts] -- <command...>       Run a command, auto-switch + retry on rate limit"
    echo ""
    echo "Rate Limiting:"
    echo "  rate-check [--threshold N]       Check if usage exceeds threshold"
    echo "  rate-setup [--threshold N]       Install PreToolUse hook for auto-switch"
    echo "  rate-setup --disable             Remove hook and disable auto-switch"
    echo "  statusline-setup [--force]       Install statusline (shows usage, keeps cache warm)"
    echo "  statusline-setup --disable       Remove the ccs statusline"
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
    echo "  --resume                         Switch, then resume this directory's conversation"
    echo "  --fork-session                   With --resume: fork into a new session (default)"
    echo "  --no-fork-session                With --resume: continue the same session"
    echo "  --allow-root                     Allow running as root (or set CCSWITCH_ALLOW_ROOT=1)"
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
    echo "  ccs to 2 --resume                          # Switch to account 2 and resume the conversation"
    echo "  ccs to 2 --resume --no-fork-session        # Resume without forking (keeps the session id)"
    echo "  ccs resume-mode same                       # Make same-session the default for --resume"
    echo "  ccs profile 1 work                         # Name account 1 'work'"
    echo "  ccs dir ~/work 1                           # Map ~/work to account 1"
    echo "  ccs auto                                   # Switch based on current directory"
    echo "  ccs exec 2 -- claude -p \"hi\"               # Run claude as account 2, isolated"
    echo "  ccs rm user@example.com                    # Remove account"
}

# Main script logic
main() {
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
            --resume)
                RESUME_AFTER=true
                shift
                ;;
            --fork-session)
                RESUME_MODE="fork"
                shift
                ;;
            --no-fork-session)
                RESUME_MODE="same"
                shift
                ;;
            --no-restart)
                RESTART_FLAG="no-restart"
                shift
                ;;
            --allow-root)
                ALLOW_ROOT=true
                shift
                ;;
            exec)
                # `exec` runs an arbitrary command — stop interpreting global
                # flags so anything after it (e.g. --no-restart for claude) is
                # passed through verbatim. Put ccs options before `exec`.
                args+=("$@")
                break
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Restore positional parameters from remaining args
    set -- "${args[@]+"${args[@]}"}"

    # Basic checks - allow root execution in containers or via --allow-root
    if should_block_root "$EUID" "$ALLOW_ROOT"; then
        echo "Error: Do not run this script as root."
        echo "If you understand the risks (e.g. sandbox testing), re-run with --allow-root"
        echo "or set CCSWITCH_ALLOW_ROOT=1."
        exit 1
    fi
    if [[ $EUID -eq 0 && "$ALLOW_ROOT" == "true" ]] && ! is_running_in_container; then
        echo "Warning: Running as root (--allow-root). Proceed at your own risk." >&2
    fi

    case "${1:-}" in
        add|--add-account)
            cmd_add_account
            ;;
        add-endpoint)
            shift
            cmd_add_endpoint "$@"
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
        exec)
            shift
            cmd_exec "$@"
            ;;
        config-dir)
            shift
            cmd_config_dir "$@"
            ;;
        run)
            shift
            cmd_run "$@"
            ;;
        resume-mode)
            shift
            cmd_resume_mode "$@"
            ;;
        rate-check)
            shift
            cmd_rate_check "$@"
            ;;
        rate-setup)
            shift
            cmd_rate_setup "$@"
            ;;
        statusline-setup)
            shift
            cmd_statusline_setup "$@"
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
