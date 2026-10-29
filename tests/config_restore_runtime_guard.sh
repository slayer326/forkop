#!/bin/sh
set -eu

# A snapshot restore while a failed lifecycle transition keeps its
# fail-closed guard (UC-019): the guard table ForkopTableDpiGuard of a
# failed rollback, or the forkop_transition_guard
# chain of a failed sing-box rollback. service/lifecycle.uc refuses every
# reload over them (runtime_guard_active) and only a restart removes them, so
# no reload proves a coherent runtime while one is left:
#   - one that is already there refuses the transaction before anything
#     changes: no restore guard, no pre-restore snapshot, no history event;
#   - one that a reload leaves behind (it exited 0, or it failed with the
#     guard kept) ends needs_attention with the reason runtime_guard_active:
#     the restore guard stays, last-known-working does not move, and no
#     success is recorded. After a failed target the previous configuration
#     is put back for the restart, without a rollback reload that would be
#     refused anyway; a rollback reload that leaves one behind ends the same.
# The guard is looked for after init.d released reload.lock. A lifecycle
# action that holds the lock by then (a WAN-up or hotplug reload, the holder
# a queued reload waited for) installs guards of its own for its transition:
# one seen while such an action runs counts as kept only once it ended.
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$STATE/events" ] || sed 's/^/  event: /' "$STATE/events" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state/tables"
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_LIB="$LIB"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export STATE="$WORK/state"
TABLES="$STATE/tables"

# The restore guard (ForkopConfigRestore) with the real contracts of the
# state query, ensure and remove; validator and health are modelled.
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    echo "$4:$guard" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo "$guard"; exit 0 ;;
      ensure-dpi-transition-guard) echo valid > "$STATE/guard"; exit 0 ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard"; exit 0 ;;
    esac
    exit 1 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# nft knows the tables and chains in $STATE/tables: "<table>" and
# "<table>.<chain>".
cat > "$WORK/bin/nft" <<'STUB'
#!/bin/sh
echo "nft $*" >> "$STATE/events"
case "$1 $2 $3" in
  "list table inet") [ -e "$STATE/tables/$4" ] ;;
  "list chain inet") [ -e "$STATE/tables/$4.$5" ] ;;
  *) exit 1 ;;
esac
STUB
# The lifecycle reload. $STATE/leave: the guard table or chain a failed
# transition keeps during this reload; $STATE/reload-status: its exit status;
# $STATE/<name>.<n> the same for the n-th reload of a case only.
# It is refused, as service/lifecycle.uc refuses it, while a kept guard is
# already there. $STATE/inflight: once it returns, another lifecycle action
# holds reload.lock with the DPI guard of its own transition installed; after
# 2 s it ends, removing the guard unless the file says "kept".
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
n=$(($(cat "$STATE/reload-count" 2>/dev/null || echo 0) + 1))
echo "$n" > "$STATE/reload-count"
if [ -n "$(ls "$STATE/tables")" ]; then
  echo "reload-refused" >> "$STATE/events"
  exit 1
fi
for leave in "$STATE/leave" "$STATE/leave.$n"; do
  if [ -e "$leave" ]; then
    : > "$STATE/tables/$(cat "$leave")"
    rm -f "$leave"
  fi
done
if [ -e "$STATE/inflight" ]; then
  kept="$(cat "$STATE/inflight")"
  rm -f "$STATE/inflight"
  mkdir "$FORKOP_RELOAD_LOCK_DIR"
  sleep 300 >/dev/null 2>&1 &
  holder=$!
  echo "$holder" > "$FORKOP_RELOAD_LOCK_DIR/pid"
  : > "$STATE/tables/ForkopTableDpiGuard"
  (
    sleep 2
    [ "$kept" = kept ] || rm -f "$STATE/tables/ForkopTableDpiGuard"
    rm -f "$FORKOP_RELOAD_LOCK_DIR/pid"
    rmdir "$FORKOP_RELOAD_LOCK_DIR"
    kill "$holder"
    echo "inflight-ended" >> "$STATE/events"
  ) >/dev/null 2>&1 &
fi
if [ -e "$STATE/reload-status.$n" ]; then exit "$(cat "$STATE/reload-status.$n")"; fi
exit "$(cat "$STATE/reload-status" 2>/dev/null || echo 0)"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/bin/nft" "$WORK/reload"

config() { printf "config settings 'settings'\n option marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined?"":v)' "$WORK/result.json" "$1"; }
snap() { PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@"; }
snaps() { find "$FORKOP_SNAPSHOT_DIR" -maxdepth 1 -name '*.json' | wc -l; }
has() { grep -qx "$1" "$STATE/events"; }

config good
good_id="$(snap create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: target snapshot not created"

reset_case() {
  config current
  echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
  echo absent > "$STATE/guard"
  rm -f "$STATE/leave" "$STATE"/leave.* "$STATE/reload-status" "$STATE"/reload-status.* "$STATE/reload-count" \
    "$STATE/inflight" "$TABLES"/*
  : > "$STATE/events"
}
restore() { snap restore "$good_id" > "$WORK/result.json" || true; }

# 1. Control: without a kept guard the restore succeeds and releases its guard.
reset_case
restore
[ "$(field status)" = success ] || fail "control: $(cat "$WORK/result.json")"
[ "$(cat "$STATE/guard")" = absent ] || fail "control: the restore guard was left behind"

# 2. A kept guard is already there: the restore is refused before anything
#    changes (the reload it needs would be refused), and says why.
for kept in ForkopTableDpiGuard ForkopTable.forkop_transition_guard; do
  reset_case
  : > "$TABLES/$kept"
  before="$(snaps)"
  restore
  [ "$(field status)" = failed ] || fail "$kept already kept: $(cat "$WORK/result.json")"
  [ "$(field reason)" = runtime_guard_active ] || fail "$kept already kept: $(cat "$WORK/result.json")"
  ! grep -q '^ensure-dpi-transition-guard' "$STATE/events" || fail "$kept already kept: the restore guard was installed"
  ! grep -q '^reload:' "$STATE/events" || fail "$kept already kept: a reload was requested"
  ! grep -q '^health:' "$STATE/events" || fail "$kept already kept: a refusal that changed nothing was recorded as a restore"
  [ "$(snaps)" = "$before" ] || fail "$kept already kept: a pre-restore snapshot was written"
  grep -q "marker 'current'" "$FORKOP_CONFIG_FILE" || fail "$kept already kept: the configuration changed"
  [ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "$kept already kept: last-known-working moved"
done

# 3. The target reload exits 0 but a failed transition kept its guard: no
#    coherent runtime, so needs_attention; the restore guard stays, LKG does
#    not move, the restored configuration stays for the restart.
for kept in ForkopTableDpiGuard ForkopTable.forkop_transition_guard; do
  reset_case
  echo "$kept" > "$STATE/leave"
  restore
  [ "$(field status)" = needs_attention ] || fail "$kept left by the reload: $(cat "$WORK/result.json")"
  [ "$(field reason)" = runtime_guard_active ] || fail "$kept left by the reload: $(cat "$WORK/result.json")"
  [ "$(field guard)" = active ] || fail "$kept left by the reload: the result does not name the active guard"
  [ "$(cat "$STATE/guard")" = valid ] || fail "$kept left by the reload: the restore guard was released"
  [ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "$kept left by the reload: last-known-working moved"
  grep -q "marker 'good'" "$FORKOP_CONFIG_FILE" || fail "$kept left by the reload: the restored configuration was not kept"
  has 'health:restore:failure' || fail "$kept left by the reload: not recorded as a failed restore"
done

# 4. The target reload fails and its DPI rollback keeps the guard (the
#    double fault): the previous configuration is put back for the restart,
#    no rollback reload is attempted over the guard, the result names it.
reset_case
echo ForkopTableDpiGuard > "$STATE/leave"
echo 1 > "$STATE/reload-status"
restore
[ "$(field status)" = needs_attention ] || fail "failed target with a kept guard: $(cat "$WORK/result.json")"
[ "$(field reason)" = runtime_guard_active ] || fail "failed target with a kept guard: $(cat "$WORK/result.json")"
[ "$(cat "$STATE/guard")" = valid ] || fail "failed target with a kept guard: the restore guard was released"
grep -q "marker 'current'" "$FORKOP_CONFIG_FILE" || fail "failed target with a kept guard: the previous configuration was not put back"
[ "$(grep -c '^reload:' "$STATE/events")" = 1 ] || fail "failed target with a kept guard: a rollback reload was attempted over the guard"
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "failed target with a kept guard: last-known-working moved"

# 4b. The target reload fails without a kept guard, and the rollback reload
#     leaves one: the previous configuration is back but no reload proved it,
#     so needs_attention as well; the restore guard stays, LKG does not move.
for kept in ForkopTableDpiGuard ForkopTable.forkop_transition_guard; do
  reset_case
  echo 1 > "$STATE/reload-status.1"
  echo "$kept" > "$STATE/leave.2"
  restore
  [ "$(grep -c '^reload:' "$STATE/events")" = 2 ] || fail "$kept left by the rollback: no rollback reload ran"
  [ "$(field status)" = needs_attention ] || fail "$kept left by the rollback: $(cat "$WORK/result.json")"
  [ "$(field reason)" = runtime_guard_active ] || fail "$kept left by the rollback: $(cat "$WORK/result.json")"
  [ "$(cat "$STATE/guard")" = valid ] || fail "$kept left by the rollback: the restore guard was released"
  [ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "$kept left by the rollback: last-known-working moved"
  grep -q "marker 'current'" "$FORKOP_CONFIG_FILE" || fail "$kept left by the rollback: the previous configuration was not put back"
done

# 4c. After the target reload, another lifecycle action holds reload.lock
#     with the DPI guard of its own transition: that guard is not kept by a
#     failed transition. The restore waits for the action and succeeds once
#     it removed its guard; had the action kept it, needs_attention.
reset_case
echo removed > "$STATE/inflight"
restore
[ "$(field status)" = success ] || fail "guard of an action in flight: $(cat "$WORK/result.json")"
has inflight-ended || fail "guard of an action in flight: the restore did not wait for the action"
[ "$(cat "$STATE/guard")" = absent ] || fail "guard of an action in flight: the restore guard was left behind"
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$good_id" ] || fail "guard of an action in flight: last-known-working did not move"
reset_case
echo kept > "$STATE/inflight"
restore
has inflight-ended || fail "guard kept by an action in flight: the restore did not wait for the action"
[ "$(field status)" = needs_attention ] || fail "guard kept by an action in flight: $(cat "$WORK/result.json")"
[ "$(field reason)" = runtime_guard_active ] || fail "guard kept by an action in flight: $(cat "$WORK/result.json")"
[ "$(cat "$STATE/guard")" = valid ] || fail "guard kept by an action in flight: the restore guard was released"

printf 'config_restore_runtime_guard: PASS\n'
