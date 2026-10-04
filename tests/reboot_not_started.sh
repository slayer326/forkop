#!/usr/bin/env bash
set -euo pipefail

# Forkop that nobody started since boot stays down like Forkop stopped by the
# user (D-15(a), UC-056).
#
# Before: the stop marker lives in /var/run and ends with a reboot. With
# autostart disabled nothing held Forkop down after the reboot, and its
# runtime was not told apart from one that went down: a manual reload, the
# final reload of a list update and a snapshot restore took the crash-repair
# path and started Forkop; the restore even reported success and moved
# last-known-working to a configuration that nobody had asked to run.
#
# Now an explicit start (boot with autostart, UI/CLI start and restart,
# init.d start/restart) is recorded in runtime state, and the user's explicit
# stop removes the record. A runtime that is down without that record is not
# started by a reload, a restore or a list update. One that was started and
# went down is still repaired. A package upgrade of a running Forkop keeps it
# running, and its restart counts as an explicit start; so does a runtime
# that runs across an upgrade whose previous version kept no record.
#
# The init.d script (behind an rc.common stand-in), service/initd.uc,
# config/snapshots.uc, the final reload of components/updates.uc and
# service/package.uc are real. The Forkop runtime (`forkop` start, stop,
# reload, get_status), the restore guard, the validator, health and the UI
# are modelled. A reboot empties the modelled /var/run and takes the runtime
# down; the configuration, the snapshots and /etc/rc.d survive it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
holder=
trap '[ -z "$holder" ] || kill "$holder" 2>/dev/null || true; rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM

STATE="$WORK/model"
RUN="$WORK/run"
ETC="$WORK/etc"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$STATE/events" ] || sed 's/^/  event: /' "$STATE/events" >&2
  [ ! -s "$STATE/syslog" ] || sed 's/^/  syslog: /' "$STATE/syslog" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$STATE" "$RUN/forkop" "$ETC/config" "$ETC/rc.d" "$WORK/proc"
export STATE REAL_UCODE TEST_LIB="$LIB" REAL_INITD="$ROOT/forkop/files/etc/init.d/forkop"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"
export FORKOP_LIB="$LIB" FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_CONFIG_FILE="$ETC/config/forkop"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state"
export FORKOP_SNAPSHOT_DIR="$ETC/snapshots" FORKOP_SNAPSHOT_HASH_DIR="$RUN/forkop/snapshot-hash"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export FORKOP_AUTOTUNE_APPLY_STATE="$ETC/autotune-apply.json"
export FORKOP_SNAPSHOT_LOCK_DIR="$RUN/forkop/config-snapshot.lock"
export FORKOP_RUNTIME_STATE_DIR="$RUN/forkop"
export FORKOP_PENDING_RELOAD_FILE="$RUN/forkop/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$RUN/forkop.reload.lock"
export FORKOP_LIST_UPDATE_PID_FILE="$RUN/forkop_list_update.pid"
export FORKOP_LIST_UPDATE_RELOAD_FILE="$RUN/forkop/list-update.reload"
export FORKOP_RULESET_REFRESH_AFTER_LIST_FILE="$RUN/forkop/ruleset-refresh-after-list"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$RUN/forkop.internal-config-change"
export FORKOP_RELOAD_COMMAND="$WORK/init.d" FORKOP_SERVICE_INIT="$WORK/init.d" FORKOP_INIT="$WORK/init.d"
# service/package.uc: the hand-off lives in /tmp, which a reboot empties too.
export FORKOP_PACKAGE_UPGRADE_STATE="$RUN/forkop-package-was-running"
export FORKOP_CONFIG_PATH="$ETC/config/forkop" FORKOP_DEFAULT_CONFIG_PATH="$ETC/config/forkop"
export FORKOP_RT_TABLES="$WORK/rt_tables" FORKOP_PROC_DIR="$WORK/proc"
export FORKOP_DNS_APPLY_UC="$WORK/missing-dns-apply.uc"
export FORKOP_SING_BOX_INIT="$WORK/missing-sing-box-init" FORKOP_SING_BOX_BIN="$WORK/missing-sing-box"
export FORKOP_SING_BOX_CRONET="$WORK/missing-cronet"
export FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$RUN/forkop/component-update-checks"
export FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$RUN/forkop/component-update-check.timestamp"
export FORKOP_START_SETTLE_SECONDS=5
unset FORKOP_UI_ACTION_TRACKED FORKOP_STOP_SOURCE FORKOP_START_REQUEST FORKOP_PACKAGE_TEST_MODE
STOP_MARKER="$RUN/forkop/stop.requested"
START_RECORD="$RUN/forkop/start.explicit"

cat >"$WORK/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=1
EOF

# ucode: the restore guard, the validator, health and the UI are modelled;
# everything else is the real code.
cat >"$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    case "$4" in
      ensure-dpi-transition-guard) echo valid > "$STATE/guard" ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard" ;;
      dpi-transition-guard-state) cat "$STATE/guard" ;;
    esac
    exit 0 ;;
  */config/validator.uc) exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
  */singbox/ruleset_cache.uc) exit 1 ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
STUB
# forkop: the runtime. A reload repairs a runtime that is down, as the
# lifecycle does once init.d lets it run (its own gate under reload.lock:
# tests/user_stop_sticky.sh). With down-during-reload armed the runtime goes
# down before the reload and the lifecycle gate skips it.
cat >"$WORK/bin/forkop" <<'STUB'
#!/bin/sh
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE"; }
case "$1" in
  show_version) echo 1.0.26-test ;;
  get_status)
    if [ "$(cat "$STATE/runtime")" = up ]; then echo '{"running":1}'; else echo '{"running":0}'; fi ;;
  start) echo "runtime-start:$(marker)" >> "$STATE/events"; echo up > "$STATE/runtime" ;;
  stop) echo runtime-stop >> "$STATE/events"; echo down > "$STATE/runtime" ;;
  reload)
    if [ -e "$STATE/down-during-reload" ]; then
      rm -f "$STATE/down-during-reload"
      echo down > "$STATE/runtime"
      echo "lifecycle-skipped:${2:-}" >> "$STATE/events"
      exit 0
    fi
    echo "runtime-reload:${2:-}:$(marker)" >> "$STATE/events"; echo up > "$STATE/runtime" ;;
esac
exit 0
STUB
# /etc/init.d/forkop as rc.common runs it (no procd lock on fd 1000 here, so
# a start runs in the foreground).
cat >"$WORK/init.d" <<'STUB'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
echo "init.d-$action:${1:-}" >> "$STATE/events"
case "$action" in
  boot|start) start_service "$@" ;;
  stop) stop_service "$@" ;;
  restart) stop_service; start_service "$@" ;;
  reload) reload_service "$@" ;;
  status) status_service ;;
  retry_start_on_wan_up) retry_start_on_wan_up ;;
  *) exit 64 ;;
esac
STUB
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$STATE/syslog" >"$WORK/bin/logger"
chmod +x "$WORK/bin/ucode" "$WORK/bin/forkop" "$WORK/init.d" "$WORK/bin/logger"

config() { printf "config settings 'settings'\n option dns_server '1.1.1.1'\n option marker '%s'\n" "$1" >"$FORKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$1" "$2"; }
snap() { "$REAL_UCODE" -L "$LIB" "$LIB/config/snapshots.uc" "$@"; }
snap_id() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))'; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE"; }
runtime() { cat "$STATE/runtime"; }
events() { cat "$STATE/events" 2>/dev/null || true; }
has_event() { events | grep -q "$1"; }
no_event() { ! events | grep -q "$1"; }
clear_events() { : >"$STATE/events"; : >"$STATE/syslog"; }
initd() { "$WORK/init.d" "$@" 2>"$WORK/init.d.err"; }

# A reboot: /var/run (runtime state, reload.lock, the upgrade hand-off) is
# empty, the runtime is down. Only /etc/rc.d/S99forkop starts Forkop at boot.
reboot() {
  rm -rf "$RUN"
  mkdir -p "$RUN/forkop"
  echo down >"$STATE/runtime"
  echo absent >"$STATE/guard"
  clear_events
  if [ -e "$ETC/rc.d/S99forkop" ]; then
    "$WORK/init.d" boot >/dev/null || fail "the boot start failed: $(cat "$WORK/init.d.err" 2>/dev/null)"
  fi
}
# The runtime goes down on its own; nothing is recorded.
crash() { echo down >"$STATE/runtime"; clear_events; }

# Snapshots "good" and "other"; production runs "bad", confirmed as
# last-known-working.
config good; good_id="$(snap create manual | snap_id)"
config other; other_id="$(snap create manual | snap_id)"
config bad; snap confirm-working >/dev/null
base_lkg="$(lkg)"
{ [ -n "$base_lkg" ] && [ "$base_lkg" != "$good_id" ]; } || fail "fixture: last-known-working not set"

# 1. Reboot with autostart disabled: Forkop is not started at boot, and
#    nothing but an explicit start starts it.
rm -f "$ETC/rc.d/S99forkop"
reboot
[ -z "$(events)" ] || fail "a boot without autostart ran init.d"
[ "$(runtime)" = down ] || fail "fixture: the runtime runs after the reboot"

# 1a. Reloads by any reason, a manual one included, do not start it; the
#     transaction callers are told "stopped", the others get no answer (not
#     "queued" either: the start applies everything).
for reason in "" ruleset-cache pending badwan_interface_up list-content some-caller config-restore autotune; do
  clear_events
  output="$(initd reload "$reason")" || fail "reload '$reason' of a Forkop not started since boot failed: $(cat "$WORK/init.d.err")"
  case "$reason" in
    config-restore | autotune) want=stopped ;;
    *) want='' ;;
  esac
  [ "$output" = "$want" ] || fail "reload '$reason' of a Forkop not started since boot answered '$output', not '$want'"
  no_event '^runtime-reload:' || fail "reload '$reason' started a Forkop that was not started since boot"
  [ "$(runtime)" = down ] || fail "reload '$reason' left the runtime of a Forkop not started since boot running"
  grep -q "Reload '$reason' skipped: Forkop was not started" "$STATE/syslog" ||
    fail "the skipped reload '$reason' of a Forkop not started since boot was not logged"
  [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] || fail "reload '$reason' left reload.lock behind"
  [ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "reload '$reason' was queued for a Forkop not started since boot"
  [ ! -e "$START_RECORD" ] || fail "reload '$reason' recorded an explicit start"
done

# 1b. A snapshot restore replaces and checks the configuration, starts
#     nothing and says so; last-known-working stays.
clear_events
snap restore "$good_id" >"$WORK/result.json" || true
[ "$(field "$WORK/result.json" status)" = restored_not_started ] ||
  fail "restore of a Forkop not started since boot: $(cat "$WORK/result.json")"
[ "$(field "$WORK/result.json" reason)" = service_stopped ] || fail "restore reason: $(cat "$WORK/result.json")"
[ "$(marker)" = "marker 'good'" ] || fail "the restore did not keep the restored configuration for the start"
no_event '^runtime-reload:' || fail "the restore started a Forkop that was not started since boot"
[ "$(runtime)" = down ] || fail "the restore left the runtime running"
[ "$(lkg)" = "$base_lkg" ] || fail "the restore moved last-known-working without a started runtime"
[ "$(cat "$STATE/guard")" = absent ] || fail "the restore left its guard behind"
has_event '^health:restore:not_started$' || fail "the restore was not recorded as not started"

# 1c. An autotune apply is put back: nothing verifies it, nothing starts.
config bad; bad_hash="$(sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1)"
config other; cp "$FORKOP_CONFIG_FILE" "$WORK/candidate"; config bad
clear_events
snap apply "$WORK/candidate" "$bad_hash" >"$WORK/result.json" || true
[ "$(field "$WORK/result.json" reason)" = service_stopped ] ||
  fail "autotune apply to a Forkop not started since boot: $(cat "$WORK/result.json")"
[ "$(sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1)" = "$bad_hash" ] || fail "the autotune apply kept its candidate"
no_event '^runtime-reload:' || fail "the autotune apply started a Forkop that was not started since boot"
[ "$(lkg)" = "$base_lkg" ] || fail "the autotune apply moved last-known-working"

# 1d. A list update commits its generation; its final reload does not start
#     Forkop, and the generation stays marked for the next start.
list_update_finish() {
  "$REAL_UCODE" -L "$LIB" "$LIB/components/updates.uc" finish-list-update-fixture 0 1 1 >/dev/null 2>&1
}
clear_events
rm -f "$FORKOP_LIST_UPDATE_RELOAD_FILE"
list_update_finish || fail "the list update failed on a Forkop not started since boot"
has_event '^init.d-reload:list-content$' || fail "fixture: the list update did not request its final reload"
no_event '^runtime-reload:' || fail "the list update started a Forkop that was not started since boot"
[ "$(runtime)" = down ] || fail "the list update left the runtime running"
[ "$(cat "$FORKOP_LIST_UPDATE_RELOAD_FILE" 2>/dev/null)" = apply-pending ] ||
  fail "the list update dropped the apply request of its committed generation"

# 1e. A runtime that runs without a start record (a previous version started
#     it and kept none) goes down while a restore reloads it: the lifecycle
#     gate skips the reload under reload.lock, and init.d tells the restore
#     so; it keeps the configuration for the start and does not move
#     last-known-working.
config bad; snap confirm-working >/dev/null; base_lkg="$(lkg)"
echo up >"$STATE/runtime"
: >"$STATE/down-during-reload"
clear_events
snap restore "$good_id" >"$WORK/result.json" || true
has_event '^lifecycle-skipped:config-restore$' || fail "fixture: the runtime did not go down during the restore's reload"
[ "$(field "$WORK/result.json" status)" = restored_not_started ] ||
  fail "restore whose reload the lifecycle skipped: $(cat "$WORK/result.json")"
[ "$(lkg)" = "$base_lkg" ] || fail "a restore whose reload was skipped moved last-known-working"
[ "$(runtime)" = down ] || fail "fixture: the runtime runs after the skipped reload"

# 2. An explicit start is recorded; a runtime that goes down after it is
#    repaired by a reload, a restore reloads it and confirms last-known-working.
clear_events
initd start >/dev/null || fail "the explicit start failed: $(cat "$WORK/init.d.err")"
has_event '^runtime-start:' || fail "the explicit start did not start Forkop"
[ -e "$START_RECORD" ] || fail "the explicit start was not recorded"
[ ! -e "$STOP_MARKER" ] || fail "the explicit start left a stop marker"
crash
output="$(initd reload "")" || fail "the reload after a crash failed"
has_event '^runtime-reload::' || fail "a reload did not repair a runtime that went down after an explicit start"
[ "$(runtime)" = up ] || fail "the repaired runtime is not running"
crash
config bad; snap confirm-working >/dev/null; base_lkg="$(lkg)"
snap restore "$other_id" >"$WORK/result.json" || true
[ "$(field "$WORK/result.json" status)" = success ] || fail "restore after a crash: $(cat "$WORK/result.json")"
has_event "^runtime-reload:config-restore:marker 'other'$" || fail "the restore after a crash did not repair the runtime"
[ "$(lkg)" = "$other_id" ] || fail "the restore after a crash did not confirm last-known-working"
crash
rm -f "$FORKOP_LIST_UPDATE_RELOAD_FILE"
list_update_finish || fail "the list update after a crash failed"
has_event '^runtime-reload:list-content:' || fail "the list update did not repair a runtime that went down after an explicit start"

# 2b. The user's stop removes the record: reloads are skipped as after any
#     stop, and a reboot does not bring the record back.
clear_events
initd stop || fail "the explicit stop failed"
[ ! -e "$START_RECORD" ] || fail "the explicit stop kept the start record"
[ -e "$STOP_MARKER" ] || fail "fixture: the explicit stop recorded no stop"
clear_events
initd reload "" >/dev/null || fail "the reload after the stop failed"
no_event '^runtime-reload:' || fail "a reload started Forkop after the user stopped it"
grep -q "Reload '' skipped: Forkop was stopped" "$STATE/syslog" || fail "the reload after a stop was not logged as such"

# 3. init.d restart after a reboot is an explicit start.
reboot
initd restart >/dev/null || fail "the restart after a reboot failed"
has_event '^runtime-start:' || fail "the restart after a reboot did not start Forkop"
[ -e "$START_RECORD" ] || fail "the restart after a reboot was not recorded as an explicit start"
crash
initd reload "" >/dev/null || fail "the reload after a crash failed"
has_event '^runtime-reload:' || fail "a reload did not repair a runtime that went down after a restart"

# 4. Reboot with autostart enabled: the start at boot is an explicit start,
#    and a runtime that goes down later is repaired.
: >"$ETC/rc.d/S99forkop"
reboot
has_event '^init.d-boot:' || fail "fixture: the boot did not run init.d"
has_event '^runtime-start:' || fail "the boot with autostart did not start Forkop"
[ "$(runtime)" = up ] || fail "the boot with autostart left the runtime down"
[ -e "$START_RECORD" ] || fail "the start at boot was not recorded as an explicit start"
crash
initd reload ruleset-cache >/dev/null || fail "the reload after a crash failed"
has_event '^runtime-reload:ruleset-cache:' || fail "a reload did not repair a runtime that went down after the boot start"
crash
config bad; snap confirm-working >/dev/null; base_lkg="$(lkg)"
snap restore "$good_id" >"$WORK/result.json" || true
[ "$(field "$WORK/result.json" status)" = success ] || fail "restore after a crash following the boot start: $(cat "$WORK/result.json")"
[ "$(lkg)" = "$good_id" ] || fail "the restore after a crash following the boot start did not confirm last-known-working"
rm -f "$ETC/rc.d/S99forkop"

# 4b. Reboot with autostart enabled while another operation holds
#     reload.lock: the start at boot is deferred, not dropped. It was asked
#     for, so it is recorded before it waits for the lock: a runtime that is
#     down meanwhile is no Forkop that nobody started (the UI would call it
#     harmless and no reload would repair it). The deferred start runs once
#     the lock is released.
hold_reload_lock() {
  sleep 300 &
  holder=$!
  "$REAL_UCODE" -L "$LIB" -e 'exit(require("core.runtime_lock").acquire(ARGV[0], ARGV[1]) ? 0 : 1);' \
    "$FORKOP_RELOAD_LOCK_DIR" "$holder" || fail "fixture: could not hold reload.lock"
}
release_reload_lock() {
  "$REAL_UCODE" -L "$LIB" -e 'exit(require("core.runtime_lock").release(ARGV[0], ARGV[1]) ? 0 : 1);' \
    "$FORKOP_RELOAD_LOCK_DIR" "$holder" || fail "fixture: could not release reload.lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  holder=
}
# The deferred start is done: the runtime is up, the start released
# reload.lock and ended its retry.
wait_deferred_start_done() {
  for _ in $(seq 1 100); do
    if [ "$(runtime)" = up ] && [ ! -e "$FORKOP_RELOAD_LOCK_DIR" ] && [ ! -e "$RUN/forkop/start.retry" ] &&
      [ ! -e "$RUN/forkop/start-retry.pid" ]; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}
reboot
: >"$ETC/rc.d/S99forkop"
hold_reload_lock
FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS=1 FORKOP_START_DEFERRED_RETRY_DELAY_SECONDS=1 \
  "$WORK/init.d" boot >/dev/null 2>&1 || true
grep -q '^reason=start_deferred$' "$RUN/forkop/start.retry" 2>/dev/null || fail "fixture: the boot start was not deferred"
[ "$(runtime)" = down ] || fail "fixture: the deferred boot start ran while reload.lock was held"
[ -e "$START_RECORD" ] || fail "the start at boot that waits for reload.lock was not recorded as an explicit start"
release_reload_lock
wait_deferred_start_done || fail "the deferred start at boot did not start Forkop once reload.lock was released"
has_event '^runtime-start:' || fail "the deferred start at boot did not run the start"

# 4c. The same, and the retry of the deferred start cannot be scheduled: the
#     start at boot failed, and a reload repairs the runtime as after any
#     failed start.
rm -f "$ETC/rc.d/S99forkop"
reboot
: >"$ETC/rc.d/S99forkop"
: >"$WORK/not-a-dir"
hold_reload_lock
FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS=1 FORKOP_START_RETRY_PID_FILE="$WORK/not-a-dir/start-retry.pid" \
  "$WORK/init.d" boot >/dev/null 2>&1 || true
grep -q 'its retry could not be scheduled' "$STATE/syslog" || fail "fixture: the retry of the deferred boot start was scheduled"
[ "$(runtime)" = down ] || fail "fixture: the boot start ran while reload.lock was held"
[ -e "$START_RECORD" ] || fail "a start at boot whose retry could not be scheduled was not recorded as an explicit start"
release_reload_lock
initd reload "" >/dev/null || fail "the reload after the failed boot start failed"
has_event '^runtime-reload::' || fail "a reload did not repair the runtime after the start at boot failed"
[ "$(runtime)" = up ] || fail "the runtime is down after the repairing reload"
rm -f "$ETC/rc.d/S99forkop"

# 4d. The user stops Forkop while a start waits for reload.lock: the stop
#     ends the start recorded when it was asked for, the start is skipped
#     once it gets the lock, and nothing starts Forkop afterwards.
reboot
hold_reload_lock
FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS=20 "$WORK/init.d" start >/dev/null 2>&1 &
waiting_start=$!
for _ in $(seq 1 100); do
  [ -e "$START_RECORD" ] && break
  sleep 0.1
done
[ -e "$START_RECORD" ] || fail "the start that waits for reload.lock was not recorded"
FORKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS=1 initd stop || fail "the stop during the waiting start failed"
[ ! -e "$START_RECORD" ] || fail "the user's stop kept the record of the start it overtook"
release_reload_lock
wait "$waiting_start" || true
no_event '^runtime-start:' || fail "a start overtaken by the user's stop started Forkop"
[ ! -e "$START_RECORD" ] || fail "a start overtaken by the user's stop recorded an explicit start"
[ -e "$STOP_MARKER" ] || fail "a start overtaken by the user's stop removed the stop"
# The WAN retry of a failed start is no explicit start either.
initd start triggered >/dev/null || true
no_event '^runtime-start:' || fail "the WAN retry started Forkop after the user's stop"
[ ! -e "$START_RECORD" ] || fail "the WAN retry after the user's stop recorded an explicit start"
initd reload "" >/dev/null || fail "the reload after the stop failed"
no_event '^runtime-reload:' || fail "a reload started Forkop after the user's stop overtook its start"

# 5. A package upgrade of a running Forkop that the previous version started
#    (it kept no start record): prerm hands the restart to postinst, whose
#    start is an explicit start; a runtime that goes down afterwards is
#    repaired.
printf '100 main\n105 forkop\n' >"$FORKOP_RT_TABLES"
reboot
echo up >"$STATE/runtime"
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" prerm upgrade || fail "prerm of the upgrade failed"
[ -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] || fail "prerm did not hand the restart of the running Forkop to postinst"
[ "$(runtime)" = down ] || fail "fixture: prerm did not stop Forkop"
clear_events
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" postinst || fail "postinst of the upgrade failed"
has_event '^runtime-start:' || fail "postinst did not start Forkop again"
[ "$(runtime)" = up ] || fail "Forkop does not run after the upgrade"
[ -e "$START_RECORD" ] || fail "the restart after the upgrade was not recorded as an explicit start"
[ ! -e "$STOP_MARKER" ] || fail "the restart after the upgrade kept the package's stop"
crash
initd reload "" >/dev/null || fail "the reload after a crash following the upgrade failed"
has_event '^runtime-reload:' || fail "a reload did not repair a runtime that went down after the upgrade"

# 5b. A runtime that runs across the upgrade (a package manager that ran no
#     prerm) was started by the previous version, which kept no record:
#     postinst records it, so a crash is still repaired.
reboot
echo up >"$STATE/runtime"
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" postinst || fail "postinst without a hand-off failed"
[ -e "$START_RECORD" ] || fail "postinst did not record the running Forkop as explicitly started"
crash
initd reload "" >/dev/null || fail "the reload after a crash following the upgrade failed"
has_event '^runtime-reload:' || fail "a reload did not repair the runtime that ran across the upgrade"

# 5c. An upgrade of a Forkop that was not started since boot starts nothing
#     and records no start: it stays not started.
reboot
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" prerm upgrade || fail "prerm of a Forkop not started failed"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] || fail "prerm handed a restart of a Forkop that was not running to postinst"
clear_events
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" postinst || fail "postinst of a Forkop not started failed"
no_event '^runtime-start:' || fail "the upgrade started a Forkop that was not started since boot"
[ ! -e "$START_RECORD" ] || fail "the upgrade recorded a start of a Forkop that was not started since boot"
initd reload "" >/dev/null || fail "the reload after the upgrade failed"
no_event '^runtime-reload:' || fail "a reload after the upgrade started a Forkop that was not started since boot"

# 5d. Removing the package stops Forkop for good: no start follows, so the
#     start record goes with it. A reinstall that does not start Forkop leaves
#     it not started, not a failed start, and no reload starts it.
reboot
initd start >/dev/null || fail "the start before the removal failed: $(cat "$WORK/init.d.err")"
[ -e "$START_RECORD" ] || fail "fixture: the start before the removal was not recorded"
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" prerm remove || fail "prerm of the removal failed"
[ "$(runtime)" = down ] || fail "fixture: prerm of the removal did not stop Forkop"
[ ! -e "$START_RECORD" ] || fail "the removal of the package kept the record of an explicit start"
clear_events
"$REAL_UCODE" -L "$LIB" "$LIB/service/package.uc" postinst || fail "postinst of the reinstall failed"
no_event '^runtime-start:' || fail "the reinstall started Forkop"
[ ! -e "$START_RECORD" ] || fail "the reinstall recorded an explicit start"
initd reload "" >/dev/null || fail "the reload after the reinstall failed"
no_event '^runtime-reload:' || fail "a reload after the reinstall started Forkop"

printf 'reboot not started checks passed\n'
