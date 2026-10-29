#!/usr/bin/env bash
set -euo pipefail

# After the target reload a restore compares the configuration file with the
# snapshot it wrote (UC-023). When the bytes differ (the lifecycle's
# shutdown_correctly commit rewrites the file through libuci) the two are
# compared as libuci loads them, which takes a while for a big configuration
# (seconds on a router). An edit committed meanwhile is an edit as well: the
# restore must not put the previous configuration back over it.
#
# The test makes that window deterministic: the reload stub starts a watcher
# that waits until snapshots.uc has read the whole file for its comparison
# (its read counter in /proc/<pid>/io), stops the process, commits the edit
# and lets it go on. The configuration is big enough that the comparison is
# far from done by then.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }
skip() { printf 'SKIP: config_restore_edit_during_compare: %s\n' "$1"; exit 0; }
REAL_UCODE="$(command -v ucode)" || fail "ucode is required"
grep -q '^rchar:' "/proc/$$/io" 2>/dev/null || skip "no read counter in /proc/<pid>/io"

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

# Guard model (absent | valid); the validator accepts; health is logged.
cat >"$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    guard="$(cat "$STATE/guard")"
    case "$4" in
      dpi-transition-guard-state) echo "$guard"; exit 0 ;;
      ensure-dpi-transition-guard) echo valid > "$STATE/guard"; exit 0 ;;
      remove-dpi-transition-guard) echo absent > "$STATE/guard"; exit 0 ;;
    esac
    exit 1 ;;
  */config/validator.uc) exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
# The watcher (watch <read counter before the reload returned>): once the
# process in $STATE/pid has read the whole file since, it is stopped, the
# edit is committed (a new file renamed into place, as uci commit does) and
# it continues.
cat >"$WORK/watch" <<'STUB'
#!/usr/bin/env bash
pid="$(cat "$STATE/pid")"
rchar() { local k v; while read -r k v; do [ "$k" = rchar: ] && { echo "$v"; return; }; done < "/proc/$pid/io"; }
size="$(wc -c < "$FORKOP_CONFIG_FILE")"
base="$1"
while kill -0 "$pid" 2>/dev/null; do
  now="$(rchar)" || exit 0
  if [ -n "$now" ] && [ $((now - base)) -ge "$size" ]; then
    kill -STOP "$pid"
    sed "s/option marker 'good'/option marker 'edit'/" "$FORKOP_CONFIG_FILE" > "$FORKOP_CONFIG_FILE.new"
    mv "$FORKOP_CONFIG_FILE.new" "$FORKOP_CONFIG_FILE"
    touch "$STATE/edited"
    kill -CONT "$pid"
    exit 0
  fi
done
STUB
# Reload steps from $STATE/plan: "s1" rewrites the lifecycle's
# shutdown_correctly flag (other bytes, the same configuration), starts the
# watcher with the read counter of snapshots.uc, which waits for this reload
# and has not read the file since, and fails; "0" succeeds.
cat >"$WORK/reload" <<'STUB'
#!/bin/sh
set -- $(cat "$STATE/plan")
step="${1:-0}"; [ $# -eq 0 ] || shift
echo "$*" > "$STATE/plan"
echo "reload:$step" >> "$STATE/events"
case "$step" in
  s1)
    sed -i "s/option shutdown_correctly '0'/option shutdown_correctly '1'/" "$FORKOP_CONFIG_FILE"
    for _ in $(seq 1 500); do [ -s "$STATE/pid" ] && break; sleep 0.01; done
    base="$(awk '$1 == "rchar:" { print $2 }' "/proc/$(cat "$STATE/pid")/io")"
    "$WORK/watch" "$base" >/dev/null 2>&1 </dev/null &
    exit 1 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/watch" "$WORK/reload"
export WORK

# A big configuration: settings and 900 rules with their lists (~1 MB).
config() {
  {
    printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption shutdown_correctly '0'\n\toption marker '%s'\n" "$1"
    awk 'BEGIN { for (r = 0; r < 900; r++) {
      printf "\nconfig section '\''rule%d'\''\n\toption action '\''zapret'\''\n", r
      for (d = 0; d < 30; d++) printf "\tlist domains '\''host%d-%d.example.com'\''\n", r, d } }'
  } > "$FORKOP_CONFIG_FILE"
}
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE" | sed "s/marker '\(.*\)'/\1/"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }

config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: the target snapshot was not created"

config bad
echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"
echo absent > "$STATE/guard"; echo "s1 0" > "$STATE/plan"; : > "$STATE/events"
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$good_id" > "$WORK/result.json" &
echo "$!" > "$STATE/pid"
wait "$!" || true
[ -e "$STATE/edited" ] || fail "fixture: the edit was never committed during the comparison"
[ "$(field status)" = needs_attention ] && [ "$(field reason)" = config_changed_during_transaction ] ||
  fail "edit committed while the restore compared the file: $(cat "$WORK/result.json")"
[ "$(marker)" = edit ] || fail "the previous configuration was put back over the edit (config: $(marker))"
[ "$(grep -c '^reload:' "$STATE/events")" = 1 ] || fail "a rollback reload ran over the edit: $(tr '\n' ' ' < "$STATE/events")"
[ "$(cat "$STATE/guard")" = valid ] || fail "the guard was removed without a proven runtime"
saved="$(field saved_snapshot)"
[ -n "$saved" ] && grep -q "option marker 'edit'" "$FORKOP_SNAPSHOT_DIR/$saved.json" || fail "the edit is not saved: $(cat "$WORK/result.json")"
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "last-known-working moved"
ok "edit committed while the restore compared a rewritten file with the snapshot -> kept, saved, needs_attention"

printf 'config_restore_edit_during_compare: PASS\n'
