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

# Resolve the usage cache the same way ccswitch.sh's usage_cache_file() does so
# reader (this hook) and writer (statusline) always agree: honor
# $CCS_USAGE_CACHE, else the system temp dir ($TMPDIR/$TMP/$TEMP, else /tmp).
if [[ -n "${CCS_USAGE_CACHE:-}" ]]; then
    CACHE_FILE="$CCS_USAGE_CACHE"
else
    _cache_dir="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
    CACHE_FILE="${_cache_dir%/}/claude-usage-cache.json"
fi
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
    # Round the way ccswitch.sh's usage_to_int() does — keep the two in sync.
    # LC_ALL=C because printf's %f honors LC_NUMERIC and a comma-decimal locale
    # fails on the cache's dot-decimal string after printing a partial result;
    # a statement inside the subshell, not an `LC_ALL=C printf` prefix, because
    # bash 3.2 (macOS /bin/bash) ignores the prefix for a builtin. No `|| echo`
    # fallback inside the substitution, which would append to that partial output
    # and read 15.0 as 150. An unreadable value leaves fast_ok false, so we
    # delegate rather than guess.
    if usage_int=$(LC_ALL=C; printf '%.0f' "$usage" 2>/dev/null) && [[ "$usage_int" =~ ^-?[0-9]+$ ]]; then
        if [[ "$cached_at" -gt 0 && "$age" -lt "$CACHE_TTL" && "$usage_int" -lt "$THRESHOLD" ]]; then
            fast_ok=true
        fi
    fi
fi
[[ "$fast_ok" == true ]] && exit 0

# Delegate to ccs rate-check (refreshes the cache if missing/stale, then switches
# if over threshold). Resolve ccs: 1) CCS_PATH env (set by rate-setup),
# 2) sibling of this script's dir (source checkout, npm package), 3) the bin/
# next to the share/ccswitch/ we were installed into (`make install`, Homebrew),
# 4) PATH, 5) common locations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CCS="${CCS_PATH:-}"
[[ -x "$CCS" ]] || CCS="${SCRIPT_DIR}/../ccswitch.sh"
[[ -x "$CCS" ]] || CCS="${SCRIPT_DIR}/../../../bin/ccs"
[[ -x "$CCS" ]] || CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -x "$CCS" ]] || CCS="/usr/local/bin/ccs"
[[ -x "$CCS" ]] || { echo "ccs not found" >&2; exit 0; }

# Run in subshell, capture output. On any failure → fail open.
result=$("$CCS" rate-check --auto-switch --hook-mode --threshold "$THRESHOLD" --max-age "$CACHE_TTL" 2>/dev/null) || true

if [[ -n "$result" ]]; then
    echo "$result"
else
    # Fallback: just warn, don't block
    exit 0
fi
