#!/usr/bin/env bash
# Manual Paperclip/Multica simulation: confirm the rate-limit PreToolUse hook
# fires in MANY concurrent headless `claude -p` agents (an orchestrator spawning
# agents on heartbeats). Uses a SHIMMED ccs that only logs each invocation, so
# NO real account switching or credential mutation happens — your live login is
# untouched. Requires a logged-in Claude Code and network. NOT run in CI.
#
# Usage: bash test/manual/paperclip-sim.sh [N]   (default N=5 concurrent agents)
set -uo pipefail

N="${1:-5}"
CLAUDE="${CLAUDE_BIN:-claude}"
command -v "$CLAUDE" >/dev/null 2>&1 || CLAUDE="/Applications/cmux.app/Contents/Resources/bin/claude"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/paperclip-sim-XXXXXX")
LOG="$WORK/fired.log"
SHIM="$WORK/ccs-shim.sh"
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hooks/ccs-rate-hook.sh"
trap 'rm -rf "$WORK"' EXIT

# Shim ccs: record that the hook reached it, then exit 0 (no switch, no rate-check).
cat > "$SHIM" <<'EOF'
#!/usr/bin/env bash
echo "FIRED pid=$$ args=$*" >> "$CCS_SIM_LOG"
exit 0
EOF
chmod +x "$SHIM"

# Nested-schema PreToolUse hook wired to the real shipped hook, with CCS_PATH -> shim.
SETTINGS=$(jq -n --arg cmd "CCS_PATH=$SHIM CCS_SIM_LOG=$LOG $HOOK" \
    '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:$cmd}]}]}}')

echo "Spawning $N concurrent headless claude -p agents, each making a Bash tool call..."
for i in $(seq 1 "$N"); do
    "$CLAUDE" -p "Use the Bash tool to run exactly: echo agent-$i. Then reply done." \
        --settings "$SETTINGS" --dangerously-skip-permissions --allowedTools "Bash" \
        </dev/null >"$WORK/agent-$i.out" 2>&1 &
done
wait

fired=$(grep -c FIRED "$LOG" 2>/dev/null || echo 0)
echo "----"
echo "Agents spawned:   $N"
echo "Hook firings:     $fired"
if [[ "$fired" -ge "$N" ]]; then
    echo "RESULT: PASS — the PreToolUse hook fired in every concurrent headless agent."
else
    echo "RESULT: PARTIAL — $fired/$N agents fired the hook. Check $WORK kept for inspection."
    trap - EXIT
    echo "(work dir retained: $WORK)"
fi
