# Credential-format-aware token handling (supersedes the `ccs sync` idea, #31)

**Date:** 2026-06-25
**Issue:** [#31](https://github.com/fairy-pitta/cc-account-switcher/issues/31) (repurposed — see "Background")
**Related:** #29 (credential format / `-<hash>` migration), #30 (active-account reconcile), #32 (single-line JSON / hex fix)

## Background

While designing `ccs sync` (#31), tracing the existing refresh code surfaced a larger,
verified bug: **ccswitch's token-introspection layer reads a credential format that
does not exist on current macOS Claude Code.**

- Real macOS credential (`Claude Code-credentials`, Claude Code 2.1.x) is nested
  camelCase: `{"claudeAiOauth":{"accessToken":…,"refreshToken":…,"expiresAt":<epoch_ms>}}`.
  Verified on this machine: `.claudeAiOauth.accessToken` length 108; flat `.access_token`
  length **0**.
- ccswitch reads **flat snake_case** everywhere it introspects a token:
  - `fetch_usage_data` (`ccswitch.sh:1633`) reads `.access_token` → empty → `return 1`
    immediately. **Result: usage-based rate-limit auto-switch cannot read usage on
    macOS; it silently fails open.** The refresh-on-401 block (`:1652,1676,1686`) is
    never reached, and it writes refreshed tokens back as flat keys (`'.access_token = …'`),
    which would corrupt a nested credential into a hybrid shape.
  - `ccs status` token expiry (`:705`) reads `.access_token`, JWT-decodes it for `exp`.
    On macOS the token is empty → "unable to determine expiry". The nested credential
    carries `expiresAt` directly, so a JWT decode isn't even needed.

The `ccs sync` idea is dropped: switching moves the credential as an opaque blob (so the
switch itself is format-agnostic and works), and once `fetch_usage_data` can read the
token, its existing refresh-on-401 makes the rotation path self-heal — a dedicated
"refresh on switch" step would be redundant. The valuable remnant of the original intent
— a clear "this account needs re-login" message when a refresh token is revoked — is kept.

This likely explains "it worked in April": an older credential format (or Claude version)
was flat snake_case and matched the code; Claude Code 2.1.x moved to nested camelCase
(same era as the `-<hash>` keychain migration in #29) and silently broke token
introspection. Note this is separate from the switch 401s seen during verification
(those were dead tokens: logout-revocation and expired+hex-corrupted backups).

## Goal

Make ccswitch's token introspection work on the real (nested camelCase) credential
format while still accepting the legacy flat format, so that:
- rate-limit auto-switch can actually read usage and refresh on macOS,
- `ccs status` shows correct token expiry,
- refreshed tokens are written back in the credential's own shape (single-line),
- a revoked refresh token produces a clear re-login message instead of a silent failure.

## Non-goals

- No standalone `ccs sync` / switch-time-refresh command (redundant — see Background).
- No change to the switch mechanism itself (it is format-agnostic and works).
- No `CLAUDE_CONFIG_DIR` / parallel-isolation work (out of scope; macOS limitation per #29).

## Components

### 1. Credential accessor layer (new helpers in `ccswitch.sh`)

Place near the other credential helpers (around the `keychain_read`/`read_credentials`
region, ~line 295-330). Each takes a credential JSON string on stdin or as `$1`.

- `cred_access_token <json>` →
  `jq -r '.claudeAiOauth.accessToken // .access_token // .token // empty'`
- `cred_refresh_token <json>` →
  `jq -r '.claudeAiOauth.refreshToken // .refresh_token // empty'`
- `cred_expiry_epoch <json>` → epoch **seconds**, or empty if undeterminable:
  - if `.claudeAiOauth.expiresAt` present (epoch **ms**) → integer-divide by 1000;
  - else if a flat/`.access_token` JWT is present → `decode_jwt_payload` (existing) → `.exp`;
  - else empty.
- `cred_set_tokens <json> <access> <refresh>` → returns updated JSON, **single-line**
  (via existing `normalize_credential`):
  - if input has `.claudeAiOauth` → set `.claudeAiOauth.accessToken=$access |
    .claudeAiOauth.refreshToken=$refresh`;
  - else → set flat `.access_token`/`.refresh_token`.

These are pure string→string functions: no I/O, independently testable.

### 2. Fix the three consumers to use the accessors

- **`fetch_usage_data`** (`ccswitch.sh:~1621-1695`):
  - replace `jq -r '.access_token'` (1633) with `cred_access_token`;
  - replace `jq -r '.refresh_token'` (1652) with `cred_refresh_token`;
  - replace the refresh write-back (1683-1686, currently `'.access_token=$at |
    .refresh_token=$rt'`) with `cred_set_tokens "$creds" "$new_access"
    "${new_refresh:-$refresh_token}"`, then `write_credentials` (already normalizes).
  - behavior otherwise unchanged (usage API call, 401→refresh→retry).
- **`ccs status`** token-expiry block (`ccswitch.sh:~698-731`):
  - compute expiry via `cred_expiry_epoch "$creds"`; if empty, print the existing
    "Unable to determine expiry"; otherwise reuse the existing diff/format branches.
  - drop the direct `.access_token` JWT path in favour of the accessor (which still
    falls back to JWT decode for flat creds).

### 3. Clear re-login message on revoked refresh token

In `fetch_usage_data` when the refresh grant returns non-200 (revoked/expired refresh
token), and elsewhere a refresh is attempted on a user path:
- **non-hook / user-facing:** emit to stderr
  `"Account <email> needs re-login. Run: claude /login"` then `return 1`.
- **hook mode:** keep failing open (existing behaviour), but the message may be logged.
  (`fetch_usage_data` itself has no hook/non-hook flag; surface the message at the
  caller that knows the mode — `cmd_rate_check` — or keep it minimal: have
  `fetch_usage_data` return a distinct non-zero on refresh-revoked and let the
  user-facing caller print the message. Implementation chooses the least invasive of
  these; the requirement is: a revoked refresh token is reported clearly on the user
  path and never blocks in hook mode.)

## Data flow

Rate-limit rotation: hook → `rate-check --hook-mode` → over threshold → `perform_switch`
restores account X (possibly expired access token) → rotation loop calls
`fetch_usage_data` → (fixed) reads X's nested token, calls usage API, on 401 refreshes
via the refresh-token grant, writes the refreshed token back in nested shape (single
line) → X is usable. `ccs status` reads `expiresAt` directly and shows correct expiry.

## Error handling

- Undeterminable token/expiry → accessors return empty; callers degrade gracefully
  (status prints "unable to determine"; `fetch_usage_data` returns non-zero).
- Refresh grant non-200 → treated as revoked: clear re-login message on user path,
  fail-open in hook mode.
- All `jq` calls guarded (`2>/dev/null`), consistent with existing style.

## Testing (bats)

New `test/test_credentials_format.bats`, plus extensions to `test/test_rate_check.bats`.
Follow `test_<action>_<condition>_<expected_result>`.

- **Accessors:**
  - `cred_access_token` returns the token from a **nested** cred and from a **flat** cred.
  - `cred_refresh_token` likewise.
  - `cred_expiry_epoch` returns seconds from `claudeAiOauth.expiresAt` (ms input) and from
    a flat JWT cred; returns empty when neither is present.
  - `cred_set_tokens` updates the nested path for a nested cred and the flat keys for a
    flat cred; output is single-line; other fields preserved.
- **`fetch_usage_data` (mock `curl`, mock `security`):**
  - with a **nested** cred and a 200 usage response → succeeds (previously failed: token
    unreadable). Assert the cache is written.
  - with a nested cred and 401→refresh(200)→retry(200) → succeeds and the stored
    credential is updated **in the nested shape** and single-line.
- **`ccs status`:** with a nested cred whose `expiresAt` is in the future → prints an
  "Expires in …" line (not "unable to determine").
- **Re-login message:** refresh grant returns non-200 on a user path → output contains
  the re-login hint; in hook mode the call still exits 0 (fail open).

`shellcheck` clean; full suite green (currently 149).

## Files touched

- `ccswitch.sh` — new accessor helpers; `fetch_usage_data`; `ccs status` expiry block;
  re-login message wiring.
- `test/test_credentials_format.bats` (new); `test/test_rate_check.bats` (extend).
- Possibly `test/test_helper.bash` — add a nested-format fake-credential helper
  (`create_fake_credentials_nested`) so tests cover the real shape.

## Issue housekeeping

- Repurpose/close #31: the format fix replaces the `ccs sync` plan; record this design
  and the verified root cause (flat-vs-nested) on the issue.
