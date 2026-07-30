#!/usr/bin/env bats

# Paperclip/Multica-style SOAK test: many headless orchestrator heartbeats
# cross the rate-limit threshold at the same instant and all call
# `ccs rate-check --auto-switch --hook-mode` concurrently. This exercises the
# real cross-process rotation path under contention and asserts integrity:
# valid sequence.json, no lost account, no orphaned lock, no per-slot credential
# cross-contamination, valid credential store.
#
# Scope note: this is a soak/smoke test, NOT a deterministic proof that the
# switch lock is load-bearing. The contamination race the lock guards against
# needs an asymmetric interleaving that portable sleep-based timing cannot force
# (all processes hit the critical section symmetrically), and #30's
# active-account reconcile plus atomic write_json already close most paths. The
# lock primitive's correctness (acquire/release/timeout/steal) is unit-tested in
# test_concurrency.bats. Credentials here are mocked; real-auth rotation needs
# live multi-account logins (see test/manual/paperclip-sim.sh).

load test_helper

setup() {
    setup_test_env
    # Three managed accounts, account 1 active.
    setup_fake_account "user1@example.com" "uuid-1"
    add_account_to_sequence "1" "user1@example.com" "uuid-1" "true"
    add_account_to_sequence "2" "user2@example.com" "uuid-2" "false"
    add_account_to_sequence "3" "user3@example.com" "uuid-3" "false"
    # Enable rate limiting with a low threshold.
    local updated
    updated=$(jq '.rateLimit = {enabled: true, threshold: 50}' "$SEQUENCE_FILE")
    echo "$updated" > "$SEQUENCE_FILE"
    # Usage API always reports over-threshold, so every heartbeat wants to switch.
    cat > "$MOCK_BIN/curl" << 'MOCK_EOF'
#!/bin/bash
echo '{"five_hour":{"utilization":95,"limit":100,"used":95}}'
echo "200"
MOCK_EOF
    chmod +x "$MOCK_BIN/curl"
}

teardown() {
    rm -f "$CCS_USAGE_CACHE"
    teardown_test_env
}

@test "test_concurrent_auto_switch_heartbeats_keep_sequence_intact" {
    # Fire 10 concurrent heartbeats (like an orchestrator spawning agents).
    local i
    for i in $(seq 1 10); do
        run_ccswitch rate-check --auto-switch --hook-mode --threshold 50 >/dev/null 2>&1 &
    done
    wait

    # Invariant 1: sequence.json is still valid JSON (no half-written state).
    run jq -e . "$SEQUENCE_FILE"
    [ "$status" -eq 0 ]

    # Invariant 2: the active account is one of the managed accounts.
    local active
    active=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    [[ "$active" == "1" || "$active" == "2" || "$active" == "3" ]]

    # Invariant 3: no account was lost from the rotation sequence.
    [ "$(jq '.sequence | length' "$SEQUENCE_FILE")" -eq 3 ]

    # Invariant 4: the switch lock was released (no orphan).
    [ ! -d "$BACKUP_DIR/.switch.lock" ]

    # Invariant 5: the accounts map still has all three entries intact.
    [ "$(jq '.accounts | length' "$SEQUENCE_FILE")" -eq 3 ]

    # Invariant 6: no cross-contamination. Each per-account backup slot still
    # holds ITS OWN credential. This is the hazard the switch lock exists to
    # prevent: a racing backup writing the live global (another account's) creds
    # into the wrong slot. write_json is atomic, so JSON validity alone would
    # NOT catch this — this assertion is what distinguishes locked from unlocked.
    local n slot
    for n in 1 2 3; do
        slot=$(security find-generic-password -s "Claude Code-Account-${n}-user${n}@example.com" -w 2>/dev/null)
        [[ "$slot" == *"at-user${n}@example.com"* ]]
    done
}

@test "test_concurrent_auto_switch_does_not_corrupt_credential_store" {
    local i
    for i in $(seq 1 10); do
        run_ccswitch rate-check --auto-switch --hook-mode --threshold 50 >/dev/null 2>&1 &
    done
    wait

    # The active global credential must remain valid JSON for whichever account
    # won the race (never a half-applied/empty write).
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    [ -n "$creds" ]
    run bash -c "printf '%s' '$creds' | jq -e ."
    [ "$status" -eq 0 ]
}
