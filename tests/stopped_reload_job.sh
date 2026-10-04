#!/usr/bin/env bash
# A reload after an explicit stop leaves no service action behind (UC-012).
#
# No reload brings an explicitly stopped runtime back, whoever requests it:
# background work on its own (the list worker, the rule-set refresh, the
# deferred subscription recovery, a queued request, procd's triggers) and a
# manual reload alike; only a start does (D-15, UC-056). Before
# that was decided, service/initd.uc had already opened a UI "reload" job:
# the skipped reload returned 0, service/ui.uc waited for the runtime to run
# again, and with the service enabled the stopped Forkop showed as
# "reloading" for SERVICE_ACTION_TIMEOUT_SECONDS; a UI start was refused as
# "Another service action is already running", the job then failed as "did
# not reach expected state", and health recorded a successful reload.
#
# service/initd.uc, service/ui.uc, service/state.uc, diagnostics/health.uc
# and, for a reload after a stop, service/lifecycle.uc are real;
# init.d runs behind an rc.common stand-in that holds fd 1000 like procd.sh.
# The service counts as enabled through /etc/rc.d/S99forkop, which exists
# only in a private user+mount namespace (/etc is an overlay there). The test
# is skipped only when such a namespace cannot be created here.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
PUBLIC_CLI="$ROOT_DIR/forkop/files/usr/bin/forkop"
REAL_UCODE="$(command -v ucode)"
NAMESPACE=(unshare --user --map-root-user --mount --propagation private)

namespaces() { printf '%s %s' "$(readlink /proc/self/ns/user)" "$(readlink /proc/self/ns/mnt)"; }

# An overlay keeps the host's /etc visible and takes the new files.
mount_etc_overlay() {
  mkdir -p "$1/upper" "$1/work"
  mount -t overlay overlay -o "lowerdir=/etc,upperdir=$1/upper,workdir=$1/work" /etc
}

if [ "${1:-}" != "--in-namespace" ]; then
  skip() {
    printf 'SKIP: stopped_reload_job: %s\n' "$1"
    exit 0
  }
  command -v unshare >/dev/null 2>&1 || skip 'unshare is not installed'
  PROBE_DIR="$(mktemp -d)"
  probe_status=0
  probe="$("${NAMESPACE[@]}" bash -c "$(declare -f mount_etc_overlay); mount_etc_overlay \"\$1\" && mkdir -p /etc/rc.d" \
    probe "$PROBE_DIR" 2>&1)" || probe_status=$?
  chmod -R u+rwx "$PROBE_DIR" 2>/dev/null || true
  rm -rf "$PROBE_DIR"
  [ "$probe_status" = 0 ] || skip "a private user+mount namespace with an overlay on /etc is unavailable: $probe"
  FORKOP_STOPPED_RELOAD_HOST_NAMESPACES="$(namespaces)" exec "${NAMESPACE[@]}" bash "$0" --in-namespace
fi

# ---- inside the namespace ---------------------------------------------------

refuse() {
  printf 'FAIL: --in-namespace is only for the private namespace this test creates (%s)\n' "$1" >&2
  exit 1
}
# Never mount over the caller's /etc. The environment can be forged, the
# user namespace cannot: only one that maps nothing but root, as `unshare
# --map-root-user` creates it, is accepted, and both namespaces must be new.
mapfile -t uid_map </proc/self/uid_map
read -r map_inside _ map_count <<<"${uid_map[0]:-}"
if [ "${#uid_map[@]}" != 1 ] || [ "$map_inside" != 0 ] || [ "$map_count" != 1 ]; then
  refuse "not a user namespace mapping only root: ${uid_map[*]:-}"
fi
read -r host_user host_mnt <<<"${FORKOP_STOPPED_RELOAD_HOST_NAMESPACES:-}"
read -r own_user own_mnt <<<"$(namespaces)"
if [ -z "${host_user:-}" ] || [ "$own_user" = "$host_user" ] || [ "$own_mnt" = "${host_mnt:-}" ]; then
  refuse "the user or mount namespace is not new"
fi

WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

cleanup() {
  # Waiters and job workers that service/ui.uc detached.
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  umount /etc 2>/dev/null || true
  chmod -R u+rwx "$WORK_DIR" 2>/dev/null || true
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

mount_etc_overlay "$WORK_DIR/etc-overlay" || refuse "cannot mount the /etc overlay"
mkdir -p /etc/rc.d
printf '#!/bin/sh\nexit 0\n' >/etc/rc.d/S99forkop
chmod +x /etc/rc.d/S99forkop

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp"
cat >"$WORK_DIR/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=1
EOF
: >"$WORK_DIR/forkop.config"

STATE_DIR="$WORK_DIR/run/forkop"
export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export RC_PROCD_LOCK="$WORK_DIR/procd_forkop.lock"
export STOP_MARKER="$STATE_DIR/stop.requested"
export START_RECORD="$STATE_DIR/start.explicit"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_SERVICE_NAME=forkop
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_START_IN_PROGRESS_FILE="$STATE_DIR/start.in-progress"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
# A regressed lifecycle gate goes on with the reload and takes an automatic
# snapshot (config/snapshots.uc): never in the host's /var/run or /etc.
export FORKOP_SNAPSHOT_DIR="$WORK_DIR/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$STATE_DIR/snapshot-hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$STATE_DIR/config-snapshot.lock"
export FORKOP_OPKG_RECOVERY_DIR="$WORK_DIR/opkg-recovery"
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$FORKOP_UI_STATE_DIR/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$FORKOP_UI_STATE_DIR/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$FORKOP_UI_STATE_DIR/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$FORKOP_UI_STATE_DIR/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$FORKOP_UI_STATE_DIR/subscription-actions"
export FORKOP_LATENCY_TEST_LOCK_DIR="$STATE_DIR/automatic-latency-test.lock"
export FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1
# Long enough that a waiter still runs when the checks below look.
export FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=60
unset FORKOP_UI_ACTION_TRACKED

# Nothing here may reach the host's syslog, nftables or routing: without the
# production table the runtime is down.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/ubus"

# initd now invokes lifecycle.uc directly once it owns reload.lock. Preserve
# this test's lifecycle model, while calls made by the model itself still use
# the real module.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
if [ "${3:-}" = "$TEST_LIB/service/lifecycle.uc" ] && [ "${4:-}" = reload ] &&
   [ -e "$FORKOP_RELOAD_LOCK_DIR" ]; then
  exec "$FORKOP_BIN" reload "${5:-}"
fi
exec "$REAL_UCODE" "$@"
SH

# `forkop`. A reload after a stop, or of a Forkop not started since boot (no
# start record), runs the real lifecycle.uc, whose gate returns before it
# touches anything. Any other reload is only recorded: here it stands for a
# reload that runs. get_status reports the runtime as running while
# runtime.up exists.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  reload)
    if [ -e "$STOP_MARKER" ] || [ ! -e "$START_RECORD" ]; then
      ev "lifecycle reload ${2:-}"
      exec ucode -L "$TEST_LIB" "$TEST_LIB/service/lifecycle.uc" reload "${2:-}"
    fi
    ev "reload ran ${2:-}"
    ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":true}\n'; else printf '{"running":false}\n'; fi
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
  reload) reload_service "$@" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc"

ui() { ucode -L "$LIB" "$LIB/service/ui.uc" "$@"; }

has_event() { grep -qx "$1" "$EVENTS" 2>/dev/null; }

no_active_service_action() {
  [ -z "$(ui active-service-action)" ]
}

# A UI start is accepted: no service action is left running. The probe job
# is finished at once.
ui_start_accepted() {
  local job status=0
  job="$(ui service-action-begin-if-idle start ui)" || status=$?
  [ "$status" = 0 ] && [ -n "$job" ] || return 1
  rm -f "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json"
}

# job_state JOB: "running=<bool> success=<bool> message=<text>"
job_state() {
  ucode -e 'let s = json(require("fs").readfile(ARGV[0])); print(sprintf("running=%s success=%s message=%s\n", s.running, s.success, s.message));' \
    "$FORKOP_UI_SERVICE_ACTION_DIR/$1.json"
}

no_reload_health_event() {
  ! grep -q '"kind": *"reload"' "$STATE_DIR/health-events.json" 2>/dev/null
}

reset_case() {
  # Waiters that service/ui.uc left for this test's jobs (never another
  # test's processes: their commands name its own job directory).
  pkill -KILL -f "$FORKOP_UI_SERVICE_ACTION_DIR/" 2>/dev/null || true
  rm -rf "$FORKOP_UI_STATE_DIR" "$STATE_DIR/health-events.json" "$FORKOP_HISTORY_FILE" \
    "$FORKOP_PENDING_RELOAD_FILE" "$WORK_DIR/runtime.up" "$START_RECORD"
  printf 'stop\n' >"$STOP_MARKER"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload.lock leaked from the previous case"
}

# 1. Each reload that init.d runs after an explicit stop, a manual one ("")
#    too: no UI job is opened, a UI start is accepted at once, health records
#    no reload and the stopped runtime is left alone.
for reason in ruleset-cache list-content subscription_deferred_recovery pending badwan_interface_up on_config_change ""; do
  reset_case
  output="$("$FORKOP_SERVICE_INIT" reload "$reason")" || fail "reload '$reason' after a stop failed"
  [ -z "$output" ] || fail "reload '$reason' after a stop printed '$output'"
  no_active_service_action || fail "reload '$reason' after a stop left a '$(ui active-service-action)' service action running"
  if compgen -G "$FORKOP_UI_SERVICE_ACTION_DIR/*.json" >/dev/null; then
    fail "reload '$reason' after a stop opened a UI job"
  fi
  if grep -q '^lifecycle reload' "$EVENTS"; then
    fail "init.d ran reload '$reason' after a stop"
  fi
  ui_start_accepted || fail "a UI start was refused after reload '$reason' after a stop"
  no_reload_health_event || fail "health recorded reload '$reason' that a stop skipped"
  if grep -q '^reload ran' "$EVENTS"; then
    fail "reload '$reason' after a stop reloaded the runtime"
  fi
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload '$reason' after a stop left reload.lock behind"
  [ -e "$STOP_MARKER" ] || fail "reload '$reason' ended the explicit stop"
  grep -q "Reload '$reason' skipped: Forkop was stopped" "$WORK_DIR/syslog" ||
    fail "skipped reload '$reason' was not logged"
done

# 2. The stop comes after init.d's check (the runtime still ran then), so the
#    lifecycle's own gate under reload.lock skips the reload: the job init.d
#    opened completes at once instead of waiting for the stopped runtime, and
#    health records no reload.
reset_case
: >"$WORK_DIR/runtime.up"
"$FORKOP_SERVICE_INIT" reload ruleset-cache >/dev/null || fail "a reload skipped by the lifecycle gate failed"
has_event "lifecycle reload ruleset-cache" || fail "the reload did not reach the lifecycle gate"
wait_until 10 no_active_service_action || fail "the job of a reload skipped by the lifecycle gate stays running"
ui_start_accepted || fail "a UI start was refused after a reload skipped by the lifecycle gate"
no_reload_health_event || fail "health recorded a reload that the lifecycle gate skipped"

# 3. The public CLI enters initd's gate before a UI job is opened.
reset_case
"$REAL_UCODE" "$PUBLIC_CLI" reload ruleset-cache || fail "a direct background reload after a stop failed"
if grep -q '^lifecycle reload\|^reload ran' "$EVENTS"; then
  fail "the public CLI bypassed initd's stopped gate"
fi
no_active_service_action || fail "a direct background reload after a stop left a service action running"
no_reload_health_event || fail "health recorded a direct background reload that a stop skipped"

# 4. A queued reload that service/ui.uc applies in a job of its own keeps its
#    reason, so it is skipped after a stop too, and its job ends without
#    waiting for the stopped runtime: no failure, but no reload either
#    (UC-061).
reset_case
job="$(ui service-action-begin-if-idle reload initd)" || fail "the queued reload job was not opened"
timeout -s KILL 30 ucode -L "$LIB" "$LIB/service/ui.uc" service-action-worker \
  "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json" reload "$job" pending ||
  fail "the queued reload job worker did not finish in time"
state="$(job_state "$job")"
case "$state" in
  "running=false success=true message=Service reload skipped: Forkop is stopped"*) ;;
  *) fail "the queued reload job after a stop did not end as skipped: $state" ;;
esac
if grep -q '^reload ran' "$EVENTS"; then
  fail "the queued reload that service/ui.uc applied after a stop ran as a manual reload"
fi
ui_start_accepted || fail "a UI start was refused after the queued reload job"

# 5. Controls: without a stop request, after an explicit start (the runtime
#    went down since), the reload runs as before, a manual one too.
for reason in ruleset-cache ""; do
  reset_case
  rm -f "$STOP_MARKER"
  : >"$START_RECORD"
  "$FORKOP_SERVICE_INIT" reload "$reason" >/dev/null || fail "reload '$reason' without a stop failed"
  has_event "reload ran $reason" || fail "reload '$reason' without a stop request did not run"
done

# 6. Forkop not started since boot (here autostart was enabled after the
#    boot): no stop, no start record. Its reload is skipped like one after a
#    stop: no UI job, a UI start is accepted at once, health records nothing
#    and the runtime is left alone (D-15(a)).
not_started_case() {
  reset_case
  rm -f "$STOP_MARKER"
}
for reason in ruleset-cache list-content pending ""; do
  not_started_case
  output="$("$FORKOP_SERVICE_INIT" reload "$reason")" || fail "reload '$reason' of a Forkop not started failed"
  [ -z "$output" ] || fail "reload '$reason' of a Forkop not started printed '$output'"
  no_active_service_action || fail "reload '$reason' of a Forkop not started left a service action running"
  if compgen -G "$FORKOP_UI_SERVICE_ACTION_DIR/*.json" >/dev/null; then
    fail "reload '$reason' of a Forkop not started opened a UI job"
  fi
  if grep -q '^lifecycle reload\|^reload ran' "$EVENTS"; then
    fail "init.d ran reload '$reason' of a Forkop not started"
  fi
  ui_start_accepted || fail "a UI start was refused after reload '$reason' of a Forkop not started"
  no_reload_health_event || fail "health recorded reload '$reason' of a Forkop not started"
  grep -q "Reload '$reason' skipped: Forkop was not started" "$WORK_DIR/syslog" ||
    fail "skipped reload '$reason' of a Forkop not started was not logged"
done

# 6b. The runtime went down after init.d's check: the lifecycle gate skips
#     the reload and the job init.d opened completes at once.
not_started_case
: >"$WORK_DIR/runtime.up"
"$FORKOP_SERVICE_INIT" reload ruleset-cache >/dev/null || fail "a reload of a Forkop not started skipped by the lifecycle gate failed"
has_event "lifecycle reload ruleset-cache" || fail "the reload of a Forkop not started did not reach the lifecycle gate"
wait_until 10 no_active_service_action || fail "the job of a reload of a Forkop not started stays running"
no_reload_health_event || fail "health recorded a reload of a Forkop not started"
grep -q "Reload 'ruleset-cache' skipped: Forkop was not started" "$WORK_DIR/syslog" ||
  fail "the lifecycle gate did not skip the reload of a Forkop not started"

# 6c. A queued reload that service/ui.uc applies in a job of its own ends
#     as skipped without waiting for a runtime that nobody started.
not_started_case
job="$(ui service-action-begin-if-idle reload initd)" || fail "the queued reload job was not opened"
timeout -s KILL 30 ucode -L "$LIB" "$LIB/service/ui.uc" service-action-worker \
  "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json" reload "$job" pending ||
  fail "the queued reload job worker did not finish in time"
state="$(job_state "$job")"
case "$state" in
  "running=false success=true message=Service reload skipped: Forkop is stopped"*) ;;
  *) fail "the queued reload job of a Forkop not started did not end as skipped: $state" ;;
esac

printf 'stopped reload job checks passed\n'
