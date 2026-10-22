#!/usr/bin/env bash
set -euo pipefail

# The outcome of a Forkop start or restart (UC-013).
#
# procd.sh opens its lock on fd 1000 for every init.d call, so start_service
# always detaches the start worker and `/etc/init.d/forkop start|restart`
# exits 0 before the start has run. Callers that act on the outcome (the
# Direct Proxy rollback, the restart after a component change, the WAN-up
# retry, the package postinst, a UI start) must learn the real result:
# service/initd.uc start-and-wait runs the same init.d command, waits for the
# detached worker's own result and then checks the runtime.
#
# The init script is the real one behind an rc.common stand-in that holds fd
# 1000 like procd.sh; its backend `forkop` fails or succeeds on demand and
# reports the runtime as running or not. The component action paths are
# checked on the real action.uc functions with doubles.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
REAL_UCODE="$(command -v ucode)"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

# A failed start schedules a delayed retry: `/bin/sh -c 'sleep "$1"; rm -f
# .../start-retry.pid; exec init retry_start_on_wan_up' sh N`.
kill_retry_workers() {
  local pid
  for pid in $(pgrep -f "$WORK_DIR/run/forkop/start-retry.pid" 2>/dev/null); do
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -f "$WORK_DIR/run/forkop/start-retry.pid"
}

cleanup() {
  local owner
  # A detached start worker that still runs (a slow start when a check
  # failed) would schedule its retry once its `forkop start` is killed: stop
  # it first by the reload.lock it holds.
  owner="$("$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" runtime-dir-lock-owner "$FORKOP_RELOAD_LOCK_DIR" 2>/dev/null || true)"
  [ -z "$owner" ] || kill -KILL "$owner" 2>/dev/null || true
  # Scheduled retries, detached start workers and UI waiters.
  kill_retry_workers
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/proc"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"
printf "config settings 'settings'\n" >"$WORK_DIR/forkop.conf"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_forkop.lock"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/forkop/reload.pending"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_START_RETRY_DELAY_SECONDS=300
export FORKOP_START_WAIT_TIMEOUT_SECONDS=20
export FORKOP_START_SETTLE_SECONDS=6
export FORKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"

# `forkop` behind initd.uc: start exits with start.status and brings the
# modelled runtime up when runtime.comes-up exists.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  start)
    printf 'start\n' >>"$TEST_WORK/starts"
    # A slow cold start runs until start.slow is removed.
    n=0
    while [ -e "$TEST_WORK/start.slow" ] && [ "$n" -lt 600 ]; do n=$((n + 1)); sleep 0.1; done
    status="$(cat "$TEST_WORK/start.status" 2>/dev/null || echo 0)"
    [ "$status" != 0 ] || [ ! -e "$TEST_WORK/runtime.comes-up" ] || : >"$TEST_WORK/runtime.up"
    # A reload drained right after the start takes the runtime out of
    # "stably running" for a moment.
    if [ "$status" = 0 ] && [ -e "$TEST_WORK/runtime.comes-up-later" ]; then
      (sleep 2; : >"$TEST_WORK/runtime.up") </dev/null >/dev/null 2>&1 &
    fi
    exit "$status"
    ;;
  stop) rm -f "$TEST_WORK/runtime.up" ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":1}\n'; else printf '{"running":0}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/forkop as procd runs it: rc.common with fd 1000 open and
# flocked (procd.sh procd_lock); bash stands in for busybox ash (dash has no
# file descriptor above 9). start and restart return service_started's
# status, as rc.common does.
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
FORKOP_INITD_UC="${TEST_INITD_UC:-$TEST_LIB/service/initd.uc}"
case "$action" in
  start) start_service "$@"; service_started ;;
  stop) stop_service "$@" ;;
  restart) stop_service; start_service "$@"; service_started ;;
  *) exit 64 ;;
esac
SH

# ui.uc asks service/state.uc whether the runtime is stably running.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    if [ "${4:-}" = forkop-stably-running ]; then
      [ -e "$TEST_WORK/runtime.up" ]
      exit $?
    fi
    ;;
  */dns/apply.uc | */diagnostics/health.uc) exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

initd() { "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" "$@"; }

reset_case() {
  kill_retry_workers
  rm -f "$WORK_DIR/runtime.up" "$WORK_DIR/runtime.comes-up" "$WORK_DIR/runtime.comes-up-later" "$WORK_DIR/start.status" \
    "$FORKOP_RUNTIME_STATE_DIR"/start.retry "$FORKOP_RUNTIME_STATE_DIR"/stop.requested
  : >"$WORK_DIR/syslog"
}

start_fails() { printf '1\n' >"$WORK_DIR/start.status"; }
start_succeeds() { printf '0\n' >"$WORK_DIR/start.status"; : >"$WORK_DIR/runtime.comes-up"; }

# timed ACTION: the start-and-wait status; failures must be reported within
# a bounded time, not by running into the wait timeout.
timed_wait() {
  local began status=0
  began="$(date +%s)"
  initd start-and-wait "$@" >"$WORK_DIR/wait.out" 2>&1 || status=$?
  WAIT_SECONDS=$(($(date +%s) - began))
  return "$status"
}

# 1. The detached start still returns at once with 0 (procd), but its
#    failure reaches a caller that waits for it.
reset_case
start_fails
status=0
"$FORKOP_SERVICE_INIT" start >"$WORK_DIR/init.out" 2>&1 || status=$?
[ "$status" = 0 ] || fail "a detached init.d start no longer returns at once: status $status"
# Its worker fails afterwards and schedules a retry.
wait_until 10 file_nonempty "$FORKOP_RUNTIME_STATE_DIR/start-retry.pid" ||
  fail "the detached start worker did not fail and schedule its retry"
reset_case
start_fails
timed_wait start && fail "a failed start was reported as successful to a waiting caller"
[ "$WAIT_SECONDS" -lt "$FORKOP_START_WAIT_TIMEOUT_SECONDS" ] ||
  fail "a failed start was only noticed after the wait timeout"
# The failed start scheduled its retry; that later start is not the one the
# caller waited for and must not report under its request.
retry_sleep() {
  local shell_pid child
  shell_pid="$(head -n 1 "$FORKOP_RUNTIME_STATE_DIR/start-retry.pid" 2>/dev/null)" || return 1
  for child in $(pgrep -P "$shell_pid" 2>/dev/null); do
    process_exec_is "$child" sleep && { printf '%s\n' "$child"; return 0; }
  done
  return 1
}
wait_until 10 retry_sleep >/dev/null || fail "the failed start scheduled no retry"
if tr '\0' '\n' <"/proc/$(retry_sleep)/environ" | grep -q '^FORKOP_START_REQUEST='; then
  fail "the scheduled retry inherited the waiting caller's start request"
fi

# 2. A start that succeeds and leaves the runtime running.
reset_case
start_succeeds
timed_wait start || fail "a successful start was reported as failed: $(cat "$WORK_DIR/wait.out")"

# 3. A start whose backend reports success while the runtime is not running.
reset_case
printf '0\n' >"$WORK_DIR/start.status"
timed_wait start && fail "a start that left no running runtime was reported as successful"
# ... but only briefly after its result: the runtime is given time to settle.
reset_case
printf '0\n' >"$WORK_DIR/start.status"
: >"$WORK_DIR/runtime.comes-up-later"
timed_wait start || fail "a start whose runtime settled shortly after its result was reported as failed"

# 3b. A result that its caller no longer waits for (the wait timed out) does
#     not stay in the runtime state directory for good: the next wait removes
#     results older than the wait timeout, and leaves recent ones alone.
reset_case
start_succeeds
printf 'status=0\n' >"$FORKOP_RUNTIME_STATE_DIR/start-result.gone.1"
touch -d '1 hour ago' "$FORKOP_RUNTIME_STATE_DIR/start-result.gone.1"
printf 'status=0\n' >"$FORKOP_RUNTIME_STATE_DIR/start-result.recent.1"
timed_wait start || fail "a successful start was reported as failed: $(cat "$WORK_DIR/wait.out")"
[ ! -e "$FORKOP_RUNTIME_STATE_DIR/start-result.gone.1" ] || fail "a start result nobody waits for was left behind"
[ -e "$FORKOP_RUNTIME_STATE_DIR/start-result.recent.1" ] || fail "a recent start result was removed"
rm -f "$FORKOP_RUNTIME_STATE_DIR/start-result.recent.1"

# 4. restart: stop, then the detached start.
reset_case
start_fails
timed_wait restart && fail "a failed restart was reported as successful"
reset_case
start_succeeds
timed_wait restart || fail "a successful restart was reported as failed: $(cat "$WORK_DIR/wait.out")"

# 5. A worker that cannot be launched at all fails the init.d start itself.
reset_case
start_succeeds
status=0
TEST_INITD_UC="$WORK_DIR/missing-initd.uc" "$FORKOP_SERVICE_INIT" start >"$WORK_DIR/init.out" 2>&1 || status=$?
[ "$status" != 0 ] || fail "init.d start reported success without a start worker"

# No result is left behind for callers that are gone.
if ls "$FORKOP_RUNTIME_STATE_DIR"/start-result.* >/dev/null 2>&1; then
  fail "start results were left in the runtime state directory"
fi

# 6. The WAN-up retry start (reason "triggered") reports its own outcome:
#    "recovered" only after the start really succeeded.
reset_case
start_succeeds
initd start-service triggered >/dev/null 2>&1 || fail "a successful retry start failed"
grep -q 'recovered automatically after a failed start' "$WORK_DIR/syslog" ||
  fail "a successful retry start did not report the recovery"
reset_case
start_fails
initd start-service triggered >/dev/null 2>&1 && fail "a failed retry start succeeded"
grep -q 'recovered automatically' "$WORK_DIR/syslog" && fail "a failed retry start was logged as a recovery"
grep -q 'automatic recovery attempt failed' "$WORK_DIR/syslog" ||
  fail "a failed retry start was not logged as a failed recovery"

# 7. A UI start (service/ui.uc job worker, service disabled on this host)
#    finishes as failed when the start fails, and as success when it works.
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$FORKOP_UI_STATE_DIR/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$FORKOP_UI_STATE_DIR/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$FORKOP_UI_STATE_DIR/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$FORKOP_UI_STATE_DIR/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$FORKOP_UI_STATE_DIR/subscription-actions"
export FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1
export FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=20
ui() { "$REAL_UCODE" -L "$LIB" "$LIB/service/ui.uc" "$@"; }
ui_start() {
  local job
  job="$(ui service-action-begin-if-idle start ui)" || fail "could not begin a UI start job"
  ui service-action-worker "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json" start "$job" "" >/dev/null 2>&1 || true
  UI_JOB="$FORKOP_UI_SERVICE_ACTION_DIR/$job.json"
}
reset_case
start_fails
began="$(date +%s)"
ui_start
grep -q '"success": *false' "$UI_JOB" || fail "a failed UI start finished as success: $(cat "$UI_JOB")"
[ "$(($(date +%s) - began))" -lt "$FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS" ] ||
  fail "a failed UI start was only reported after the action timeout"
reset_case
start_succeeds
ui_start
grep -q '"success": *true' "$UI_JOB" || fail "a successful UI start did not finish as success: $(cat "$UI_JOB")"
unset FORKOP_UI_ACTION_TRACKED

# 8. The package postinst restores the pre-upgrade service and reports a
#    start that did not come up, without failing the package operation: the
#    failed start schedules its own retry, and opkg configures a package whose
#    postinst failed again on every later install. The upgrade hand-off is
#    consumed either way, so such a re-run neither waits for the runtime that
#    came up meanwhile nor starts a Forkop that was stopped since.
postinst() {
  FORKOP_POSTINST_START_WAIT_SECONDS="${POSTINST_WAIT:-15}" \
  FORKOP_INIT="$FORKOP_SERVICE_INIT" \
  FORKOP_CONFIG_PATH="$WORK_DIR/forkop.conf" \
  FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/forkop.conf" \
  FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/was-running" \
  FORKOP_PROC_DIR="$WORK_DIR/proc" \
  FORKOP_UPGRADE_SING_BOX_WAIT_SECONDS=1 \
    "$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" postinst >"$WORK_DIR/postinst.out" 2>&1
}
starts() { grep -c '^start$' "$WORK_DIR/starts" 2>/dev/null || true; }
reset_case
rm -f "$WORK_DIR/starts"
start_fails
printf '1\n' >"$WORK_DIR/was-running"
postinst || fail "postinst failed the package operation for a start that failed: $(cat "$WORK_DIR/postinst.out")"
grep -q 'did not start after the package upgrade' "$WORK_DIR/postinst.out" ||
  fail "postinst did not report the start that failed: $(cat "$WORK_DIR/postinst.out")"
[ ! -e "$WORK_DIR/was-running" ] || fail "postinst kept the upgrade hand-off of a failed start"
[ "$(starts)" = 1 ] || fail "postinst did not attempt the start exactly once"
# The retry brought Forkop up (a sing-box runs); opkg configures the package
# again during an unrelated install.
kill_retry_workers
mkdir -p "$WORK_DIR/proc/4242"
ln -s /usr/bin/sing-box "$WORK_DIR/proc/4242/exe"
began="$(date +%s)"
postinst || fail "a postinst re-run with Forkop running failed: $(cat "$WORK_DIR/postinst.out")"
[ "$(($(date +%s) - began))" -lt 5 ] || fail "a postinst re-run waited for the running sing-box"
[ "$(starts)" = 1 ] || fail "a postinst re-run started Forkop again"
rm -rf "$WORK_DIR/proc/4242"
# The user has stopped Forkop since; a re-run does not start it.
start_succeeds
postinst || fail "a postinst re-run with Forkop stopped failed: $(cat "$WORK_DIR/postinst.out")"
[ "$(starts)" = 1 ] || fail "a postinst re-run started a Forkop that was stopped"
[ ! -e "$WORK_DIR/runtime.up" ] || fail "a postinst re-run brought a stopped Forkop up"
reset_case
start_succeeds
printf '1\n' >"$WORK_DIR/was-running"
postinst || fail "postinst failed for a start that succeeded: $(cat "$WORK_DIR/postinst.out")"
[ ! -e "$WORK_DIR/was-running" ] || fail "postinst kept the upgrade hand-off after a successful start"
[ -e "$WORK_DIR/runtime.up" ] || fail "postinst did not start Forkop"
# A slow cold start runs inside the package manager's transaction (it holds
# its lock): the postinst waits for it only for its own, shorter bound, then
# says that the start carries on instead of reporting a failure.
reset_case
rm -f "$WORK_DIR/starts"
start_succeeds
: >"$WORK_DIR/start.slow"
printf '1\n' >"$WORK_DIR/was-running"
began="$(date +%s)"
POSTINST_WAIT=2 postinst || fail "postinst failed for a slow start: $(cat "$WORK_DIR/postinst.out")"
[ "$(($(date +%s) - began))" -lt 10 ] || fail "postinst waited for a slow start beyond its own bound"
grep -q 'still starting after the package upgrade' "$WORK_DIR/postinst.out" ||
  fail "postinst did not say that the slow start carries on: $(cat "$WORK_DIR/postinst.out")"
if grep -q 'did not start after the package upgrade' "$WORK_DIR/postinst.out"; then
  fail "postinst reported a slow start as failed"
fi
[ ! -e "$WORK_DIR/was-running" ] || fail "postinst kept the upgrade hand-off of a slow start"
rm -f "$WORK_DIR/start.slow"
wait_until 20 test -e "$WORK_DIR/runtime.up" || fail "the slow start did not finish after the postinst"

# 9. Component actions act on the real outcome (components/action.uc).
python3 - "$ROOT_DIR" "$WORK_DIR/action-probe.uc" <<'PY'
import pathlib
import re
import sys

source = (pathlib.Path(sys.argv[1]) / 'forkop/files/usr/lib/components/action.uc').read_text()


def extract(name, optional=False):
    found = re.search(r'^function ' + name + r'\([^\n]*\) \{\n.*?^\}', source, re.M | re.S)
    if not found:
        if optional:
            return ''
        raise SystemExit('missing action.uc function: ' + name)
    return found.group()


doubles = r'''
const CONFIG_NAME = "forkop";
const LIB_DIR = "/lib";
const SERVICE_INIT = "/etc/init.d/forkop";
const SYSTEM_INFO_CACHE_FILE = "/test/system-info.json";
let forkop_was_running = true;
let forkop_stopped_for_sing_box_change = false;
let uci = {};
let calls = [];
let results = [];
let outcome = null;
// The initd.uc on disk: an older release (installed by this very action)
// has no start-and-wait mode.
let initd_source = 'else if (mode == "start-and-wait")';
let status_results = [];
// service/state.uc: an explicit stop was requested; the runtime's nft table
// is in place (runtime-apply-allowed also refuses after a stop).
let stop_requested = false;
let runtime_table = false;
let constants = { NFT_TABLE_NAME: "ForkopTable" };
function as_string(value) { return value == null ? "" : "" + value; }
function die_check(message) { warn("FAIL: " + message + "\n"); exit(1); }
function check(condition, message) { if (!condition) die_check(message); }
let uci_core = {
    available: function() { return true; },
    get: function(path) { return uci[path]; },
    set: function(path, value) { uci[path] = value; return true; },
    "delete": function(path) { delete uci[path]; return true; },
    commit: function() { return true; }
};
let netstat = { listen_port_in_use: function() { return false; } };
function file_exists(path) { return path == SERVICE_INIT; }
function remove_file(path) { return true; }
function command_exists(name) { return true; }
function command_output_from_args(args) { return "tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN\n"; }
function module_output(args) { return "192.168.1.1\n"; }
function command_from_args(args) { return join(" ", args); }
function updates_log(message, level) { push(calls, "log:" + as_string(level || "info")); }
function prepare_sing_box_service_disabled() { push(calls, "disable-sing-box"); }
function next_result() { return length(results) > 0 ? shift(results) : true; }
function read_file(path) {
    check(path == LIB_DIR + "/service/initd.uc", "unexpected read of " + path);
    return initd_source;
}
function forkop_status_running_with_timeout() {
    push(calls, "status");
    return length(status_results) > 0 ? shift(status_results) : false;
}
// The init script accepts every request at once, as under procd.
function command_success_from_args(args) {
    if (args[0] == "sleep")
        return true;
    check(args[0] == SERVICE_INIT, "unexpected command " + join(" ", args));
    push(calls, "init:" + args[1]);
    return true;
}
function run_logged(description, command) {
    push(calls, "init:" + split(command, " ")[1]);
    return true;
}
function module_success(args) {
    if (args[0] == LIB_DIR + "/service/state.uc" && args[1] == "stop-requested")
        return stop_requested;
    if (args[0] == LIB_DIR + "/service/state.uc" && args[1] == "runtime-apply-allowed") {
        check(args[2] == "ForkopTable", "the runtime check names no nft table");
        return !stop_requested && runtime_table;
    }
    check(args[0] == LIB_DIR + "/service/initd.uc" && args[1] == "start-and-wait",
        "unexpected module " + join(" ", args));
    push(calls, "wait:" + args[2]);
    return next_result();
}
function action_fail(component, action, message) {
    outcome = { success: false, message };
    die("ACTION_END");
}
function action_success(component, action, message) {
    outcome = { success: true, message };
    die("ACTION_END");
}
function pkg_is_installed(name) { return true; }
function provider_installed(module) { return false; }
function provider_package_version(module) { return "1.0"; }
function is_apk() { return false; }
function clear_version_caches() { return true; }
function reset(values) {
    uci = { "forkop.settings.direct_proxy_enabled": "0", "forkop.settings.direct_proxy_port": "2080" };
    calls = []; results = values; outcome = null;
    forkop_was_running = true; forkop_stopped_for_sing_box_change = false;
    initd_source = 'else if (mode == "start-and-wait")'; status_results = [];
    stop_requested = false; runtime_table = false;
}
function run(fn) {
    try { fn(); }
    catch (e) { if (e.message != "ACTION_END") die_check("action raised " + e.message); }
}
'''

cases = r'''
// Direct Proxy: a restart that does not bring Forkop up rolls the settings
// back, restarts the previous configuration and fails the action.
reset([ false, true ]);
run(function() { set_direct_proxy("enable"); });
check(outcome != null && !outcome.success, "Direct Proxy enable was reported as success although Forkop did not start");
check(uci["forkop.settings.direct_proxy_enabled"] == "0", "the failed Direct Proxy settings were kept");
check(join(",", calls) == "wait:restart,wait:restart", "the previous Direct Proxy settings were not restarted: " + join(",", calls));

reset([ true ]);
run(function() { set_direct_proxy("enable"); });
check(outcome != null && outcome.success, "a working Direct Proxy enable was reported as failure");
check(uci["forkop.settings.direct_proxy_enabled"] == "1", "a working Direct Proxy enable was rolled back");

// A restart after a successful component change reports its outcome.
reset([ false ]);
check(restart_forkop_after_successful_change() === false, "a restart that failed after a component change was reported as done");
reset([ true ]);
check(restart_forkop_after_successful_change() === true, "a working restart after a component change was reported as failed");
check(join(",", calls) == "log:info,wait:restart", "an ordinary component change did not restart Forkop: " + join(",", calls));
// The sing-box update stopped Forkop before replacing its package. A second
// stop through init.d restart may fail and suppress the subsequent start.
reset([ true ]);
forkop_stopped_for_sing_box_change = true;
check(restart_forkop_after_successful_change() === true, "a stopped Forkop was not started after a sing-box change");
check(join(",", calls) == "log:info,wait:start", "a sing-box change invoked a second stop: " + join(",", calls));
reset([]);
forkop_was_running = false;
check(restart_forkop_after_successful_change() === true, "a skipped restart was reported as failed");
check(index(join(",", calls), "wait:") < 0 && index(join(",", calls), "init:") < 0, "a stopped Forkop was restarted after a component change");

// The component action reports a Forkop that did not come back.
reset([ false ]);
run(function() { remove_optional_component("zapret", "zapret", "zapret", "/lib/providers/zapret/runtime.uc"); });
check(outcome != null && !outcome.success, "a component removal was reported as success although Forkop did not start again");

// After a failed sing-box change, a start that fails falls back to a restart.
reset([ false, true ]);
forkop_stopped_for_sing_box_change = true;
restart_forkop_after_failed_sing_box_change();
check(join(",", calls) == "log:info,wait:start,wait:restart", "a failed start after a failed sing-box change had no restart fallback: " + join(",", calls));
// Direct Proxy of a stopped Forkop: the setting is saved and applies at its
// next start; a setting change does not start it (D-15).
reset([]);
forkop_was_running = false;
run(function() { set_direct_proxy("enable"); });
check(outcome != null && outcome.success, "Direct Proxy of a stopped Forkop was not saved");
check(uci["forkop.settings.direct_proxy_enabled"] == "1", "Direct Proxy of a stopped Forkop was rolled back");
check(index(join(",", calls), "wait:") < 0 && index(join(",", calls), "init:") < 0,
    "a Direct Proxy change started a stopped Forkop: " + join(",", calls));
// Nor one that the user stopped, although its status still read running (the
// stop is waiting for reload.lock) or its nft table is still there.
reset([]);
stop_requested = true; runtime_table = true;
run(function() { set_direct_proxy("enable"); });
check(outcome != null && outcome.success && uci["forkop.settings.direct_proxy_enabled"] == "1",
    "Direct Proxy of a Forkop that the user stopped was not saved");
check(index(join(",", calls), "wait:") < 0, "a Direct Proxy change restarted a Forkop that the user stopped: " + join(",", calls));
// A Forkop whose status probe failed in the middle of a sing-box restart (a
// DNS-failover switch, a subscription update, a reload) or answered too
// slowly still has its runtime: the change is applied by a restart.
reset([ true ]);
forkop_was_running = false; runtime_table = true;
run(function() { set_direct_proxy("enable"); });
check(outcome != null && outcome.success, "Direct Proxy of a Forkop in a transition was reported as failure");
check(join(",", calls) == "wait:restart", "Direct Proxy of a Forkop in a transition was not applied by a restart: " + join(",", calls));

// An older release installed by the action has no start-and-wait: the
// restart goes through init.d and the runtime is polled instead.
reset([]);
initd_source = 'else if (mode == "start-service")';
status_results = [ false, true ];
check(restart_forkop_after_successful_change() === true, "a restart through an older initd.uc was reported as failed");
check(index(join(",", calls), "wait:") < 0, "start-and-wait was used with an initd.uc that has no such mode");
check(index(join(",", calls), "init:restart,status,status") >= 0,
    "an older initd.uc was not restarted through init.d and polled: " + join(",", calls));
reset([]);
initd_source = 'else if (mode == "start-service")';
forkop_stopped_for_sing_box_change = true;
status_results = [ false, true ];
check(restart_forkop_after_successful_change() === true, "an older initd.uc was not started after a sing-box change");
check(index(join(",", calls), "init:start,status,status") >= 0,
    "an older initd.uc repeated stop after a sing-box change: " + join(",", calls));
reset([]);
initd_source = 'else if (mode == "start-service")';
check(restart_forkop_after_successful_change() === false, "an older release that did not start was reported as started");
print("component start outcome checks passed\n");
'''

pathlib.Path(sys.argv[2]).write_text('\n'.join([
    doubles,
    extract('forkop_start_and_wait', optional=True),
    extract('forkop_active_for_setting_change', optional=True),
    extract('restart_forkop_after_failed_sing_box_change'),
    extract('restart_forkop_after_successful_change'),
    extract('remove_optional_component'),
    extract('set_direct_proxy'),
    cases,
]))
PY
"$REAL_UCODE" "$WORK_DIR/action-probe.uc" || fail "component actions do not act on the start outcome"

printf 'start result wait checks passed\n'
