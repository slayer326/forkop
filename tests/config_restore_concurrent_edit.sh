#!/bin/sh
set -eu

# A configuration edit committed while a restore owns the configuration (a
# LuCI Save & Apply, another tab's URLTest override) is never discarded (UC-023, UC-017). The
# transaction puts the previous configuration back only while the file still
# holds what it wrote itself; otherwise the edit is kept in place, also saved
# as an automatic snapshot, and the result is needs_attention
# config_changed_during_transaction. A restore given the hash it expects to
# replace refuses the same way before it changes anything. The lifecycle's own shutdown_correctly bookkeeping is no
# edit.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc"
export FORKOP_CONFIG_FILE="$WORK/etc/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_LIB="$LIB"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export STATE="$WORK/state"

# Guard model (absent | valid) with the real contracts of the state query,
# ensure (reuse valid, create absent) and remove. An edit may land while the
# guard is being installed ($STATE/edit-in-guard) or while the target is
# validated ($STATE/edit-in-validate, the validator then refuses the target).
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
edit() { sed -i "s/option marker '[a-z]*'/option marker '$1'/" "$FORKOP_CONFIG_FILE"; }
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    echo "$4:$guard" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo "$guard"; exit 0 ;;
      ensure-dpi-transition-guard)
        echo valid > "$STATE/guard"
        if [ -e "$STATE/edit-in-guard" ]; then rm -f "$STATE/edit-in-guard"; edit guardedit; fi
        exit 0 ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard"; exit 0 ;;
    esac
    exit 1 ;;
  */config/validator.uc)
    echo validate >> "$STATE/events"
    if [ -e "$STATE/edit-in-validate" ]; then rm -f "$STATE/edit-in-validate"; edit validateedit; exit 1; fi
    exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# Reload outcomes are consumed one per call from $STATE/plan: 0 and 1 are
# exit codes; e1/e0 first commit an edit (another writer, during the reload),
# s1 rewrites only the lifecycle's shutdown_correctly flag, eq commits an edit
# and answers like init.d behind a busy reload lock (queued), es commits an
# edit and answers like init.d while an explicit stop holds the runtime down.
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
set -- $(cat "$STATE/plan")
step="${1:-0}"; [ $# -eq 0 ] || shift
echo "$*" > "$STATE/plan"
echo "reload:$step:$(grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE")" >> "$STATE/events"
case "$step" in
  e*) sed -i "s/option marker '[a-z]*'/option marker 'edit'/" "$FORKOP_CONFIG_FILE" ;;
  s*) sed -i "s/option shutdown_correctly '[01]'/option shutdown_correctly '1'/" "$FORKOP_CONFIG_FILE" ;;
esac
case "$step" in
  eq) echo queued; exit 0 ;;
  es) echo stopped; exit 0 ;;
  *0) exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"

config() {
  printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption shutdown_correctly '0'\n\toption marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"
}
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE" | sed "s/marker '\(.*\)'/\1/"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],r);console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
lkg() { cat "$FORKOP_SNAPSHOT_DIR/last-known-working" 2>/dev/null || true; }
# snapshot_holding <marker> [reason]: the id of a snapshot whose content has
# the marker (and the given reason, if any), or nothing.
snapshot_holding() {
  node - "$FORKOP_SNAPSHOT_DIR" "$1" "${2:-}" <<'JS'
const fs = require('node:fs');
const [dir, marker, reason] = process.argv.slice(2);
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.json'))) {
  const s = JSON.parse(fs.readFileSync(`${dir}/${f}`, 'utf8'));
  if (s.content.includes(`option marker '${marker}'`) && (!reason || s.reason === reason)) { console.log(s.id); break; }
}
JS
}
snapshot_count() { find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l; }
# run <mode...>: snapshots.uc with the stubs, result in $WORK/result.json.
run() {
  : > "$STATE/events"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" "$@" > "$WORK/result.json" || true
}
restore() { # restore <initial guard> <reload plan> [expected hash]
  echo "$1" > "$STATE/guard"; echo "$2" > "$STATE/plan"
  if [ -n "${3:-}" ]; then run restore "$good_id" "$3"; else run restore "$good_id"; fi
}
reloads() { grep -c '^reload:' "$STATE/events" || true; }

config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: target snapshot not created"

# 1. UC-023: the target reload fails, and an edit was committed while it ran.
#    Putting the previous configuration back would discard the edit, which no
#    snapshot holds (the lifecycle's own before-reload snapshot is refused by
#    the held snapshot lock). The edit stays, is saved as a snapshot, and the
#    guard keeps protecting the runtime that no reload proved.
config bad; echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
restore absent "e1"
[ "$(field status)" = needs_attention ] || fail "edit during a failed target reload: $(cat "$WORK/result.json")"
[ "$(field reason)" = config_changed_during_transaction ] || fail "edit during a failed target reload: $(cat "$WORK/result.json")"
[ "$(field guard)" = active ] || fail "the result must name the active guard: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] || fail "the edit committed during the reload was overwritten (config: $(marker))"
[ "$(reloads)" = 1 ] || fail "a rollback reload ran over the edit: $(tr '\n' ' ' < "$STATE/events")"
[ "$(cat "$STATE/guard")" = valid ] || fail "the guard was removed without a proven runtime"
kept="$(snapshot_holding edit concurrent-change)"
[ -n "$kept" ] || fail "the edit is not saved as a snapshot"
[ "$(field saved_snapshot)" = "$kept" ] || fail "the result does not name the snapshot of the edit: $(cat "$WORK/result.json")"
[ -n "$(snapshot_holding bad pre-restore)" ] || fail "the pre-restore snapshot is gone"
[ "$(lkg)" = stale ] || fail "last-known-working moved"
grep -q '^health:restore:failure$' "$STATE/events" || fail "the unfinished restore is not recorded as a failure"
"$REAL_UCODE" -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(!l.some((s)=>s.id===process.argv[2]&&s.reason==="concurrent-change"&&s.kind==="automatic"))process.exit(1)' "$WORK/list.json" "$kept" ||
  fail "the snapshot list does not name the saved edit: $(cat "$WORK/list.json")"
ok "UC-023: edit committed during a failed target reload -> kept, saved, needs_attention, guard kept"

# 1a. The recovery restore reuses the guard; the saved edit is a snapshot
#     like any other and restores coherently.
echo valid > "$STATE/guard"; echo 0 > "$STATE/plan"
run restore "$kept"
[ "$(field status)" = success ] || fail "the saved edit could not be restored: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] && [ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = "$kept" ] ||
  fail "restore of the saved edit: config $(marker), guard $(cat "$STATE/guard"), lkg $(lkg)"
ok "the saved edit restores like any snapshot and clears the guard"

# 2. The target reload was only queued behind another lifecycle action, and
#    an edit landed meanwhile: the same.
config bad; echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
restore absent "eq"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit during a queued target reload: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] && [ "$(reloads)" = 1 ] || fail "queued target: the edit was overwritten or a rollback reload ran"
rm -f "$FORKOP_PENDING_RELOAD_FILE"
ok "edit during a queued target reload -> kept, needs_attention"

# 2a. An explicit stop skipped the target reload, and an edit landed
#     meanwhile: the restore did not put the snapshot in place, so it is not
#     reported as restored for the next start. No runtime runs that a guard
#     could protect, so the guard goes (a kept one would outlive the start).
config bad; echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
restore absent "es"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit while a stop skipped the target reload: $(cat "$WORK/result.json")"
[ "$(field guard)" = inactive ] && [ "$(field runtime)" = stopped ] && [ "$(cat "$STATE/guard")" = absent ] ||
  fail "stopped runtime: the guard must go: $(cat "$WORK/result.json"), guard $(cat "$STATE/guard")"
[ "$(marker)" = edit ] && [ "$(reloads)" = 1 ] && [ "$(lkg)" = stale ] || fail "stopped runtime: edit overwritten, reloaded or LKG moved"
[ -n "$(field saved_snapshot)" ] || fail "stopped runtime: the edit is not saved"
ok "edit while a stop skipped the target reload -> kept, not reported as restored, guard released"

# 3. The validator refuses the target, and an edit lands while it validates.
config bad
touch "$STATE/edit-in-validate"
restore absent "0"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit while the target is validated: $(cat "$WORK/result.json")"
[ "$(marker)" = validateedit ] && [ "$(reloads)" = 0 ] || fail "invalid target: the edit was overwritten or a reload ran"
[ -n "$(snapshot_holding validateedit concurrent-change)" ] || fail "invalid target: the edit is not saved"
ok "edit while the target is validated -> kept, needs_attention"

# 4. The lifecycle rewrites its own shutdown_correctly flag during a failing
#    target reload: that is no edit, the previous configuration comes back.
config bad
restore absent "s1 0"
[ "$(field status)" = recovered ] || fail "shutdown_correctly bookkeeping taken for an edit: $(cat "$WORK/result.json")"
[ "$(marker)" = bad ] && [ "$(cat "$STATE/guard")" = absent ] || fail "bookkeeping only: the previous configuration was not put back"
ok "only the lifecycle's shutdown_correctly flag changed -> ordinary recovery"

# 5. No edit: the recovery is unchanged (the check reads the file it wrote).
config bad
restore absent "1 0"
[ "$(field status)" = recovered ] && [ "$(field reason)" = target_reload_failed ] || fail "plain recovery: $(cat "$WORK/result.json")"
[ "$(marker)" = bad ] || fail "plain recovery: previous configuration not put back"
ok "no edit -> ordinary recovery"

# 6. An edit landing while the guard is installed (after the pre-restore
#    snapshot): the restore refuses before it writes, and releases only the
#    guard it installed itself.
config bad; touch "$STATE/edit-in-guard"
restore absent "0"
[ "$(field status)" = failed ] && [ "$(field reason)" = concurrent_change ] || fail "edit while the guard is installed: $(cat "$WORK/result.json")"
[ "$(marker)" = guardedit ] && [ "$(reloads)" = 0 ] || fail "edit while the guard is installed: overwritten or reloaded"
[ "$(cat "$STATE/guard")" = absent ] || fail "the guard this restore installed was left behind"
config bad; touch "$STATE/edit-in-guard"
restore valid "0"
[ "$(field status)" = failed ] && [ "$(field reason)" = concurrent_change ] && [ "$(field guard)" = active ] ||
  fail "edit while an inherited guard is reused: $(cat "$WORK/result.json")"
[ "$(marker)" = guardedit ] && [ "$(cat "$STATE/guard")" = valid ] || fail "inherited guard: edit overwritten or guard removed"
ok "edit while the guard is installed -> refused before the write, own guard released, inherited guard kept"

# 7. A restore given the hash it expects to replace refuses before any
#    change when the file is something else, and saves that file.
config bad; expected="$(sha "$FORKOP_CONFIG_FILE")"
config other; echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
restore absent "0" "$expected"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "unexpected configuration: $(cat "$WORK/result.json")"
[ "$(marker)" = other ] || fail "unexpected configuration: overwritten"
! grep -q -e '^reload:' -e '^ensure-dpi-transition-guard' "$STATE/events" || fail "unexpected configuration: the transaction started: $(tr '\n' ' ' < "$STATE/events")"
[ "$(cat "$STATE/guard")" = absent ] && [ "$(lkg)" = stale ] || fail "unexpected configuration: guard or last-known-working changed"
[ -n "$(snapshot_holding other concurrent-change)" ] || fail "unexpected configuration: the file is not saved"
[ -z "$(field guard)" ] || fail "no guard was touched, yet the result names one: $(cat "$WORK/result.json")"
count="$(snapshot_count)"
restore absent "0" "$expected"
[ "$(snapshot_count)" = "$count" ] || fail "the same unexpected file is saved again"
ok "restore with an expected hash that the file no longer has -> needs_attention, nothing changed, file saved once"

# 7a. The expected file restores normally; one that differs only by the
#     lifecycle's shutdown_correctly flag counts as the expected one (the
#     expected value may be its user fingerprint).
config bad; expected="$(sha "$FORKOP_CONFIG_FILE")"
restore absent "0" "$expected"
[ "$(field status)" = success ] && [ "$(marker)" = good ] || fail "expected hash: $(cat "$WORK/result.json")"
config bad
fingerprint="$(grep -v 'option shutdown_correctly' "$FORKOP_CONFIG_FILE" | sha256sum | cut -d' ' -f1)"
sed -i "s/option shutdown_correctly '0'/option shutdown_correctly '1'/" "$FORKOP_CONFIG_FILE"
restore absent "0" "$fingerprint"
[ "$(field status)" = success ] && [ "$(marker)" = good ] || fail "expected user fingerprint: $(cat "$WORK/result.json")"
restore absent "0" "not-a-hash"
[ "$(field status)" = failed ] && [ "$(field reason)" = invalid_expected_hash ] && [ "$(reloads)" = 0 ] ||
  fail "a malformed expected hash must be refused: $(cat "$WORK/result.json")"
ok "expected hash or user fingerprint matches -> restore proceeds; malformed -> refused"

# 8. Another snapshot (here an automatic before-reload one, next in line for
#    retention) already holds exactly the edited configuration. The edit is
#    still saved as a "Concurrent edit" snapshot of its own, and the result
#    names that one: the page says so, and retention does not take it first.
#    Without room for a snapshot the result names none (the edit stays in the
#    file only).
rm -rf "$FORKOP_SNAPSHOT_DIR"
config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
config good; sed -i "s/option marker 'good'/option marker 'edit'/" "$FORKOP_CONFIG_FILE"
other="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create automatic | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$other" ] || fail "fixture: the before-reload snapshot was not created"
config bad
restore absent "e1"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit held by another snapshot: $(cat "$WORK/result.json")"
saved="$(field saved_snapshot)"
[ -n "$saved" ] && [ "$saved" != "$other" ] && grep -q '"reason": *"concurrent-change"' "$FORKOP_SNAPSHOT_DIR/$saved.json" &&
  grep -q "option marker 'edit'" "$FORKOP_SNAPSHOT_DIR/$saved.json" ||
  fail "the result names no Concurrent edit snapshot of the edit: $(cat "$WORK/result.json")"
count="$(snapshot_count)"
config bad
restore absent "e1"
[ "$(field saved_snapshot)" = "$saved" ] && [ "$(snapshot_count)" = "$((count + 1))" ] ||
  fail "the same edit is saved twice as a Concurrent edit: $(cat "$WORK/result.json"), $(snapshot_count) snapshots"
# Retention full: 8 manual snapshots, last-known-working and the
# pre-restore snapshot leave no room, so nothing is saved, nor named.
rm -rf "$FORKOP_SNAPSHOT_DIR"
for i in 1 2 3 4 5 6 7 8; do
  config "manual$(printf '%s' "$i" | tr 0-9 a-j)"
  "$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual >/dev/null
done
config working; "$REAL_UCODE" -L "$LIB" "$SCRIPT" confirm-working >/dev/null
config other; "$REAL_UCODE" -L "$LIB" "$SCRIPT" create automatic >/dev/null
[ "$(snapshot_count)" = 10 ] || fail "fixture: $(snapshot_count) snapshots instead of 10"
good_id="$(snapshot_holding manualb manual)"
config bad
restore absent "e1"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] && [ "$(marker)" = edit ] ||
  fail "retention full: $(cat "$WORK/result.json"), config $(marker)"
[ -z "$(field saved_snapshot)" ] && [ -z "$(snapshot_holding edit)" ] || fail "retention full: a snapshot is named or saved: $(cat "$WORK/result.json")"
ok "edit already held by another kind of snapshot -> saved as a Concurrent edit of its own, once; retention full -> none named"

printf 'config_restore_concurrent_edit: PASS\n'
