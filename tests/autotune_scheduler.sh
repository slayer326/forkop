#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.4: scheduled and background autotune runs. The Stage 3-5 tools are
# replaced by stand-ins (tests/helpers/autotune_scheduler) so the scheduler
# itself is under test: groups in turn, hysteresis across runs, blockers,
# the worker lock, interruption, merging with concurrent target edits,
# background jobs and the cron line. Nothing is ever applied here.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/autotune_scheduler/setup.sh
source "$ROOT_DIR/tests/helpers/autotune_scheduler/setup.sh"
# shellcheck source=tests/helpers/wait.sh
source "$ROOT_DIR/tests/helpers/wait.sh"
WORKER_LOCK="$FORKOP_AUTOTUNE_STATE_DIR/worker.lock"
worker_lock_free() { ! lock_held "$WORKER_LOCK"; }
# job_state_is JOB STATE FILE: run-status of JOB, saved to FILE, reports STATE.
job_state_is() { manager run-status "$1" >"$3" && [ "$(json_get "$3" job.state)" = "\"$2\"" ]; }

# ---- groups as the scheduler sees them -------------------------------------
manager groups >"$WORK/groups.json"
[ "$(json_get "$WORK/groups.json" groups.youtube.targets)" = '["yt","ytimg"]' ] || fail "youtube group: $(cat "$WORK/groups.json")"
[ "$(json_get "$WORK/groups.json" groups.discord.targets)" = '["dc"]' ] || fail "discord group: $(cat "$WORK/groups.json")"

# ---- mode off: nothing runs ------------------------------------------------
manager if-due >"$WORK/off.json"
[ "$(json_get "$WORK/off.json" reason)" = '"mode_off"' ] || fail "mode off must skip: $(cat "$WORK/off.json")"
[ -z "$(calls)" ] || fail "mode off must not tune"

# ---- cron line follows the mode --------------------------------------------
manager policy-set mode recommend >"$WORK/mode.json"
[ "$(json_get "$WORK/mode.json" cron)" = '"ok"' ] || fail "mode change must sync cron: $(cat "$WORK/mode.json")"
grep -Fxq '*/15 * * * * /usr/bin/forkop autotune_if_due >/dev/null 2>&1 # forkop-autotune' "$WORK/crontab" || fail "cron line missing: $(cat "$WORK/crontab")"
grep -Fxq '0 3 * * * /usr/bin/other-job' "$WORK/crontab" || fail "other cron jobs must stay"
grep -Fxq '# forkop-list-update line stays' "$WORK/crontab" || fail "other Forkop cron jobs must stay"
manager cron-sync >"$WORK/cron-again.json"
[ "$(json_get "$WORK/cron-again.json" changed)" = 'false' ] || fail "an unchanged crontab is not rewritten"
[ "$(grep -c forkop-autotune "$WORK/crontab")" = 1 ] || fail "one cron line only"

# ---- scheduled runs: one group in turn -------------------------------------
before="$(date +%s)"
manager if-due >"$WORK/run1.json"
[ "$(json_get "$WORK/run1.json" result)" = '"completed"' ] || fail "first run: $(cat "$WORK/run1.json")"
[ "$(json_get "$WORK/run1.json" trigger)" = '"schedule"' ] || fail "scheduled trigger"
[ "$(calls)" = 'discord.com ' ] || fail "first scheduled run tunes the first group only: $(calls)"
[ "$(json_get "$WORK/run1.json" groups.discord.events.0.event)" = '"started"' ] || fail "hysteresis started: $(cat "$WORK/run1.json")"
next="$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" next_run_at)"
[ "$next" -ge $((before + 21600)) ] && [ "$next" -le $(( $(date +%s) + 21600 )) ] || fail "next run after the interval: $next"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" rotation)" = 1 ] || fail "rotation advances"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" worker.result)" = '"completed"' ] || fail "worker record"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.dc.selected)" = '"multisplit"' ] || fail "summary recorded"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.dc.group)" = '"discord"' ] || fail "summary knows its group"
[ -s "$WORK/run/last/dc.json" ] || fail "full output kept in tmpfs"

reset_calls
manager if-due >"$WORK/not-due.json"
[ "$(json_get "$WORK/not-due.json" reason)" = '"not_due"' ] || fail "not due: $(cat "$WORK/not-due.json")"
[ -z "$(calls)" ] || fail "a run that is not due does not tune"

make_due
manager if-due >"$WORK/run2.json"
[ "$(calls)" = 'www.youtube.com i.ytimg.com ' ] || fail "second scheduled run tunes the next group: $(calls)"
grep -q '^tune www.youtube.com max:5 192.0.2.53$' "$WORK/tune/calls.log" || fail "the policy probe count (an upper bound) and the resolver are passed: $(cat "$WORK/tune/calls.log")"
grep -q '^tune i.ytimg.com max:5 192.0.2.1$' "$WORK/tune/calls.log" || fail "the first plain IPv4 Forkop DNS server otherwise"
[ "$(json_get "$WORK/run2.json" groups.youtube.result.status)" = '"recommendation"' ] || fail "youtube recommendation"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = 'false' ] || fail "one run is not enough"

# ---- manual run: hysteresis confirms --------------------------------------
reset_calls
manager run youtube >"$WORK/manual.json"
[ "$(calls)" = 'www.youtube.com i.ytimg.com ' ] || fail "manual run of one group"
[ "$(json_get "$WORK/manual.json" groups.youtube.events.0.event)" = '"ready"' ] || fail "second agreeing run is ready: $(cat "$WORK/manual.json")"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.ready)" = 'true' ] || fail "ready stored"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.youtube.pending.count)" = 2 ] || fail "count stored"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" rotation)" = 2 ] || fail "manual runs do not move the rotation"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" next_run_at)" -gt "$(date +%s)" ] || fail "manual runs do not move the schedule"
manager run all >"$WORK/all.json"
node -e 'const r=require(process.argv[1]); if (JSON.stringify(Object.keys(r.groups))!==JSON.stringify(["discord","youtube"])) process.exit(1)' "$WORK/all.json" || fail "run all: $(cat "$WORK/all.json")"
if manager run nosuch >"$WORK/unknown.json"; then fail "an unknown group must fail"; fi
[ "$(json_get "$WORK/unknown.json" reason)" = '"unknown_group"' ] || fail "unknown group reason"
if manager run 'a b' >"$WORK/invalid.json"; then fail "an invalid scope must fail"; fi
[ "$(json_get "$WORK/invalid.json" reason)" = '"invalid_scope"' ] || fail "invalid scope reason"

# ---- blockers: nothing is measured, the run is retried later ---------------
for case in guard snapshot service unresolved lock; do
  case "$case" in
    guard) body='{"state":null,"guards":["ForkopConfigRestoreDpiGuard"]}'; want=dpi_guard_present ;;
    snapshot) body='{"state":null,"guards":[],"snapshot_operation":true}'; want=snapshot_operation_active ;;
    service) body='{"state":null,"guards":[],"service_action":"reload_pending"}'; want=reload_pending ;;
    unresolved) body='{"state":{"phase":"applying"},"guards":[],"resolved":false}'; want=apply_unresolved ;;
    lock) body='{"state":null,"guards":[],"autotune_lock_held":true}'; want=autotune_in_progress ;;
  esac
  printf '%s\n' "$body" >"$STUB_APPLY_STATUS"
  make_due; reset_calls
  manager if-due >"$WORK/blocked-$case.json"
  [ "$(json_get "$WORK/blocked-$case.json" result)" = '"skipped"' ] || fail "$case must skip: $(cat "$WORK/blocked-$case.json")"
  [ "$(json_get "$WORK/blocked-$case.json" reason)" = "\"$want\"" ] || fail "$case reason: $(cat "$WORK/blocked-$case.json")"
  [ -z "$(calls)" ] || fail "$case: nothing is tuned"
  next="$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" next_run_at)"
  [ "$next" -le $(( $(date +%s) + 900 )) ] && [ "$next" -gt $(( $(date +%s) + 800 )) ] || fail "$case: retried after 15 minutes ($next)"
  [ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" rotation)" = 2 ] || fail "$case: the group keeps its turn"
done
rm -f "$STUB_APPLY_STATUS"
printf 'not json\n' >"$STUB_APPLY_STATUS"
make_due; manager if-due >"$WORK/blocked-invalid.json"
[ "$(json_get "$WORK/blocked-invalid.json" reason)" = '"apply_status_unavailable"' ] || fail "unreadable apply status blocks"
rm -f "$STUB_APPLY_STATUS"

# ---- no resolver: the target is not measured; cached results never confirm --
cp "$WORK/config/forkop" "$WORK/config.dns"
sed -i "/list dns_server/d" "$WORK/config/forkop"
printf '{"status":"inconclusive","reason":"all_failed","target":{"host":"www.youtube.com"},"candidates":[]}\n' >"$WORK/tune/www.youtube.com.json"
reset_calls
manager run youtube >"$WORK/no-resolver.json"
[ "$(calls)" = 'www.youtube.com ' ] || fail "a target without a resolver is not tuned: $(calls)"
[ "$(json_get "$WORK/no-resolver.json" unmeasured)" = '[{"id":"ytimg","reason":"resolver_missing"}]' ] || fail "unmeasured: $(cat "$WORK/no-resolver.json")"
[ "$(json_get "$WORK/no-resolver.json" groups.youtube.result.status)" = '"inconclusive"' ] ||
  fail "the cached result of ytimg must not count: $(cat "$WORK/no-resolver.json")"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.ytimg.selected)" = '"fake"' ] || fail "the cached result is kept for display"
cp "$WORK/config.dns" "$WORK/config/forkop"
selected www.youtube.com fake high

# ---- a busy tune records nothing and stops the run -------------------------
printf '{"status":"busy","reason":"autotune_in_progress"}\n' >"$WORK/tune/discord.com.json"
dc_before="$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.dc.at)"
make_due; reset_calls
manager if-due >"$WORK/busy.json"
[ "$(json_get "$WORK/busy.json" reason)" = '"autotune_in_progress"' ] || fail "busy tune: $(cat "$WORK/busy.json")"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.dc.at)" = "$dc_before" ] || fail "a busy tune keeps the cached result"
selected discord.com multisplit high

# ---- the worker lock ------------------------------------------------------
# The holder is one process (the lock stays with fd 9 across exec), so killing
# it releases the lock; wait until it is really held instead of a fixed delay.
( flock 9 && exec sleep 60 ) 9>>"$WORKER_LOCK" &
lock_holder=$!
BG_PIDS+=("$lock_holder")
wait_until 30 lock_held "$WORKER_LOCK" || fail "the worker lock holder did not take the lock"
if manager run all >"$WORK/locked.json"; then fail "a second worker must be refused"; fi
[ "$(json_get "$WORK/locked.json" reason)" = '"autotune_worker_running"' ] || fail "worker lock: $(cat "$WORK/locked.json")"
if manager run-async all >"$WORK/locked-async.json"; then fail "a job must not start while a worker runs"; fi
kill "$lock_holder"
wait "$lock_holder" || true
wait_until 30 worker_lock_free || fail "the worker lock was not released"

# ---- a target edited during the run keeps the edit -------------------------
printf '%s\n' "FORKOP_LIB='$LIB' ucode -L '$LIB' '$LIB/autotune/manager.uc' target-set ytimg img.youtube.com >/dev/null" >"$WORK/tune/www.youtube.com.hook"
manager run youtube >"$WORK/edited.json"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.ytimg)" = 'null' ] || fail "a result for the old host must not be stored: $(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.ytimg)"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.yt.selected)" = '"fake"' ] || fail "other results are stored"
grep -q "option host 'img.youtube.com'" "$WORK/config/forkop" || fail "the edit stays"
manager target-set ytimg i.ytimg.com >/dev/null

# ---- a removed target is pruned, groups of existing rules stay -----------
manager target-remove dc >/dev/null
manager run youtube >/dev/null
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.dc)" = 'null' ] || fail "removed target pruned"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.discord.fingerprint)" != 'null' ] || fail "a group of an existing rule is kept"
cp "$WORK/config/forkop" "$WORK/config.keep"
sed -i "/option label 'Discord'/a\\\toption enabled '0'" "$WORK/config/forkop"
grep -q "option enabled '0'" "$WORK/config/forkop" || fail "fixture: rule not disabled"
manager run youtube >/dev/null
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.discord.fingerprint)" != 'null' ] || fail "a disabled rule keeps its group"
awk '/^config section .discord./{skip=1;next} /^config /{skip=0} !skip' "$WORK/config.keep" >"$WORK/config/forkop"
manager run youtube >/dev/null
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" groups.discord)" = 'null' ] || fail "a deleted rule loses its group"
cp "$WORK/config.keep" "$WORK/config/forkop"
manager target-set dc discord.com >/dev/null

# ---- interruption: the current target finishes, the run stops -------------
reset_calls
STUB_TUNE_SLEEP=1 ucode -L "$LIB" "$LIB/autotune/manager.uc" run all >"$WORK/interrupted.json" &
run_pid=$!
for _ in $(seq 50); do [ -s "$WORK/tune/calls.log" ] && break; sleep 0.1; done
kill -TERM "$run_pid"
wait "$run_pid" || true
[ "$(json_get "$WORK/interrupted.json" result)" = '"interrupted"' ] || fail "interrupted run: $(cat "$WORK/interrupted.json")"
[ "$(calls)" = 'discord.com ' ] || fail "no target after the stop request: $(calls)"
[ "$(json_get "$WORK/interrupted.json" tuned)" = '["dc"]' ] || fail "the current target completes: $(cat "$WORK/interrupted.json")"

# ---- background jobs --------------------------------------------------------
STUB_TUNE_SLEEP=1 manager run-async youtube >"$WORK/job.json"
job="$(node -e 'console.log(require(process.argv[1]).job)' "$WORK/job.json")"
[[ "$job" =~ ^[0-9]+_[0-9]+$ ]] || fail "job id: $(cat "$WORK/job.json")"
wait_until 30 job_state_is "$job" running "$WORK/job-status.json" || fail "job running: $(cat "$WORK/job-status.json")"
# While it runs the status shows every target of the run, the one measured
# now and the phase of its tune.
running_target() { manager status >"$WORK/progress.json" && node -e 'const w=require(process.argv[1]).worker; if (!w.progress || !w.progress.items.some((i) => i.state === "running")) process.exit(1)' "$WORK/progress.json"; }
wait_until 30 running_target || fail "progress while running: $(cat "$WORK/progress.json")"
node -e 'const w=require(process.argv[1]).worker, a=require("node:assert/strict");
  a.equal(w.progress.total, 2); a.deepEqual(w.progress.items.map((i) => i.host), ["www.youtube.com", "i.ytimg.com"]);
  a.ok(w.progress.items.every((i) => i.expected_s > 0)); a.deepEqual(w.tune, { phase: "measuring", done: 3, total: 8 });' "$WORK/progress.json" ||
  fail "run progress: $(cat "$WORK/progress.json")"
if manager run-async all >"$WORK/job-busy.json"; then fail "one job at a time"; fi
[ "$(json_get "$WORK/job-busy.json" reason)" = '"autotune_worker_running"' ] || fail "busy job reason"
wait_until 60 job_state_is "$job" finished "$WORK/job-status.json" || fail "job finished: $(cat "$WORK/job-status.json")"
[ "$(json_get "$WORK/job-status.json" job.result.result)" = '"completed"' ] || fail "job result"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" worker.trigger)" = '"manual"' ] || fail "job runs are manual"
[ ! -e "$FORKOP_AUTOTUNE_STATE_DIR/run-progress.json" ] || fail "the progress is removed when the run ends"
[ "$(json_get "$FORKOP_AUTOTUNE_STATE_FILE" targets.yt.duration_s)" != null ] || fail "the tune duration is kept for the next estimate"

STUB_TUNE_SLEEP=3 manager run-async youtube >"$WORK/job2.json"
job2="$(node -e 'console.log(require(process.argv[1]).job)' "$WORK/job2.json")"
wait_until 30 job_state_is "$job2" running "$WORK/job2-status.json" || fail "job2 running: $(cat "$WORK/job2-status.json")"
worker_pid="$(json_get "$WORK/job2-status.json" job.pid | tr -d '"')"
kill -9 "$worker_pid"
wait_until 30 job_state_is "$job2" lost "$WORK/job2-lost.json" ||
  fail "a killed job is reported lost: $(cat "$WORK/job2-lost.json")"
if manager run-status '../x' >"$WORK/job-bad.json"; then fail "invalid job ids are refused"; fi
if manager run-status 1_1 >"$WORK/job-missing.json"; then fail "unknown jobs are refused"; fi
[ "$(json_get "$WORK/job-missing.json" reason)" = '"unknown_job"' ] || fail "unknown job reason"

for i in $(seq 12); do printf '{"id":"%s","state":"finished"}\n' "1_$i" >"$FORKOP_AUTOTUNE_STATE_DIR/jobs/1_$i.json"; done
# The killed worker's tune stand-in keeps the inherited lock until its sleep ends.
wait_until 30 worker_lock_free || fail "the killed job's worker lock was not released"
manager run-async youtube >/dev/null
[ "$(find "$FORKOP_AUTOTUNE_STATE_DIR/jobs" -name '*.json' | wc -l)" -le 10 ] || fail "old jobs are pruned"
wait_until 30 worker_lock_free || fail "the pruning job did not finish"

# ---- mode off removes the cron line ----------------------------------------
manager policy-set mode off >/dev/null
if grep -q forkop-autotune "$WORK/crontab"; then fail "mode off removes the cron line"; fi
grep -Fxq '0 3 * * * /usr/bin/other-job' "$WORK/crontab" || fail "other cron jobs stay after removal"
manager policy-set mode recommend >/dev/null
manager cron-remove >/dev/null
if grep -q forkop-autotune "$WORK/crontab"; then fail "cron-remove removes the cron line"; fi

# ---- no raw strategies in anything the scheduler writes -------------------
if grep -R -E 'dpi-desync|nfqws_opt' "$FORKOP_AUTOTUNE_STATE_FILE" "$FORKOP_AUTOTUNE_STATE_DIR/jobs" >/dev/null; then
  fail "raw strategies must not reach the state or job files"
fi
[ "$(stat -c %a "$FORKOP_AUTOTUNE_STATE_FILE")" = 600 ] || fail "state file mode"

echo "autotune scheduler: OK"
