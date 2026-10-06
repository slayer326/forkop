#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="${FORKOP_TEST_LIB:-$ROOT/forkop/files/usr/lib}"
SCRIPT="${FORKOP_TEST_SCRIPT:-$LIB/config/snapshots.uc}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_AUTOTUNE_APPLY_STATE="$WORK/autotune-apply.json"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_LIB="$LIB"

printf "config settings 'settings'\n option dns_server '1.1.1.1'\n" > "$FORKOP_CONFIG_FILE"
ucode -L "$LIB" "$SCRIPT" confirm-working > "$WORK/confirmed.json" || { cat "$WORK/confirmed.json" >&2; exit 1; }
working="$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")"
printf "config settings 'settings'\n option dns_server '8.8.8.8'\n" > "$FORKOP_CONFIG_FILE"
ucode -L "$LIB" "$SCRIPT" create automatic > "$WORK/pre.json"
pre="$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).snapshot.id)' "$WORK/pre.json")"
printf '{"phase":"applying","reload":null,"pre_snapshot":null}\n' > "$FORKOP_AUTOTUNE_APPLY_STATE"
if ucode -L "$LIB" "$SCRIPT" delete "$pre" > "$WORK/applying.json"; then
  echo 'snapshot was deleted during an incomplete autotune apply' >&2
  exit 1
fi
printf '{"phase":"applied","reload":{"status":"success"},"pre_snapshot":"%s"}\n' "$pre" > "$FORKOP_AUTOTUNE_APPLY_STATE"

ucode -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
ucode -e '
let rows = json(require("fs").readfile(ARGV[0]));
let working = false, protected = false;
for (let row in rows) {
    if (row.id == ARGV[1]) working = row.is_lkg == true;
    if (row.id == ARGV[2]) protected = row.is_protected == true;
}
if (!working || !protected) exit(1);
' "$WORK/list.json" "$working" "$pre"
if ucode -L "$LIB" "$SCRIPT" delete "$pre" > "$WORK/delete.json"; then
  echo 'autotune rollback snapshot was deleted' >&2
  exit 1
fi
test "$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).reason)' "$WORK/delete.json")" = protected_for_recovery
test -f "$FORKOP_SNAPSHOT_DIR/$pre.json"

# Fill retention and rotate automatic snapshots. Neither LKG nor the active
# rollback source may be evicted to make room.
i=1
while [ "$i" -le 9 ]; do
  printf "config settings 'settings'\n option dns_server '10.0.0.%s'\n" "$i" > "$FORKOP_CONFIG_FILE"
  ucode -L "$LIB" "$SCRIPT" create automatic > "$WORK/rotation.json"
  i=$((i + 1))
done
test -f "$FORKOP_SNAPSHOT_DIR/$pre.json"
test -f "$FORKOP_SNAPSHOT_DIR/$working.json"

# An unreadable apply record must fail closed; after a completed rollback the
# earlier snapshot is no longer pinned and may be removed explicitly.
printf '{broken' > "$FORKOP_AUTOTUNE_APPLY_STATE"
if ucode -L "$LIB" "$SCRIPT" delete "$pre" > "$WORK/unreadable.json"; then
  echo 'snapshot was deleted while autotune state was unreadable' >&2
  exit 1
fi
printf '{"phase":"rolled_back","reload":{"status":"success"},"pre_snapshot":"%s"}\n' "$pre" > "$FORKOP_AUTOTUNE_APPLY_STATE"
ucode -L "$LIB" "$SCRIPT" delete "$pre" > "$WORK/deleted.json"
test "$(ucode -e 'print(json(require("fs").readfile(ARGV[0])).status)' "$WORK/deleted.json")" = deleted
test ! -e "$FORKOP_SNAPSHOT_DIR/$pre.json"
test -f "$FORKOP_SNAPSHOT_DIR/$working.json"
