#!/usr/bin/env bash
set -euo pipefail

# An explicit stop against a start that is still at work (UC-012).
#
# A start holds reload.lock for all of `forkop start`, and a stop waits for
# that lock only for a bounded time. Neither the start that holds the lock
# nor one that still waits for it may bring Forkop back after the stop: a
# failed start must not schedule its automatic retry, a retry must not run
# after a stop, a start requested before the stop must not run after it, and
# a start that outlives the stop's wait abandons its remaining phases.
#
# Part 1 runs the real init script behind an rc.common stand-in that holds
# fd 1000 like procd.sh (so start detaches its worker, as on a router) and
# the real service/initd.uc; `forkop` is a double. Part 2 runs the real
# service/lifecycle.uc start with every module it calls replaced by a double.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
REAL_UCODE="$(command -v ucode)"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  if [ -s "$WORK_DIR/syslog" ]; then
    sed 's/^/  syslog: /' "$WORK_DIR/syslog" >&2
  fi
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_forkop.lock"
export RELOAD_LOCK="$WORK_DIR/run/forkop.reload.lock"
export STATE_DIR="$WORK_DIR/run/forkop"
export STOP_MARKER="$STATE_DIR/stop.requested"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_START_RETRY_DELAY_SECONDS=300
export FORKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=20
export FORKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"

# `forkop` behind initd.uc. start can be held at a gate, exits with
# start.status and brings the modelled runtime up on success; stop records
# whether it runs inside reload.lock.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  start)
    ev "forkop start"
    while [ -e "$TEST_WORK/start.gate-armed" ] && [ ! -e "$TEST_WORK/start.gate" ]; do sleep 0.05; done
    status="$(cat "$TEST_WORK/start.status" 2>/dev/null || echo 0)"
    [ "$status" != 0 ] || : >"$TEST_WORK/runtime.up"
    ev "forkop start exit $status"
    exit "$status"
    ;;
  stop)
    owner="$(ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" runtime-dir-lock-owner "$RELOAD_LOCK" || true)"
    cmd=""
    [ -z "$owner" ] || cmd="$(tr '\0' ' ' <"/proc/$owner/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *"service/initd.uc stop-service"*) ev "forkop stop (locked)" ;;
      *) ev "forkop stop (unlocked)" ;;
    esac
    rm -f "$TEST_WORK/runtime.up"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/forkop as procd runs it: rc.common with fd 1000 open and
# flocked (procd.sh procd_lock); bash stands in for busybox ash.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
exec 1000>"$RC_PROCD_LOCK"
flock 1000
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@"; service_started ;;
  stop) stop_service "$@" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

initd() { "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" "$@"; }

has_event() { grep -qx "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q "$1" "$EVENTS" 2>/dev/null; }
before() {
  awk -v first="$1" -v second="$2" '
    $0 == first && !seen_second { seen_first = 1 }
    $0 == second { seen_second = 1 }
    END { exit seen_first && seen_second ? 0 : 1 }
  ' "$EVENTS"
}

# Actors run in their own process group under a hard deadline.
start_actor() {
  setsid timeout -s KILL 90 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

# The actor's process group polls a lock: initd.uc waits for reload.lock in
# `sleep 1` steps, and nothing else in these groups sleeps.
in_lock_wait() {
  pgrep -g "$1" -x sleep >/dev/null 2>&1
}

# The detached start worker of the actor's init.d start has finished (a retry
# it may have scheduled stays in the same process group).
start_worker_gone() {
  ! pgrep -g "$1" -f 'service/initd.uc start-service' >/dev/null 2>&1
}

finish() {
  local label="$1" pid="$2" status=0
  wait_until 60 process_gone "$pid" || fail "$label did not finish"
  wait "$pid" || status=$?
  [ "$status" = 0 ] || fail "$label failed with status $status"
}

# Some other work (a subscription update, say) holds reload.lock until the
# gate opens.
hold_reload_lock() {
  rm -f "$WORK_DIR/hold.gate"
  start_actor sh -c '
    ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" acquire-runtime-dir-lock "$RELOAD_LOCK" "$$" || exit 1
    : >"$TEST_WORK/hold.acquired"
    while [ ! -e "$TEST_WORK/hold.gate" ]; do sleep 0.05; done
    ucode -L "$TEST_LIB" "$TEST_LIB/service/state.uc" release-runtime-dir-lock "$RELOAD_LOCK" "$$"
  '
  HOLDER="$LAST_ACTOR"
  wait_until 10 test -e "$WORK_DIR/hold.acquired" || fail "the lock holder did not get reload.lock"
}

release_reload_lock() {
  : >"$WORK_DIR/hold.gate"
  wait_until 10 process_gone "$HOLDER" || fail "the lock holder did not finish"
  wait "$HOLDER" 2>/dev/null || true
}

launch_stop() {
  start_actor "$FORKOP_SERVICE_INIT" stop
  STOP_ACTOR="$LAST_ACTOR"
}

# A scheduled start retry, waiting out its delay: start-retry.pid records the
# worker (pid and start ticks) and start.retry marks the retry as pending.
fake_scheduled_retry() {
  local child
  initd schedule-start-retry "$STATE_DIR/start-retry.pid" 300 || fail "the start retry was not scheduled"
  RETRY_WORKER="$(head -n 1 "$STATE_DIR/start-retry.pid")"
  actors+=("$RETRY_WORKER")
  # Its sleep outlives a cancelled retry.
  wait_until 10 pgrep -P "$RETRY_WORKER" >/dev/null || fail "the scheduled retry did not start waiting"
  for child in $(pgrep -P "$RETRY_WORKER"); do actors+=("$child"); done
  printf 'reason=start_failed\n' >"$STATE_DIR/start.retry"
}

retry_scheduled() {
  local pid
  [ ! -e "$STATE_DIR/start.retry" ] || return 0
  pid="$(head -n 1 "$STATE_DIR/start-retry.pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && process_running "$pid"
}

reset_case() {
  local pid
  pid="$(head -n 1 "$STATE_DIR/start-retry.pid" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$WORK_DIR"/runtime.up "$WORK_DIR"/start.status "$WORK_DIR"/start.gate "$WORK_DIR"/start.gate-armed \
    "$WORK_DIR"/hold.gate "$WORK_DIR"/hold.acquired \
    "$STATE_DIR"/start.retry "$STATE_DIR"/start-retry.pid "$STOP_MARKER"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
}

# 1. The detached start holds reload.lock while an explicit stop waits for
#    it, and then fails: it schedules no retry, the stop runs after it under
#    the lock, and nothing starts Forkop after the stop.
reset_case
printf '1\n' >"$WORK_DIR/start.status"
: >"$WORK_DIR/start.gate-armed"
start_actor "$FORKOP_SERVICE_INIT" start
START_ACTOR="$LAST_ACTOR"
wait_until 10 has_event "forkop start" || fail "the detached start worker did not run forkop start"
[ -d "$RELOAD_LOCK" ] || fail "the start worker runs forkop start without reload.lock"
launch_stop
wait_until 10 in_lock_wait "$STOP_ACTOR" || fail "the stop did not wait for the start's reload.lock"
[ -s "$STOP_MARKER" ] || fail "the stop did not record the stop request before waiting"
: >"$WORK_DIR/start.gate"
finish "stop during a failing start" "$STOP_ACTOR"
wait_until 20 start_worker_gone "$START_ACTOR" || fail "the start worker did not finish"
before "forkop start exit 1" "forkop stop (locked)" || fail "the stop did not run after the start under reload.lock"
retry_scheduled && fail "a start that failed during an explicit stop scheduled its automatic retry"
grep -q 'scheduled an automatic retry' "$WORK_DIR/syslog" &&
  fail "a start that failed during an explicit stop announced an automatic retry"
grep -q 'stop was requested; no automatic retry' "$WORK_DIR/syslog" ||
  fail "the start did not log why it schedules no retry"
[ "$(grep -c '^forkop start$' "$EVENTS")" = 1 ] || fail "Forkop was started again after the explicit stop"
[ -e "$STOP_MARKER" ] || fail "the explicit stop is no longer recorded"

# 2. A start that still waits for reload.lock when the stop is requested does
#    not run: whichever of them gets the lock first, the stop wins.
reset_case
printf '0\n' >"$WORK_DIR/start.status"
hold_reload_lock
start_actor "$FORKOP_SERVICE_INIT" start
START_ACTOR="$LAST_ACTOR"
wait_until 10 in_lock_wait "$START_ACTOR" || fail "the detached start did not wait for reload.lock"
launch_stop
wait_until 10 in_lock_wait "$STOP_ACTOR" || fail "the stop did not wait for reload.lock"
release_reload_lock
finish "stop requested after a waiting start" "$STOP_ACTOR"
wait_until 60 start_worker_gone "$START_ACTOR" || fail "the start worker did not finish"
no_event '^forkop start' || fail "a start requested before the explicit stop ran after it"
[ ! -e "$WORK_DIR/runtime.up" ] || fail "Forkop runs after the explicit stop"
has_event "forkop stop (locked)" || fail "the stop did not run under reload.lock"
grep -q 'start skipped: a stop was requested after it' "$WORK_DIR/syslog" ||
  fail "the skipped start was not logged"
retry_scheduled && fail "a start skipped for an explicit stop scheduled a retry"

# 2b. Control: a start requested after an earlier stop does run, and ends the
#     explicit stop.
reset_case
printf '0\n' >"$WORK_DIR/start.status"
printf 'earlier\n' >"$STOP_MARKER"
hold_reload_lock
start_actor "$FORKOP_SERVICE_INIT" start
START_ACTOR="$LAST_ACTOR"
wait_until 10 in_lock_wait "$START_ACTOR" || fail "the detached start did not wait for reload.lock"
release_reload_lock
wait_until 30 start_worker_gone "$START_ACTOR" || fail "the start worker did not finish"
has_event "forkop start exit 0" || fail "a start after an earlier stop did not run"
[ ! -e "$STOP_MARKER" ] || fail "a start after an earlier stop kept the explicit stop"

# 3. A retry that a failed start scheduled while the stop waited for
#    reload.lock is cancelled before the stop tears the runtime down.
reset_case
hold_reload_lock
launch_stop
wait_until 10 in_lock_wait "$STOP_ACTOR" || fail "the stop did not wait for reload.lock"
fake_scheduled_retry
release_reload_lock
finish "stop with a retry scheduled meanwhile" "$STOP_ACTOR"
wait_until 10 process_gone "$RETRY_WORKER" || fail "the stop left the retry scheduled meanwhile running"
[ ! -e "$STATE_DIR/start.retry" ] || fail "the stop left the retry scheduled meanwhile pending"

# 4. The WAN-up retry after an explicit stop does not start Forkop, and the
#    WAN-up handler cancels the scheduled retry.
reset_case
printf '1\n' >"$STOP_MARKER"
printf 'reason=start_failed\n' >"$STATE_DIR/start.retry"
initd retry-start-on-wan-up >/dev/null 2>&1 || fail "the WAN-up retry after a stop failed"
no_event '^forkop start' || fail "the WAN-up retry started Forkop after an explicit stop"
[ ! -e "$STATE_DIR/start.retry" ] || fail "the WAN-up retry after a stop stayed pending"
grep -q 'retry skipped: Forkop was stopped' "$WORK_DIR/syslog" || fail "the skipped WAN-up retry was not logged"
reset_case
printf '1\n' >"$STOP_MARKER"
fake_scheduled_retry
initd handle-wan-up >/dev/null 2>&1 || fail "WAN-up after a stop failed"
wait_until 10 process_gone "$RETRY_WORKER" || fail "WAN-up after a stop kept the scheduled retry"
[ ! -e "$STATE_DIR/start.retry" ] || fail "WAN-up after a stop kept the retry pending"
no_event '^forkop start' || fail "WAN-up started Forkop after an explicit stop"
# The retry's own start (reason "triggered") does not run once a stop was
# requested, even if the stop came after the retry's check.
reset_case
printf '0\n' >"$WORK_DIR/start.status"
printf '1\n' >"$STOP_MARKER"
initd start-service triggered >/dev/null 2>&1 && fail "the retry's start after an explicit stop succeeded"
no_event '^forkop start' || fail "the retry's start ran after an explicit stop"
[ -e "$STOP_MARKER" ] || fail "the retry's start ended the explicit stop"
# A retry's start that fails because a stop was requested while it ran is
# not a failed recovery.
reset_case
printf '1\n' >"$WORK_DIR/start.status"
: >"$WORK_DIR/start.gate-armed"
start_actor sh -c 'exec "$0" -L "$1" "$1/service/initd.uc" start-service triggered >/dev/null 2>&1' "$REAL_UCODE" "$LIB"
RETRY_START_ACTOR="$LAST_ACTOR"
wait_until 10 has_event "forkop start" || fail "the retry's start did not run forkop start"
printf 'stop\n' >"$STOP_MARKER"
: >"$WORK_DIR/start.gate"
wait_until 20 process_gone "$RETRY_START_ACTOR" || fail "the retry's start did not finish"
grep -q 'automatic recovery attempt failed' "$WORK_DIR/syslog" &&
  fail "a retry's start overtaken by an explicit stop was logged as a failed recovery"
retry_scheduled && fail "a retry's start overtaken by an explicit stop scheduled another retry"
# The same retry's start skipped for an earlier stop.
reset_case
printf '1\n' >"$STOP_MARKER"
initd start-service triggered >/dev/null 2>&1 || true
grep -q 'automatic recovery attempt failed' "$WORK_DIR/syslog" &&
  fail "a retry's start skipped for an explicit stop was logged as a failed recovery"
[ "$(initd retry-start-on-wan-up-action 0 1 1 1)" = skip_stopped ] ||
  fail "the retry decision ignores an explicit stop"
[ "$(initd wan-up-action 0 1 1 0 1)" = skip_stopped ] || fail "the WAN-up decision ignores an explicit stop"
[ "$(initd retry-start-on-wan-up-action 0 1 1)" = start ] || fail "the retry decision changed without a stop"

# Part 2. The real lifecycle start abandons its remaining phases once a stop
# was requested during it: before the nftables policy is applied (after the
# network I/O of the caches) and before sing-box is started.
FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$FAKE_LIB"
printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=1\n' >"$WORK_DIR/uci.state"

# Every module the start calls: records "<module> <mode>", can be held at a
# gate, and succeeds unless it is FAKE_FAIL. Locks go to the real
# service/state.uc.
fake_module() {
  mkdir -p "$(dirname "$FAKE_LIB/$1")"
  cat >"$FAKE_LIB/$1" <<UC
let fs = require("fs");
function q(value) { return "'" + replace("" + value, /'/g, "'\\\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
let name = "$1";
if (name == "service/state.uc" && index(mode, "runtime-dir-lock") >= 0) {
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
// A health record carries its outcome.
if (name == "diagnostics/health.uc")
    mode = join(" ", ARGV);
system("printf '%s\\\\n' " + q(name + " " + mode) + " >> " + q(getenv("EVENTS")));
let gate = getenv("FAKE_GATE") || "";
if (gate != "" && gate == name + " " + mode) {
    system("printf '%s\\\\n' " + q("held " + gate) + " >> " + q(getenv("EVENTS")));
    for (let n = 0; fs.stat(getenv("TEST_WORK") + "/fake.gate") == null && n < 1200; n++)
        system("sleep 0.05");
}
if ((getenv("FAKE_FAIL") || "") == name + " " + mode)
    exit(1);
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "forkop-stably-running" ||
    mode == "sing-box-process-conflict" || mode == "forkop-running"))
    exit(1);
exit(0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc singbox/generator.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc service/lifecycle.uc; do
  fake_module "$module"
done

run_lifecycle_start() {
  start_actor env FORKOP_LIB="$FAKE_LIB" FAKE_GATE="$1" FAKE_FAIL="${FAKE_FAIL:-}" \
    ucode -L "$LIB" "$LIB/service/lifecycle.uc" start
  LIFECYCLE_ACTOR="$LAST_ACTOR"
}

lifecycle_start_status() {
  local status=0
  wait_until 60 process_gone "$LIFECYCLE_ACTOR" || fail "the lifecycle start did not finish"
  wait "$LIFECYCLE_ACTOR" || status=$?
  printf '%s\n' "$status"
}

# 5. A stop requested while the start prepares the subscription caches.
reset_case
rm -f "$WORK_DIR/fake.gate"
run_lifecycle_start "subscription/cache.uc prepare-caches"
wait_until 20 has_event "held subscription/cache.uc prepare-caches" ||
  fail "the lifecycle start did not reach its subscription caches"
printf 'stop\n' >"$STOP_MARKER"
: >"$WORK_DIR/fake.gate"
[ "$(lifecycle_start_status)" != 0 ] || fail "a start abandoned for a stop reported success"
no_event '^nft/apply.uc nft-rebuild-runtime' || fail "the start built the nftables policy after a stop request"
no_event '^service/state.uc start-managed-sing-box-runtime' || fail "the start started sing-box after a stop request"
grep -q 'start abandoned before the nftables policy' "$WORK_DIR/syslog" || fail "the abandoned start was not logged"
no_event '^diagnostics/health.uc record start failure' || fail "a start abandoned for a stop was recorded as a failed start"

# 6. A stop requested once the nftables policy is in place, before sing-box.
reset_case
rm -f "$WORK_DIR/fake.gate"
run_lifecycle_start "singbox/runtime.uc init-config"
wait_until 20 has_event "held singbox/runtime.uc init-config" ||
  fail "the lifecycle start did not reach the sing-box configuration"
printf 'stop\n' >"$STOP_MARKER"
: >"$WORK_DIR/fake.gate"
[ "$(lifecycle_start_status)" != 0 ] || fail "a start abandoned for a stop reported success"
has_event "nft/apply.uc nft-rebuild-runtime-from-uci" || fail "the start did not reach the nftables policy"
no_event '^service/state.uc start-managed-sing-box-runtime' || fail "the start started sing-box after a stop request"
no_event '^singbox/priority.uc start-runtime' || fail "the start started Priority after a stop request"
has_event "service/state.uc stop-managed-sing-box-runtime" || fail "the abandoned start did not clean up its runtime"
grep -q 'start abandoned before sing-box' "$WORK_DIR/syslog" || fail "the abandoned start was not logged"
no_event '^diagnostics/health.uc record start failure' || fail "a start abandoned for a stop was recorded as a failed start"

# 6b. A stop requested once sing-box runs: providers start before the deferred
#     subscription bootstrap so provider-routed downloads have a live target.
#     Once Stop wins, no later provider, bootstrap, DNS, or background work may
#     start, and the runtime started so far is cleaned up.
for gate in "subscription/cache.uc run-deferred-bootstrap" "providers/zapret2/runtime.uc start-runtime" \
  "service/state.uc write-current-reload-state-clean"; do
  reset_case
  rm -f "$WORK_DIR/fake.gate"
  run_lifecycle_start "$gate"
  wait_until 20 has_event "held $gate" || fail "the lifecycle start did not reach $gate"
  printf 'stop\n' >"$STOP_MARKER"
  printf '%s\n' "-- stop requested" >>"$EVENTS"
  : >"$WORK_DIR/fake.gate"
  [ "$(lifecycle_start_status)" != 0 ] || fail "a start overtaken by a stop at $gate reported success"
  has_event "service/state.uc start-managed-sing-box-runtime" || fail "the start did not reach sing-box before $gate"
  after_stop="$(sed -n '/^-- stop requested$/,$p' "$EVENTS")"
  for step in "providers/zapret/runtime.uc start-runtime" "providers/zapret2/runtime.uc start-runtime" \
    "dns/apply.uc configure" "dns/apply.uc restore" "singbox/dns_failover.uc start-runtime" \
    "components/updates.uc list-update-after-start" "service/lifecycle.uc refresh-rulesets-after-start" \
    "diagnostics/runtime.uc automatic-latency-test"; do
    if printf '%s\n' "$after_stop" | grep -q "^$step"; then
      fail "a start overtaken by a stop at $gate still ran $step"
    fi
  done
  printf '%s\n' "$after_stop" | grep -q '^service/state.uc stop-managed-sing-box-runtime' ||
    fail "a start overtaken by a stop at $gate did not stop the sing-box it started"
  grep -q 'start abandoned before' "$WORK_DIR/syslog" || fail "the start abandoned at $gate was not logged"
  no_event '^diagnostics/health.uc record start failure' ||
    fail "a start abandoned for a stop at $gate was recorded as a failed start"
done

# 6c. Control: a start that fails without a stop request is recorded as a
#     failed start.
reset_case
rm -f "$WORK_DIR/fake.gate"
FAKE_FAIL="subscription/cache.uc run-deferred-bootstrap"
run_lifecycle_start ""
FAKE_FAIL=""
[ "$(lifecycle_start_status)" != 0 ] || fail "a failing start reported success"
has_event "diagnostics/health.uc record start failure" || fail "a failed start without a stop request was not recorded"

# A configured provider must be running before deferred subscription work.
# Provider startup failure aborts instead of letting a protected download time
# out or fall back through another route.
reset_case
rm -f "$WORK_DIR/fake.gate"
FAKE_FAIL="providers/zapret/runtime.uc start-runtime"
run_lifecycle_start ""
FAKE_FAIL=""
[ "$(lifecycle_start_status)" != 0 ] || fail "a failed Zapret start was accepted"
no_event '^subscription/cache.uc run-deferred-bootstrap' ||
  fail "deferred subscriptions ran after Zapret failed to start"
has_event "diagnostics/health.uc record start failure" ||
  fail "a provider startup failure was not recorded"

# 7. Control: without a stop request the same start reaches sing-box, and an
#    earlier stop request does not hold it back.
reset_case
rm -f "$WORK_DIR/fake.gate"
printf 'earlier\n' >"$STOP_MARKER"
run_lifecycle_start ""
lifecycle_start_status >/dev/null
has_event "service/state.uc start-managed-sing-box-runtime" || fail "a start without a stop request did not start sing-box"
for step in "providers/zapret/runtime.uc start-runtime" "providers/zapret2/runtime.uc start-runtime" \
  "dns/apply.uc restore" "singbox/dns_failover.uc start-runtime"; do
  has_event "$step" || fail "a start without a stop request did not run $step"
done
before "providers/zapret/runtime.uc start-runtime" "subscription/cache.uc run-deferred-bootstrap" ||
  fail "Zapret must start before deferred subscriptions"
before "providers/zapret2/runtime.uc start-runtime" "subscription/cache.uc run-deferred-bootstrap" ||
  fail "Zapret2 must start before deferred subscriptions"
wait_until 20 has_event "service/lifecycle.uc refresh-rulesets-after-start" ||
  fail "a start without a stop request did not start its background workers"
has_event "diagnostics/health.uc record start success" || fail "a start without a stop request was not recorded"
[ ! -e "$STOP_MARKER" ] || fail "a start kept an earlier explicit stop"

printf 'stop during start checks passed\n'
