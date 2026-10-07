#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
grep -Fq 'config_snapshot_create: [ "config/snapshots.uc", "create-rolling", 1 ]' \
  "$ROOT/forkop/files/usr/bin/forkop"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_LIB="$LIB"

snapshot() { ucode -L "$LIB" "$SCRIPT" "$@"; }
snapshot_id() {
  node -e 'let s=""; process.stdin.on("data", d => s += d).on("end", () => console.log(JSON.parse(s).snapshot.id))'
}
snapshot_count() { snapshot list | node -e 'let s=""; process.stdin.on("data", d => s += d).on("end", () => console.log(JSON.parse(s).length))'; }
config() { printf "config settings 'settings'\n option dns_server '%s'\n" "$1" > "$FORKOP_CONFIG_FILE"; }

config 1.1.1.1
old="$(snapshot create manual | snapshot_id)"
snapshot confirm-working > /dev/null
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$old" ] || exit 1

# If the running configuration is unchanged, the new verified copy becomes
# LKG immediately and the previous file can be removed at once.
same="$(snapshot create-rolling manual | snapshot_id)"
[ "$same" != "$old" ] || exit 1
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$same" ] || exit 1
[ ! -e "$FORKOP_SNAPSHOT_DIR/$old.json" ] || exit 1
[ "$(snapshot_count)" = 1 ] || exit 1
old="$same"

# The new snapshot is written first; an LKG that still holds the old working
# configuration is never removed before the new one has passed a reload.
config 2.2.2.2
new="$(snapshot create-rolling manual | snapshot_id)"
[ -e "$FORKOP_SNAPSHOT_DIR/$old.json" ] || exit 1
[ -e "$FORKOP_SNAPSHOT_DIR/$new.json" ] || exit 1
[ "$(snapshot_count)" = 2 ] || exit 1
[ "$(cat "$FORKOP_SNAPSHOT_DIR/rolling-snapshot")" = "$new" ] || exit 1

# A failed save must leave both the newest snapshot and the working one.
if FORKOP_CONFIG_FILE="$WORK/missing" snapshot create-rolling manual > "$WORK/failed.json"; then exit 1; fi
[ "$(snapshot_count)" = 2 ] || exit 1
[ -e "$FORKOP_SNAPSHOT_DIR/$old.json" ] || exit 1
[ -e "$FORKOP_SNAPSHOT_DIR/$new.json" ] || exit 1

snapshot confirm-working > /dev/null
[ "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$new" ] || exit 1
[ "$(snapshot_count)" = 1 ] || exit 1
[ ! -e "$FORKOP_SNAPSHOT_DIR/$old.json" ] || exit 1

# Even at the ten-snapshot cap, a rolling save writes the new file before
# removing obsolete ones. Internal create/manual retains its legacy behavior.
for n in 1 2 3 4 5 6 7 8 9; do snapshot create manual > /dev/null; done
[ "$(snapshot_count)" = 10 ] || exit 1
config 3.3.3.3
latest="$(snapshot create-rolling manual | snapshot_id)"
[ -e "$FORKOP_SNAPSHOT_DIR/$new.json" ] || exit 1
[ -e "$FORKOP_SNAPSHOT_DIR/$latest.json" ] || exit 1
[ "$(snapshot_count)" = 2 ] || exit 1
snapshot confirm-working > /dev/null
[ "$(snapshot_count)" = 1 ] || exit 1

# An autotune rollback point remains until its recovery record is gone.
config 4.4.4.4
protected="$(snapshot create automatic | snapshot_id)"
printf '{"phase":"applied","reload":{},"pre_snapshot":"%s"}\n' "$protected" > "$FORKOP_AUTOTUNE_APPLY_STATE"
config 5.5.5.5
next="$(snapshot create-rolling manual | snapshot_id)"
[ -e "$FORKOP_SNAPSHOT_DIR/$protected.json" ] || exit 1
snapshot confirm-working > /dev/null
[ -e "$FORKOP_SNAPSHOT_DIR/$protected.json" ] || exit 1
[ -e "$FORKOP_SNAPSHOT_DIR/$next.json" ] || exit 1
[ "$(snapshot_count)" = 2 ] || exit 1
rm "$FORKOP_AUTOTUNE_APPLY_STATE"
snapshot confirm-working > /dev/null
[ "$(snapshot_count)" = 1 ] || exit 1

printf 'config_snapshot_rolling: PASS\n'
