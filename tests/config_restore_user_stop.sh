#!/bin/sh
set -eu

# A snapshot restore and an autotune apply while Forkop is stopped by the
# user (UC-056, D-15(a)), against the real init.d script, service/initd.uc
# reload-service and config/snapshots.uc.
#
# Before: the restore's reload of an explicitly stopped runtime started the
# whole runtime again. Once reloads leave such a runtime alone, init.d gave
# the restore no answer, so the skipped reload read as one that ran: the
# restore reported success and moved last-known-working to a configuration
# no runtime had loaded.
#
# Now init.d answers "stopped" for the restore and autotune reasons. A
# restore keeps the validated configuration for the next explicit start and
# says so (restored_not_started): no runtime is started or claimed, LKG is
# not moved, and the restore guard, also one inherited from an earlier
# needs_attention, is released, so it cannot outlive the start that the
# runtime now waits for. A snapshot that does not validate is put back, the
# same way. An autotune apply is refused before anything changes; a stop
# that overtakes it puts the previous configuration back. A stop that is
# already under way (it holds reload.lock, the runtime is not down yet) gets
# the same answer: before, the reload and its rollback were only queued
# behind it, the stop dropped both, and the restore guard stayed active past
# the next start.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
# Owns reload.lock for a stop that is under way (case 9).
sleep 300 &
STOP_HOLDER=$!
trap 'kill "$STOP_HOLDER" 2>/dev/null || true; rm -rf "$WORK"' EXIT HUP INT TERM
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/state/events" ] || sed 's/^/  event: /' "$WORK/state/events" >&2
  exit 1
}

export STATE="$WORK/state" REAL_UCODE TEST_LIB="$LIB" REAL_INITD="$ROOT/forkop/files/etc/init.d/forkop"
export FORKOP_LIB="$LIB" FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots" FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/forkop/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/forkop.reload.lock"
export FORKOP_RELOAD_COMMAND="$WORK/init.d" FORKOP_SERVICE_INIT="$WORK/init.d"
export STOP_MARKER="$FORKOP_RUNTIME_STATE_DIR/stop.requested" STOP_HOLDER
START_RECORD="$FORKOP_RUNTIME_STATE_DIR/start.explicit"
mkdir -p "$WORK/bin" "$WORK/run/forkop" "$STATE"
echo absent > "$STATE/guard"
echo up > "$STATE/runtime"
# Forkop runs after an explicit start (service/initd.uc records it).
: > "$START_RECORD"

# ucode: the restore guard, the validator (a configuration marked "invalid"
# fails it), health and the UI are modelled; snapshots.uc, initd.uc and
# process identity are the real code.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4:$(cat "$STATE/guard")" >> "$STATE/events"
    case "$4" in
      ensure-dpi-transition-guard) echo valid > "$STATE/guard" ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard" ;;
      dpi-transition-guard-state) cat "$STATE/guard" ;;
    esac
    exit 0 ;;
  */config/validator.uc)
    echo validate >> "$STATE/events"
    # A stop that begins after the restore's busy check: it records its
    # request and takes reload.lock while the runtime is still up.
    if [ -e "$STATE/stop-takes-lock" ]; then
      rm -f "$STATE/stop-takes-lock"
      echo stop > "$STOP_MARKER"
      "$REAL_UCODE" -L "$TEST_LIB" "$TEST_LIB/service/state.uc" acquire-runtime-dir-lock \
        "$FORKOP_RELOAD_LOCK_DIR" "$STOP_HOLDER" || exit 99
    fi
    ! grep -q "marker 'invalid'" "$FORKOP_CONFIG_FILE"
    exit $? ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
STUB
# forkop: get_status reports the modelled runtime. A reload records which
# configuration it loaded and repairs a runtime that is down (as the
# lifecycle does without a stop). With stop-during-reload armed, a stop
# overtakes the reload: the lifecycle gate under reload.lock skips it and the
# runtime goes down.
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
case "$1" in
  show_version) echo 1.0.26-test ;;
  get_status)
    if [ "$(cat "$STATE/runtime")" = up ]; then echo '{"running":1}'; else echo '{"running":0}'; fi ;;
  reload)
    if [ -e "$STATE/stop-during-reload" ]; then
      rm -f "$STATE/stop-during-reload"
      echo stop > "$STOP_MARKER"; echo down > "$STATE/runtime"
      echo "lifecycle-skipped:${2:-}" >> "$STATE/events"
      exit 0
    fi
    echo "runtime-reload:${2:-}:$(grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE")" >> "$STATE/events"
    echo up > "$STATE/runtime" ;;
esac
exit 0
STUB
# rc.common stand-in around the real init.d script.
cat > "$WORK/init.d" <<'STUB'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
[ "$action" = reload ] || exit 1
echo "init.d-reload:${1:-}" >> "$STATE/events"
reload_service "$@"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/forkop" "$WORK/init.d"
# Nothing here may reach the host's syslog.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/logger"
chmod +x "$WORK/bin/logger"

config() { printf "config settings 'settings'\n option dns_server '1.1.1.1'\n option marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$1" "$2"; }
snap() { PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@"; }
snap_id() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))'; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
snaps() { find "$FORKOP_SNAPSHOT_DIR" -maxdepth 1 -name '*.json' | wc -l; }
chash() { sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1; }
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE"; }
events() { cat "$STATE/events" 2>/dev/null || true; }
run() {
  : > "$STATE/events"
  rc=0
  snap "$@" > "$WORK/result.json" || rc=$?
}
expect() { # expect <status> <reason> <what>
  [ "$(field "$WORK/result.json" status)" = "$1" ] || fail "$3: $(cat "$WORK/result.json")"
  [ -z "$2" ] || [ "$(field "$WORK/result.json" reason)" = "$2" ] || fail "$3: $(cat "$WORK/result.json")"
}
# The user's stop also ends the explicit start; a start records itself.
user_stop() { echo stop > "$STOP_MARKER"; rm -f "$START_RECORD"; echo down > "$STATE/runtime"; }
user_start() { rm -f "$STOP_MARKER"; : > "$START_RECORD"; echo up > "$STATE/runtime"; }

# Snapshots "good" and "invalid"; production runs "bad", confirmed as
# last-known-working.
config good; good_id="$(snap create manual | snap_id)"
config invalid; invalid_id="$(snap create manual | snap_id)"
config bad; snap confirm-working > /dev/null
base_lkg="$(lkg)"
{ [ -n "$base_lkg" ] && [ "$base_lkg" != "$good_id" ]; } || fail "fixture: last-known-working not set"

# 1. Stopped by the user: the configuration is replaced and validated, the
#    runtime is neither reloaded nor started, the result says so, LKG stays
#    and the restore guard is released.
user_stop
run restore "$good_id"
expect restored_not_started service_stopped "restore while stopped by the user"
[ "$rc" = 0 ] || fail "restored_not_started exited $rc"
[ "$(field "$WORK/result.json" guard)" = inactive ] || fail "restore while stopped: $(cat "$WORK/result.json")"
[ "$(marker)" = "marker 'good'" ] || fail "restore while stopped did not keep the restored configuration"
events | grep -q '^validate$' || fail "restore while stopped did not validate the configuration"
[ "$(events | grep -c '^init.d-reload:config-restore$')" = 1 ] || fail "restore while stopped did not ask init.d once"
! events | grep -q '^runtime-reload:' || fail "restore while stopped reloaded (started) the runtime"
[ "$(cat "$STATE/runtime")" = down ] || fail "restore while stopped started the runtime"
[ -e "$STOP_MARKER" ] || fail "restore while stopped ended the explicit stop"
[ "$(lkg)" = "$base_lkg" ] || fail "restore while stopped moved last-known-working without a verified runtime"
[ "$(cat "$STATE/guard")" = absent ] || fail "restore while stopped left the restore guard behind"
events | grep -q '^health:restore:not_started$' || fail "restore while stopped not recorded as not started"
! events | grep -q '^health:restore:success$' || fail "restore while stopped recorded a success"

# 2. The guard does not outlive the explicit start: after the start LKG can
#    be confirmed for the restored configuration, and a restore of a running
#    runtime completes as before.
user_start
run confirm-working
expect confirmed "" "confirm-working after the explicit start"
grep -q "marker 'good'" "$FORKOP_SNAPSHOT_DIR/$(lkg).json" || fail "LKG after the start is not the restored configuration"
config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"
run restore "$good_id"
expect success "" "restore of a running runtime after the stop"
events | grep -q "^runtime-reload:config-restore:marker 'good'$" || fail "restore of a running runtime did not reload it"
{ [ "$(lkg)" = "$good_id" ] && [ "$(cat "$STATE/guard")" = absent ]; } || fail "restore of a running runtime did not complete"

# 3. A guard inherited from an earlier needs_attention goes too: the stop
#    took down the runtime it protected.
config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"
echo valid > "$STATE/guard"
user_stop
run restore "$good_id"
expect restored_not_started service_stopped "restore with an inherited guard while stopped"
[ "$(cat "$STATE/guard")" = absent ] || fail "restore while stopped kept an inherited guard"
[ "$(lkg)" = "$base_lkg" ] || fail "restore with an inherited guard moved last-known-working"
! events | grep -q '^runtime-reload:' || fail "restore with an inherited guard started the runtime"

# 4. A snapshot that does not validate: the previous configuration is put
#    back, nothing is started, the guard goes, LKG stays.
config bad; base_hash="$(chash)"
run restore "$invalid_id"
expect failed target_invalid "restore of an invalid snapshot while stopped"
[ "$(field "$WORK/result.json" runtime)" = stopped ] || fail "invalid restore while stopped: $(cat "$WORK/result.json")"
[ "$rc" != 0 ] || fail "failed restore exited 0"
[ "$(chash)" = "$base_hash" ] || fail "invalid restore while stopped did not put the configuration back"
! events | grep -q '^runtime-reload:' || fail "invalid restore while stopped started the runtime"
[ "$(cat "$STATE/guard")" = absent ] || fail "invalid restore while stopped left the guard"
[ "$(lkg)" = "$base_lkg" ] || fail "invalid restore while stopped moved last-known-working"
events | grep -q '^health:restore:failure$' || fail "invalid restore while stopped not recorded as a failure"

# 5. The stop overtakes the restore's reload: the lifecycle gate skips it and
#    init.d still says "stopped".
user_start; config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"
: > "$STATE/stop-during-reload"
run restore "$good_id"
expect restored_not_started service_stopped "restore overtaken by a stop"
events | grep -q '^lifecycle-skipped:config-restore$' || fail "fixture: the stop did not overtake the reload"
{ [ "$(marker)" = "marker 'good'" ] && [ "$(lkg)" = "$base_lkg" ] && [ "$(cat "$STATE/guard")" = absent ]; } ||
  fail "restore overtaken by a stop: $(cat "$WORK/result.json")"

# 6. Autotune apply while stopped: refused before anything changes.
config bad; base_hash="$(chash)"
config good; cp "$FORKOP_CONFIG_FILE" "$WORK/candidate"; config bad
before="$(snaps)"
run apply "$WORK/candidate" "$base_hash"
expect stale service_stopped "autotune apply while stopped"
{ [ "$(snaps)" = "$before" ] && [ "$(chash)" = "$base_hash" ] && [ -z "$(events)" ]; } ||
  fail "autotune apply while stopped changed state"

# 7. A stop overtakes the apply's reload: the candidate is put back, nothing
#    is started, the guard goes, LKG stays.
user_start; snap confirm-working > /dev/null; base_lkg="$(lkg)"
: > "$STATE/stop-during-reload"
run apply "$WORK/candidate" "$base_hash"
expect failed service_stopped "autotune apply overtaken by a stop"
[ "$(field "$WORK/result.json" runtime)" = stopped ] || fail "apply overtaken by a stop: $(cat "$WORK/result.json")"
[ "$(chash)" = "$base_hash" ] || fail "apply overtaken by a stop kept the candidate"
! events | grep -q '^runtime-reload:' || fail "apply overtaken by a stop reloaded the runtime"
{ [ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = "$base_lkg" ]; } || fail "apply overtaken by a stop: guard or LKG"
[ "$(cat "$STATE/runtime")" = down ] || fail "apply overtaken by a stop started the runtime"

# 8. Control: a runtime that went down without a stop after an explicit start
#    (it crashed) is repaired by the restore's reload, as before. One that was
#    not started since a reboot with autostart disabled is not: the restore
#    keeps the configuration for the start (D-15(a);
#    tests/reboot_not_started.sh).
rm -f "$STOP_MARKER"; : > "$START_RECORD"; echo down > "$STATE/runtime"; config bad; snap confirm-working > /dev/null
run restore "$good_id"
expect success "" "restore of a crashed runtime"
events | grep -q "^runtime-reload:config-restore:marker 'good'$" || fail "restore of a crashed runtime did not reload it"
[ "$(lkg)" = "$good_id" ] || fail "restore of a crashed runtime did not confirm LKG"

# 9. A stop that takes reload.lock after the restore's busy check, while the
#    runtime is still up: the restore's reload is not queued behind it (the
#    stop drops what is queued for the runtime it takes down), so neither the
#    reload nor its rollback ends "queued" with the restore guard kept past
#    the next start. The restore is kept for that start, as in case 1.
stop_finishes() {
  "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" release-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$STOP_HOLDER"
  echo down > "$STATE/runtime"
  rm -f "$FORKOP_PENDING_RELOAD_FILE"
}
user_start; config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"
: > "$STATE/stop-takes-lock"
run restore "$good_id"
stop_finishes
[ ! -e "$STATE/stop-takes-lock" ] || fail "fixture: the stop did not take reload.lock"
expect restored_not_started service_stopped "restore overtaken by a stop that holds reload.lock"
{ [ "$(marker)" = "marker 'good'" ] && [ "$(lkg)" = "$base_lkg" ]; } ||
  fail "restore behind a stop that holds reload.lock: configuration or LKG"
[ "$(cat "$STATE/guard")" = absent ] || fail "restore behind a stop that holds reload.lock left the restore guard behind"
! events | grep -q '^runtime-reload:' || fail "restore behind a stop that holds reload.lock reloaded the runtime"

# 9b. The same for an autotune apply: the candidate is put back and the guard
#     goes.
user_start; config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"; base_hash="$(chash)"
: > "$STATE/stop-takes-lock"
run apply "$WORK/candidate" "$base_hash"
stop_finishes
[ ! -e "$STATE/stop-takes-lock" ] || fail "fixture: the stop did not take reload.lock"
expect failed service_stopped "autotune apply overtaken by a stop that holds reload.lock"
[ "$(field "$WORK/result.json" runtime)" = stopped ] || fail "apply behind a stop that holds reload.lock: $(cat "$WORK/result.json")"
[ "$(chash)" = "$base_hash" ] || fail "apply behind a stop that holds reload.lock kept the candidate"
{ [ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = "$base_lkg" ]; } ||
  fail "apply behind a stop that holds reload.lock: guard or LKG"

printf 'config_restore_user_stop: PASS\n'
