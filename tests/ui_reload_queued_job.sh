#!/usr/bin/env bash
# A service reload from the UI is reported as done only when it ran (UC-061).
#
# service/ui.uc runs `init.d reload` for the job of a UI reload (the URLTest
# settings save on the dashboard asks for one) and for the reload that
# applies a queued request after a service action. While another operation
# holds reload.lock (a list or subscription update, a start, another reload)
# service/initd.uc only queues the request and init.d exits 0: the job said
# "Service reload completed" for a reload that had not run, and, as a
# success, applied the queued request at once in a job of its own, which was
# queued again. After an explicit stop init.d skips the reload: the job said
# "completed" as well.
#
# init.d now tells the UI-tracked caller "queued" or "stopped", as it tells
# a snapshot restore: the job ends as queued (not a success; while the lock
# is still held it applies nothing on its behalf: the lock holder drains the
# request) or as skipped because Forkop is stopped. A reload that ran
# completes as before. A holder that released reload.lock before the queued
# job ended may have drained the queue while the job still ran (init.d then
# leaves the request queued for that job) or not at all: the job applies the
# request itself once the lock is free, or it would wait for an unrelated
# later reload.
#
# service/ui.uc, service/initd.uc, service/state.uc and the init.d script
# are real; init.d runs behind an rc.common stand-in that holds fd 1000 like
# procd.sh, and `forkop reload` only records that it ran.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"
LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
REAL_UCODE="$(command -v ucode)"
WORK_DIR="$(mktemp -d)"

cleanup() {
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp"
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
export FORKOP_SNAPSHOT_DIR="$WORK_DIR/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$STATE_DIR/snapshot-hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$STATE_DIR/config-snapshot.lock"
export FORKOP_OPKG_RECOVERY_DIR="$WORK_DIR/opkg-recovery"
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$FORKOP_UI_STATE_DIR/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$FORKOP_UI_STATE_DIR/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$FORKOP_UI_STATE_DIR/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$FORKOP_UI_STATE_DIR/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$FORKOP_UI_STATE_DIR/subscription-actions"
export FORKOP_LATENCY_TEST_LOCK_DIR="$STATE_DIR/automatic-latency-test.lock"
export FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1
export FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=5
unset FORKOP_UI_ACTION_TRACKED

# Nothing here may reach the host's syslog, nftables or routing.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/ubus"

# service/initd.uc calls lifecycle directly after taking reload.lock. The
# lifecycle itself is outside this UI result contract, so record that call.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
if [ "${3:-}" = "$TEST_LIB/service/lifecycle.uc" ] && [ "${4:-}" = reload ]; then
  exec "$FORKOP_BIN" reload "${5:-}"
fi
exec "$REAL_UCODE" "$@"
SH

# `forkop`: a reload only records that it ran; get_status reports the
# runtime as running while runtime.up exists.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  reload) printf 'reload ran %s\n' "${2:-}" >>"$EVENTS" ;;
  get_status)
    if [ -e "$TEST_WORK/runtime.up" ]; then printf '{"running":true}\n'; else printf '{"running":false}\n'; fi
    ;;
esac
exit 0
SH

# /etc/init.d/forkop as procd runs it: rc.common with fd 1000 open and
# flocked (procd.sh procd_lock); bash stands in for busybox ash. While
# init.hold exists, the next UI-tracked call is held after init.d returned
# (the procd lock is free again) and before its job records the outcome,
# until init.go appears.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
status=0
bash "$TEST_WORK/rc" "$@" || status=$?
if [ "${FORKOP_UI_ACTION_TRACKED:-}" = 1 ] && rm "$TEST_WORK/init.hold" 2>/dev/null; then
  : >"$TEST_WORK/init.held"
  n=0
  while [ ! -e "$TEST_WORK/init.go" ] && [ "$n" -lt 1200 ]; do
    sleep 0.05
    n=$((n + 1))
  done
fi
exit "$status"
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

# job_state JOB: "running=<bool> success=<bool> outcome=<token> message=<text>"
job_state() {
  ucode -e 'let s = json(require("fs").readfile(ARGV[0])); print(sprintf("running=%s success=%s outcome=%s message=%s\n", s.running, s.success, s.outcome ?? "", s.message));' \
    "$FORKOP_UI_SERVICE_ACTION_DIR/$1.json"
}

# A live lifecycle action owns reload.lock (the legacy pid record).
hold_lock() {
  mkdir "$FORKOP_RELOAD_LOCK_DIR"
  sleep 300 >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$FORKOP_RELOAD_LOCK_DIR/pid"
  printf '%s\n' "$!" >"$WORK_DIR/holder"
}
release_lock() {
  kill "$(cat "$WORK_DIR/holder")" 2>/dev/null || true
  rm -f "$WORK_DIR/holder" "$FORKOP_RELOAD_LOCK_DIR/pid"
  rmdir "$FORKOP_RELOAD_LOCK_DIR"
}

reset_case() {
  pkill -KILL -f "$FORKOP_UI_SERVICE_ACTION_DIR/" 2>/dev/null || true
  [ ! -e "$WORK_DIR/holder" ] || release_lock
  rm -rf "$FORKOP_UI_STATE_DIR" "$STATE_DIR/health-events.json" "$FORKOP_PENDING_RELOAD_FILE" "$STOP_MARKER" \
    "$WORK_DIR/init.hold" "$WORK_DIR/init.held" "$WORK_DIR/init.go"
  : >"$START_RECORD"
  : >"$WORK_DIR/runtime.up"
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
}

# ui_reload REASON: runs the job of a UI reload to its end; prints the job id.
ui_reload() {
  local job
  job="$(ui service-action-begin-if-idle reload "${2:-ui}")" || fail "the reload job was not opened"
  timeout -s KILL 60 ucode -L "$LIB" "$LIB/service/ui.uc" service-action-worker \
    "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json" reload "$job" "$1" >/dev/null 2>&1 ||
    fail "the reload job worker did not finish in time"
  printf '%s\n' "$job"
}
only_job() {
  local count
  count="$(find "$FORKOP_UI_SERVICE_ACTION_DIR" -name '*.json' | wc -l)"
  [ "$count" = 1 ] || fail "$1: $count service action jobs, expected only its own"
}

# 1. Control: with reload.lock free the reload runs and completes.
reset_case
job="$(ui_reload "")"
grep -q '^reload ran' "$EVENTS" || fail "control: the UI reload did not run"
state="$(job_state "$job")"
[ "$state" = "running=false success=true outcome= message=Service reload completed" ] ||
  fail "control: the UI reload that ran did not complete: $state"

# 2. A list update holds reload.lock: the UI reload is only queued. The job
#    says so and is no success; it does not apply the queued request itself
#    (the lock holder drains it), so no second job churns behind it.
reset_case
hold_lock
job="$(ui_reload "")"
! grep -q '^reload ran' "$EVENTS" || fail "queued: the reload ran although another operation held reload.lock"
state="$(job_state "$job")"
case "$state" in
  "running=false success=false outcome=queued message=Service reload queued"*) ;;
  *) fail "queued: the UI job did not report the queued reload: $state" ;;
esac
only_job "queued"
[ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "queued: the queued request was consumed by the UI job"

# 3. The job that applies a queued request after a service action
#    ("pending") while the lock is still held: queued again, no churn.
job="$(ui_reload pending initd)"
state="$(job_state "$job")"
case "$state" in
  "running=false success=false outcome=queued message=Service reload queued"*) ;;
  *) fail "pending: the job of a queued request did not report it queued again: $state" ;;
esac
[ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "pending: the queued request was lost"

# 4. After an explicit stop the reload is skipped: the job says so instead
#    of "completed"; skipping it is no failure.
reset_case
printf 'stop\n' >"$STOP_MARKER"
rm -f "$WORK_DIR/runtime.up"
job="$(ui_reload "")"
! grep -q '^reload ran' "$EVENTS" || fail "stopped: the reload ran after an explicit stop"
state="$(job_state "$job")"
case "$state" in
  "running=false success=true outcome=stopped message=Service reload skipped"*) ;;
  *) fail "stopped: the UI job did not report the skipped reload: $state" ;;
esac

# 5. The holder releases reload.lock after init.d queued the UI reload and
#    before its job ended: it drained the queue while the job still ran
#    ("drain": init.d leaves the request queued for the running job) or it
#    drains nothing on release ("release"). The job, queued, then applies the
#    request itself: nobody else is left to (UC-061).
reload_ran_pending() { grep -q '^reload ran pending$' "$EVENTS"; }
for variant in drain release; do
  reset_case
  hold_lock
  : >"$WORK_DIR/init.hold"
  job="$(ui service-action-begin-if-idle reload ui)" || fail "$variant: the reload job was not opened"
  timeout -s KILL 60 ucode -L "$LIB" "$LIB/service/ui.uc" service-action-worker \
    "$FORKOP_UI_SERVICE_ACTION_DIR/$job.json" reload "$job" "" >/dev/null 2>&1 &
  worker=$!
  wait_until 20 test -e "$WORK_DIR/init.held" || fail "$variant: init.d of the UI reload did not return"
  [ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "$variant: init.d did not queue the UI reload"
  release_lock
  if [ "$variant" = drain ]; then
    ucode -L "$LIB" "$LIB/service/state.uc" run-pending-reload-if-requested \
      "$FORKOP_PENDING_RELOAD_FILE" "$FORKOP_SERVICE_INIT" || fail "drain: the holder's drain failed"
    [ -e "$FORKOP_PENDING_RELOAD_FILE" ] ||
      fail "drain: the holder's drain did not leave the request to the running UI job"
  fi
  : >"$WORK_DIR/init.go"
  wait "$worker" || fail "$variant: the reload job worker failed"
  state="$(job_state "$job")"
  case "$state" in
    "running=false success=false outcome=queued message=Service reload queued"*) ;;
    *) fail "$variant: the UI job did not report the queued reload: $state" ;;
  esac
  wait_until 20 reload_ran_pending || fail "$variant: the queued UI reload never ran"
  wait_until 20 test ! -e "$FORKOP_PENDING_RELOAD_FILE" || fail "$variant: the queued request was left behind"
done

printf 'ui reload queued job checks passed\n'
