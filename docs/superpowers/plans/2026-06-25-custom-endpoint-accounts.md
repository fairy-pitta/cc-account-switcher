# Custom Endpoint Accounts & Fallback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ccs` manage custom Anthropic-compatible endpoints (`ANTHROPIC_BASE_URL` + API key/token, optional model) as first-class switchable accounts alongside OAuth accounts, including participation in the automatic rate-limit fallback via probe-based health checks.

**Architecture:** Endpoint accounts live in the same `sequence.json` `accounts` map as OAuth accounts, distinguished by `authType: "endpoint"`. Switching toggles a `ccs`-owned `env` block in `~/.claude/settings.json` (write keys for endpoint, delete them for OAuth) instead of swapping OAuth credentials. Fallback keeps usage-% pre-emptive switching for OAuth and adds a reactive HTTP probe (GET `/models`, fallback POST `/messages`) for endpoints. The `activeAccountNumber` in `sequence.json` is treated as the source of truth for whether the live account is an endpoint, because endpoint accounts leave `.claude.json`/credentials untouched.

**Tech Stack:** Bash 3.2+, `jq`, `curl`, `security` (macOS Keychain) / protected files (Linux/WSL). Tests: bats-core with mocks in `test/test_helper.bash`.

**Spec:** `docs/superpowers/specs/2026-06-25-custom-endpoint-accounts-design.md`

---

## File Structure

- Modify: `ccswitch.sh` — all logic (single-file tool, follow existing convention).
  - New helpers (account-type + field accessors): near the credential accessors (~line 343–412).
  - New settings `env` helpers: new section after credential accessors.
  - New endpoint secret accessor + probe: new section before `fetch_usage_data` (~line 1725).
  - `cmd_add_endpoint`: after `cmd_add_account` (~line 1100).
  - `resolve_account_identifier` label support: ~line 131.
  - `cmd_list` / `cmd_status` display: ~line 1210 / ~line 770.
  - `cmd_remove_account` label support: ~line 1103.
  - `perform_switch` branching: ~line 1325.
  - `cmd_rate_check` branching: ~line 1832.
  - `cmd_exec` / `cmd_config_dir` env export: ~line 1663 / ~line 1627.
  - `show_usage` + `main` dispatch: ~line 2250 / ~line 2368.
- Create tests: `test/test_endpoint_accounts.bats`, `test/test_endpoint_switch.bats`, `test/test_endpoint_probe.bats`, `test/test_endpoint_rate_check.bats`.
- Modify docs: `README.md`, `README.ja.md`.

**Conventions to follow (already in repo):**
- JSON writes go through `write_json "$file" "$content"` (atomic temp + `jq` validation + `chmod 600`).
- Account secrets are stored via `write_account_credentials <num> <id> <json>` / `read_account_credentials <num> <id>` (Keychain on macOS, file on Linux/WSL).
- Tests source nothing; they invoke the script as a subprocess via `run_ccswitch` and mock `curl`/`security`/`uname` by dropping executables into `$MOCK_BIN`.
- Run a single test file: `bats test/test_endpoint_probe.bats`. Run all: `make test` (or `bats test/`).

---

## Task 1: Account-type and field accessors

**Files:**
- Modify: `ccswitch.sh` (add helpers after `write_account_config`, ~line 479)
- Test: `test/test_endpoint_accounts.bats`

- [ ] **Step 1: Write the failing test**

Create `test/test_endpoint_accounts.bats`:

```bash
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
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; set +e; is_endpoint_account 2; echo \$?"
    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]]
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_accounts.bats`
Expected: FAIL — `is_endpoint_account: command not found` (or similar).

- [ ] **Step 3: Add the helpers**

In `ccswitch.sh`, immediately after `write_account_config()` (the function ending ~line 479, before `init_sequence_file()`), add:

```bash
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_accounts.bats`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_accounts.bats
git commit -m "feat: add account-type accessors for endpoint accounts"
```

---

## Task 2: Settings `env` block write/clear helpers

**Files:**
- Modify: `ccswitch.sh` (add after the Task 1 helpers)
- Test: `test/test_endpoint_accounts.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/test_endpoint_accounts.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_accounts.bats`
Expected: FAIL — `write_endpoint_env: command not found`.

- [ ] **Step 3: Add the helpers**

In `ccswitch.sh`, immediately after the Task 1 helpers, add:

```bash
# --- Endpoint env block (settings.json) -----------------------------------
# Switching to an endpoint writes ANTHROPIC_* into the user-global settings env
# block; switching to oauth removes exactly those keys so stored OAuth creds
# take over again. settings.json env is applied at Claude Code startup, so a
# restart is required for an endpoint-crossing switch to take effect.

# Env keys ccs owns. The token var (api key vs auth token) is also in this set
# so the unused one is always cleared.
readonly CCS_ENV_KEYS=("ANTHROPIC_BASE_URL" "ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "ANTHROPIC_MODEL")

ccs_settings_file() { echo "$HOME/.claude/settings.json"; }

# write_endpoint_env <base_url> <token_header: api_key|auth_token> <token> <model-or-empty>
write_endpoint_env() {
    local base_url="$1" token_header="$2" token="$3" model="$4"
    local file; file="$(ccs_settings_file)"
    mkdir -p "$(dirname "$file")"

    local base='{}'
    if [[ -f "$file" ]] && jq -e . "$file" >/dev/null 2>&1; then
        base=$(cat "$file")
    fi

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_accounts.bats`
Expected: PASS (10 tests total).

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_accounts.bats
git commit -m "feat: add settings env block write/clear for endpoints"
```

---

## Task 3: Endpoint secret accessor + `add-endpoint` command

**Files:**
- Modify: `ccswitch.sh` (secret accessor after Task 2 helpers; `cmd_add_endpoint` after `cmd_add_account` ~line 1100; dispatch in `main` ~line 2369; `show_usage` ~line 2257)
- Test: `test/test_endpoint_accounts.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/test_endpoint_accounts.bats`:

```bash
@test "test_add_endpoint_creates_account_and_stores_secret" {
    run run_ccswitch add-endpoint openrouter \
        --base-url https://openrouter.ai/api/v1 --token-header api_key --key-stdin <<< "sk-or-123"
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter"* ]]

    # Metadata recorded, no secret in plaintext JSON.
    run jq -r '.accounts | to_entries[] | select(.value.label=="openrouter") | .value.authType' "$SEQUENCE_FILE"
    [[ "$output" == "endpoint" ]]
    run grep -c "sk-or-123" "$SEQUENCE_FILE"
    [[ "$output" == "0" ]]

    # Secret retrievable via the credential store (mock keychain).
    num=$(jq -r '.accounts | to_entries[] | select(.value.label=="openrouter") | .key' "$SEQUENCE_FILE")
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; endpoint_secret $num"
    [[ "$output" == "sk-or-123" ]]
}

@test "test_add_endpoint_rejects_duplicate_label" {
    run_ccswitch add-endpoint dup --base-url https://a.test/v1 --key-stdin <<< "k1"
    run run_ccswitch add-endpoint dup --base-url https://b.test/v1 --key-stdin <<< "k2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"already"* ]]
}

@test "test_add_endpoint_requires_base_url" {
    run run_ccswitch add-endpoint nobaseurl --key-stdin <<< "k"
    [ "$status" -ne 0 ]
    [[ "$output" == *"base-url"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_accounts.bats`
Expected: FAIL — `Error: Unknown command 'add-endpoint'` (exit 1 but wrong message), and `endpoint_secret: command not found`.

- [ ] **Step 3a: Add the secret accessor**

In `ccswitch.sh`, after `clear_endpoint_env()` (Task 2), add:

```bash
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
```

- [ ] **Step 3b: Add `cmd_add_endpoint`**

In `ccswitch.sh`, immediately after `cmd_add_account()` (~line 1100), add:

```bash
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
    local base_url="" model="" token_header="api_key" key_stdin=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-url)     base_url="$2"; shift 2 ;;
            --model)        model="$2"; shift 2 ;;
            --token-header) token_header="$2"; shift 2 ;;
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
    if [[ -n "$(resolve_account_identifier "$label")" ]]; then
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
```

- [ ] **Step 3c: Wire dispatch + usage**

In `main()`'s `case` (~line 2369, right after the `add|--add-account)` block), add:

```bash
        add-endpoint)
            shift
            cmd_add_endpoint "$@"
            ;;
```

In `show_usage()` under "Account Management:" (after the `add` line, ~line 2255), add:

```bash
    echo "  add-endpoint <label> --base-url <URL> [--model M] [--token-header api_key|auth_token]"
    echo "                                   Add a custom ANTHROPIC_BASE_URL endpoint as an account"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_accounts.bats`
Expected: PASS (13 tests total).

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_accounts.bats
git commit -m "feat: add 'ccs add-endpoint' command and secret storage"
```

---

## Task 4: Resolve endpoints by label; list/remove support

**Files:**
- Modify: `ccswitch.sh` — `resolve_account_identifier` (~line 131), `cmd_list` (~line 1210), `cmd_remove_account` (~line 1103)
- Test: `test/test_endpoint_accounts.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/test_endpoint_accounts.bats`:

```bash
@test "test_resolve_identifier_matches_endpoint_label" {
    seed_mixed_accounts
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; resolve_account_identifier openrouter"
    [[ "$output" == "2" ]]
}

@test "test_list_shows_endpoint_tag" {
    seed_mixed_accounts
    create_fake_claude_config "user1@example.com" "uuid-1"
    run run_ccswitch ls
    [ "$status" -eq 0 ]
    [[ "$output" == *"openrouter"* ]]
    [[ "$output" == *"[endpoint]"* ]]
}

@test "test_remove_endpoint_by_label_deletes_secret" {
    run_ccswitch add-endpoint gone --base-url https://g.test/v1 --key-stdin <<< "sk-gone"
    num=$(jq -r '.accounts | to_entries[] | select(.value.label=="gone") | .key' "$SEQUENCE_FILE")
    run run_ccswitch rm gone <<< "y"
    [ "$status" -eq 0 ]
    run jq -r --arg n "$num" '.accounts[$n] // "removed"' "$SEQUENCE_FILE"
    [[ "$output" == "removed" ]]
    # Secret slot cleared.
    run /bin/bash -c "source '$CCSWITCH_SCRIPT'; endpoint_secret $num"
    [[ -z "$output" ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_accounts.bats`
Expected: FAIL — `resolve_account_identifier openrouter` prints nothing; `rm gone` errors on email validation.

- [ ] **Step 3a: Add label matching to `resolve_account_identifier`**

In `ccswitch.sh`, in `resolve_account_identifier()` (~line 143), after the profile-name lookup block and before the final `else echo ""`, add a label lookup. Replace the trailing portion:

```bash
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
```

(The previous final `if/else` that printed the profile result is replaced by the block above — make sure there is exactly one terminal `echo ""`.)

- [ ] **Step 3b: Show `[endpoint]` in `cmd_list`**

In `cmd_list()` (~line 1228), replace the `jq -r --arg active ... ` block with one that labels endpoints by `label` and tags the type:

```bash
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
```

> Note: `cmd_list`'s active-account detection (~line 1222) still uses the live `.claude.json` email. Endpoint-active display is fixed in Task 6 via `effective_active_account_num`; here we only add the type tag and label rendering.

- [ ] **Step 3c: Allow label/number removal in `cmd_remove_account`**

In `cmd_remove_account()` (~line 1117), replace the email-or-number resolution block:

```bash
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
```

Then update the deletion to use the account's display id (label or email) for the credential slot. Replace the `email=$(echo "$account_info" | jq -r '.email')` line (~line 1144) with:

```bash
    local email
    email=$(echo "$account_info" | jq -r '.label // .email')
```

(The Keychain service / credential file already keys on this id, matching how `add`/`add-endpoint` wrote it.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_accounts.bats`
Expected: PASS (16 tests total).

Also run the existing remove/list tests to confirm no regression:
Run: `bats test/test_remove_account.bats test/test_list.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_accounts.bats
git commit -m "feat: resolve, list, and remove endpoint accounts by label"
```

---

## Task 5: Endpoint health probe

**Files:**
- Modify: `ccswitch.sh` (add before `fetch_usage_data` ~line 1725)
- Test: `test/test_endpoint_probe.bats`

- [ ] **Step 1: Write the failing test**

Create `test/test_endpoint_probe.bats`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_probe.bats`
Expected: FAIL — `probe_endpoint_health: command not found`.

- [ ] **Step 3: Add the probe**

In `ccswitch.sh`, immediately before `fetch_usage_data()` (~line 1725), add:

```bash
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
# Args: <method> <url> <extra curl args...>
_probe_http_code() {
    local method="$1" url="$2"; shift 2
    curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X "$method" "$url" "$@" 2>/dev/null \
        || echo "000"
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
    if [[ "$code" =~ ^2 ]]; then return 0; fi

    # Step 2: /models was reachable but non-2xx (e.g. 404). Probe /messages.
    code=$(_probe_http_code POST "${base%/}/messages" \
        "${auth[@]}" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
    cls=$(_classify_probe_code "$code")
    [[ "$cls" == "healthy" ]] && return 0 || return 1
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_probe.bats`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_probe.bats
git commit -m "feat: add reactive HTTP health probe for endpoint accounts"
```

---

## Task 6: Switch mechanics — endpoint-aware `perform_switch`

**Files:**
- Modify: `ccswitch.sh` — add `effective_active_account_num` (near Task 1 helpers); branch `perform_switch` (~line 1325); fix `cmd_list` active marker (~line 1222)
- Test: `test/test_endpoint_switch.bats`

- [ ] **Step 1: Write the failing test**

Create `test/test_endpoint_switch.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export RESTART_FLAG="no-restart"
}
teardown() { teardown_test_env; }

# OAuth account 1 (active) + endpoint account 2.
seed() {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
}

@test "test_switch_to_endpoint_writes_env_block" {
    seed
    run run_ccswitch --no-restart to ep
    [ "$status" -eq 0 ]
    run jq -r '.env.ANTHROPIC_BASE_URL' "$HOME/.claude/settings.json"
    [[ "$output" == "https://ep.test/v1" ]]
    run jq -r '.env.ANTHROPIC_API_KEY' "$HOME/.claude/settings.json"
    [[ "$output" == "sk-ep" ]]
    # activeAccountNumber updated to the endpoint.
    run jq -r '.activeAccountNumber' "$SEQUENCE_FILE"
    ep_num=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    [[ "$output" == "$ep_num" ]]
}

@test "test_switch_endpoint_then_back_to_oauth_clears_env" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch --no-restart to 1
    [ "$status" -eq 0 ]
    run jq -r '.env | has("ANTHROPIC_BASE_URL") or has("ANTHROPIC_API_KEY")' "$HOME/.claude/settings.json"
    [[ "$output" == "false" ]]
    run jq -r '.activeAccountNumber' "$SEQUENCE_FILE"
    [[ "$output" == "1" ]]
}

@test "test_list_marks_endpoint_active" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch ls
    [[ "$output" == *"ep [endpoint] (active)"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_switch.bats`
Expected: FAIL — switching to `ep` errors (`Missing backup data` / invalid oauthAccount), env block not written.

- [ ] **Step 3a: Add `effective_active_account_num`**

In `ccswitch.sh`, after `account_display_id()` (Task 1), add:

```bash
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
```

- [ ] **Step 3b: Branch `perform_switch`**

In `perform_switch()`, make three changes.

(1) After acquiring the lock and reading `current_account`/`current_email` (~line 1364–1365), replace the email-based reconciliation block (~line 1367–1394) so it is skipped when the current account is an endpoint:

```bash
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
```

(2) Replace the backup + activation block (Step 1 ~line 1434 through the `write_json "$(get_claude_config_path)" "$merged_config"` success at ~line 1485) with a type-branched version. The `target_email` lookup near the top of `perform_switch` (~line 1331) must also use the display id; change it to:

```bash
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].label // .accounts[$num].email' "$SEQUENCE_FILE")
```

Then the branched body:

```bash
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
```

> Leave Step 4 (stats/state update, `write_json "$SEQUENCE_FILE"`, `release_switch_lock`, restart handling) exactly as-is — it already keys on `$current_account`/`$target_account` numbers and works for both types.

(3) Add an endpoint-restart hint. In the post-commit display block (~line 1538, inside `if [[ "${CCS_SILENT:-}" != "1" ]]`), after `cmd_list`, add:

```bash
        if is_endpoint_account "$target_account" || [[ "$current_is_endpoint" == true ]]; then
            echo "Note: this switch changes settings.json env — restart Claude Code for it to take effect."
        fi
```

- [ ] **Step 3c: Fix `cmd_list` active marker for endpoints**

In `cmd_list()` (~line 1221), replace the active-account-number detection with the authoritative helper:

```bash
    # Find which account number is active (endpoint-aware).
    local active_account_num=""
    active_account_num=$(effective_active_account_num)
```

(Remove the now-redundant `current_email` lookup lines just above it if they are unused; keep `current_email` if other parts of the function reference it — they do not after this change, so the `current_email=$(get_current_account)` line at ~1219 may be deleted.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_switch.bats`
Expected: PASS (3 tests).

Regression check:
Run: `bats test/test_switch.bats test/test_switch_to.bats test/test_list.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_switch.bats
git commit -m "feat: switch to/from endpoint accounts via settings env block"
```

---

## Task 7: Fallback — endpoint-aware `cmd_rate_check`

**Files:**
- Modify: `ccswitch.sh` — `cmd_rate_check` (~line 1832)
- Test: `test/test_endpoint_rate_check.bats`

- [ ] **Step 1: Write the failing test**

Create `test/test_endpoint_rate_check.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export RESTART_FLAG="no-restart"
}
teardown() {
    rm -f /tmp/claude-usage-cache.json
    teardown_test_env
}

# Mock curl: /models and /messages return per-arg codes; usage API returns 200
# with a utilization body so oauth candidates look healthy.
mock_curl() {
    local models="${1:-200}" usage_util="${2:-10}"
    cat > "$MOCK_BIN/curl" <<MOCK_EOF
#!/bin/bash
args="\$*"
if [[ "\$args" == *"/models"* ]]; then echo "$models"; exit 0; fi
if [[ "\$args" == *"oauth/usage"* ]]; then
    # curl is called with -w "\n%{http_code}"; emit body + code.
    echo '{"five_hour":{"utilization":$usage_util}}'
    echo "200"
    exit 0
fi
# /messages probe
echo "$models"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
}

@test "test_rate_check_endpoint_active_healthy_returns_0" {
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    mock_curl 200
    run run_ccswitch rate-check
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "test_rate_check_endpoint_active_429_switches_to_oauth" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    # Endpoint probe is 429 (unhealthy); oauth usage is 10% (healthy).
    mock_curl 429 10
    run run_ccswitch --no-restart rate-check --auto-switch
    [ "$status" -eq 1 ]
    [[ "$output" == *"Switched to Account-1"* ]]
}

@test "test_rate_check_endpoint_unhealthy_hook_mode_denies_with_switch" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "false"
    run_ccswitch add-endpoint ep --base-url https://ep.test/v1 --key-stdin <<< "sk-ep"
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    jq --arg n "$ep" '.activeAccountNumber = ($n|tonumber)' "$SEQUENCE_FILE" > "$SEQUENCE_FILE.t" && mv "$SEQUENCE_FILE.t" "$SEQUENCE_FILE"
    mock_curl 503 10
    run run_ccswitch rate-check --auto-switch --hook-mode
    [ "$status" -eq 0 ]
    [[ "$output" == *"permissionDecision"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_rate_check.bats`
Expected: FAIL — endpoint-active path falls through the oauth usage logic (no cache / wrong decision).

- [ ] **Step 3: Make `cmd_rate_check` endpoint-aware**

Two edits in `cmd_rate_check()`.

(1) Replace the active-account usage evaluation (the block from `local current_email` at ~line 1892 through the "Above threshold" echo at ~line 1945) so that an endpoint-active account is judged by probe, while oauth keeps the cache/fetch path. Insert at the start (right after the TTL resolution block ~line 1890):

```bash
    local active_num over_threshold=false usage_int="n/a"
    active_num=$(jq -r '.activeAccountNumber // empty' "$SEQUENCE_FILE" 2>/dev/null || true)

    if [[ -n "$active_num" ]] && is_endpoint_account "$active_num"; then
        # Endpoint active: reactive probe instead of usage %.
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
```

Then guard the existing oauth usage block so it only runs when not already decided. Wrap the original lines from `local current_email` (~1892) through the `# Above threshold` echo (~1945) in:

```bash
    if [[ "$over_threshold" != true ]]; then
        local current_email
        current_email=$(get_current_account)
        # ... (existing need_fetch / fetch_usage_data / cache / usage_int logic) ...
        # existing block sets usage_int and, when usage_int < threshold, exits 0.
        # Replace the final "Above threshold" stretch so it sets over_threshold
        # instead of duplicating the report:
        if [[ "$usage_int" -lt "$threshold" ]]; then
            if [[ "$hook_mode" != true ]]; then
                echo "Usage: ${usage_int}% (threshold: ${threshold}%) — OK"
            fi
            exit 0
        fi
        over_threshold=true
        if [[ "$hook_mode" != true ]]; then
            echo "Usage: ${usage_int}% exceeds threshold ${threshold}%"
        fi
    fi
```

> Implementation note for the worker: keep the existing fetch/fail-open lines verbatim inside the `if [[ "$over_threshold" != true ]]` block; only the threshold comparison tail is restructured to set `over_threshold=true` rather than falling straight into the auto-switch `if`. The subsequent `if [[ "$auto_switch" == true ]]` block stays where it is and now runs whenever `over_threshold` is true.

(2) In the auto-switch `while` loop, evaluate each candidate by type. Replace the post-switch verification (the `rm -f "$cache_file"; if fetch_usage_data; then ... else ... fi` block, ~line 1992–2018) with:

```bash
            # Verify the candidate by type.
            local healthy=false
            if is_endpoint_account "$next_account"; then
                if probe_endpoint_health "$next_account"; then healthy=true; fi
            else
                rm -f "$cache_file"
                if fetch_usage_data; then
                    local new_usage new_usage_int
                    new_usage=$(jq -r '.five_hour.utilization // 0' "$cache_file" 2>/dev/null || echo "0")
                    new_usage_int=$(printf "%.0f" "$new_usage" 2>/dev/null || echo "0")
                    [[ "$new_usage_int" -lt "$threshold" ]] && healthy=true
                else
                    # Can't verify usage; assume OK (matches prior behavior).
                    healthy=true
                fi
            fi

            if [[ "$healthy" == true ]]; then
                if [[ "$hook_mode" == true ]]; then
                    _rate_hook_deny "Switched to Account-$next_account ($next_email). Please restart Claude Code."
                    exit 0
                fi
                echo "Switched to Account-$next_account ($next_email)"
                handle_restart_after_switch
                exit 1
            fi
```

> `next_email` is already computed in the loop (~line 1980); change its lookup to be type-aware: replace `next_email=$(jq -r --arg num "$next_account" '.accounts[$num].email' "$SEQUENCE_FILE")` with `next_email=$(account_display_id "$next_account")`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_rate_check.bats`
Expected: PASS (3 tests).

Regression check:
Run: `bats test/test_rate_check.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_rate_check.bats
git commit -m "feat: include endpoint accounts in rate-check fallback via probe"
```

---

## Task 8: Status display + `exec`/`config-dir` for endpoints

**Files:**
- Modify: `ccswitch.sh` — `cmd_status` (~line 770), `cmd_exec` (~line 1663), `cmd_config_dir` (~line 1627)
- Test: `test/test_endpoint_switch.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/test_endpoint_switch.bats`:

```bash
@test "test_status_shows_endpoint_base_url_when_active" {
    seed
    run_ccswitch --no-restart to ep
    run run_ccswitch status
    [ "$status" -eq 0 ]
    [[ "$output" == *"ep"* ]]
    [[ "$output" == *"https://ep.test/v1"* ]]
    # Secret never printed.
    [[ "$output" != *"sk-ep"* ]]
}

@test "test_exec_endpoint_exports_env_vars" {
    seed
    ep=$(jq -r '.accounts | to_entries[] | select(.value.label=="ep") | .key' "$SEQUENCE_FILE")
    run run_ccswitch exec "$ep" -- /bin/bash -c 'echo "U=$ANTHROPIC_BASE_URL K=$ANTHROPIC_API_KEY"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"U=https://ep.test/v1"* ]]
    [[ "$output" == *"K=sk-ep"* ]]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/test_endpoint_switch.bats`
Expected: FAIL — status omits base URL; `exec` on an endpoint errors in `materialize_config_dir` (no stored creds/config).

- [ ] **Step 3a: `cmd_status` endpoint branch**

In `cmd_status()`, insert an endpoint-active branch immediately after the `SEQUENCE_FILE` existence guard (~line 774, before `local current_email`). This short-circuits before the OAuth-specific email/token-expiry logic, which does not apply to endpoints:

```bash
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
```

> The branch must come after `effective_active_account_num` (Task 6) is defined — it is, since it is added in Task 6 which precedes this task. The existing OAuth body (from `local current_email` onward) stays untouched below.

- [ ] **Step 3b: `materialize_config_dir` / exec / config-dir for endpoints**

`materialize_config_dir` (~line 1560) assumes oauth creds+config. Endpoints have neither. Add an early endpoint branch at the top of `materialize_config_dir`, right after it resolves `email` (~line 1565). Replace the `email` resolution so it tolerates endpoints, then branch:

```bash
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
        token_var="ANTHROPIC_API_KEY"; [[ "$ep_th" == "auth_token" ]] && token_var="ANTHROPIC_AUTH_TOKEN"
        mkdir -p "$dest" && chmod 700 "$dest" 2>/dev/null || true
        jq -nc --arg url "$ep_base" --arg tvar "$token_var" --arg tok "$ep_token" --arg model "$ep_model" '
            {env: ({ANTHROPIC_BASE_URL:$url, ($tvar):$tok}
                   + (if $model != "" then {ANTHROPIC_MODEL:$model} else {} end))}
        ' > "$dest/settings.json" || return 1
        chmod 600 "$dest/settings.json" 2>/dev/null || true
        return 0
    fi
```

> Leave the rest of `materialize_config_dir` (the oauth path) unchanged below this branch. Remove the now-duplicated original `email=$(...)` lookup at ~1564-1569 (the new block supersedes it).

`cmd_exec` (~line 1722) currently runs `CLAUDE_CONFIG_DIR="$dest" exec "${cmd[@]}"`. For endpoints, also export the env vars directly so the test (and a non-Claude command) sees them, and Claude Code picks them up from `$dest/settings.json` too. Replace the final exec line:

```bash
    _isolation_macos_note
    if is_endpoint_account "$account_num"; then
        local ep_th token_var
        ep_th=$(account_field "$account_num" tokenHeader api_key)
        token_var="ANTHROPIC_API_KEY"; [[ "$ep_th" == "auth_token" ]] && token_var="ANTHROPIC_AUTH_TOKEN"
        ANTHROPIC_BASE_URL="$(account_field "$account_num" baseUrl)" \
        ANTHROPIC_MODEL="$(account_field "$account_num" model)" \
        CLAUDE_CONFIG_DIR="$dest" \
            env "$token_var=$(endpoint_secret "$account_num")" exec "${cmd[@]}"
    else
        CLAUDE_CONFIG_DIR="$dest" exec "${cmd[@]}"
    fi
```

`cmd_config_dir` already prints `$dest` and the `CLAUDE_CONFIG_DIR` export; no change needed (the materialized `settings.json` carries the env). Optionally it could note the endpoint, but keep scope tight.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats test/test_endpoint_switch.bats`
Expected: PASS (5 tests).

Regression check:
Run: `bats test/test_isolation.bats test/test_subcommands.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ccswitch.sh test/test_endpoint_switch.bats
git commit -m "feat: status, exec, and config-dir support for endpoint accounts"
```

---

## Task 9: Full suite, lint, and documentation

**Files:**
- Modify: `README.md`, `README.ja.md`
- Verify: entire `test/` suite + shellcheck

- [ ] **Step 1: Run the entire test suite**

Run: `make test` (or `bats test/`)
Expected: PASS — all existing tests plus the 4 new files. If any pre-existing test regressed, fix the cause in `ccswitch.sh` before continuing (do not edit unrelated tests).

- [ ] **Step 2: Run the linter**

Run: `make lint`
Expected: shellcheck passes (the repo's pre-commit also runs syntax check + shellcheck). Fix any new warnings in the added code.

- [ ] **Step 3: Document the feature (README.md)**

In `README.md`, under the "Features" list, update the rate-limit bullet and add an endpoints bullet:

```markdown
- **Custom endpoints** — Add `ANTHROPIC_BASE_URL` + API key/token providers (OpenRouter, gateways, proxies, self-hosted) as switchable accounts via `ccs add-endpoint`
```

Add a usage section (place it after the account-management examples):

```markdown
### Custom endpoints

Add an Anthropic-compatible endpoint as a switchable account:

```bash
# API-key (x-api-key) provider, key read from a prompt (not shell history)
ccs add-endpoint openrouter --base-url https://openrouter.ai/api/v1 --token-header api_key

# Bearer-token provider, key piped in
echo "$MY_TOKEN" | ccs add-endpoint gateway --base-url https://gw.corp/v1 --token-header auth_token --key-stdin --model claude-3-5-sonnet

ccs to openrouter        # switch (writes ANTHROPIC_* into ~/.claude/settings.json env)
ccs to 1                 # switch back to an OAuth account (removes those env vars)
```

Switching to/from an endpoint changes Claude Code's `settings.json` `env`, which
is read at startup — **restart Claude Code** (or use `-r` / `--resume`) for the
change to take effect.

Endpoints also participate in rate-limit auto-switch: because they have no usage
API, `ccs` probes the endpoint (`/models`, then `/messages`) and falls back to the
next account when it returns auth, rate-limit, server, or timeout errors.
```

- [ ] **Step 4: Document the feature (README.ja.md)**

Mirror the same additions in `README.ja.md` in Japanese (Features bullet + 「カスタムエンドポイント」セクション), matching the existing translation style.

- [ ] **Step 5: Commit**

```bash
git add README.md README.ja.md
git commit -m "docs: document custom endpoint accounts and fallback"
```

---

## Self-Review Notes (verification checklist for the executor)

Run these confirmations after Task 9:

- [ ] **Spec coverage:** add-endpoint (T3) · unified account list with `authType` (T1) · secret kept out of JSON (T3 test) · switch via env write/remove with no residue (T2/T6) · backward compatibility for `authType`-less records (T1) · probe classification 2xx/401/429/5xx/timeout (T5) · mixed-list fallback ordering (T7) · `exec`/`config-dir` env injection (T8) · restart warning (T6) · docs EN+JA (T9). All present.
- [ ] **No secret leakage:** `grep -rn endpointKey ccswitch.sh` — only in `endpoint_secret`, `cmd_add_endpoint`. Secrets never written to `sequence.json` (asserted in T3, T4, T8 tests).
- [ ] **Type consistency:** field names used identically everywhere — `authType`, `label`, `baseUrl`, `tokenHeader`, `model`; helpers `is_endpoint_account`, `account_field`, `account_display_id`, `effective_active_account_num`, `endpoint_secret`, `probe_endpoint_health`, `write_endpoint_env`, `clear_endpoint_env`, `ccs_settings_file`.
- [ ] **Env key ownership:** the four `CCS_ENV_KEYS` are the only keys written/removed; user env keys preserved (asserted in T2).
```
