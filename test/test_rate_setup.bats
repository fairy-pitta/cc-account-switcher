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

@test "rate-setup finds the hook when only the binary is in bin/ (make install layout)" {
    # `make install` puts ccs in <prefix>/bin and the shipped scripts in
    # <prefix>/share/ccswitch — the hook is not next to the binary.
    local prefix="$TEST_HOME/prefix" ccs
    ccs="$(install_ccs_prefix "$prefix" share)"

    run run_ccswitch_at "$ccs" rate-setup
    [ "$status" -eq 0 ]

    run jq -e --arg h "$prefix/share/ccswitch/hooks/ccs-rate-hook.sh" \
        '.hooks.PreToolUse[0].hooks[0].command | contains($h)' "$(SETTINGS)"
    [ "$status" -eq 0 ]
}

@test "rate-setup resolves the hook through a symlinked ccs" {
    local prefix="$TEST_HOME/prefix" ccs
    ccs="$(install_ccs_prefix "$prefix" sibling)"
    mkdir -p "$TEST_HOME/link-bin"
    ln -s "$ccs" "$TEST_HOME/link-bin/ccs"

    run run_ccswitch_at "$TEST_HOME/link-bin/ccs" rate-setup
    [ "$status" -eq 0 ]

    run jq -e --arg h "$prefix/bin/hooks/ccs-rate-hook.sh" \
        '.hooks.PreToolUse[0].hooks[0].command | contains($h)' "$(SETTINGS)"
    [ "$status" -eq 0 ]
    # CCS_PATH keeps the path ccs was invoked through: for a versioned install
    # reached through a stable link, that's the path that survives an upgrade.
    run jq -e --arg c "CCS_PATH=$TEST_HOME/link-bin/ccs " \
        '.hooks.PreToolUse[0].hooks[0].command | startswith($c)' "$(SETTINGS)"
    [ "$status" -eq 0 ]
}

@test "rate-setup honors CCS_SHARE_DIR" {
    local share="$TEST_HOME/share"
    mkdir -p "$share/hooks"
    cp "${BATS_TEST_DIRNAME}/../hooks/ccs-rate-hook.sh" "$share/hooks/"

    run env CCS_SHARE_DIR="$share" HOME="$TEST_HOME" \
        PATH="$MOCK_BIN:$ORIGINAL_PATH" /bin/bash "$CCSWITCH_SCRIPT" rate-setup
    [ "$status" -eq 0 ]

    run jq -e --arg h "$share/hooks/ccs-rate-hook.sh" \
        '.hooks.PreToolUse[0].hooks[0].command | contains($h)' "$(SETTINGS)"
    [ "$status" -eq 0 ]
}

@test "rate-setup fails without enabling when the hook script is missing" {
    local prefix="$TEST_HOME/prefix"
    mkdir -p "$prefix/bin"
    cp "$CCSWITCH_SCRIPT" "$prefix/bin/ccs"

    run run_ccswitch_at "$prefix/bin/ccs" rate-setup
    [ "$status" -eq 1 ]
    [[ "$output" == *"not found"* ]]
    # Config must not claim the auto-switch is on when no hook was installed
    run jq -r '.rateLimit.enabled // "unset"' "$SEQUENCE_FILE"
    [ "$output" != "true" ]
}

@test "reinstalling at a different prefix replaces our hook entry" {
    local first second
    first="$(install_ccs_prefix "$TEST_HOME/prefix-a" share)"
    second="$(install_ccs_prefix "$TEST_HOME/prefix-b" share)"

    run_ccswitch_at "$first" rate-setup
    run run_ccswitch_at "$second" rate-setup
    [ "$status" -eq 0 ]

    run jq '.hooks.PreToolUse | length' "$(SETTINGS)"
    [ "$output" -eq 1 ]
    run jq -e --arg h "$TEST_HOME/prefix-b/share/ccswitch/hooks/ccs-rate-hook.sh" \
        '.hooks.PreToolUse[0].hooks[0].command | contains($h)' "$(SETTINGS)"
    [ "$status" -eq 0 ]
}

@test "rate-setup --disable leaves a similarly named third-party hook intact" {
    mkdir -p "$(dirname "$(SETTINGS)")"
    cat > "$(SETTINGS)" << 'EOF'
{"hooks":{"PreToolUse":[{"matcher":"","hooks":[
  {"type":"command","command":"/home/u/bin/my-ccs-rate-hook.sh"}
]}]}}
EOF

    run run_ccswitch rate-setup --disable
    [ "$status" -eq 0 ]

    run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$(SETTINGS)"
    [ "$output" = "/home/u/bin/my-ccs-rate-hook.sh" ]
}

@test "rate-setup --disable removes the installed hook" {
    run_ccswitch rate-setup
    run_ccswitch rate-setup --disable
    run jq '.hooks.PreToolUse | length' "$(SETTINGS)"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
}
