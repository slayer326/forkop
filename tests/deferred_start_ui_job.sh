#!/usr/bin/env bash
set -euo pipefail

# The UI job of a non-UI detached start (boot, CLI, postinst) stays a live
# running job for the whole start, and the reload queued during the start is
# applied by that job's waiter once the start has finished (UC-010).
#
# Before UC-010 the job carried the pid of the rc.common shell, which exits
# right after start_service returns: service/ui.uc marked the job "Service
# action worker exited unexpectedly" once ACTION_STALE_GRACE_SECONDS had
# passed, while `forkop start` was still running.
#
# rc.common is emulated as in OpenWrt (fd 1000 open and flocked when the real
# init script's handler runs). service/initd.uc, service/ui.uc and
# service/state.uc are real; `forkop start` blocks until the test releases
# it, and the runtime counts as stably running.

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
  # Waiters and job workers that service/ui.uc detached.
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

STALE_GRACE=1
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" EVENTS REAL_INITD REAL_UCODE
export TEST_LIB="$LIB"
export LOCK="$WORK_DIR/run/forkop.reload.lock"
export RC_PROCD_LOCK="$WORK_DIR/procd_forkop.lock"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_RELOAD_LOCK_DIR="$LOCK"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/forkop/reload.pending"
export FORKOP_START_IN_PROGRESS_FILE="$WORK_DIR/run/forkop/start.in-progress"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_START_RETRY_DELAY_SECONDS=300
export FORKOP_UI_STATE_DIR="$WORK_DIR/ui-state"
export FORKOP_UI_SERVICE_ACTION_DIR="$FORKOP_UI_STATE_DIR/service-actions"
export FORKOP_UI_SERVICE_ACTION_LOCK_DIR="$FORKOP_UI_STATE_DIR/service-actions.lock"
export FORKOP_UI_LATENCY_ACTION_DIR="$FORKOP_UI_STATE_DIR/latency-actions"
export FORKOP_UI_COMPONENT_ACTION_DIR="$FORKOP_UI_STATE_DIR/component-actions"
export FORKOP_UI_SUBSCRIPTION_ACTION_DIR="$FORKOP_UI_STATE_DIR/subscription-actions"
export FORKOP_LATENCY_TEST_LOCK_DIR="$WORK_DIR/run/forkop/automatic-latency-test.lock"
export FORKOP_UI_ACTION_STALE_GRACE_SECONDS="$STALE_GRACE"
export FORKOP_UI_SERVICE_ACTION_SETTLE_SECONDS=1
export FORKOP_UI_SERVICE_ACTION_TIMEOUT_SECONDS=20
unset FORKOP_UI_ACTION_TRACKED

# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
# /etc/init.d/forkop: records who applies a queued reload (a service/ui.uc
# job worker runs it with FORKOP_UI_ACTION_TRACKED=1).
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
printf 'init %s tracked=%s\n' "$1 $2" "${FORKOP_UI_ACTION_TRACKED:-0}" >>"$EVENTS"
exec bash "$TEST_WORK/rc" "$@"
SH

# The runtime counts as stably running; DNS failsafe, nft guards, validation
# and health are outside this contract.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/state.uc)
    [ "${4:-}" != forkop-stably-running ] || exit 0
    ;;
  */dns/apply.uc | */nft/apply.uc | */config/validator.uc | */diagnostics/health.uc) exit 0 ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
SH

# `forkop start` runs until start.gate exists; a reload records whether it
# ran next to a start.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
ev() { printf '%s\n' "$1" >>"$EVENTS"; }
case "$1" in
  start)
    printf '%s\n' "$$" >"$TEST_WORK/start.running"
    ev "start begin"
    n=0
    while [ ! -e "$TEST_WORK/start.gate" ]; do
      n=$((n + 1))
      [ "$n" -lt 1200 ] || { ev "start gate timeout"; break; }
      sleep 0.05
    done
    ev "start end"
    rm -f "$TEST_WORK/start.running"
    exit 0
    ;;
  reload)
    if [ -e "$TEST_WORK/start.running" ]; then ev "reload during start"; else ev "reload after start"; fi
    ;;
  get_status) printf '{"running":true}\n' ;;
esac
exit 0
SH

# rc.common stand-in: sourcing procd.sh opens and flocks fd 1000 before any
# handler runs; bash stands in for busybox ash (dash has no fd above 9).
cat >"$WORK_DIR/rc" <<'SH'
#!/usr/bin/env bash
action="$1"
shift
printf '%s\n' "$$" >"$TEST_WORK/rc-$action.pid"
exec 1000>"$RC_PROCD_LOCK"
flock 1000
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
case "$action" in
  start) start_service "$@" ;;
  reload) reload_service "$@" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$WORK_DIR/bin/ucode" "$WORK_DIR/bin/forkop" "$WORK_DIR/bin/logger" \
  "$WORK_DIR/bin/nft" "$WORK_DIR/bin/init" "$WORK_DIR/rc"

ui() { "$REAL_UCODE" -L "$LIB" "$LIB/service/ui.uc" "$@"; }
has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
job_file() {
  local path
  for path in "$FORKOP_UI_SERVICE_ACTION_DIR"/*.json; do
    [ -e "$path" ] || continue
    grep -q "\"action\": *\"$1\"" "$path" && { printf '%s\n' "$path"; return 0; }
  done
  return 1
}
job_field() { sed -n "s/.*\"$2\": *\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p" "$1" | head -n 1; }
no_active_action() { ! ui active-service-action >/dev/null 2>&1; }
clock_after() { [ "$(date +%s)" -gt "$1" ]; }

: >"$EVENTS"

# 1. A non-UI start, as rcS runs it: init.d returns at once and the detached
#    worker owns reload.lock and the UI start job.
status=0
setsid timeout -s KILL 90 bash "$WORK_DIR/rc" start manual >"$WORK_DIR/rc-start.out" 2>&1 &
caller=$!
actors+=("$caller")
wait_until 10 process_gone "$caller" || fail "init.d start did not return while the start worker runs"
wait "$caller" || status=$?
[ "$status" = 0 ] || fail "init.d start returned $status: $(cat "$WORK_DIR/rc-start.out")"
wait_until 10 file_nonempty "$WORK_DIR/start.running" || fail "detached start did not reach its backend"
START_JOB="$(job_file start)" || fail "the start registered no UI job"
owner="$("$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" runtime-dir-lock-owner "$LOCK")" ||
  fail "the detached start does not hold reload.lock"
[ "$(job_field "$START_JOB" pid)" = "$owner" ] ||
  fail "the UI start job is tracked under pid '$(job_field "$START_JOB" pid)', not the reload.lock owner $owner"

# 2. The job stays running past the stale grace while `forkop start` runs:
#    status reads refresh it against the live worker.
started_at="$(job_field "$START_JOB" started_at)"
wait_until 10 clock_after "$((started_at + STALE_GRACE + 1))" || fail "clock did not advance"
[ "$(ui active-service-action)" = start ] || fail "the start job is not the active service action past the stale grace"
ui service-action-status "$(basename "$START_JOB" .json)" | grep -q '"running": *true' ||
  fail "the start job turned stale while the start runs: $(cat "$START_JOB")"
[ -e "$WORK_DIR/start.running" ] || fail "the start backend ended early"

# 3. A reload requested during the start is queued, not run next to it.
status=0
timeout -s KILL 30 bash "$WORK_DIR/rc" reload badwan_interface_up >"$WORK_DIR/rc-reload.out" 2>&1 || status=$?
[ "$status" = 0 ] || fail "queued reload returned $status: $(cat "$WORK_DIR/rc-reload.out")"
[ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the reload was neither run nor queued"
has_event '^reload' && fail "a reload ran next to the start"

# 4. The start finishes as success, and its waiter (the start job is still
#    active when the start releases reload.lock) applies the queued reload
#    once, through a tracked UI reload job.
touch "$WORK_DIR/start.gate"
wait_until 30 has_event '^reload after start$' || fail "the queued reload was not applied after the start"
wait_until 30 no_active_action || fail "a service action is still running after the start and its queued reload"
wait_until 10 test ! -e "$LOCK" || fail "reload.lock was not released"
grep -q '"success": *true' "$START_JOB" || fail "the start job did not finish as success: $(cat "$START_JOB")"
grep -q 'exited unexpectedly' "$START_JOB" && fail "the start job was marked stale: $(cat "$START_JOB")"
has_event '^reload during start$' && fail "a reload ran next to the start"
[ "$(grep -c '^reload after start$' "$EVENTS")" = 1 ] || fail "the queued reload did not run exactly once"
[ "$(grep -c '^init ' "$EVENTS")" = 1 ] || fail "the queued reload was applied more than once"
# service/initd.uc's own drain would run `init.d reload pending` untracked.
has_event '^init reload .*tracked=1$' || fail "the queued reload was not applied by the start job's waiter"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the queued reload is still pending"

printf 'deferred start UI job checks passed\n'
