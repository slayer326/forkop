#!/usr/bin/env bash
set -euo pipefail

# Waiting for the deferred subscription bootstrap retry must not hold
# reload.lock (UC-057 class, found by the S3 regression).
#
# The retry (subscription/cache.uc deferred-bootstrap-worker) is the only
# process that downloads under subscription-update.lock without reload.lock:
# it fetches the deferred rules through the sing-box service proxy under it,
# for as long as those requests take. Global lock order (service/state.uc):
# reload.lock before subscription-update.lock. A forced subscription update
# that took reload.lock and then waited (up to 300 s) for the retry, or a
# start whose start_main waited for it inside the reload.lock of init.d, held
# reload.lock all that time: a DNS failover switch (it gives reload.lock 2 s)
# was refused, every reload only queued, a restore and an autotune apply were
# refused as busy.
#
# 1. The retry holds its lock for 20 s when a forced update comes: the update
#    waits for it without reload.lock, a DNS failover switch applies
#    meanwhile, and the update then takes both locks in order and completes.
# 2. A start supersedes the retry (it prepares the caches and retries the
#    deferred rules itself): it stops the retry by its identity instead of
#    waiting for its download.
# 3. All three at once: the retry downloads, a forced update waits for it and
#    a start comes through init.d. Nobody deadlocks, and the update never
#    waits for one lock while it holds the other.
# 4. The retry lets go of its lock only as the update's wait for it runs out:
#    the update still tries the free reload.lock once and completes instead of
#    giving up as if a reload held it.
#
# The update is the real components/updates.uc, the switch the real
# service/lifecycle.uc dns-failover-apply, the start the real init.d
# start_service, service/initd.uc and service/lifecycle.uc start. The
# modules they call are doubles, but every lock goes to the real
# service/state.uc (core/runtime_lock.uc), and the retry is stopped by the
# real subscription/cache.uc (core/process_identity.uc). The retry itself is a
# double that runs under the retry's production command line.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
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
  exit 1
}

FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$FAKE_LIB"
cat >"$WORK_DIR/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=1
EOF

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_LIB REAL_INITD FAKE_LIB
export RELOAD_LOCK="$WORK_DIR/run/forkop.reload.lock"
export SUB_LOCK="$WORK_DIR/run/forkop/subscription-update.lock"
export WORKER_PID_FILE="$WORK_DIR/run/forkop/subscription-bootstrap-retry.pid"
export FORKOP_LIB="$FAKE_LIB"
export FORKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$SUB_LOCK"
export FORKOP_SUBSCRIPTION_BOOTSTRAP_RETRY_PID_FILE="$WORKER_PID_FILE"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/forkop/reload.pending"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
export FORKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"

# `forkop start` behind initd.uc, which holds reload.lock around it: the real
# lifecycle start on the doubles.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  start)
    ev "S start begin"
    status=0
    FORKOP_LIB="$FAKE_LIB" ACTOR=S ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" start >"$TEST_WORK/lifecycle.out" 2>&1 || status=$?
    ev "S start end $status"
    exit "$status"
    ;;
  get_status) printf '{"running":false}\n' ;;
esac
exit 0
SH

# rc.common stand-in: sources the real init script and runs its handler (no
# procd lock on fd 1000: the start runs in this shell).
cat >"$WORK_DIR/rc" <<'SH'
#!/bin/sh
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$REAL_LIB"
FORKOP_INITD_UC="$REAL_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

# Every module the update, the switch and the start call. Each call is
# recorded as "<actor> <module> <mode>". Lock calls go to the real
# service/state.uc and are recorded around it, so the test sees who held
# which lock when. The retry double takes subscription-update.lock under its
# own pid, records itself as the retry is recorded, and holds the lock for at
# least HOLD_SECONDS and until worker.gate exists; it is stopped by the real
# subscription/cache.uc.
cat >"$WORK_DIR/fake-module.uc" <<'UC'
let fs = require("fs");
function q(value) { return "'" + replace("" + value, /'/g, "'\\''") + "'"; }
function ev(line) { system("printf '%s\\n' " + q(line) + " >> " + q(getenv("EVENTS"))); }
function real(module, args) {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/" + module);
    for (let arg in args)
        command += " " + q(arg);
    return system(command);
}
let name = "@NAME@";
let actor = getenv("ACTOR") || "?";
let mode = "" + (ARGV[0] ?? "");

if (name == "service/state.uc" && index(mode, "runtime-dir-lock") >= 0) {
    if (mode == "runtime-dir-lock-owner")
        exit(real(name, ARGV));
    let lock = "" + (ARGV[1] ?? "");
    let lock_name = lock == getenv("RELOAD_LOCK") ? "reload" : lock == getenv("SUB_LOCK") ? "sub" : lock;
    ev(actor + " call " + mode + " " + lock_name);
    // Case 4: the retry lets go of its lock only once the update's wait for
    // it (the timeout it passes) has run out.
    if (actor == "B" && mode == "acquire-runtime-dir-lock-wait" && lock_name == "sub" &&
        getenv("SUB_FREED_AT_DEADLINE") == "1") {
        system("sleep " + int(ARGV[3] ?? "0"));
        system("touch " + q(getenv("TEST_WORK") + "/worker.gate"));
        for (let n = 0; fs.stat(lock) != null && n < 200; n++)
            system("sleep 0.05");
    }
    let status = real(name, ARGV);
    if (index(mode, "acquire") == 0)
        ev(actor + " " + mode + " " + lock_name + " rc=" + status);
    exit(status);
}

if (name == "subscription/cache.uc" && mode == "deferred-bootstrap-worker") {
    let self = "" + fs.readlink("/proc/self");
    system("ucode -L " + q(getenv("REAL_LIB")) + " -e " +
        q("require(\"core.process_identity\").record(ARGV[0], ARGV[1])") + " " +
        q(getenv("WORKER_PID_FILE")) + " " + q(self));
    if (real("service/state.uc", [ "acquire-runtime-dir-lock", getenv("SUB_LOCK"), self ]) != 0) {
        ev("W sub busy");
        exit(1);
    }
    ev("W sub acquired");
    let until = time() + int(getenv("HOLD_SECONDS") || "0");
    let gate = getenv("TEST_WORK") + "/worker.gate";
    for (let n = 0; (time() < until || fs.stat(gate) == null) && n < 2400; n++)
        system("sleep 0.05");
    ev("W sub released");
    real("service/state.uc", [ "release-runtime-dir-lock", getenv("SUB_LOCK"), self ]);
    exit(0);
}

ev(actor + " " + name + " " + mode);
if (name == "subscription/cache.uc") {
    if (mode == "stop-deferred-bootstrap-worker")
        exit(real(name, ARGV));
    // No prefetch; the update finds its sources unchanged, so no runtime
    // transition follows.
    if (mode == "prefetch-request")
        exit(1);
    if (mode == "update-request") {
        print("0 0 1 0\n");
        exit(0);
    }
}
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "forkop-stably-running" ||
    mode == "sing-box-process-conflict" || mode == "forkop-running"))
    exit(1);
exit(0);
UC
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc singbox/generator.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc service/lifecycle.uc; do
  mkdir -p "$(dirname "$FAKE_LIB/$module")"
  sed "s|@NAME@|$module|" "$WORK_DIR/fake-module.uc" >"$FAKE_LIB/$module"
done

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
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
  setsid timeout -s KILL 120 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

finish() {
  local label="$1" pid="$2" out="$3" status=0
  wait_until 60 process_gone "$pid" || fail "$label did not finish (deadlock on reload.lock/subscription-update.lock)"
  wait "$pid" || status=$?
  [ "$status" = 0 ] || fail "$label failed with status $status: $(cat "$out")"
}

reset_case() {
  : >"$EVENTS"
  rm -f "$WORK_DIR/worker.gate" "$WORKER_PID_FILE" "$FORKOP_PENDING_RELOAD_FILE"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
  [ ! -e "$SUB_LOCK" ] || fail "subscription-update.lock leaked from the previous case"
}

# The retry, under the command line start_deferred_subscription_bootstrap_retry_worker
# gives it, downloading under subscription-update.lock.
launch_worker() {
  start_actor env ACTOR=W HOLD_SECONDS="$1" ucode -L "$FAKE_LIB" "$FAKE_LIB/subscription/cache.uc" deferred-bootstrap-worker alpha
  wait_until 10 has_event '^W sub acquired$' || fail "the retry double did not take subscription-update.lock"
  wait_until 10 file_nonempty "$WORKER_PID_FILE" || fail "the retry double did not record itself"
  WORKER="$(head -n 1 "$WORKER_PID_FILE")"
}

# Arguments: extra environment assignments for the update.
launch_update() {
  start_actor env ACTOR=B "$@" ucode -L "$REAL_LIB" "$REAL_LIB/components/updates.uc" subscription-update >"$WORK_DIR/update.out" 2>&1
  UPDATE_PID="$LAST_ACTOR"
  wait_until 20 has_event '^B call acquire-runtime-dir-lock-wait sub$' ||
    fail "the forced update did not start waiting for subscription-update.lock: $(cat "$WORK_DIR/update.out")"
}

locks_released() {
  local label="$1"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: reload.lock was left behind"
  [ ! -e "$SUB_LOCK" ] || fail "$label: subscription-update.lock was left behind"
}

# The update waits for neither lock while it holds the other, and updates the
# cache only with both.
update_lock_order() {
  awk -v label="$1" '
    /^B acquire-runtime-dir-lock(-wait)? reload rc=0$/ { reload = 1 }
    /^B call release-runtime-dir-lock reload$/ { reload = 0 }
    /^B acquire-runtime-dir-lock(-wait)? sub rc=0$/ { held = 1 }
    /^B call release-runtime-dir-lock sub$/ { held = 0 }
    /^B call acquire-runtime-dir-lock-wait sub$/ {
      if (reload) bad = "the update waited for subscription-update.lock while it held reload.lock"
    }
    /^B call acquire-runtime-dir-lock(-wait)? reload$/ {
      if (held) bad = "the update waited for reload.lock while it held subscription-update.lock"
    }
    /^B subscription\/cache.uc update-request$/ {
      if (!reload || !held) bad = "the update changed the subscription cache without both locks"
    }
    END { if (bad != "") { print label ": " bad; exit 1 } }
  ' "$EVENTS" >"$WORK_DIR/order.out" || fail "$(cat "$WORK_DIR/order.out")"
}

# Nobody takes a lock that another one holds. The start holds reload.lock
# around its backend (init.d); the retry holds subscription-update.lock until
# it releases it or the start stops it.
exclusive() {
  awk -v label="$1" '
    function take(lock, who) {
      if (holder[lock] != "" && holder[lock] != who) bad = who " took " lock ".lock from " holder[lock]
      holder[lock] = who
    }
    function drop(lock, who) { if (holder[lock] == who) holder[lock] = "" }
    /^S start begin$/ { take("reload", "S") }
    /^S start end/ { drop("reload", "S") }
    /^[BFS] acquire-runtime-dir-lock(-wait)? (reload|sub) rc=0$/ { take($3, $1) }
    /^[BFS] call release-runtime-dir-lock (reload|sub)$/ { drop($4, $1) }
    /^W sub acquired$/ { take("sub", "W") }
    /^W sub released$/ { drop("sub", "W") }
    /^S subscription\/cache.uc stop-deferred-bootstrap-worker$/ { drop("sub", "W") }
    END { if (bad != "") { print label ": " bad; exit 1 } }
  ' "$EVENTS" >"$WORK_DIR/exclusive.out" || fail "$(cat "$WORK_DIR/exclusive.out")"
}

# 1. The retry downloads under subscription-update.lock for 20 s when a
#    forced update comes. The update waits for it without reload.lock: a DNS
#    failover switch applies meanwhile. Once the retry is done, the update
#    takes reload.lock and then subscription-update.lock and completes.
reset_case
launch_worker 20
launch_update
printf '{}\n' >"$WORK_DIR/candidate.json"
status=0
env ACTOR=F timeout -s KILL 60 ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" dns-failover-apply \
  "$WORK_DIR/candidate.json" >"$WORK_DIR/failover.out" 2>&1 || status=$?
[ "$status" = 0 ] ||
  fail "a DNS failover switch was refused (status $status) while a forced update waited for the retry's subscription-update.lock"
has_event '^F singbox/dns_failover.uc commit-state$' || fail "the DNS failover switch was not committed"
no_event '^W sub released$' || fail "the retry released its lock before the DNS failover check"
process_running "$UPDATE_PID" || fail "the forced update gave up waiting for the retry: $(cat "$WORK_DIR/update.out")"
no_event '^B subscription/cache.uc update-request$' || fail "the forced update ran next to the retry's download"
: >"$WORK_DIR/worker.gate"
finish "forced update after the retry" "$UPDATE_PID" "$WORK_DIR/update.out"
has_event '^B subscription/cache.uc update-request$' || fail "the forced update did not update the subscription cache"
before "W sub released" "B subscription/cache.uc update-request" || fail "the forced update ran before the retry released its lock"
no_event '^B service/state.uc mark-pending-reload$' || fail "the forced update gave up and queued a reload"
update_lock_order "forced update behind the retry"
exclusive "forced update behind the retry"
locks_released "forced update behind the retry"

# 2. A start while the retry downloads: the start prepares the subscription
#    caches and retries the deferred rules itself, so it stops the retry by
#    its identity rather than wait for its download inside reload.lock.
reset_case
launch_worker 0
start_actor env ACTOR=S ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" start >"$WORK_DIR/lifecycle.out" 2>&1
START_PID="$LAST_ACTOR"
wait_until 20 has_event '^S subscription/cache.uc prepare-caches$' ||
  fail "the start waited for the retry's download instead of stopping the retry"
wait_until 10 process_gone "$WORKER" || fail "the start did not stop the retry"
no_event '^W sub released$' || fail "the retry finished its download before the start went on"
before "S subscription/cache.uc stop-deferred-bootstrap-worker" "S acquire-runtime-dir-lock-wait sub rc=0" ||
  fail "the start took subscription-update.lock without stopping the retry first"
finish "start during the retry" "$START_PID" "$WORK_DIR/lifecycle.out"
[ ! -e "$WORKER_PID_FILE" ] || fail "the stopped retry is still recorded"
exclusive "start during the retry"
locks_released "start during the retry"

# 3. The retry downloads, a forced update waits for it, and a start comes
#    through init.d. The start takes reload.lock, stops the retry and runs;
#    the update runs after it. Nobody waits on anybody for good.
reset_case
launch_worker 0
launch_update
start_actor env FORKOP_BIN="$WORK_DIR/bin/forkop" FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS=20 \
  FORKOP_START_RETRY_DELAY_SECONDS=300 sh "$WORK_DIR/rc" start manual >"$WORK_DIR/start.out" 2>&1
START_PID="$LAST_ACTOR"
finish "start during the update's wait" "$START_PID" "$WORK_DIR/start.out"
has_event '^S start end 0$' || fail "the start did not run its backend: $(cat "$WORK_DIR/start.out") $(cat "$WORK_DIR/lifecycle.out")"
finish "forced update during the start" "$UPDATE_PID" "$WORK_DIR/update.out"
process_gone "$WORKER" || fail "the start did not stop the retry"
no_event '^W sub released$' || fail "the retry finished its download before the start went on"
before "S start end 0" "B subscription/cache.uc update-request" || fail "the forced update did not run after the start"
no_event '^B service/state.uc mark-pending-reload$' || fail "the forced update gave up and queued a reload"
update_lock_order "start and forced update behind the retry"
exclusive "start and forced update behind the retry"
locks_released "start and forced update behind the retry"

# 4. The retry holds its lock until the forced update's wait for it has run
#    out (a 3 s budget here) and only then lets go of it. The update got
#    subscription-update.lock within its wait and reload.lock is free: it
#    tries reload.lock once more and completes, rather than giving up as if a
#    reload held it and queueing a reload that brings no new subscription.
reset_case
launch_worker 0
launch_update SUB_FREED_AT_DEADLINE=1 FORKOP_SUBSCRIPTION_LOCK_WAIT_SECONDS=3
wait_until 60 process_gone "$UPDATE_PID" || fail "the forced update did not finish (deadlock on reload.lock/subscription-update.lock)"
status=0
wait "$UPDATE_PID" || status=$?
has_event '^W sub released$' || fail "the retry did not let go of its lock at the end of the update's wait"
no_event '^B service/state.uc mark-pending-reload$' ||
  fail "the forced update gave up with reload.lock free and queued a reload after it got subscription-update.lock at the end of its wait"
[ "$status" = 0 ] || fail "the forced update failed with status $status: $(cat "$WORK_DIR/update.out")"
has_event '^B subscription/cache.uc update-request$' || fail "the forced update did not update the subscription cache"
before "W sub released" "B subscription/cache.uc update-request" || fail "the forced update ran before the retry released its lock"
update_lock_order "forced update freed at the end of its wait"
exclusive "forced update freed at the end of its wait"
locks_released "forced update freed at the end of its wait"

printf 'subscription bootstrap lock wait checks passed\n'
