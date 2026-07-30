# Custom Endpoint Accounts & Fallback — Design

**Issue:** [#36](https://github.com/fairy-pitta/cc-account-switcher/issues/36) — Support custom `ANTHROPIC_BASE_URL` / API keys and automatic fallback switching
**Date:** 2026-06-25
**Status:** Approved design, pre-implementation

## Goal

Let `ccs` treat a custom Anthropic-compatible endpoint (OpenRouter, corporate gateway, proxy, self-hosted) as a first-class, switchable "account" alongside existing OAuth subscription accounts — including participation in the existing automatic rate-limit fallback.

## Scope

In scope:
- Add custom-endpoint accounts (`ANTHROPIC_BASE_URL` + API key/token, optional model) to the same account list as OAuth accounts.
- Switch to/from custom-endpoint accounts via the existing command surface (`to`, `sw`, rotation, `dir`, `rm`).
- Include custom-endpoint accounts in automatic fallback, using a probe-based health check (OAuth keeps usage-% pre-emptive switching).

Out of scope:
- Pre-emptive (usage-%) fallback for custom endpoints — they have no usage API, so fallback is reactive (probe detects failure).
- Per-request error interception inside Claude Code (the hook model does not expose live API error responses).

## Background: how Claude Code consumes a custom endpoint

Confirmed against Claude Code docs (code.claude.com/docs/en/settings):

- `settings.json` supports an `env` block: variables there are "applied to every session and to subprocesses Claude Code spawns." Applied at **startup**.
- Relevant variables:
  - `ANTHROPIC_BASE_URL` — custom API base URL.
  - `ANTHROPIC_API_KEY` — sent as both `X-Api-Key` and `Authorization: Bearer`.
  - `ANTHROPIC_AUTH_TOKEN` — alternative auth token.
  - `ANTHROPIC_MODEL` — default model override.
  - `ANTHROPIC_CUSTOM_HEADERS` — extra headers (not used by default; reserved).
- Settings precedence: managed > command line > `.claude/settings.local.json` > `.claude/settings.json` > `~/.claude/settings.json`.

**Integration point:** `ccs` toggles the `env` block of `~/.claude/settings.json` (user-global, since account switching is a global operation). Switching to a custom endpoint writes the env keys; switching to OAuth removes the `ccs`-owned env keys so stored OAuth credentials take over again. Because `env` is applied at startup, any switch that crosses an endpoint boundary requires a Claude Code restart to take effect (handled by existing `-r/--restart` / `--resume`; otherwise a clear warning is shown).

## Section 1 — Account model & storage

Extend the existing `accounts` map in `sequence.json` with an `authType` field. OAuth and custom endpoints share one numbered list.

```jsonc
// sequence.json -> accounts["3"] (custom endpoint example)
{
  "authType": "endpoint",            // "oauth" (default, existing) | "endpoint"
  "label": "openrouter",             // display name / identifier (in place of email)
  "baseUrl": "https://openrouter.ai/api/v1",
  "model": "anthropic/claude-...",   // optional -> ANTHROPIC_MODEL; omit if unset
  "tokenHeader": "api_key",          // "api_key" -> ANTHROPIC_API_KEY | "auth_token" -> ANTHROPIC_AUTH_TOKEN
  "added": "...", "switchCount": 0, "totalSeconds": 0, "lastUsed": "..."
}
```

- **Backward compatibility:** existing OAuth records have no `authType` and are treated as `oauth`. `email`/`uuid` keep their current meaning.
- **Secret storage (unchanged path):** the API key/token is **never** written to the metadata JSON. It is stored via the existing per-platform secret path:
  - macOS: Keychain, service `Claude Code-Account-{num}-{label}`.
  - Linux/WSL: `~/.claude-switch-backup/credentials/` (mode 600).
- **Metadata storage:** non-secret fields (`baseUrl`, `model`, `tokenHeader`, `authType`, `label`) live in the existing config JSON / `sequence.json`.
- **Identifier:** OAuth = email; endpoint = `label`. `ccs to <label>` resolves either.

## Section 2 — Switch mechanics & fallback

### Switch (dispatch on `authType` inside `perform_switch()`)

| Target | `env` block action | credentials / `.claude.json` |
|---|---|---|
| → `oauth` | **Remove** `ccs`-owned env keys (`ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`) | Existing behavior: restore credentials + swap `oauthAccount` in `.claude.json` |
| → `endpoint` | **Write** `ANTHROPIC_BASE_URL` + key (`ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` per `tokenHeader`) + optional `ANTHROPIC_MODEL` | Leave credentials / `oauthAccount` untouched (env wins; OAuth creds may remain dormant) |

- Write target: the `env` object of `~/.claude/settings.json`. Only `ccs`-owned keys are added/removed; any user-defined env keys are preserved. The set of owned keys is defined once as a constant; a single function performs the write/remove to avoid env residue.
- Lock + rollback reuse the existing framework: capture the prior `env`/credential state before writing, restore on mid-switch failure.
- Endpoint-crossing switches need a restart. With `--resume`/`-r`, proceed as usual. Without, emit an explicit warning that `env` changes apply only after a Claude Code restart.

### Automatic fallback (`ccs rate-check --auto-switch`, PreToolUse hook)

Branch on the active account's `authType`:

1. **Active = oauth** → unchanged: usage API → 5-hour utilization % → switch when over threshold.
2. **Active = endpoint** → no usage API; **probe-based health check**:
   - `ccs` issues a lightweight request to the active `ANTHROPIC_BASE_URL` using the stored key: first try `GET {baseUrl}/models`; if unsupported, fall back to a minimal `POST {baseUrl}/messages` with `max_tokens: 1`.
   - Classify HTTP status: `401/403` (auth), `429` (rate/credit), `5xx`, or timeout ⇒ **unhealthy** ⇒ trigger fallback. `2xx` ⇒ healthy.
   - Result is cached via the existing temp/cache-file helper (reuse TTL) so probing does not hardcode `/tmp` and stays portable across macOS, Linux, WSL, and Git Bash.
3. **Fallback target selection:** walk `sequence` order across the mixed oauth/endpoint list. For each candidate verify health (`oauth`: utilization < threshold; `endpoint`: probe returns `2xx`) and switch to the first healthy one. If none are healthy, emit the existing deny protocol (exit 3).

Accepted trade-off: endpoint fallback is **reactive** — it fires after the endpoint actually rejects a request (e.g. 429), not pre-emptively. This is inherent to having no usage API.

## Section 3 — Command UX, edge cases, testing

### Commands

- **Add (separate from `ccs add`, which imports the live OAuth login):**
  ```
  ccs add-endpoint <label> --base-url <URL> [--model <M>] [--token-header api_key|auth_token]
  ```
  - The secret is read via hidden interactive prompt or `--key-stdin` (stdin). It is never passed as a CLI argument (avoid shell-history leakage).
  - After add, the endpoint joins the normal numbering; `to`/`sw`/`rm`/`dir`/rotation all work.
- **Edit (minimal, optional / may be deferred):**
  ```
  ccs edit-endpoint <label> [--base-url ... | --model ... | --token-header ... | --key-stdin]
  ```
  (If deferred, `rm` + `add-endpoint` is the workaround.)
- **List:** `ccs ls` shows `authType` (e.g. `3  openrouter  [endpoint]  openrouter.ai`). `ccs status` shows base URL + model when the active account is an endpoint. Keys are always masked.
- **Remove:** `ccs rm` for an endpoint also clears its Keychain/credentials secret (reuse the existing rm path).

### Edge cases & error handling

- **No-restart no-op:** an endpoint-crossing switch without a restart flag warns that `env` changes need a Claude Code restart.
- **Env residue:** switching back to OAuth must reliably delete all `ccs`-owned env keys (otherwise an OAuth session keeps talking to the custom endpoint). Owned keys are a single constant; write/remove is one function.
- **Zero healthy targets:** all oauth over threshold and all endpoints unhealthy → existing deny protocol + manual guidance.
- **Probe false positives:** a network outage and an endpoint failure are not distinguished (both "unhealthy"). The hook stays **fail-open** — if the probe itself errors, allow the tool through; never block on probe failure.
- **`config-dir` / `exec` (parallel isolation):** endpoint accounts are expressed via env, so `exec`/`config-dir` must export the endpoint env (in addition to `CLAUDE_CONFIG_DIR`) through the existing env-injection path.

### Testing

Follow the existing bash test suite under `test/` (85 passing). Add cases for:
- `add-endpoint` → `ls` → `to` → `status` round trip.
- `env` block write on switch-to-endpoint and **complete removal** on switch-back-to-oauth (no residue).
- Backward compatibility: records without `authType` behave as `oauth`.
- Probe classification with mocked `curl`: `2xx` / `401` / `429` / `5xx` / timeout each map to the right healthy/unhealthy decision.
- Mixed-list fallback ordering picks the first healthy account.
- Secrets never appear in plaintext metadata JSON.

### Docs

Add an endpoint section to both `README.md` and `README.ja.md` (OSS → English + Japanese).

## Open follow-ups (not blocking)

- `edit-endpoint` may ship in a later PR if the initial scope is large.
- `ANTHROPIC_CUSTOM_HEADERS` support is reserved for a future iteration.
