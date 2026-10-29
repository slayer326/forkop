#!/bin/sh
set -eu

# A restore never runs while changes to Forkop X are staged in the uci save
# directory the router reads through (/tmp/.uci/forkop: `uci set` without a
# commit). The validator, the generator and the lifecycle read the
# configuration through libuci with that directory, so the reload would load
# the snapshot plus those changes while last-known-working names the pure
# snapshot; a staged change could also make a good snapshot fail and roll it
# back (UC-068). The restore is refused before anything changes and is no
# restore attempt in the history. An empty delta file (left by uci commit or
# revert) and changes to other packages do not count.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
REAL_UCODE="$(command -v ucode)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'OK: %s\n' "$1"; }

mkdir -p "$WORK/bin" "$WORK/run" "$WORK/state" "$WORK/etc" "$WORK/uci-save"
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

cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
case "${3:-}" in
  */nft/apply.uc)
    echo "$4" >> "$STATE/events"
    case "$4" in
      dpi-transition-guard-state) echo absent ;;
    esac
    exit 0 ;;
  */config/validator.uc) echo validate >> "$STATE/events"; exit 0 ;;
  */diagnostics/health.uc) echo "health:$5:$6" >> "$STATE/events"; exit 0 ;;
esac
exit 0
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
echo "reload:$*" >> "$STATE/events"
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"

config() { printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n\toption marker '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }
marker() { grep -o "marker '[a-z]*'" "$FORKOP_CONFIG_FILE" | sed "s/marker '\(.*\)'/\1/"; }
field() { node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=r[process.argv[2]];console.log(v===undefined||v===null?"":v)' "$WORK/result.json" "$1"; }
count() { find "$FORKOP_SNAPSHOT_DIR" -name '*.json' | wc -l; }
restore() {
  : > "$STATE/events"
  PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$good_id" > "$WORK/result.json" || true
}

config good
good_id="$("$REAL_UCODE" -L "$LIB" "$SCRIPT" create manual | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).snapshot.id))')"
[ -n "$good_id" ] || fail "fixture: target snapshot not created"
config bad
echo stale > "$FORKOP_SNAPSHOT_DIR/last-known-working"

# 1. A staged change of forkop: refused before anything changes.
printf "forkop.settings.dns_server='9.9.9.9'\n" > "$FORKOP_UCI_SAVEDIR/forkop"
before="$(count)"
restore
[ "$(field status)" = failed ] && [ "$(field reason)" = uncommitted_uci_changes ] ||
  fail "restore with staged uci changes: $(cat "$WORK/result.json")"
[ "$(marker)" = bad ] || fail "the configuration was replaced"
[ ! -s "$STATE/events" ] || fail "the transaction started (guard, validation, reload or history): $(tr '\n' ' ' < "$STATE/events")"
[ "$(count)" = "$before" ] || fail "a pre-restore snapshot was written"
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = stale ] || fail "last-known-working moved"
[ "$(cat "$FORKOP_UCI_SAVEDIR/forkop")" = "forkop.settings.dns_server='9.9.9.9'" ] || fail "the staged changes were touched"
ok "staged uci changes of forkop -> restore refused, nothing changed, no history event"

# 2. uci commit/revert leave an empty delta file: nothing is staged.
: > "$FORKOP_UCI_SAVEDIR/forkop"
restore
[ "$(field status)" = success ] && [ "$(marker)" = good ] || fail "empty delta file: $(cat "$WORK/result.json")"
grep -q '^health:restore:success$' "$STATE/events" || fail "empty delta file: the restore is not recorded"
ok "empty delta file -> restore runs"

# 3. Changes staged for another package do not concern the restore.
rm -f "$FORKOP_UCI_SAVEDIR/forkop"; config bad
printf "network.lan.proto='dhcp'\n" > "$FORKOP_UCI_SAVEDIR/network"
restore
[ "$(field status)" = success ] && [ "$(marker)" = good ] || fail "changes of another package: $(cat "$WORK/result.json")"
ok "staged changes of another package -> restore runs"

printf 'config_restore_staged_changes: PASS\n'
