#!/usr/bin/env bats

load test_helper

setup() { setup_test_env; }
teardown() {
    rm -f "$TEST_HOME/claude-argv" 2>/dev/null || true
    teardown_test_env
}

@test "test_build_resume_command_with_session_id_forks" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "sid-123")" = "claude --resume sid-123 --fork-session" ]
}

@test "test_build_resume_command_without_session_id_is_fresh" {
    source_ccswitch_functions
    [ "$(build_resume_command claude "")" = "claude" ]
}

@test "test_capture_resume_session_id_reads_lastsessionid_for_cwd" {
    create_fake_claude_config "user1@example.com" "uuid-1"
    local cwd cfg updated
    cwd="$PWD"
    cfg="$HOME/.claude/.claude.json"
    updated=$(jq --arg c "$cwd" '.projects[$c] = {lastSessionId: "sess-abc"}' "$cfg")
    echo "$updated" > "$cfg"

    source_ccswitch_functions
    [ "$(capture_resume_session_id)" = "sess-abc" ]
}

@test "test_capture_resume_session_id_empty_when_no_entry" {
    create_fake_claude_config "user1@example.com" "uuid-1"
    source_ccswitch_functions
    [ -z "$(capture_resume_session_id)" ]
}
