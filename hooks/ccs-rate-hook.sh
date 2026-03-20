#!/usr/bin/env bash
# PreToolUse hook for Claude Code — auto-switch on rate limit detection
# This script is called by Claude Code before each tool invocation.
# It reads the usage cache (kept warm by the statusline) and delegates
# to `ccs rate-check` when the threshold is exceeded.
#
# Design: fail open on ALL errors — never block the user due to our bugs.

set -uo pipefail  # No -e: we handle errors manually

# Consume stdin (required by hook protocol)
# shellcheck disable=SC2034  # INPUT consumed per hook protocol, not used in script
INPUT=$(cat)

CACHE_FILE="/tmp/claude-usage-cache.json"
THRESHOLD=80

# Fail open: if anything goes wrong, allow the tool call
trap 'exit 0' ERR

# Quick check: does cache file exist?
[[ -f "$CACHE_FILE" ]] || exit 0

# Read 5-hour utilization
usage=$(jq -r '.five_hour.utilization // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
usage_int=$(printf "%.0f" "$usage" 2>/dev/null || echo "0")

# Read config threshold if available
SEQ="$HOME/.claude-switch-backup/sequence.json"
if [[ -f "$SEQ" ]]; then
    cfg=$(jq -r '.rateLimit.threshold // empty' "$SEQ" 2>/dev/null || true)
    [[ -n "$cfg" ]] && THRESHOLD="$cfg"
    # Check if feature is disabled
    enabled=$(jq -r '.rateLimit.enabled // true' "$SEQ" 2>/dev/null || echo "true")
    [[ "$enabled" == "false" ]] && exit 0
fi

[[ $usage_int -lt $THRESHOLD ]] && exit 0

# Threshold exceeded — delegate to ccs rate-check
CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -z "$CCS" ]] && CCS="/usr/local/bin/ccs"
[[ -x "$CCS" ]] || { echo "ccs not found" >&2; exit 0; }

# Run in subshell, capture output. On any failure → fail open
result=$("$CCS" rate-check --auto-switch --hook-mode --threshold "$THRESHOLD" 2>/dev/null) || true

if [[ -n "$result" ]]; then
    echo "$result"
else
    # Fallback: just warn, don't block
    exit 0
fi
