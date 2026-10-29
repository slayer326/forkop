#!/bin/sh
set -eu

# Config restore and the DPI transition guard: a restore started while the
# restore guard from a failed attempt (needs_attention) is still active must be
# able to reuse that guard, and the guard may only disappear after a reload
# proved a coherent runtime.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
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
# Real history records (snapshot creation) stay out of /etc/forkop and /run/forkop.
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export STATE="$WORK/state" REAL_UCODE
mkdir -p "$WORK/bin" "$WORK/run" "$STATE"

# Guard model: absent | valid | invalid, with the real contracts of
# ensure (reuse valid, create absent, refuse invalid) and the legacy
# create-only install (refuse anything present).
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    echo "$4:$guard" >> "$STATE/events"
    case "$4" in
      ensure-dpi-transition-guard)
        [ "$guard" = absent ] && { echo valid > "$STATE/guard"; exit 0; }
        [ "$guard" = valid ] && exit 0
        exit 1 ;;
      install-dpi-transition-guard)
        [ "$guard" = absent ] && { echo valid > "$STATE/guard"; exit 0; }
        exit 1 ;;
      remove-dpi-transition-guard)
        echo absent > "$STATE/guard"; exit 0 ;;
    esac ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# Reload outcomes are consumed one per call from $STATE/plan. q answers like
# init.d when another lifecycle action owns reload.lock: status 0, "queued"
# on stdout and reload.pending from the production writer; m leaves only the
# marker, as an init.d that does not acknowledge the queue would; t leaves
# only the token, as when the lock holder consumed the marker before the
# caller looked at it.
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "$*" >> "$STATE/reload-args"
set -- $(cat "$STATE/plan")
rc="${1:-0}"; shift || true
echo "$*" > "$STATE/plan"
echo "reload:$rc:$(grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE")" >> "$STATE/events"
case "$rc" in
  q|m)
    "$REAL_UCODE" -L "$FORKOP_LIB" "$FORKOP_LIB/service/state.uc" mark-pending-reload "$FORKOP_PENDING_RELOAD_FILE" reload_busy
    [ "$rc" = m ] || echo queued
    exit 0 ;;
  t) echo queued; exit 0 ;;
esac
exit "$rc"
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"

config() { printf "config settings 'settings'\n option dns_server '1.1.1.1'\n option marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"

# restore <lib dir> <initial guard> <reload plan> -> $WORK/result.json, $STATE/events
# The snapshot lock identifies its owner by argv, so each variant runs from its
# own library directory.
restore() {
  echo "$2" > "$STATE/guard"; echo "$3" > "$STATE/plan"; : > "$STATE/events"
  FORKOP_LIB="$1" PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$1" "$1/config/snapshots.uc" restore "$good_id" > "$WORK/result.json" || true
}
check() {
  node - "$WORK/result.json" "$STATE/events" "$(cat "$STATE/guard")" "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null)" "$good_id" "$(grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE")" "$1" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const [resultFile, eventsFile, guard, lkg, goodId, marker, expectJson] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
const events = fs.readFileSync(eventsFile, 'utf8').trim().split('\n').filter(Boolean);
const expect = JSON.parse(expectJson);
assert.equal(result.status, expect.status, JSON.stringify(result));
if (expect.reason) assert.equal(result.reason, expect.reason);
if (expect.guardField) assert.equal(result.guard, expect.guardField);
assert.equal(guard, expect.guard, `guard state, events: ${events}`);
assert.equal(marker, `marker '${expect.config}'`);
if (expect.lkgGood !== undefined) assert.equal(lkg === goodId, expect.lkgGood);
if (expect.lkg !== undefined) assert.equal(lkg, expect.lkg);
if (expect.health) assert.ok(events.includes(`health:restore:${expect.health}`), events.join(' '));
if (expect.health && expect.health !== 'success') assert.ok(!events.includes('health:restore:success'), events.join(' '));
// Invariant: a guard is only removed right after a reload that succeeded.
events.forEach((event, i) => {
  if (event.startsWith('remove-dpi-transition-guard'))
    assert.match(events[i - 1] || '', /^reload:0:/, `remove without proven reload: ${events}`);
});
if (expect.noReload) assert.ok(!events.some((e) => e.startsWith('reload:')), events.join(' '));
if (expect.noRemove) assert.ok(!events.some((e) => e.startsWith('remove')), events.join(' '));
JS
}

# Old behaviour: create-only install refuses the still-active guard.
cp -R "$LIB" "$WORK/oldlib"
sed 's/"ensure-dpi-transition-guard"/"install-dpi-transition-guard"/' "$SCRIPT" > "$WORK/oldlib/config/snapshots.uc"
grep -q '"install-dpi-transition-guard"' "$WORK/oldlib/config/snapshots.uc"
config bad; restore "$WORK/oldlib" valid "0"
check '{"status":"failed","reason":"guard_unavailable","guard":"valid","config":"bad","noReload":true,"noRemove":true}'

# 1. Guard absent: restore creates it, reloads and removes it.
config bad; restore "$LIB" absent "0"
check '{"status":"success","guard":"absent","config":"good","lkgGood":true,"health":"success"}'
grep -q '^ensure-dpi-transition-guard:absent$' "$STATE/events"

# 2./3. Valid guard already active: restore proceeds, succeeds, removes it, updates LKG.
echo "stale" > "$FORKOP_SNAPSHOT_DIR/last-known-working"
config bad; restore "$LIB" valid "0"
check '{"status":"success","guard":"absent","config":"good","lkgGood":true,"health":"success"}'
grep -q '^ensure-dpi-transition-guard:valid$' "$STATE/events"

# 4. Valid guard + target reload fails + rollback reload succeeds: recovered, guard removed.
config bad; restore "$LIB" valid "1 0"
check '{"status":"recovered","reason":"target_reload_failed","guardField":"inactive","guard":"absent","config":"bad","health":"recovered"}'

# 5. Valid guard + both reloads fail: needs_attention and the guard stays.
config bad; restore "$LIB" valid "1 1"
check '{"status":"needs_attention","reason":"runtime_rollback_failed","guardField":"active","guard":"valid","config":"bad","noRemove":true,"health":"failure"}'

# 6. needs_attention -> second restore of the known-good snapshot is allowed and recovers.
restore "$LIB" "$(cat "$STATE/guard")" "0"
check '{"status":"success","guard":"absent","config":"good","lkgGood":true}'

# 7. Unexpected guard state: fail closed, config not replaced, guard not removed.
config bad; restore "$LIB" invalid "0"
check '{"status":"failed","reason":"guard_unavailable","guard":"invalid","config":"bad","noReload":true,"noRemove":true}'

# 8. Queued reloads (UC-005): a reload that init.d only queued is not a
#    completed one. Both queued -> needs_attention, guard kept, LKG untouched.
echo "stale" > "$FORKOP_SNAPSHOT_DIR/last-known-working"
: > "$STATE/reload-args"
config bad; restore "$LIB" valid "q q"
check '{"status":"needs_attention","reason":"rollback_reload_queued","guardField":"active","guard":"valid","config":"bad","lkg":"stale","noRemove":true,"health":"failure"}'
[ "$(sort -u "$STATE/reload-args")" = "reload config-restore" ]

# 9. A lifecycle action owns reload.lock: the next restore is refused before
#    any change (no pre-restore snapshot, no guard, no reload, no history).
count="$(find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l)"
mkdir "$FORKOP_RELOAD_LOCK_DIR"
sleep 300 >/dev/null 2>&1 </dev/null &
holder=$!
echo "$holder" > "$FORKOP_RELOAD_LOCK_DIR/pid"
restore "$LIB" valid "0"
kill "$holder" 2>/dev/null || true
rm -f "$FORKOP_RELOAD_LOCK_DIR/pid"; rmdir "$FORKOP_RELOAD_LOCK_DIR"
check '{"status":"busy","reason":"service_action_in_progress","guard":"valid","config":"bad","lkg":"stale","noReload":true,"noRemove":true}'
[ ! -s "$STATE/events" ]
[ "$(find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l)" = "$count" ]

# 9a. The queued request is still pending but nobody owns the lock: it is no
#     refusal (the restore's own reload takes the lock and drains it), so the
#     recovery restore reuses the guard and completes.
[ -e "$FORKOP_PENDING_RELOAD_FILE" ]
restore "$LIB" valid "0"
check '{"status":"success","guard":"absent","config":"good","lkgGood":true,"health":"success"}'
rm -f "$FORKOP_PENDING_RELOAD_FILE"
echo "stale" > "$FORKOP_SNAPSHOT_DIR/last-known-working"

# 10. Target reload queued, rollback reload ran: recovered with the queue
#     named; LKG never names the target. The configuration put back was never
#     confirmed, so LKG stays where it was (UC-059); put back over the
#     last-known-working configuration itself, LKG names it again.
config bad; restore "$LIB" valid "q 0"
check '{"status":"recovered","reason":"target_reload_queued","guardField":"inactive","guard":"absent","config":"bad","lkg":"stale","health":"recovered"}'
rm -f "$FORKOP_PENDING_RELOAD_FILE"
"$REAL_UCODE" -L "$LIB" "$SCRIPT" confirm-working > /dev/null
restore "$LIB" valid "q 0"
check '{"status":"recovered","reason":"target_reload_queued","guardField":"inactive","guard":"absent","config":"bad","lkgGood":false,"health":"recovered"}'
lkg_id="$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")"
grep -q "marker 'bad'" "$FORKOP_SNAPSHOT_DIR/$lkg_id.json"
rm -f "$FORKOP_PENDING_RELOAD_FILE"

# 11. Target reload failed, rollback reload queued: needs_attention.
echo "stale" > "$FORKOP_SNAPSHOT_DIR/last-known-working"
config bad; restore "$LIB" absent "1 q"
check '{"status":"needs_attention","reason":"rollback_reload_queued","guardField":"active","guard":"valid","config":"bad","lkg":"stale","noRemove":true,"health":"failure"}'
rm -f "$FORKOP_PENDING_RELOAD_FILE"

# 12. Without the acknowledgement the unique reload.pending marker still
#     reveals both queued reloads (same second, same reason).
config bad; restore "$LIB" valid "m m"
check '{"status":"needs_attention","reason":"rollback_reload_queued","guardField":"active","guard":"valid","config":"bad","lkg":"stale","noRemove":true,"health":"failure"}'
rm -f "$FORKOP_PENDING_RELOAD_FILE"

# 13. The acknowledgement alone (the holder already drained the marker) is
#     the main detector: never success, LKG untouched.
echo "stale" > "$FORKOP_SNAPSHOT_DIR/last-known-working"
config bad; restore "$LIB" valid "t t"
check '{"status":"needs_attention","reason":"rollback_reload_queued","guardField":"active","guard":"valid","config":"bad","lkg":"stale","noRemove":true,"health":"failure"}'
[ ! -e "$FORKOP_PENDING_RELOAD_FILE" ]
config bad; restore "$LIB" valid "t 0"
check '{"status":"recovered","reason":"target_reload_queued","guardField":"inactive","guard":"absent","config":"bad","lkgGood":false,"health":"recovered"}'

# Phase 22 shape without any pre-existing guard.
config bad; restore "$LIB" absent "1 0"
check '{"status":"recovered","reason":"target_reload_failed","guardField":"inactive","guard":"absent","config":"bad"}'
printf 'config_restore_guard: PASS\n'
