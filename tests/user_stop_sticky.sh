#!/usr/bin/env bash
set -euo pipefail

# An explicit stop stays in effect until an explicit start (UC-056, D-15(a)).
#
# Before: only the reloads that background work requests on its own were
# skipped after a stop. A manual `init.d reload`, a snapshot restore
# ("config-restore") and an autotune apply ("autotune") of a stopped runtime
# took the "runtime state is incomplete" branch and started the whole
# runtime again (restart_runtime_for_reload), which also ended the stop. A
# reload that restarted the runtime cleared a stop that was still waiting
# for reload.lock. The stop left the rule-set refresh workers running (their
# final reload is the trigger) and its queued reload.pending behind.
#
# Now every reload of a runtime that an explicit stop took down is skipped,
# whoever requests it, and only an explicit start or restart ends the stop; a
# stopped runtime that nobody stopped after an explicit start (a crash, a
# failed start) is still repaired by a reload; one that nobody started since
# boot is held down too (D-15(a)). `forkop stop` terminates the refresh
# workers by their recorded identity (core/process_identity.uc) and drops
# reload.pending.
#
# service/lifecycle.uc, service/initd.uc, init.d and singbox/ruleset_cache.uc
# are real; sing-box, nft and the modules the lifecycle calls are modelled.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
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
  # Orphaned downloads of killed refresh workers wait on this test's gate.
  pkill -KILL -f "$WORK_DIR/" 2>/dev/null || true
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

LIB="$WORK_DIR/lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" \
  "$LIB/service" "$LIB/config" "$LIB/singbox" "$WORK_DIR/ui-state"
# The modelled library: the real lifecycle, rule-set cache and core modules
# by their paths in it (the refresh workers are recognised by those command
# lines), modelled modules for the rest; a module that is missing fails.
ln -s "$REAL_LIB/core" "$LIB/core"
ln -s "$REAL_LIB/service/lifecycle.uc" "$LIB/service/lifecycle.uc"
ln -s "$REAL_LIB/singbox/ruleset_cache.uc" "$LIB/singbox/ruleset_cache.uc"
ln -s "$REAL_LIB/singbox/rulesets.uc" "$LIB/singbox/rulesets.uc"

cat >"$WORK_DIR/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=1
EOF
: >"$WORK_DIR/forkop.config"

STATE_DIR="$WORK_DIR/run/forkop"
export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB REAL_INITD REAL_UCODE LIB
export TEST_WORK="$WORK_DIR"
export SING_BOX_STATE="$WORK_DIR/singbox.state"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export STOP_MARKER="$STATE_DIR/stop.requested"
START_RECORD="$STATE_DIR/start.explicit"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_SERVICE_NAME=forkop
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$STATE_DIR/subscription-update.lock"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_LIST_UPDATE_PID_FILE="$STATE_DIR/list-update.pid"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$FORKOP_UI_STATE_DIR/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$FORKOP_UI_STATE_DIR/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$FORKOP_UI_STATE_DIR/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$FORKOP_UI_STATE_DIR/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$FORKOP_UI_STATE_DIR/subscription-actions"
export FORKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export FORKOP_SING_BOX_RELOAD_PID_TIMEOUT=2
export FORKOP_RULESET_CACHE_DIR="$WORK_DIR/ruleset-cache"
export FORKOP_RULESET_CACHE_MANIFEST="$WORK_DIR/ruleset-cache/manifest.json"
export FORKOP_RULESET_RUNTIME_CACHE_DIR="$WORK_DIR/ruleset-runtime"
export FORKOP_RULESET_RUNTIME_MANIFEST="$STATE_DIR/ruleset-cache-runtime.json"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK_DIR/list-cache"
export DOWNLOAD_GATE="$WORK_DIR/download.gate"
export RULESET_SOURCE="$WORK_DIR/ruleset-source.json"

# Nothing here may reach the host's syslog, firewall, routing or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
# Only the production table is modelled: no DPI guard of a failed transition
# or of a restore (ForkopTableDpiGuard, ForkopConfigRestoreDpiGuard).
if [ "$1 $2 $3" = "list table inet" ] && [ "$4" != ForkopTable ]; then
  exit 1
fi
if [ "$1 $2 $3" = "list table inet" ]; then
  [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  rm -f "$NFT_TABLE_FILE"
fi
[ "$1 $2" != "list chain" ]
SH
# /etc/init.d/forkop for the workers: only records the reload they request.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
printf 'init %s\n' "$*" >>"$EVENTS"
exit 0
SH
# A rule-set download waits for the test's gate; then it delivers a valid
# source rule set.
printf '{"version":1,"rules":[{"domain_suffix":["example.test"]}]}\n' >"$RULESET_SOURCE"
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --proxy|--connect-timeout|--max-time|--resolve) shift 2 ;;
    *) shift ;;
  esac
done
printf 'download begin\n' >>"$EVENTS"
while [ ! -e "$DOWNLOAD_GATE" ]; do
  [ -d "$TEST_WORK" ] || exit 1
  sleep 0.05
done
cp "$RULESET_SOURCE" "$output"
SH

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
let mode = "" + (ARGV[0] ?? "");
'

# Locks and the stop marker go to the real service/state.uc; the runtime is
# modelled by files.
cat >"$LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
if (mode == "forkop-running" || mode == "forkop-stably-running")
    exit(trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running" && fs.stat(getenv("NFT_TABLE_FILE")) != null ? 0 : 1);
if (mode == "sing-box-process-conflict")
    exit(1);
if (mode == "stop-managed-sing-box-runtime") {
    ev("stop-managed");
    fs.writefile(getenv("SING_BOX_STATE"), "stopped\n");
    exit(0);
}
if (mode == "start-managed-sing-box-runtime") {
    ev("start-managed");
    exit(1);
}
ev("state " + mode);
exit(0);
UC

cat >"$LIB/config/validator.uc" <<UC
$fake_header
exit(0);
UC

# The reload plan: the current reload state is unavailable, so a reload of a
# running runtime restarts it.
cat >"$LIB/service/reload.uc" <<UC
$fake_header
ev("reload-plan " + mode);
exit(mode == "plan-state-files" ? 2 : 0);
UC

mkdir -p "$LIB/subscription"
cat >"$LIB/subscription/cache.uc" <<UC
$fake_header
ev("subscription " + mode);
exit(0);
UC

for module in priority dns_failover; do
  cat >"$LIB/singbox/$module.uc" <<UC
$fake_header
ev("$module " + mode);
exit(0);
UC
done

# `forkop` behind service/initd.uc: get_status reports the modelled runtime;
# a reload is recorded.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  get_status)
    if [ "$(cat "$SING_BOX_STATE" 2>/dev/null)" = running ] && [ -e "$NFT_TABLE_FILE" ]; then
      printf '{"running":1}\n'
    else
      printf '{"running":0}\n'
    fi
    ;;
  reload)
    printf 'reload ran %s\n' "${2:-}" >>"$EVENTS"
    ;;
esac
exit 0
SH

# initd owns reload.lock before it invokes lifecycle directly. Keep initd's
# orchestration under test while retaining the explicit real-lifecycle cases
# below, which call the module without that lock.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
if [ "${3:-}" = "$LIB/service/lifecycle.uc" ] && [ "${4:-}" = reload ] &&
   [ -e "$FORKOP_RELOAD_LOCK_DIR" ]; then
  exec "$FORKOP_BIN" reload "${5:-}"
fi
exec "$REAL_UCODE" "$@"
SH

# /etc/init.d/forkop as procd runs it: the real script behind rc.common.
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$LIB"
FORKOP_INITD_UC="$REAL_LIB/service/initd.uc"
case "$action" in
  reload) reload_service "$@" ;;
  stop) stop_service "$@" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q "$1" "$EVENTS" 2>/dev/null; }

start_actor() {
  setsid timeout -s KILL 90 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

runtime_up() {
  printf 'running\n' >"$SING_BOX_STATE"
  printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
}

runtime_down() {
  printf 'stopped\n' >"$SING_BOX_STATE"
  rm -f "$NFT_TABLE_FILE"
}

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -rf "$STOP_MARKER" "$START_RECORD" "$FORKOP_PENDING_RELOAD_FILE" "$DOWNLOAD_GATE" \
    "$FORKOP_RULESET_CACHE_DIR" "$FORKOP_RULESET_RUNTIME_CACHE_DIR" "$FORKOP_RULESET_RUNTIME_MANIFEST"
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock leaked from the previous case"
}

lifecycle() {
  ucode -L "$LIB" "$LIB/service/lifecycle.uc" "$@" >"$WORK_DIR/lifecycle.out" 2>&1
}

# 1. Every reload of a runtime that an explicit stop took down is skipped
#    under reload.lock: a manual reload, a snapshot restore, an autotune apply
#    and any other reason as well as the background ones. The runtime is not
#    touched and the stop stays in effect.
for reason in "" config-restore autotune list-content ruleset-cache pending on_config_change some-caller; do
  reset_case
  runtime_down
  printf 'stop\n' >"$STOP_MARKER"
  lifecycle reload "$reason" || fail "reload '$reason' of a stopped runtime failed: $(cat "$WORK_DIR/lifecycle.out")"
  no_event '^stop-managed$' || fail "reload '$reason' of a stopped runtime touched sing-box"
  no_event '^reload-plan' || fail "reload '$reason' of a stopped runtime reached the reload plan"
  if grep -q 'restarting Forkop runtime' "$WORK_DIR/syslog"; then
    fail "reload '$reason' restarted a runtime that an explicit stop took down"
  fi
  grep -q "Reload '$reason' skipped: Forkop was stopped" "$WORK_DIR/syslog" ||
    fail "skipped reload '$reason' of a stopped runtime was not logged"
  [ -e "$STOP_MARKER" ] || fail "reload '$reason' ended the explicit stop"
done

# 1b. Control: a runtime that is down without a stop after an explicit start
#     (it crashed, a start failed) is still repaired by a reload.
reset_case
runtime_down
: >"$START_RECORD"
lifecycle reload "" || true
grep -q 'Runtime state is incomplete; restarting Forkop runtime' "$WORK_DIR/syslog" ||
  fail "a reload did not repair a runtime that is down without a stop"

# 1c. A runtime that nobody started since boot (no stop, no explicit start
#     recorded: autostart disabled) is held down like a stopped one
#     (D-15(a); tests/reboot_not_started.sh).
for reason in "" config-restore list-content; do
  reset_case
  runtime_down
  lifecycle reload "$reason" || fail "reload '$reason' of a Forkop not started failed: $(cat "$WORK_DIR/lifecycle.out")"
  no_event '^reload-plan' || fail "reload '$reason' of a Forkop not started reached the reload plan"
  grep -q "Reload '$reason' skipped: Forkop was not started" "$WORK_DIR/syslog" ||
    fail "reload '$reason' started a Forkop that nobody started since boot"
  [ ! -e "$START_RECORD" ] || fail "reload '$reason' recorded an explicit start"
done

# 2. A reload that restarts a running runtime (its reload state is gone)
#    while a stop waits for reload.lock does not end that stop: only an
#    explicit start does. The restarted start gives way to the stop.
reset_case
runtime_up
printf 'stop\n' >"$STOP_MARKER"
lifecycle reload "" || true
grep -q 'Reload state is unavailable; restarting Forkop runtime' "$WORK_DIR/syslog" ||
  fail "the reload did not reach the runtime restart"
[ -e "$STOP_MARKER" ] || fail "a reload that restarted the runtime ended a pending explicit stop"
no_event '^start-managed$' || fail "a reload restarted sing-box while a stop was pending"

# 3. init.d: the reload of a stopped runtime is not run, whoever requests
#    it. The transaction callers (snapshot restore, autotune apply) are told
#    "stopped", never an empty answer that reads as a reload that ran
#    (tests/config_restore_user_stop.sh), and so is the job of a UI reload
#    (service/ui.uc, tests/ui_reload_queued_job.sh); for others the answer
#    stays empty. Only service/ui.uc runs init.d with FORKOP_UI_ACTION_TRACKED.
initd_reload() {
  env -u FORKOP_UI_ACTION_TRACKED bash "$WORK_DIR/rc" reload "$@" 2>"$WORK_DIR/initd.err"
}
for reason in "" list-content some-caller config-restore autotune; do
  reset_case
  runtime_down
  printf 'stop\n' >"$STOP_MARKER"
  output="$(initd_reload "$reason")" || fail "init.d reload '$reason' of a stopped runtime failed: $(cat "$WORK_DIR/initd.err")"
  case "$reason" in
    config-restore | autotune) want=stopped ;;
    *) want='' ;;
  esac
  [ "$output" = "$want" ] || fail "init.d reload '$reason' of a stopped runtime answered '$output', not '$want'"
  no_event '^reload ran' || fail "init.d ran reload '$reason' of a stopped runtime"
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "init.d reload '$reason' of a stopped runtime left reload.lock behind"
  [ -e "$STOP_MARKER" ] || fail "init.d reload '$reason' ended the explicit stop"
done
reset_case
runtime_down
printf 'stop\n' >"$STOP_MARKER"
output="$(FORKOP_UI_ACTION_TRACKED=1 bash "$WORK_DIR/rc" reload "" 2>"$WORK_DIR/initd.err")" ||
  fail "the UI reload of a stopped runtime failed: $(cat "$WORK_DIR/initd.err")"
[ "$output" = stopped ] || fail "the UI reload of a stopped runtime answered '$output', not 'stopped'"
no_event '^reload ran' || fail "init.d ran the UI reload of a stopped runtime"

# 3b. Controls: a running runtime, and one that is down without a stop after
#     an explicit start, are reloaded (the lifecycle repairs the latter); the
#     answer stays empty.
reset_case
runtime_up
output="$(initd_reload config-restore)" || fail "init.d reload of a running runtime failed"
has_event '^reload ran config-restore$' || fail "init.d did not reload a running runtime"
[ -z "$output" ] || fail "a reload of a running runtime answered '$output'"
reset_case
runtime_down
: >"$START_RECORD"
output="$(initd_reload config-restore)" || fail "init.d reload of a crashed runtime failed"
has_event '^reload ran config-restore$' || fail "init.d did not pass the reload of a crashed runtime on for repair"
[ -z "$output" ] || fail "a reload of a crashed runtime answered '$output'"

# 4. `forkop stop` terminates the rule-set refresh workers, whose final
#    reload would otherwise be the next trigger, and drops the queued reload:
#    the next start applies the whole configuration anyway.
refresh_workers_recorded() {
  local count
  count="$(find "$STATE_DIR/ruleset-refresh-workers" -mindepth 1 -maxdepth 1 -name '[0-9]*' ! -name '*.tmp' 2>/dev/null | wc -l)"
  [ "$count" -ge "$1" ]
}
downloads_begun() {
  [ "$(grep -c '^download begin$' "$EVENTS" 2>/dev/null || true)" -ge "$1" ]
}
launch_refresh_workers() {
  start_actor ucode -L "$LIB" "$LIB/service/lifecycle.uc" refresh-rulesets-after-start
  AFTER_START_PID="$LAST_ACTOR"
  start_actor ucode -L "$LIB" "$LIB/singbox/ruleset_cache.uc" refresh-and-reload ""
  AND_RELOAD_PID="$LAST_ACTOR"
}
seed_ruleset_manifest() {
  mkdir -p "$FORKOP_RULESET_CACHE_DIR"
  printf '%s\n' '{"a":{"url":"https://example.test/one.json","format":"source","update_interval":"1d","last_success":0},"b":{"url":"https://example.test/two.json","format":"source","update_interval":"1d","last_success":0}}' \
    >"$FORKOP_RULESET_CACHE_MANIFEST"
}

# 4a. Control: without a stop each worker finishes its downloads and
#     requests its reload. One at a time: two workers that share the cache
#     race, and the later one finds nothing changed. (A worker's detached
#     request may carry a stray "1000" from its `1000>&-` under dash.)
for worker in refresh-rulesets-after-start refresh-and-reload; do
  reset_case
  runtime_up
  seed_ruleset_manifest
  : >"$DOWNLOAD_GATE"
  case "$worker" in
    refresh-rulesets-after-start) start_actor ucode -L "$LIB" "$LIB/service/lifecycle.uc" "$worker" ;;
    *) start_actor ucode -L "$LIB" "$LIB/singbox/ruleset_cache.uc" "$worker" "" ;;
  esac
  wait_until 40 process_gone "$LAST_ACTOR" || fail "the $worker worker did not finish"
  wait_until 20 has_event '^init reload ruleset-cache' || fail "the $worker worker did not request its reload"
done

# 4b. A stop while both download: they are terminated, their reload is never
#     requested, and a process that holds a worker's recorded pid but is no
#     refresh worker is left alone. reload.pending is gone.
reset_case
runtime_up
seed_ruleset_manifest
mkdir -p "$STATE_DIR/ruleset-refresh-workers"
sleep 60 &
DECOY_PID=$!
disown "$DECOY_PID"
actors+=("$DECOY_PID")
wait_until 10 process_exec_is "$DECOY_PID" sleep || fail "the decoy process did not start"
ucode -L "$REAL_LIB" -e 'exit(require("core.process_identity").record(ARGV[0], ARGV[1]) ? 0 : 1);' \
  "$STATE_DIR/ruleset-refresh-workers/$DECOY_PID" "$DECOY_PID" || fail "the decoy record was not written"
launch_refresh_workers
wait_until 20 downloads_begun 2 || fail "the refresh workers did not start downloading"
wait_until 20 refresh_workers_recorded 3 || fail "the refresh workers did not record themselves"
printf 'reason=pending\n' >"$FORKOP_PENDING_RELOAD_FILE"
lifecycle stop || true
[ -e "$STOP_MARKER" ] || fail "forkop stop did not record the explicit stop"
wait_until 10 process_gone "$AFTER_START_PID" || fail "forkop stop left the post-start rule-set refresh worker running"
wait_until 10 process_gone "$AND_RELOAD_PID" || fail "forkop stop left the refresh-and-reload worker running"
process_running "$DECOY_PID" || fail "forkop stop signalled a process that is no refresh worker"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "forkop stop left the queued reload behind"
: >"$DOWNLOAD_GATE"
# Their orphaned downloads finish; no reload follows.
sleep 1
no_event '^init reload' || fail "a refresh worker requested a reload after the stop"

# 5. An explicit restart ends the stop and records the explicit start, also
#    when its start fails (only a stop, not a failure, keeps the runtime
#    down).
reset_case
runtime_down
printf 'stop\n' >"$STOP_MARKER"
lifecycle restart || true
grep -q 'Starting Forkop' "$WORK_DIR/syslog" || fail "forkop restart did not reach the start"
[ ! -e "$STOP_MARKER" ] || fail "an explicit restart kept the explicit stop"
[ -e "$START_RECORD" ] || fail "an explicit restart was not recorded as an explicit start"

# 6. A stop records who asked for it: Forkop's own stop for a package or
#    component change (FORKOP_STOP_SOURCE, followed by a start) is told apart
#    from the user's (tests/stopped_by_user_state.sh); both hold reloads off
#    alike. A stop made while the user's stop is in effect stays the user's;
#    any other source is the user's.
stop_source() { sed -n 's/^by=//p' "$STOP_MARKER"; }
for how in init.d lifecycle; do
  for case_ in "package||package" "component||component" "||user" "bogus||user" "package|user|user" "component|package|component"; do
    source="${case_%%|*}"
    rest="${case_#*|}"
    previous="${rest%%|*}"
    want="${rest#*|}"
    reset_case
    runtime_down
    : >"$START_RECORD"
    [ -z "$previous" ] || printf '1.000000001.42\nby=%s\n' "$previous" >"$STOP_MARKER"
    if [ "$how" = init.d ]; then
      FORKOP_STOP_SOURCE="$source" bash "$WORK_DIR/rc" stop >"$WORK_DIR/stop.out" 2>&1 || true
    else
      FORKOP_STOP_SOURCE="$source" lifecycle stop || true
    fi
    [ -e "$STOP_MARKER" ] || fail "$how stop by '$source' did not record the stop"
    [ "$(stop_source)" = "$want" ] ||
      fail "$how stop by '$source' after a stop by '$previous' recorded '$(stop_source)', not '$want'"
    head -n 1 "$STOP_MARKER" | grep -Eq '^[0-9]+\.[0-9]{9}\.[0-9]+$' ||
      fail "$how stop by '$source' changed the stop request value: $(head -n 1 "$STOP_MARKER")"
    # The user's stop ends the explicit start; Forkop's own stop is followed
    # by a start and keeps it (D-15(a)).
    if [ "$want" = user ]; then
      [ ! -e "$START_RECORD" ] || fail "$how stop by the user kept the explicit start"
    else
      [ -e "$START_RECORD" ] || fail "$how stop by '$want' ended the explicit start"
    fi
  done
done
# An internal stop holds reloads off like the user's.
reset_case
runtime_down
printf '1.000000001.42\nby=package\n' >"$STOP_MARKER"
lifecycle reload "" || fail "reload after a package stop failed"
grep -q "Reload '' skipped: Forkop was stopped" "$WORK_DIR/syslog" || fail "a reload started a runtime that a package stop took down"

printf 'user stop sticky checks passed\n'
