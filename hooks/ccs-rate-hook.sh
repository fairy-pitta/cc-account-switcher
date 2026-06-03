#!/usr/bin/env bash
# PreToolUse hook for Claude Code — auto-switch on rate limit detection
# This script is called by Claude Code before each tool invocation.
#
# It takes a fast path when the usage cache is fresh and under threshold, and
# otherwise delegates to `ccs rate-check`, which refreshes the cache on demand
# (TTL-aware). This is what makes headless `claude -p` runs work: there's no
# statusline to keep the cache warm, so the hook must trigger a refresh itself.
#
# Design: fail open on ALL errors — never block the user due to our bugs.

set -uo pipefail  # No -e: we handle errors manually

# Consume stdin (required by hook protocol)
# shellcheck disable=SC2034  # INPUT consumed per hook protocol, not used in script
INPUT=$(cat)

CACHE_FILE="/tmp/claude-usage-cache.json"
THRESHOLD=80
CACHE_TTL=60

# Fail open: if anything goes wrong, allow the tool call
trap 'exit 0' ERR

# Read config: threshold, TTL, and the enabled toggle.
SEQ="$HOME/.claude-switch-backup/sequence.json"
if [[ -f "$SEQ" ]]; then
    cfg=$(jq -r '.rateLimit.threshold // empty' "$SEQ" 2>/dev/null || true)
    [[ -n "$cfg" ]] && THRESHOLD="$cfg"
    ttl=$(jq -r '.rateLimit.cacheTtl // empty' "$SEQ" 2>/dev/null || true)
    [[ -n "$ttl" ]] && CACHE_TTL="$ttl"
    enabled=$(jq -r '.rateLimit.enabled // true' "$SEQ" 2>/dev/null || echo "true")
    [[ "$enabled" == "false" ]] && exit 0
fi

# Fast path: if the cache is fresh (younger than the TTL) AND under threshold,
# allow the tool call without spawning ccs. Any other case (missing, stale, or
# over threshold) falls through to the delegate below, which refreshes as needed.
fast_ok=false
if [[ -f "$CACHE_FILE" ]]; then
    cached_at=$(jq -r '.cached_at // 0' "$CACHE_FILE" 2>/dev/null || echo 0)
    [[ "$cached_at" =~ ^[0-9]+$ ]] || cached_at=0
    now=$(date +%s)
    age=$(( now - cached_at ))
    usage=$(jq -r '.five_hour.utilization // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
    usage_int=$(printf "%.0f" "$usage" 2>/dev/null || echo "0")
    if [[ "$cached_at" -gt 0 && "$age" -lt "$CACHE_TTL" && "$usage_int" -lt "$THRESHOLD" ]]; then
        fast_ok=true
    fi
fi
[[ "$fast_ok" == true ]] && exit 0

# Delegate to ccs rate-check (refreshes the cache if missing/stale, then switches
# if over threshold). Resolve ccs: 1) CCS_PATH env (set by rate-setup),
# 2) sibling of this script's dir, 3) PATH, 4) common locations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCS="${CCS_PATH:-}"
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="${SCRIPT_DIR}/../ccswitch.sh"
[[ -x "$CCS" ]] || CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="/usr/local/bin/ccs"
[[ -x "$CCS" ]] || { echo "ccs not found" >&2; exit 0; }

# Run in subshell, capture output. On any failure → fail open.
result=$("$CCS" rate-check --auto-switch --hook-mode --threshold "$THRESHOLD" --max-age "$CACHE_TTL" 2>/dev/null) || true

if [[ -n "$result" ]]; then
    echo "$result"
else
    # Fallback: just warn, don't block
    exit 0
fi
