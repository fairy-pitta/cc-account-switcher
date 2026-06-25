# Credential-format-aware token handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ccswitch's token introspection work on the real nested-camelCase credential (Claude Code 2.1.x) while still accepting legacy flat snake_case, so rate-limit auto-switch and `ccs status` work on macOS and refreshed tokens are written back correctly.

**Architecture:** Add a small pure-function credential accessor layer (`cred_access_token`/`cred_refresh_token`/`cred_expiry_epoch`/`cred_set_tokens`) that handles both formats, then route the three consumers (`fetch_usage_data`, the refresh-on-401 write-back, `ccs status` expiry) through it. Add a clear re-login message when a refresh token is revoked.

**Tech Stack:** Bash 3.2+ (macOS compatible), `jq`, `bats`, `shellcheck`.

Spec: `docs/superpowers/specs/2026-06-25-credential-format-aware-token-handling-design.md`

---

## File Structure

- `ccswitch.sh`:
  - New accessor helpers, placed immediately after `normalize_credential` (ends line 339).
  - `fetch_usage_data` (~1621-1695): use accessors for read + refresh write-back; add re-login message.
  - `ccs status` token-expiry block (700-736): use `cred_expiry_epoch`.
- `test/test_helper.bash`: add `create_fake_credentials_nested` (writes the real nested shape to the mock keychain).
- `test/test_credentials_format.bats` (new): accessor unit tests + `ccs status` expiry.
- `test/test_rate_check.bats` (extend): `fetch_usage_data` with nested creds + refresh write-back + re-login message.

Implementer notes:
- Run one file: `bats test/test_credentials_format.bats`. Whole suite: `bats test/`. `shellcheck ccswitch.sh` must stay clean (pre-commit enforces it).
- Helpers in `test/test_helper.bash`: `setup_test_env`, `teardown_test_env`, `run_ccswitch <args>` (subprocess, mocked `security`/`curl`/`uname`/`ps`), `source_ccswitch_functions` (source the script to call functions directly), `setup_fake_account`, `add_account_to_sequence`, `$MOCK_BIN` (put a `curl` mock here), `$SEQUENCE_FILE`.
- Existing helpers you will reuse: `decode_jwt_payload` (ccswitch.sh:476, splits a JWT on `.`, base64url-decodes payload, returns JSON), `normalize_credential` (332, compacts JSON to one line), `read_credentials`/`write_credentials` (310/329, read/write the global `Claude Code-credentials`).
- The mock `security` stores `-w` verbatim to `$TEST_HOME/.mock-keychain/<service with ' /'→'_'>`.

---

## Task 1: Credential accessor layer

**Files:**
- Modify: `ccswitch.sh` — add four functions after `normalize_credential` (after line 339)
- Modify: `test/test_helper.bash` — add `create_fake_credentials_nested`
- Test: `test/test_credentials_format.bats` (create)

- [ ] **Step 1: Add the nested-credential test helper**

In `test/test_helper.bash`, after the existing `create_fake_credentials` function, add:

```bash
# Helper: write a NESTED camelCase credential (real Claude Code 2.1.x shape)
# to the global keychain item. expiresAt is epoch MILLISECONDS.
# Usage: create_fake_credentials_nested <access> <refresh> <expires_at_ms>
create_fake_credentials_nested() {
    local access="${1:-at-nested}" refresh="${2:-rt-nested}" exp_ms="${3:-9999999999000}"
    local creds
    creds=$(jq -nc --arg a "$access" --arg r "$refresh" --argjson e "$exp_ms" \
        '{claudeAiOauth:{accessToken:$a, refreshToken:$r, expiresAt:$e, scopes:["user:inference"]}}')
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$creds"
}
```

- [ ] **Step 2: Write the failing accessor tests**

Create `test/test_credentials_format.bats`:

```bash
#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

NESTED='{"claudeAiOauth":{"accessToken":"AT-nested","refreshToken":"RT-nested","expiresAt":9999999999000}}'
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
}

@test "test_cred_set_tokens_updates_flat_keys_for_flat_cred" {
    source_ccswitch_functions
    local out
    out=$(cred_set_tokens "$FLAT" "NEW-AT" "NEW-RT")
    [ "$(printf '%s' "$out" | jq -r '.access_token')" = "NEW-AT" ]
    [ "$(printf '%s' "$out" | jq -r '.refresh_token')" = "NEW-RT" ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats test/test_credentials_format.bats`
Expected: all FAIL — `cred_access_token: command not found` (functions undefined).

- [ ] **Step 4: Implement the accessor functions**

In `ccswitch.sh`, immediately after the `normalize_credential` function (after line 339), add:

```bash
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
    if printf '%s' "$cred" | jq -e '.claudeAiOauth' >/dev/null 2>&1; then
        out=$(printf '%s' "$cred" | jq --arg a "$access" --arg r "$refresh" \
            '.claudeAiOauth.accessToken = $a | .claudeAiOauth.refreshToken = $r' 2>/dev/null)
    else
        out=$(printf '%s' "$cred" | jq --arg a "$access" --arg r "$refresh" \
            '.access_token = $a | .refresh_token = $r' 2>/dev/null)
    fi
    normalize_credential "$out"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/test_credentials_format.bats`
Expected: all 9 PASS.

- [ ] **Step 6: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (expected: clean)

```bash
git add ccswitch.sh test/test_helper.bash test/test_credentials_format.bats
git commit -m "feat: add credential-format-aware accessors (#31)"
```

---

## Task 2: Route `fetch_usage_data` through the accessors

**Files:**
- Modify: `ccswitch.sh` — `fetch_usage_data` token read (1633), refresh-token read (1652), refresh write-back (1683-1687)
- Test: `test/test_rate_check.bats` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/test_rate_check.bats`:

```bash
@test "test_fetch_usage_data_reads_nested_credential" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    # Overwrite the global cred with the real nested shape
    create_fake_credentials_nested "AT-1" "RT-1" 9999999999000

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":42,"limit":100,"used":42}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"

    source_ccswitch_functions
    run fetch_usage_data
    [ "$status" -eq 0 ]
    [ "$(jq -r '.five_hour.utilization' /tmp/claude-usage-cache.json)" = "42" ]
}

@test "test_fetch_usage_data_refresh_writes_back_nested_shape" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_credentials_nested "OLD-AT" "OLD-RT" 9999999999000

    # Stateful curl: 1) usage -> 401, 2) refresh POST -> 200 new tokens, 3) retry usage -> 200
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
n_file=/tmp/ccs-curl-count
n=$(cat "$n_file" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$n_file"
if [ "$n" -eq 1 ]; then
    echo '{}'; echo "401"
elif [ "$n" -eq 2 ]; then
    echo '{"access_token":"NEW-AT","refresh_token":"NEW-RT"}'; echo "200"
else
    echo '{"five_hour":{"utilization":10,"limit":100,"used":10}}'; echo "200"
fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    rm -f /tmp/ccs-curl-count

    source_ccswitch_functions
    run fetch_usage_data
    [ "$status" -eq 0 ]
    # Stored global credential must keep the NESTED shape with the new token
    local stored
    stored=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    [ "$(printf '%s' "$stored" | jq -r '.claudeAiOauth.accessToken')" = "NEW-AT" ]
    [ "$(printf '%s' "$stored" | jq -r '.claudeAiOauth.refreshToken')" = "NEW-RT" ]
    # single-line (no hex risk)
    [ "$(printf '%s' "$stored" | wc -l | tr -d ' ')" -eq 0 ]
}
```

Add to the existing `teardown()` in `test/test_rate_check.bats` (alongside the existing `rm -f`):

```bash
    rm -f /tmp/ccs-curl-count
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_rate_check.bats -f "nested"`
Expected: FAIL — `fetch_usage_data` reads flat `.access_token` (empty on nested cred) → returns 1 before calling curl; refresh write-back uses flat keys so `.claudeAiOauth.accessToken` is unchanged.

- [ ] **Step 3: Use the accessors for the token reads**

In `ccswitch.sh` `fetch_usage_data`, replace line 1633:

```bash
    access_token=$(echo "$creds" | jq -r '.access_token // empty' 2>/dev/null)
```
with:
```bash
    access_token=$(cred_access_token "$creds")
```

And replace line 1652:
```bash
        refresh_token=$(echo "$creds" | jq -r '.refresh_token // empty' 2>/dev/null)
```
with:
```bash
        refresh_token=$(cred_refresh_token "$creds")
```

- [ ] **Step 4: Use `cred_set_tokens` for the refresh write-back**

In `fetch_usage_data`, replace the write-back block (lines 1683-1687):

```bash
        updated_creds=$(echo "$creds" | jq \
            --arg at "$new_access" \
            --arg rt "${new_refresh:-$refresh_token}" \
            '.access_token = $at | .refresh_token = $rt' 2>/dev/null)
        write_credentials "$updated_creds"
```
with:
```bash
        updated_creds=$(cred_set_tokens "$creds" "$new_access" "${new_refresh:-$refresh_token}")
        write_credentials "$updated_creds"
```

(The `local new_access new_refresh updated_creds` declaration just above stays.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats test/test_rate_check.bats`
Expected: the two new tests PASS and all pre-existing rate-check tests still PASS (the flat-format fake creds used elsewhere still work because the accessors fall back to `.access_token`).

- [ ] **Step 6: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_rate_check.bats
git commit -m "fix: read/write tokens in nested credential shape (#31)"
```

---

## Task 3: Fix `ccs status` token expiry

**Files:**
- Modify: `ccswitch.sh` — token-expiry block (700-736)
- Test: `test/test_credentials_format.bats` (extend)

- [ ] **Step 1: Write the failing test**

Append to `test/test_credentials_format.bats`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats test/test_credentials_format.bats -f "status_shows_expiry"`
Expected: FAIL — current code reads flat `.access_token` (empty on nested cred), prints "No access token found in credentials".

- [ ] **Step 3: Replace the expiry block with the accessor**

In `ccswitch.sh`, replace the token-expiry block. The current code is lines 700-736:

```bash
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
```

Replace it entirely with:

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_credentials_format.bats`
Expected: the new status test PASSES; all accessor tests still PASS.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_credentials_format.bats
git commit -m "fix: read token expiry from nested credential in status (#31)"
```

---

## Task 4: Clear re-login message on revoked refresh token

**Files:**
- Modify: `ccswitch.sh` — `fetch_usage_data` refresh-failure branch (1670-1672)
- Test: `test/test_rate_check.bats` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `test/test_rate_check.bats`:

```bash
@test "test_fetch_usage_data_revoked_refresh_prints_relogin_hint" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_credentials_nested "AT-x" "RT-x" 9999999999000

    # usage -> 401, refresh POST -> 403 (revoked)
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
n_file=/tmp/ccs-curl-count
n=$(cat "$n_file" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$n_file"
if [ "$n" -eq 1 ]; then echo '{}'; echo "401"; else echo '{}'; echo "403"; fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    rm -f /tmp/ccs-curl-count

    source_ccswitch_functions
    run fetch_usage_data
    [ "$status" -ne 0 ]
    [[ "$output" == *"needs re-login"* ]]
    [[ "$output" == *"claude /login"* ]]
}

@test "test_rate_check_hook_mode_revoked_refresh_fails_open" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    create_fake_credentials_nested "AT-x" "RT-x" 9999999999000
    rm -f /tmp/claude-usage-cache.json

    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
n_file=/tmp/ccs-curl-count
n=$(cat "$n_file" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$n_file"
if [ "$n" -eq 1 ]; then echo '{}'; echo "401"; else echo '{}'; echo "403"; fi
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
    rm -f /tmp/ccs-curl-count

    run run_ccswitch rate-check --hook-mode --threshold 80
    [ "$status" -eq 0 ]
}
```

Note: `run` captures both stdout and stderr in `$output`, so the `*"needs re-login"*` assertion works even though the message is written to stderr.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats test/test_rate_check.bats -f "revoked"`
Expected: `..._prints_relogin_hint` FAILS (no such message today). The hook-mode fail-open test may already pass (existing fail-open behavior) — that's fine; it guards against regression.

- [ ] **Step 3: Add the re-login message**

In `ccswitch.sh` `fetch_usage_data`, the refresh-failure branch is currently (lines 1670-1672):

```bash
        if [[ "$refresh_code" != "200" ]]; then
            return 1
        fi
```

Replace it with:

```bash
        if [[ "$refresh_code" != "200" ]]; then
            echo "ccs: account ${current_email} needs re-login — run: claude /login" >&2
            return 1
        fi
```

(`current_email` is already set near the top of `fetch_usage_data` via `get_current_account`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats test/test_rate_check.bats`
Expected: both new tests PASS; all pre-existing rate-check tests still PASS.

- [ ] **Step 5: shellcheck + commit**

Run: `shellcheck ccswitch.sh` (clean)

```bash
git add ccswitch.sh test/test_rate_check.bats
git commit -m "feat: hint re-login when refresh token is revoked (#31)"
```

---

## Task 5: Documentation + issue housekeeping

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update CHANGELOG.md**

Read `CHANGELOG.md` to match its section style, then add under the top/unreleased section:

```markdown
- fix: token introspection now reads Claude Code 2.1.x's nested credential
  format (`claudeAiOauth.accessToken` / `expiresAt`), with a fallback to the
  legacy flat shape. Previously the usage API read and `ccs status` expiry
  read a flat `access_token` that does not exist on current macOS, so
  rate-limit auto-switch could not fetch usage and `status` could not show
  token expiry on macOS.
- fix: refreshed tokens are written back in the credential's own shape
  (nested or flat), as single-line JSON.
- feat: when an account's refresh token is revoked, `ccs` now prints a clear
  "needs re-login — run: claude /login" hint instead of failing silently.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: note credential-format-aware token handling (#31)"
```

- [ ] **Step 3: Run the full suite as a final check**

Run: `bats test/`
Expected: all green (149 before this plan + the new tests). `shellcheck ccswitch.sh` clean.

---

## Done criteria

- Accessors read access/refresh tokens and expiry from both nested camelCase and flat snake_case.
- `fetch_usage_data` works with a nested credential and writes refreshed tokens back in the nested shape, single-line.
- `ccs status` shows token expiry for a nested credential.
- A revoked refresh token prints a re-login hint; hook mode still fails open.
- `bats test/` fully green; `shellcheck ccswitch.sh` clean.
- Out of scope (do not implement): standalone `ccs sync`/switch-time-refresh command; `CLAUDE_CONFIG_DIR` parallel isolation.
