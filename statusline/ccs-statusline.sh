#!/usr/bin/env bash
# Statusline script for Claude Code — shows the active account and 5-hour usage,
# and keeps the usage cache warm for the rate-limit auto-switch hook.
#
# Claude Code invokes this on each render with session JSON on stdin and uses the
# single line we print as the status line. To stay responsive we never block the
# render on the network: a TTL-aware cache refresh is kicked off in the
# background and we print whatever is currently cached.
#
# Design: fail open / never error — a broken statusline must not disrupt the UI.

set -uo pipefail

# Consume stdin (Claude Code passes session JSON; we don't need it).
# shellcheck disable=SC2034
INPUT=$(cat 2>/dev/null || true)

# Resolve the usage cache the same way ccswitch.sh's usage_cache_file() does so
# writer (this script) and readers (rate hook, ccs) always agree: honor
# $CCS_USAGE_CACHE, else the system temp dir ($TMPDIR/$TMP/$TEMP, else /tmp).
if [[ -n "${CCS_USAGE_CACHE:-}" ]]; then
    CACHE_FILE="$CCS_USAGE_CACHE"
else
    _cache_dir="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
    CACHE_FILE="${_cache_dir%/}/claude-usage-cache.json"
fi
SEQ="$HOME/.claude-switch-backup/sequence.json"

# Resolve ccs: 1) CCS_PATH env (set by statusline-setup), 2) sibling of this
# script's dir, 3) PATH, 4) common locations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"
CCS="${CCS_PATH:-}"
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="${SCRIPT_DIR}/../ccswitch.sh"
[[ -x "$CCS" ]] || CCS=$(command -v ccs 2>/dev/null || echo "")
[[ -z "$CCS" || ! -x "$CCS" ]] && CCS="/usr/local/bin/ccs"

# Kick a TTL-aware refresh in the background (no --auto-switch: refreshing the
# cache is the statusline's job; switching is the hook's). Detached so the render
# never waits on the API call.
if [[ -x "$CCS" ]]; then
    ( "$CCS" rate-check >/dev/null 2>&1 & ) 2>/dev/null || true
fi

# Print from whatever is currently cached.
if [[ -f "$CACHE_FILE" ]]; then
    acct=$(jq -r '.active_account // "?"' "$CACHE_FILE" 2>/dev/null || echo "?")
    util=$(jq -r '.five_hour.utilization // 0' "$CACHE_FILE" 2>/dev/null || echo "0")

    # Round the way ccswitch.sh's usage_to_int() does — keep the two in sync.
    # LC_ALL=C because printf's %f honors LC_NUMERIC and a comma-decimal locale
    # fails on the cache's dot-decimal string after printing a partial result;
    # no `|| echo` fallback inside the substitution, which would append to that
    # partial output and render 15.0 as 150%.
    if util_int=$(LC_ALL=C printf '%.0f' "$util" 2>/dev/null) && [[ "$util_int" =~ ^-?[0-9]+$ ]]; then
        # Threshold marker: append "(!)" when at/over the configured threshold.
        threshold=80
        if [[ -f "$SEQ" ]]; then
            cfg=$(jq -r '.rateLimit.threshold // empty' "$SEQ" 2>/dev/null || true)
            [[ -n "$cfg" ]] && threshold="$cfg"
        fi
        marker=""
        [[ "$util_int" -ge "$threshold" ]] && marker=" (!)"

        printf 'ccs %s · 5h %s%%%s\n' "$acct" "$util_int" "$marker"
    else
        # Say so rather than show a number we made up.
        printf 'ccs %s · 5h ?%%\n' "$acct"
    fi
else
    printf 'ccs (no usage data yet)\n'
fi

exit 0
