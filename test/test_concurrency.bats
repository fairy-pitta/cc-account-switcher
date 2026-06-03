#!/usr/bin/env bats
#
# Tests for the switch lock and cache-freshness helpers added for headless /
# concurrent (orchestrator) rate-limit auto-switching.

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# --- acquire_switch_lock / release_switch_lock ---------------------------------

@test "acquire_switch_lock succeeds when the lock is free" {
    source_ccswitch_functions
    run acquire_switch_lock 2
    [ "$status" -eq 0 ]
    [ -d "$LOCK_DIR" ]
}

@test "release_switch_lock removes the lock and is idempotent" {
    source_ccswitch_functions
    acquire_switch_lock 2
    [ -d "$LOCK_DIR" ]
    release_switch_lock
    [ ! -d "$LOCK_DIR" ]
    # Second release must not error
    run release_switch_lock
    [ "$status" -eq 0 ]
}

@test "acquire_switch_lock times out when held by a live process" {
    source_ccswitch_functions
    # Simulate a live holder: the lock dir exists with our own (alive) PID.
    mkdir -p "$LOCK_DIR"
    echo "$$" > "$LOCK_DIR/pid"
    run acquire_switch_lock 1
    [ "$status" -eq 1 ]
}

@test "acquire_switch_lock steals a lock owned by a dead process" {
    source_ccswitch_functions
    # A PID that is essentially guaranteed not to be running.
    mkdir -p "$LOCK_DIR"
    echo "999999" > "$LOCK_DIR/pid"
    run acquire_switch_lock 2
    [ "$status" -eq 0 ]
    [ -d "$LOCK_DIR" ]
}

# --- cache_freshness ----------------------------------------------------------

@test "cache_freshness reports stale when the cache is missing" {
    source_ccswitch_functions
    run cache_freshness "/tmp/does-not-exist-$$.json" 60 ""
    [ "$status" -eq 0 ]
    [ "$output" = "stale" ]
}

@test "cache_freshness reports fresh for a recent cache under TTL" {
    source_ccswitch_functions
    local f="$TEST_HOME/cache.json"
    echo "{\"cached_at\": $(date +%s), \"active_account\": \"a@b.com\"}" > "$f"
    run cache_freshness "$f" 60 "a@b.com"
    [ "$output" = "fresh" ]
}

@test "cache_freshness reports stale when older than TTL" {
    source_ccswitch_functions
    local f="$TEST_HOME/cache.json"
    local old=$(( $(date +%s) - 120 ))
    echo "{\"cached_at\": $old, \"active_account\": \"a@b.com\"}" > "$f"
    run cache_freshness "$f" 60 "a@b.com"
    [ "$output" = "stale" ]
}

@test "cache_freshness reports stale on account mismatch even if recent" {
    source_ccswitch_functions
    local f="$TEST_HOME/cache.json"
    echo "{\"cached_at\": $(date +%s), \"active_account\": \"other@b.com\"}" > "$f"
    run cache_freshness "$f" 60 "a@b.com"
    [ "$output" = "stale" ]
}

@test "cache_freshness reports stale when cached_at is missing" {
    source_ccswitch_functions
    local f="$TEST_HOME/cache.json"
    echo '{"active_account": "a@b.com"}' > "$f"
    run cache_freshness "$f" 60 "a@b.com"
    [ "$output" = "stale" ]
}

# --- perform_switch no-op guard -----------------------------------------------

@test "switching to the already-active account is a no-op" {
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    create_fake_credentials "user1@example.com"

    run run_ccswitch to 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Already on Account-1 (user1@example.com)"* ]]
}
