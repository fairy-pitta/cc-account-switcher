#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

SETTINGS() { echo "$HOME/.claude/settings.local.json"; }

@test "rate-setup installs a PreToolUse hook in the nested Claude Code schema" {
    run run_ccswitch rate-setup --threshold 75
    [ "$status" -eq 0 ]

    local s; s="$(SETTINGS)"
    [ -f "$s" ]
    # Exactly one matcher entry, with a nested hooks array of command handlers
    run jq -e '
        (.hooks.PreToolUse | length) == 1
        and (.hooks.PreToolUse[0] | has("hooks"))
        and (.hooks.PreToolUse[0].hooks[0].type == "command")
        and (.hooks.PreToolUse[0].hooks[0].command | test("ccs-rate-hook.sh"))
    ' "$s"
    [ "$status" -eq 0 ]
}

@test "rate-setup must NOT use the legacy flat {matcher, command} shape" {
    run run_ccswitch rate-setup
    [ "$status" -eq 0 ]
    # No PreToolUse entry should carry a top-level command key
    run jq -e '[.hooks.PreToolUse[] | select(has("command"))] | length == 0' "$(SETTINGS)"
    [ "$status" -eq 0 ]
}

@test "rate-setup is idempotent (no duplicate hook entries)" {
    run_ccswitch rate-setup --threshold 75
    run_ccswitch rate-setup --threshold 75
    run jq '.hooks.PreToolUse | length' "$(SETTINGS)"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "rate-setup --disable removes the installed hook" {
    run_ccswitch rate-setup
    run_ccswitch rate-setup --disable
    run jq '.hooks.PreToolUse | length' "$(SETTINGS)"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}
