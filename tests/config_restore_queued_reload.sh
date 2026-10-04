#!/bin/sh
set -eu

# A snapshot restore (and the autotune apply transaction) against the real
# init.d script and service/initd.uc reload-service (UC-005, UC-047). A
# reload that initd.uc only queued because another lifecycle action owns
# reload.lock never counts as applied: no success, LKG untouched, the restore
# guard stays until a reload that ran proved a coherent runtime. A lifecycle
# action that already owns the lock refuses the restore as busy before
# anything is changed. A queued reload without a live owner does not: the
# restore's own reload drains it, so recovery stays possible while the
# current configuration cannot reload and keeps failing to drain the queue.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
cleanup() {
  [ ! -e "$WORK/state/holder" ] || kill "$(cat "$WORK/state/holder")" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

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
mkdir -p "$WORK/bin" "$WORK/run/forkop" "$STATE"
echo absent > "$STATE/guard"

# Lock helpers shared by the stand-ins: a live lifecycle action owns reload.lock.
cat > "$WORK/lock.sh" <<'SH'
hold_lock() {
  mkdir "$FORKOP_RELOAD_LOCK_DIR"
  sleep 300 >/dev/null 2>&1 </dev/null &
  echo "$!" > "$FORKOP_RELOAD_LOCK_DIR/pid"
  echo "$!" > "$STATE/holder"
}
release_lock() {
  kill "$(cat "$STATE/holder")" 2>/dev/null || true
  rm -f "$STATE/holder" "$FORKOP_RELOAD_LOCK_DIR/pid"
  rmdir "$FORKOP_RELOAD_LOCK_DIR"
}
SH
export LOCK_SH="$WORK/lock.sh"
# ucode: restore guard, validator and health are modelled, UI state is out of
# scope; snapshots.uc, initd.uc and process identity are the real code.
# take-lock: a lifecycle action takes reload.lock after the restore checked
# for one (right when the restore guard is installed).
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4:$(cat "$STATE/guard")" >> "$STATE/events"
    case "$4" in
      ensure-dpi-transition-guard)
        echo valid > "$STATE/guard"
        if [ -e "$STATE/take-lock" ]; then rm -f "$STATE/take-lock"; . "$LOCK_SH"; hold_lock; fi ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard" ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
STUB
# forkop: the runtime reload records which configuration it loaded; the
# "broken" configuration fails at runtime.
cat > "$WORK/bin/forkop" <<'STUB'
#!/bin/sh
case "$1" in
  show_version) echo 1.0.26-test ;;
  get_status) echo '{"running":true}' ;;
  reload)
    m="$(grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE")"
    echo "runtime-reload:${2:-}:$m" >> "$STATE/events"
    [ "$m" != "marker 'broken'" ] || exit 1 ;;
esac
exit 0
STUB
# rc.common stand-in around the real init.d script. release-after-queue: the
# lock holder finishes right after the first request it made wait.
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
status=$?
if [ -e "$STATE/release-after-queue" ] && [ -e "$FORKOP_PENDING_RELOAD_FILE" ]; then
  rm -f "$STATE/release-after-queue"; . "$LOCK_SH"; release_lock
fi
exit "$status"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/forkop" "$WORK/init.d"
# shellcheck source=/dev/null
. "$LOCK_SH"

config() { printf "config settings 'settings'\n option dns_server '1.1.1.1'\n option marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$1" "$2"; }
snap() { PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@"; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
snaps() { find "$FORKOP_SNAPSHOT_DIR" -maxdepth 1 -name '*.json' | wc -l; }
chash() { sha256sum "$FORKOP_CONFIG_FILE" | cut -d' ' -f1; }
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE"; }
events() { cat "$STATE/events" 2>/dev/null || true; }
# run <snapshots.uc args...>: result in $WORK/result.json, exit status in $rc.
run() {
  : > "$STATE/events"
  rc=0
  snap "$@" > "$WORK/result.json" || rc=$?
}
expect() { # expect <status> <reason> <what>
  [ "$(field "$WORK/result.json" status)" = "$1" ] || fail "$3: $(cat "$WORK/result.json")"
  [ -z "$2" ] || [ "$(field "$WORK/result.json" reason)" = "$2" ] || fail "$3: $(cat "$WORK/result.json")"
}
# Invariant: the restore guard is only removed right after a runtime reload.
guard_removed_only_after_reload() {
  events | awk -v what="$1" '
    /^remove-dpi-transition-guard/ { if (last !~ /^runtime-reload:/) { print "FAIL: " what ": guard removed without a completed reload" > "/dev/stderr"; exit 1 } }
    !/^(health|init\.d-reload):/ { last = $0 }'
}

# Target snapshot "good"; production runs "bad", confirmed as last-known-working.
config good
good_id="$(snap create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
config bad
snap confirm-working > /dev/null
base_lkg="$(lkg)"; base_hash="$(chash)"
if [ -z "$base_lkg" ] || [ "$base_lkg" = "$good_id" ]; then fail "fixture: last-known-working not set"; fi

# 1. A lifecycle action already owns reload.lock: busy, nothing changed.
hold_lock; before="$(snaps)"
run restore "$good_id"
expect busy service_action_in_progress "restore under a live reload lock"
[ "$rc" != 0 ] || fail "busy restore exited 0"
[ "$(snaps)" = "$before" ] || fail "busy restore created a pre-restore snapshot"
{ [ "$(chash)" = "$base_hash" ] && [ "$(lkg)" = "$base_lkg" ] && [ "$(cat "$STATE/guard")" = absent ]; } || fail "busy restore changed state"
[ -z "$(events)" ] || fail "busy restore acted: $(events)"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "busy restore queued a reload"
release_lock

# 2. The lock is taken after the check and held: the target reload and the
#    rollback reload are both only queued -> needs_attention, guard kept, LKG
#    untouched, no success in history, the runtime never reloaded.
: > "$STATE/take-lock"
run restore "$good_id"
expect needs_attention rollback_reload_queued "target and rollback reload queued"
[ "$(field "$WORK/result.json" guard)" = active ] || fail "double queue: $(cat "$WORK/result.json")"
[ "$rc" != 0 ] || fail "needs_attention restore exited 0"
[ "$(cat "$STATE/guard")" = valid ] || fail "double queue released the restore guard"
[ "$(lkg)" = "$base_lkg" ] || fail "double queue moved last-known-working"
[ "$(marker)" = "marker 'bad'" ] || fail "double queue left the target configuration in place"
! events | grep -q '^runtime-reload:' || fail "double queue: a runtime reload ran: $(events)"
! events | grep -q '^remove-dpi-transition-guard' || fail "double queue removed the guard"
events | grep -q '^health:restore:failure$' || fail "double queue not recorded as a failure: $(events)"
! events | grep -q '^health:restore:success$' || fail "double queue recorded success"
[ "$(events | grep -c '^init.d-reload:config-restore$')" = 2 ] || fail "restore did not pass its reason to init.d: $(events)"
[ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=config-restore" ] || fail "queued restore reload not kept"

# 3. While the lifecycle action still owns the lock the recovery restore is
#    refused before any change. The action then ends without draining the
#    queue (as the automatic latency test does): the queued request alone is
#    no refusal. The recovery restore reuses the guard, its reload runs and
#    its finish drains the request with the restored configuration.
before="$(snaps)"
run restore "$good_id"
expect busy service_action_in_progress "recovery restore under the live lock"
{ [ "$(snaps)" = "$before" ] && [ -z "$(events)" ] && [ "$(cat "$STATE/guard")" = valid ]; } || fail "busy recovery restore changed state"
release_lock
[ -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "fixture: the queued restore reload is gone"
run restore "$good_id"
expect success "" "recovery restore with the queued reload left behind"
{ [ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = "$good_id" ] && [ "$(marker)" = "marker 'good'" ]; } || fail "recovery restore did not complete"
events | grep -q "^runtime-reload:config-restore:marker 'good'$" || fail "recovery restore did not reload the runtime: $(events)"
events | grep -q "^runtime-reload:pending:marker 'good'$" || fail "the queued request was not drained: $(events)"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the recovery restore left reload.pending"
guard_removed_only_after_reload "recovery restore"

# 4. The lock holder finishes right after the target reload was queued: the
#    rollback reload runs -> recovered with the queue named, the target never
#    reached the runtime, LKG names the configuration that was reloaded.
config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"
: > "$STATE/take-lock"; : > "$STATE/release-after-queue"
run restore "$good_id"
expect recovered target_reload_queued "target reload queued, rollback reload ran"
[ "$(field "$WORK/result.json" guard)" = inactive ] || fail "recovered: $(cat "$WORK/result.json")"
[ "$(cat "$STATE/guard")" = absent ] || fail "recovered restore kept the guard"
[ "$(marker)" = "marker 'bad'" ] || fail "recovered restore left the target configuration"
! events | grep -q "^runtime-reload:.*marker 'good'" || fail "the queued target reached the runtime: $(events)"
events | grep -q "^runtime-reload:config-restore:marker 'bad'$" || fail "rollback reload did not run: $(events)"
[ "$(lkg)" != "$good_id" ] || fail "recovered restore moved last-known-working to the target"
grep -q "marker 'bad'" "$FORKOP_SNAPSHOT_DIR/$(lkg).json" || fail "last-known-working is not the reloaded configuration"
events | grep -q '^health:restore:recovered$' || fail "recovered restore not recorded as recovered: $(events)"
guard_removed_only_after_reload "recovered restore"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the drained queue left reload.pending"

# 5. Autotune apply (apply mode) through the same path: busy lock -> stale
#    before any change; a queued reload without a live owner is drained by the
#    apply's own reload, as for a restore; lock taken after the check -> never
#    success.
config bad; snap confirm-working > /dev/null; base_lkg="$(lkg)"; base_hash="$(chash)"
config good; cp "$FORKOP_CONFIG_FILE" "$WORK/candidate"; config bad
hold_lock; before="$(snaps)"
run apply "$WORK/candidate" "$base_hash"
expect stale service_action_in_progress "apply under a live reload lock"
{ [ "$(snaps)" = "$before" ] && [ "$(chash)" = "$base_hash" ] && [ -z "$(events)" ]; } || fail "apply under a live lock changed state"
release_lock
printf 'reason=reload_busy\nupdated_at=1\n' > "$FORKOP_PENDING_RELOAD_FILE"
run apply "$WORK/candidate" "$base_hash"
expect success "" "apply with a queued reload without a live owner"
{ [ "$(marker)" = "marker 'good'" ] && [ "$(lkg)" = "$base_lkg" ] && [ "$(cat "$STATE/guard")" = absent ]; } ||
  fail "apply with a queued reload without a live owner: $(cat "$WORK/result.json")"
events | grep -q "^runtime-reload:autotune:marker 'good'$" || fail "the apply did not reload its candidate: $(events)"
events | grep -q "^runtime-reload:pending:marker 'good'$" || fail "the apply's reload did not drain the queued reload: $(events)"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "the apply left the queued reload behind"
config bad; before="$(snaps)"
: > "$STATE/take-lock"
run apply "$WORK/candidate" "$base_hash"
expect needs_attention rollback_reload_queued "apply: target and rollback reload queued"
{ [ "$(cat "$STATE/guard")" = valid ] && [ "$(lkg)" = "$base_lkg" ] && [ "$(marker)" = "marker 'bad'" ]; } || fail "apply double queue: $(cat "$WORK/result.json")"
! events | grep -q '^runtime-reload:' || fail "apply double queue: a runtime reload ran"
[ "$(events | grep -c '^init.d-reload:autotune$')" = 2 ] || fail "apply did not pass its reason to init.d: $(events)"
events | grep -q '^health:autotune_apply:failure$' || fail "apply double queue not recorded as a failure: $(events)"
release_lock; rm -f "$FORKOP_PENDING_RELOAD_FILE"
: > "$STATE/take-lock"; : > "$STATE/release-after-queue"
run apply "$WORK/candidate" "$base_hash"
expect recovered target_reload_queued "apply: target reload queued, rollback ran"
[ "$(cat "$STATE/guard")" = absent ] || fail "apply recovery kept the guard"
! events | grep -q "^runtime-reload:.*marker 'good'" || fail "the queued candidate reached the runtime: $(events)"
guard_removed_only_after_reload "apply recovery"

# 6. Recovery while the running configuration is broken. A restore made
#    during a list update is queued twice (needs_attention, guard kept); the
#    update then drains the queue, which fails for the broken configuration
#    and retains the request; the dashboard Reload fails the same way. The
#    retained request has no live owner, so restoring the known-good snapshot
#    is still possible: it runs, drains the request and releases the guard.
rm -f "$FORKOP_PENDING_RELOAD_FILE"
config broken; base_lkg="$(lkg)"
: > "$STATE/take-lock"
run restore "$good_id"
expect needs_attention rollback_reload_queued "restore of a broken configuration during a list update"
[ "$(cat "$STATE/guard")" = valid ] || fail "broken: guard released"
release_lock
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" run-pending-reload-if-requested "$FORKOP_PENDING_RELOAD_FILE" "$WORK/init.d" || true
[ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=pending_handoff_failed" ] || fail "fixture: failed drain did not retain the request"
rc=0; PATH="$WORK/bin:$PATH" "$WORK/init.d" reload >/dev/null 2>&1 || rc=$?
{ [ "$rc" != 0 ] && [ -e "$FORKOP_PENDING_RELOAD_FILE" ]; } || fail "fixture: the dashboard reload of the broken configuration did not fail"
{ [ "$(marker)" = "marker 'broken'" ] && [ "$(lkg)" = "$base_lkg" ]; } || fail "fixture: broken state"
run restore "$good_id"
expect success "" "recovery restore while the running configuration is broken"
[ "$rc" = 0 ] || fail "recovery restore exited $rc"
{ [ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = "$good_id" ] && [ "$(marker)" = "marker 'good'" ]; } || fail "broken: recovery restore did not complete"
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ] || fail "broken: the retained request was not drained"
events | grep -q '^health:restore:success$' || fail "broken: recovery not recorded: $(events)"
guard_removed_only_after_reload "broken recovery"

# 7. Same without a guard: a configuration saved during a list update is
#    queued, its drain fails; the restore still recovers.
config good; snap confirm-working > /dev/null
hold_lock; config broken
PATH="$WORK/bin:$PATH" "$WORK/init.d" reload on_config_change >/dev/null 2>&1
release_lock
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$LIB/service/state.uc" run-pending-reload-if-requested "$FORKOP_PENDING_RELOAD_FILE" "$WORK/init.d" || true
[ "$(sed -n 1p "$FORKOP_PENDING_RELOAD_FILE")" = "reason=pending_handoff_failed" ] || fail "fixture: failed config-change drain did not retain the request"
run restore "$good_id"
expect success "" "restore after a failed config-change drain"
{ [ "$(cat "$STATE/guard")" = absent ] && [ "$(marker)" = "marker 'good'" ] && [ ! -e "$FORKOP_PENDING_RELOAD_FILE" ]; } || fail "restore after a failed drain did not complete"

printf 'config_restore_queued_reload: PASS\n'
