#!/usr/bin/env bash
set -euo pipefail

# The detached init.d start owns reload.lock for its whole run (UC-010).
# procd.sh opens its service lock on fd 1000 whenever rc.common sources it,
# so start_service always detaches the start worker and returns at once. The
# worker must hold reload.lock (and the UI job) under its own identity, pid
# plus start ticks, not under the rc.common shell's $$, which exits right
# after start_service returns: a lock with a dead owner is taken over by the
# next contender, and a reload then runs next to the start.
#
# rc.common is emulated as in OpenWrt: fd 1000 is open and flocked when the
# real init script's start_service runs. service/initd.uc, service/state.uc,
# config/snapshots.uc and autotune/apply.uc are real; `forkop start` blocks
# until the test releases it.

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

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/snapshots"
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
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_START_RETRY_DELAY_SECONDS=300
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_SNAPSHOT_DIR="$WORK_DIR/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK_DIR/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK_DIR/run/forkop/config-snapshot.lock"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_RELOAD_COMMAND="$WORK_DIR/bin/no-init"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK_DIR/autotune-apply.json"
export FORKOP_AUTOTUNE_STATE_DIR="$WORK_DIR/run/forkop/autotune"
unset FORKOP_UI_ACTION_TRACKED

# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
# /etc/init.d/forkop: a queued reload is applied through the init script.
cat >"$WORK_DIR/bin/init" <<'SH'
#!/bin/sh
exec bash "$TEST_WORK/rc" "$@"
SH

# The UI job tracker records the pid the start registers for its job; DNS
# failsafe, nft guards, validation and history are outside this contract.
cat >"$WORK_DIR/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/ui.uc)
    case "${4:-}" in
      service-action-begin-if-idle) printf 'job-%s\n' "$5" ;;
      service-action-update-pid) printf '%s\n' "$6" >"$TEST_WORK/ui-$5.pid" ;;
      service-action-finish-after-command) printf '%s %s %s\n' "$5" "$6" "$7" >>"$TEST_WORK/ui-finished" ;;
    esac
    exit 0
    ;;
  */dns/apply.uc | */nft/apply.uc | */config/validator.uc | */diagnostics/health.uc) exit 0 ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
SH

# `forkop start` runs until START_GATE exists; a reload records whether it
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

# rc.common stand-in: sourcing procd.sh runs procd_lock, which opens and
# flocks fd 1000 before any handler runs; then the real handler runs. bash
# stands in for busybox ash: dash has no file descriptors above 9.
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
  "$WORK_DIR/bin/no-init" "$WORK_DIR/bin/nft" "$WORK_DIR/bin/init" "$WORK_DIR/rc"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
# The live reload.lock owner, read through the lock helper (core/runtime_lock.uc).
lock_owner() { "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" runtime-dir-lock-owner "$LOCK" 2>/dev/null || true; }
start_ticks() {
  local stat
  IFS= read -r stat <"/proc/$1/stat" || return 1
  stat="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $stat
  shift 19
  printf '%s\n' "$1"
}
descends_from() {
  local pid="$1" ancestor="$2" _
  for _ in 1 2 3 4; do
    pid="$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)"
    [ -n "$pid" ] || return 1
    [ "$pid" = "$ancestor" ] && return 0
  done
  return 1
}
start_finished() { [ ! -e "$WORK_DIR/start.running" ] && grep -q '^start ' "$WORK_DIR/ui-finished" 2>/dev/null; }

# `/etc/init.d/forkop start` as rcS, procd or a caller runs it: it returns at
# once, and the detached worker carries on without fd 1000.
deferred_start() {
  local status=0 caller
  : >"$EVENTS"
  rm -f "$WORK_DIR/start.gate" "$WORK_DIR/ui-finished" "$FORKOP_PENDING_RELOAD_FILE"
  setsid timeout -s KILL 90 bash "$WORK_DIR/rc" start manual >"$WORK_DIR/rc-start.out" 2>&1 &
  caller=$!
  actors+=("$caller")
  wait_until 10 process_gone "$caller" || fail "init.d start did not return while the start worker runs"
  wait "$caller" || status=$?
  [ "$status" = 0 ] || fail "init.d start returned $status: $(cat "$WORK_DIR/rc-start.out")"
  wait_until 10 file_nonempty "$WORK_DIR/start.running" || fail "detached start did not reach its backend"
  RC_PID="$(cat "$WORK_DIR/rc-start.pid")"
  BACKEND_PID="$(cat "$WORK_DIR/start.running")"
}

owner_holds_lock() {
  local label="$1" owner
  owner="$(lock_owner)"
  [ -n "$owner" ] || fail "$label: reload.lock has no owner while the start runs"
  [ "$owner" != "$RC_PID" ] || fail "$label: reload.lock names the rc.common shell that already exited"
  process_running "$owner" || fail "$label: reload.lock owner $owner is dead while the start runs"
  [ -e "$LOCK/owner.$owner.$(start_ticks "$owner")" ] ||
    fail "$label: reload.lock records no owner with the start ticks of $owner: $(ls -A "$LOCK" | tr '\n' ' ')"
  tr '\0' ' ' <"/proc/$owner/cmdline" | grep -q 'service/initd.uc start-service' ||
    fail "$label: reload.lock owner $owner is not the start worker"
  descends_from "$BACKEND_PID" "$owner" || fail "$label: \`forkop start\` does not run under the lock owner"
  OWNER="$owner"
}

# 1. The detached worker holds reload.lock under its own live identity, keeps
#    rcS/procd's fd 1000 closed, and tracks the UI job under the same pid.
deferred_start
process_gone "$RC_PID" || fail "the rc.common shell is still running"
owner_holds_lock "detached start"
[ ! -e "/proc/$OWNER/fd/1000" ] || fail "the start worker kept procd's fd 1000"
[ ! -e "/proc/$BACKEND_PID/fd/1000" ] || fail "\`forkop start\` inherited procd's fd 1000"
flock -n "$RC_PROCD_LOCK" true || fail "the detached start holds procd's service lock"
[ "$(cat "$WORK_DIR/ui-job-start.pid" 2>/dev/null)" = "$OWNER" ] ||
  fail "the UI start job is tracked under pid '$(cat "$WORK_DIR/ui-job-start.pid" 2>/dev/null)', not the start worker $OWNER"

# 2. A contender (the list worker, a subscription update, the latency test)
#    cannot take the lock while the start runs.
if "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$LOCK" "$$"; then
  fail "a contender took reload.lock from the running start"
fi
[ "$(lock_owner)" = "$OWNER" ] || fail "a failed contender changed the reload.lock owner"

# 3. The owner record keeps the lock readers working: a snapshot apply and an
#    autotune apply see the running start as a lifecycle action.
printf 'config settings\n' >"$FORKOP_CONFIG_FILE"
printf 'config settings\n\toption changed 1\n' >"$WORK_DIR/candidate"
config_hash="$(sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1)"
answer="$("$REAL_UCODE" -L "$LIB" "$LIB/config/snapshots.uc" apply "$WORK_DIR/candidate" "$config_hash")" || true
[ "$answer" = '{ "status": "stale", "reason": "service_action_in_progress" }' ] ||
  fail "snapshot apply did not see the running start: $answer"
answer="$("$REAL_UCODE" -L "$LIB" "$LIB/autotune/apply.uc" status | grep -o '"service_action": *"[a-z_]*"' || true)"
[ "$answer" = '"service_action": "service_action_in_progress"' ] ||
  fail "autotune apply did not see the running start: '$answer'"

# 4. A reload requested during the start is queued, not run next to it.
status=0
setsid timeout -s KILL 60 bash "$WORK_DIR/rc" reload badwan_interface_up >"$WORK_DIR/rc-reload.out" 2>&1 &
reloader=$!
actors+=("$reloader")
wait_until 20 process_gone "$reloader" || fail "init.d reload did not return during the start"
wait "$reloader" || status=$?
[ "$status" = 0 ] || fail "queued reload returned $status"
[ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the reload was neither run nor queued"
has_event '^reload' && fail "a reload ran next to the start"
[ "$(lock_owner)" = "$OWNER" ] || fail "the reload changed the reload.lock owner"

# 5. The owner is still the live start worker at the end of the start, and
#    the queued reload runs once the start has released reload.lock (no
#    service action is active here to drain the queue in its place).
owner_holds_lock "end of start"
[ "$OWNER" = "$(cat "$WORK_DIR/ui-job-start.pid")" ] || fail "the lock owner changed during the start"
touch "$WORK_DIR/start.gate"
wait_until 20 start_finished || fail "the start did not finish"
wait_until 10 test ! -e "$LOCK" || fail "the finished start did not release reload.lock"
[ "$(grep '^start ' "$WORK_DIR/ui-finished")" = "start job-start 0" ] || fail "the UI start job did not finish as success"
has_event '^reload during start$' && fail "a reload ran next to the start"
[ "$(grep -c '^reload after start$' "$EVENTS")" = 1 ] || fail "the queued reload did not run once after the start"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the queued reload is still pending after the start"

# 6. A start whose lock was taken over (a contender broke it) releases only
#    its own lock: the new owner's lock survives the start's release.
deferred_start
owner_holds_lock "second start"
sleep 300 >/dev/null 2>&1 &
other=$!
actors+=("$other")
rm -rf "$LOCK"
"$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$LOCK" "$other" ||
  fail "the contender could not take the broken reload.lock"
touch "$WORK_DIR/start.gate"
wait_until 20 start_finished || fail "the second start did not finish"
wait_until 10 process_gone "$OWNER" || fail "the second start worker did not exit"
[ "$(lock_owner)" = "$other" ] || fail "the start's release removed another owner's reload.lock"
"$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" release-runtime-dir-lock "$LOCK" "$other"
kill "$other" 2>/dev/null || true
[ ! -e "$LOCK" ] || fail "the contender's release left reload.lock behind"

# 7. The start ticks make the record name one process: a record whose pid now
#    belongs to another process is stale for service/state.uc and for
#    service/initd.uc, and a matching one is not. The record here is one of
#    the previous package version (<lock>/pid), which an upgrade can leave.
reload_begin() {
  "$REAL_UCODE" -L "$LIB" "$LIB/service/initd.uc" reload-begin-fixture badwan_interface_up "$$" 1 1 "" >/dev/null
}
for implementation in state initd; do
  mkdir "$LOCK"
  printf '%s\n%s\n' "$$" "$(start_ticks "$$")" >"$LOCK/pid"
  if [ "$implementation" = state ]; then
    ! "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$LOCK" "$$" ||
      fail "state.uc took a lock whose owner still runs"
  else
    ! reload_begin || fail "initd.uc took a lock whose owner still runs"
  fi
  printf '%s\n%s\n' "$$" "$(($(start_ticks "$$") + 1))" >"$LOCK/pid"
  if [ "$implementation" = state ]; then
    "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" acquire-runtime-dir-lock "$LOCK" "$$" ||
      fail "state.uc kept a lock whose owner pid was reused"
  else
    reload_begin || fail "initd.uc kept a lock whose owner pid was reused"
  fi
  rm -rf "$LOCK"
done

printf 'deferred start lock owner checks passed\n'
