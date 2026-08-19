# `ccs run` — reactive rate-limit auto-switch

**Status:** Approved (design). Reviewed twice by an independent adversarial reviewer against the real code; APPROVE on the second pass conditioned on the four implementation pins in §14.

**Date:** 2026-08-19

## 1. Summary

Add `ccs run -- <command...>` — a wrapper that runs a command (typically
`claude -p "..."`) on the active account, and when that command fails **because
the account hit a usage/rate limit**, switches to another account and retries.

This complements the existing *proactive* auto-switch (`rate-check` + the
PreToolUse hook), which rotates on a cached usage-% threshold and structurally
cannot observe a real mid-turn 429. `ccs run` adds the *reactive* path: it reacts
to an actual failure. Together they make the headline rate-limit auto-switch
robust for headless multi-agent orchestrators (Paperclip/Multica) that spawn many
`claude -p` agents and can tolerate retries.

## 2. Motivation

- The proactive hook fires *before* a tool call, so it cannot see a 429 returned
  during a model turn (established in #20).
- Orchestrators run headless `claude -p`. Their dominant limit mode is
  per-minute/burst 429 (RPM/ITPM), which does **not** move the 5-hour utilization
  metric — so a purely usage-%-based confirmation would miss exactly the case this
  feature exists to catch. Detection therefore keys on the **failure output**, not
  the usage metric (see §5).
- Goal (from #15/#20): "when one account is exhausted, agents keep working on
  another account." Mid-run seamlessness is **not** required; retries are
  acceptable.

## 3. Non-goals

- Not parallel multi-account throughput. `ccswitch` rewrites a single
  machine-global credential store; all Claude Code processes share one active
  account. `ccs run` provides **sequential rotation**, not per-agent isolation
  (that is `ccs exec` / `CLAUDE_CONFIG_DIR`, Linux/WSL only).
- Not interactive/TTY use. `ccs run` targets headless invocations.
- Not a replacement for the proactive hook; it is additive.

## 4. CLI

```
ccs run [--max-attempts N] [--limit-threshold N] [--timeout SEC] [--no-proactive] -- <command...>
```

- `<command...>` runs on the **active** account. `ccs` wraps it with
  detect → switch → retry and otherwise passes its arguments through untouched.
- `--max-attempts N` — hard cap on attempts. Default = number of managed
  accounts (each account tried at most once).
- `--limit-threshold N` — utilization %% at which the **secondary** usage
  confirmation (§5.2) considers an account "at limit". Default **95** —
  deliberately higher than, and independent of, the proactive rotation threshold
  (default 80).
- `--timeout SEC` — per-attempt deadline (§10). On timeout the child is killed;
  the buffered output is still grepped for a rate-limit signal before deciding.
- `--no-proactive` — skip the attempt-1 pre-check (§6 step 1).
- `--` is required to separate `ccs run` flags from the wrapped command.

## 5. Detection strategy — grep primary, usage secondary

A failed run (child exit ≠ 0, and not killed by signal/timeout — see §10) is
classified as rate-limited by:

### 5.1 Primary — grep the failure output (format-agnostic)

Because §6 already buffers the child's stdout and stderr, we inspect them
directly. This observes the *failure reason* and does not constrain the caller's
output format.

Scope, to avoid firing on a payload that merely *discusses* rate limits (e.g.
Claude summarizing logs that contain "429"):

- all of **stderr**, plus
- only the **final result/error line(s) of stdout** (not the whole stdout body).
- For `--output-format json` / `stream-json`, prefer the final object's
  `is_error` / `error` fields.

Case-insensitive patterns anchored on Claude Code's documented shapes:

- `API Error:.*\(429\)`
- `Request rejected \(429\)`
- `Retrying in .*attempt`   (backoff lines emitted before terminal failure)
- `overloaded`
- `usage limit`

### 5.2 Secondary — usage / health (only if the grep is inconclusive)

- OAuth account: force a fresh `fetch_usage_data`, then
  `usage_to_int(max(.five_hour.utilization, .seven_day.utilization))`
  (`// 0` when a field is absent — the weekly window matters: a weekly-limit
  exhaustion with a fresh 5h window would otherwise read as "under threshold").
  At-limit when ≥ `--limit-threshold` (default 95).
- Endpoint account: `probe_endpoint_health`.

### 5.3 Neither → genuine non-rate-limit error

Emit the buffered stdout and pass the child's exit code through unchanged. Do not
switch. (Not masking real errors is a hard requirement — see idempotency, §12.)

## 6. Per-attempt algorithm

For each attempt (bounded by `--max-attempts`):

0. **Re-read `started_account`** = the current active account number, via the
   same endpoint-aware view `perform_switch` reconciles to
   (`effective_active_account_num`). **This is done before *every* spawn, inside
   the retry loop** — not once up front (pin 3, §14).
1. **(attempt 1 only, if proactive)** via `cache_freshness`, if the active
   account is over the *proactive* threshold, rotate first (§7). Skipped with
   `--no-proactive`.
2. **Bound internal retries** for the child (§9): export
   `CLAUDE_CODE_MAX_RETRIES` (default 3, caller override respected) and
   `CLAUDE_CODE_RETRY_WATCHDOG` (default 0, caller override respected), scoped to
   the child.
3. **Run the child** (§8, §10): stdin from the spool file (§8); stdout → temp
   buffer; stderr → streamed live to the caller **and** buffered (for §5 grep).
   A `--timeout` watchdog (§10) may kill it.
4. **Child exit 0** → emit the buffered stdout to the caller's stdout, `exit 0`.
5. **Child killed by signal / timeout** (§10) → clean up, pass through
   (`128+sig`, or `124`), *after* running the §5.1 grep over buffered output — a
   child killed mid-backoff is a paradigm rate-limit case, so a grep match still
   routes to step 6's rate-limit branch.
6. **Child exit ≠ 0 (genuine)** → classify via §5:
   - **Rate-limited** → rotate under the CAS contract (§7): call
     `_rotate_to_healthy_next_account(started_account)`. Map its return:
     - `0` switched-healthy → retry (loop).
     - `3` lost-race (another instance already rotated) → retry **without**
       rotating (loop).
     - `1` all-exhausted → emit last buffered stdout, print the machine line
       (§11), `exit 3`.
     - `2` switch-error → print the machine line, `exit 2`.
     Between ccs-level attempts, sleep a short **jittered** interval (storm
     avoidance).
   - **Not rate-limited** (§5.3) → emit buffered stdout, pass through child's exit
     code.

## 7. Concurrency — compare-and-swap inside `perform_switch`

`ccs run` takes **no lock of its own**. The single existing non-reentrant mkdir
switch lock is acquired only by `perform_switch`, exactly once, as today. Nesting
is impossible by construction.

`perform_switch` gains an **optional trailing `expected_active` parameter**:

- Inside its existing lock, **after** the current reconcile block (which repairs a
  drifted `activeAccountNumber`) and **before** the no-op guard, if
  `expected_active` is non-empty and the reconciled current-active ≠
  `expected_active`, `release_switch_lock` then `return 3` ("lost race — no switch
  performed"). Ordering matters: after reconcile (so drift can't produce a false
  verdict) and before the no-op guard (so a concurrent switch onto the same target
  can't be misread as our success).
- `return 3` is unused by `perform_switch` today (its subshell status is
  {0,1}), so the signal is unambiguous.
- Every existing caller passes one argument and is byte-identical in behavior.

Under concurrency this makes the confirm+rotate decision correct: if another
`ccs run` rotated the shared account out from under us, our CAS fails (3) and we
retry without rotating — no wrong-account confirmation, no backwards rotation, no
sequence thrash.

## 8. stdin — spool-first

If stdin is **not** a TTY, `ccs run` `cat`s it **fully** into a `mktemp` file
(chmod 600) **before attempt 1**, and feeds **every** attempt (including the
first) via `< "$spool"`. This guarantees byte-identical stdin per attempt and
avoids the SIGPIPE/partial-consumption truncation a concurrent `tee` would suffer
when a fast-failing attempt 1 exits before draining stdin. The spool file is
removed in the cleanup trap (§10).

If stdin **is** a TTY, no spool (interactive use is out of scope; documented).

## 9. Internal-retry environment

Claude Code retries transient errors internally (default 10, `CLAUDE_CODE_MAX_RETRIES`),
and `CLAUDE_CODE_RETRY_WATCHDOG=1` makes 429/529 retries indefinite. Either would
keep the wrapper waiting minutes on a dead account or forever. `ccs run` therefore
exports to the child only:

- `CLAUDE_CODE_MAX_RETRIES="${CLAUDE_CODE_MAX_RETRIES:-3}"`
- `CLAUDE_CODE_RETRY_WATCHDOG="${CLAUDE_CODE_RETRY_WATCHDOG:-0}"`

Caller overrides are respected (an operator forcing the watchdog opts out
knowingly). The `Retrying in … attempt` backoff lines emitted during the bounded
retries are matched by §5.1 regardless.

## 10. Signals, timeout, cleanup

- `trap` INT/TERM → forward to the child (best-effort process-group kill where
  available; otherwise the child PID), `wait`, clean temp files, exit `128+sig`.
- `--timeout` is a **background watchdog** (record child PID, backgrounded
  sleep-then-kill, cancelled if the child exits first). No reliance on `timeout`
  or `setsid` — **absent on stock macOS**, which this repo supports.
- A signal/timeout death is **not** automatically the rate-limit path, but its
  buffered output is still grepped (§5.1, §6 step 5) before falling back to
  passing `124`/`128+sig` through.

## 11. Output & exit codes

- **stdout**: only the **successful** attempt's buffered stdout. Failed attempts'
  stdout is discarded.
- **stderr**: streamed live throughout, plus `ccs run`'s own notices prefixed
  `ccs-run:`.
- **Exit**: `0` success; the child's code on non-limit failure / timeout / signal;
  `3` all-accounts-exhausted; `2` internal switch error.
- On ccs-originated outcomes, emit a machine-readable final stderr line so
  orchestrators can branch unambiguously (exit `3` could otherwise collide with a
  wrapped command's own `3`):
  `ccs-run: exhausted accounts=<N> attempts=<M>` (and an analogous line for the
  switch-error case).

Trade-off (documented): buffered stdout loses `--output-format stream-json` /
`--include-partial-messages` liveness and may trip an orchestrator's inactivity
timeout. Accepted for clean per-attempt results.

## 12. Constraints & idempotency (documented)

- **Single global account**: parallel `ccs run` instances share one active
  account; when one rotates, all benefit. Sequential-rotation semantics, not
  parallel multi-account.
- **Idempotency warning**: a rate-limited attempt may have partially executed
  side-effecting tool calls (file edits, commits, MCP writes) before failing.
  Retry re-runs the command from the start, so **side effects can duplicate**.
  Retry-by-default is an intentional decision for the headless-orchestrator use
  case; the docs must warn prominently. The §5.3 pass-through and the narrowed
  grep scope (§5.1) keep the false-positive (retry a non-limit failure) window
  small.

## 13. Refactor — `_rotate_to_healthy_next_account()`

Extract the rotate+verify core of `cmd_rate_check`'s auto-switch loop into a
helper with a **three-way (four-value) contract**:

- `0` switched to a healthy account; `1` all accounts exhausted; `2` switch error;
  `3` lost race (from the `perform_switch` CAS).
- Contains only: pick next account, `perform_switch(next, expected_active)` in a
  **subshell with `rc=$?` capture** (pin 2), verify health (endpoint probe, or
  fresh usage `< threshold` with "can't fetch → assume healthy", preserving
  current semantics).
- **Stays caller-side in `cmd_rate_check`** (must be preserved verbatim):
  `capture_resume_session_id`, `_rate_hook_deny` messaging, the
  `"Switched to Account-N (email)"` echo, and `handle_restart_after_switch`
  (its CLI "switched" path is `exit 1` + restart). `cmd_rate_check` maps helper
  `2` → its existing exit-2 / fail-open paths.
- Acceptance gate: the existing rate-check bats tests stay green unchanged.

## 14. Implementation pins (binding — from review)

1. The `return 3` CAS path in `perform_switch` calls `release_switch_lock` first,
   like every other post-acquire early exit.
2. The helper runs `(CCS_SILENT=1 perform_switch "$next" "$expected")` in a
   subshell and captures `rc=$?` — **not** `if ! …` (which both lets
   `perform_switch`'s `exit 1` kill `ccs run` in-process and collapses the 1-vs-3
   distinction).
3. `expected_active` is re-read **before every spawn, inside the retry loop**
   (§6 step 0). A single pre-loop recording causes an infinite
   retry-without-rotating loop after the first successful rotation. **Review the
   implementation for this first.**
4. `started_account` / `expected_active` is the account **number** taken via
   `effective_active_account_num` (the endpoint-aware view `perform_switch`
   reconciles to), so the CAS compares like with like.

## 15. Testing

bats with a mock `claude` in `MOCK_BIN` that can: exit 1 printing a rate-limit
marker; exit 1 with a non-limit error; exit 0; consume stdin (and echo it back,
to assert replay); and sleep (for timeout/signal). Cases:

- rate-limit marker → rotate → succeed on the next account.
- non-limit failure → pass through, no switch.
- stdin replayed byte-identically across attempts (spool-first).
- only the successful attempt's stdout reaches the caller.
- all-exhausted → exit 3 + machine line.
- signal/timeout death → pass through (but grep-on-timeout match still rotates).
- `--max-attempts` bound honored.
- concurrency: active account changed out from under us → CAS returns 3 →
  retry-without-rotating (no backwards rotation, no infinite loop — pin 3).
- `_rotate_to_healthy_next_account` three-way/four-value contract in isolation.
- existing `cmd_rate_check` behavior and tests unchanged (restart/hook/resume
  paths preserved).

## 16. Follow-ups (non-blocking)

- Validate the §5.1 marker set against a **real rate-limited account** when one is
  available; the pattern list is intentionally easy to extend.
- Consider spooling stdin under the ccs config dir (stricter than `TMPDIR`) if
  prompt-on-disk sensitivity warrants it.
