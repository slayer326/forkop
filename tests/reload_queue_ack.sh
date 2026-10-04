#!/bin/sh
set -eu

# Queued reload acknowledgement (UC-005, UC-047). When another lifecycle
# action owns reload.lock, service/initd.uc only queues a reload and still
# exits 0. Callers that must not mistake that for a completed reload (a list
# worker, a snapshot restore, an autotune apply) pass their own reason and
# get the `queued` token on stdout, through the real init.d script. Other
# reasons keep their output and status. Every queued request rewrites
# reload.pending with a unique marker, so a second request in the same second
# is still visible to a caller comparing markers.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
INITD_UC="$LIB/service/initd.uc"
STATE_UC="$LIB/service/state.uc"
INITD="$ROOT/forkop/files/etc/init.d/forkop"
PUBLIC_CLI="$ROOT/forkop/files/usr/bin/forkop"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
holder=""
cleanup() {
  [ -z "$holder" ] || kill "$holder" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/run/forkop"
export FORKOP_LIB="$LIB" TEST_LIB="$LIB" REAL_INITD="$INITD" REAL_UCODE
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/forkop/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/forkop.reload.lock"
export FORKOP_EXPLICIT_START_FILE="$WORK/run/forkop/start.explicit"
export FORKOP_STOP_REQUESTED_FILE="$WORK/run/forkop/stop.requested"
export FORKOP_SERVICE_TRIGGER_SYNC_FILE="$WORK/run/forkop/service-triggers.sync"
export FORKOP_TEST_RUNTIME_DOWN="$WORK/run/runtime.down"
export FORKOP_SERVICE_INIT="$WORK/init.d"
export PATH="$WORK/bin:$PATH"
: > "$FORKOP_EXPLICIT_START_FILE"

# UI state and dnsmasq failsafe are outside this contract.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
  */service/state.uc)
    if [ "${4:-}" = sing-box-process-conflict ] &&
       [ "${FORKOP_TEST_PROCESS_CONFLICT:-0}" = 1 ]; then
      exit 0
    fi
    ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] || exit 97
    printf 'lifecycle reload %s\n' "${5:-}" >> "$FORKOP_RUNTIME_STATE_DIR/runtime.log"
    [ "${5:-}" != on_config_change ] || printf '1\n' > "$FORKOP_SERVICE_TRIGGER_SYNC_FILE"
    exit "${FORKOP_TEST_LIFECYCLE_STATUS:-0}"
    ;;
esac
exec "$REAL_UCODE" "$@"
STUB
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
case "$1" in
  get_status)
    if [ -e "$FORKOP_TEST_RUNTIME_DOWN" ]; then
      echo '{"running":false}'
    else
      echo '{"running":true}'
    fi
    ;;
esac
exit 0
STUB
# rc.common stand-in: `<init> reload [reason]` runs the real init script's
# reload_service with the remaining arguments, as OpenWrt's rc.common does.
cat > "$WORK/init.d" <<'STUB'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
[ "$action" = reload ] || exit 1
reload_service "$@"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/forkop" "$WORK/init.d"

# A live lifecycle action owns the reload lock.
mkdir -p "$FORKOP_RUNTIME_STATE_DIR" "$FORKOP_RELOAD_LOCK_DIR"
sleep 300 >/dev/null 2>&1 &
holder=$!
echo "$holder" > "$FORKOP_RELOAD_LOCK_DIR/pid"

initd() { "$REAL_UCODE" -L "$LIB" "$INITD_UC" reload-service "$1" "$$"; }
stamp() { printf '%s:%s' "$(stat -c '%Y:%s' "$FORKOP_PENDING_RELOAD_FILE")" "$(cat "$FORKOP_PENDING_RELOAD_FILE")"; }

# 1. initd.uc: restore, autotune and list-content requests are acknowledged
#    as queued; the status stays 0 and the request is kept in reload.pending.
for reason in config-restore autotune list-content; do
  rm -f "$FORKOP_PENDING_RELOAD_FILE"
  out="$(initd "$reason")" || fail "$reason: queued reload changed the exit status"
  [ "$out" = queued ] || fail "$reason: queued reload printed '$out' instead of 'queued'"
  [ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=$reason" ] || fail "$reason: pending reason not kept"
  grep -Eq '^updated_at=[0-9]+$' "$FORKOP_PENDING_RELOAD_FILE" || fail "$reason: pending marker lost updated_at"
done

# 2. Other callers keep their contract: no token, status 0.
for reason in "" badwan_interface_up ruleset-cache subscription_deferred_recovery; do
  rm -f "$FORKOP_PENDING_RELOAD_FILE"
  out="$(initd "$reason")" || fail "'$reason': queued reload changed the exit status"
  [ -z "$out" ] || fail "'$reason': ordinary reload printed '$out'"
  [ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "'$reason': reload was not queued"
done

# 3. The real init.d script forwards the token and the status.
rm -f "$FORKOP_PENDING_RELOAD_FILE"
out="$("$WORK/init.d" reload config-restore)" || fail "init.d changed the status of a queued restore reload"
[ "$out" = queued ] || fail "init.d did not forward the queued token (got '$out')"
out="$("$WORK/init.d" reload autotune)" || fail "init.d changed the status of a queued autotune reload"
[ "$out" = queued ] || fail "init.d did not forward the queued autotune token (got '$out')"
out="$("$WORK/init.d" reload)" || fail "init.d changed the status of an ordinary queued reload"
[ -z "$out" ] || fail "init.d printed '$out' for an ordinary reload"
[ ! -e "$FORKOP_RUNTIME_STATE_DIR/runtime.log" ] || fail "a queued request reached the runtime"

# 3b. The public CLI enters the same queue. It must not bypass reload.lock or
#     reach lifecycle while another transition owns the runtime.
rm -f "$FORKOP_PENDING_RELOAD_FILE"
out="$("$REAL_UCODE" "$PUBLIC_CLI" reload direct-cli)" || fail "direct CLI reload changed the queued status"
[ -z "$out" ] || fail "direct ordinary reload printed '$out' while queued"
[ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=direct-cli" ] ||
  fail "direct CLI reload did not preserve its queued reason"
[ ! -e "$FORKOP_RUNTIME_STATE_DIR/runtime.log" ] || fail "direct queued reload bypassed reload.lock"

# 4. Every queued request leaves a distinct marker, also within one second
#    and with the same reason (initd.uc and state.uc writers alike).
for _ in 1 2 3; do
  initd config-restore > /dev/null
  first="$(stamp)"
  initd config-restore > /dev/null
  [ "$(stamp)" != "$first" ] || fail "initd.uc rewrote an identical pending marker"
  "$REAL_UCODE" -L "$LIB" "$STATE_UC" mark-pending-reload "$FORKOP_PENDING_RELOAD_FILE" reload_busy
  first="$(stamp)"
  "$REAL_UCODE" -L "$LIB" "$STATE_UC" mark-pending-reload "$FORKOP_PENDING_RELOAD_FILE" reload_busy
  [ "$(stamp)" != "$first" ] || fail "state.uc rewrote an identical pending marker"
  [ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=reload_busy" ] || fail "state.uc marker lost its reason"
done

# 5. A free lock runs the reload through lifecycle directly: no recursion
#    through the public CLI and no lock leak.
kill "$holder"; wait "$holder" 2>/dev/null || true; holder=""
rm -f "$FORKOP_RELOAD_LOCK_DIR/pid"; rmdir "$FORKOP_RELOAD_LOCK_DIR"
rm -f "$FORKOP_PENDING_RELOAD_FILE"
out="$("$WORK/init.d" reload config-restore)" || fail "a completed restore reload failed"
[ -z "$out" ] || fail "a completed restore reload printed '$out'"
grep -q '^lifecycle reload config-restore$' "$FORKOP_RUNTIME_STATE_DIR/runtime.log" || fail "restore reload did not run lifecycle directly"
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload lock not released"

# 6. The public CLI keeps initd's sync acknowledgement after a completed
#    config-change reload.
rm -f "$FORKOP_SERVICE_TRIGGER_SYNC_FILE"
out="$("$REAL_UCODE" "$PUBLIC_CLI" reload on_config_change)" || fail "direct completed reload failed"
[ "$out" = sync ] || fail "direct completed reload lost the sync token (got '$out')"
grep -q '^lifecycle reload on_config_change$' "$FORKOP_RUNTIME_STATE_DIR/runtime.log" ||
  fail "direct completed reload did not reach lifecycle"
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "direct completed reload leaked reload.lock"

# 7. Ambiguous sing-box ownership is rejected before a request can be queued
#    or lifecycle can change the active policy.
rm -f "$FORKOP_PENDING_RELOAD_FILE"
before="$(wc -l < "$FORKOP_RUNTIME_STATE_DIR/runtime.log")"
if FORKOP_TEST_PROCESS_CONFLICT=1 "$REAL_UCODE" "$PUBLIC_CLI" reload conflict; then
  fail "direct reload accepted ambiguous sing-box ownership"
fi
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "ownership conflict was turned into a queued reload"
[ "$(wc -l < "$FORKOP_RUNTIME_STATE_DIR/runtime.log")" = "$before" ] ||
  fail "ownership conflict reached lifecycle"
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "ownership conflict leaked reload.lock"

# 8. D-15 remains intact for the public CLI: after an explicit stop, reload
#    does not start or touch the runtime. Transaction callers retain the
#    `stopped` acknowledgement.
rm -f "$FORKOP_EXPLICIT_START_FILE" "$FORKOP_PENDING_RELOAD_FILE"
: > "$FORKOP_STOP_REQUESTED_FILE"
: > "$FORKOP_TEST_RUNTIME_DOWN"
before="$(wc -l < "$FORKOP_RUNTIME_STATE_DIR/runtime.log")"
out="$(FORKOP_TEST_PROCESS_CONFLICT=1 "$REAL_UCODE" "$PUBLIC_CLI" reload config-restore)" ||
  fail "stopped direct reload failed while foreign sing-box was present"
[ "$out" = stopped ] || fail "stopped direct reload lost the stopped token (got '$out')"
[ "$(wc -l < "$FORKOP_RUNTIME_STATE_DIR/runtime.log")" = "$before" ] ||
  fail "stopped direct reload reached lifecycle"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "stopped direct reload was queued"
[ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "stopped direct reload leaked reload.lock"

printf 'reload_queue_ack: PASS\n'
