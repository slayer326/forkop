#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
SUPERVISOR="$ROOT_DIR/tests/fixtures/dpi_snapshot_supervisor.uc"
CLI="$ROOT_DIR/tests/fixtures/dpi_snapshot_cli.uc"
STATE_DIR="$(mktemp -d)"
PID_DIR="$STATE_DIR/pid"
CHILD_DIR="$STATE_DIR/child-pid"
LOG_DIR="$STATE_DIR/log"
SNAPSHOT="$STATE_DIR/previous.json"
mkdir -p "$PID_DIR" "$CHILD_DIR" "$LOG_DIR"

cleanup() {
    for file in "$PID_DIR"/*.pid "$CHILD_DIR"/*.pid; do
        [ -f "$file" ] || continue
        pid="$(head -n 1 "$file")"
        case "$pid" in *[!0-9]*|'') continue;; esac
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT HUP INT TERM

live_supervisors() {
    ps -eo args= 2>/dev/null | awk -v fixture="$SUPERVISOR" '$1 ~ /(^|\/)ucode$/ && $4 == fixture && $5 == "supervisor" { count++ } END { print count+0 }'
}

ucode -L "$LIB_DIR" "$SUPERVISOR" supervisor example 4000 old "$CHILD_DIR/example.pid" >"$LOG_DIR/example.log" 2>&1 &
old_pid=$!
echo "$old_pid" > "$PID_DIR/example.pid"
sleep 1
[ -s "$CHILD_DIR/example.pid" ] || exit 1

ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
[ -s "$SNAPSHOT" ] || exit 1
cp "$SNAPSHOT" "$STATE_DIR/normal.json"

kill "$old_pid" "$(cat "$CHILD_DIR/example.pid")"
wait "$old_pid" 2>/dev/null || true
rm -f "$PID_DIR/example.pid" "$CHILD_DIR/example.pid"

ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
new_pid="$(head -n 1 "$PID_DIR/example.pid")"
[ "$new_pid" != "$old_pid" ] || exit 1
[ "$(wc -l < "$PID_DIR/example.pid")" -eq 2 ] || exit 1
kill -0 "$new_pid"
kill -0 "$(head -n 1 "$CHILD_DIR/example.pid")"
cp "$PID_DIR/example.pid" "$STATE_DIR/owned.pid"
printf '%s\n0\n' "$new_pid" > "$PID_DIR/example.pid"
if ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'snapshot accepted a reused supervisor PID' >&2; exit 1
fi
kill -0 "$new_pid"
cp "$STATE_DIR/owned.pid" "$PID_DIR/example.pid"

# A real supervisor died; its stale record must not prevent recovery.
kill -STOP "$new_pid"
kill -0 "$new_pid" || exit 1
ucode -L "$LIB_DIR" "$CLI" kill-restored "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
kill "$(head -n 1 "$CHILD_DIR/example.pid")"
sleep 1
rm -f "$CHILD_DIR/example.pid"
ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
grep -Eq '"stale"[[:space:]]*:[[:space:]]*"example"' "$SNAPSHOT" || exit 1
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'rollback claimed to restore a dead supervisor' >&2; exit 1
fi

# A surviving child makes the stale supervisor ambiguous.
sleep 300 &
survivor=$!
echo "$survivor" > "$CHILD_DIR/example.pid"
if ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'snapshot accepted a surviving child' >&2; exit 1
fi
rm -f "$PID_DIR/example.pid"
if ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'snapshot accepted an orphaned child' >&2; exit 1
fi
kill "$survivor"
wait "$survivor" 2>/dev/null || true
rm -f "$CHILD_DIR/example.pid" "$PID_DIR/example.pid"

# A live foreign PID must remain untouched.
sleep 300 &
foreign=$!
echo "$foreign" > "$PID_DIR/example.pid"
if ucode -L "$LIB_DIR" "$CLI" snapshot "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'snapshot accepted a foreign supervisor' >&2; exit 1
fi
kill -0 "$foreign"
kill "$foreign"
wait "$foreign" 2>/dev/null || true
rm -f "$PID_DIR/example.pid"

# Every entry must pass validation before the first supervisor is launched.
for order in first last; do
    node - "$STATE_DIR/normal.json" "$SNAPSHOT" "$order" <<'NODE'
const fs = require('fs');
const entry = JSON.parse(fs.readFileSync(process.argv[2]))[0];
const stale = { stale: 'missing' };
fs.writeFileSync(process.argv[3], JSON.stringify(process.argv[4] === 'first' ? [stale, entry] : [entry, stale]));
NODE
    if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
        echo 'mixed snapshot was accepted' >&2; exit 1
    fi
    [ ! -e "$PID_DIR/example.pid" ] && [ "$(live_supervisors)" -eq 0 ] || { echo 'mixed snapshot launched a supervisor' >&2; exit 1; }
done

node - "$STATE_DIR/normal.json" "$SNAPSHOT" <<'NODE'
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2]))[0];
const second = JSON.parse(JSON.stringify(first));
second.name = second.args[5] = 'second';
second.args[8] = second.args[8].replace('example.pid', 'second.pid');
fs.writeFileSync(process.argv[3], JSON.stringify([first, second, { stale: 'last' }]));
NODE
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'three-entry mixed snapshot was accepted' >&2; exit 1
fi
[ ! -e "$PID_DIR/example.pid" ] && [ "$(live_supervisors)" -eq 0 ] || { echo 'late stale entry launched a supervisor' >&2; exit 1; }

node - "$STATE_DIR/normal.json" "$SNAPSHOT" <<'NODE'
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2]))[0];
fs.writeFileSync(process.argv[3], JSON.stringify([first, first]));
NODE
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'duplicate provider name was accepted' >&2; exit 1
fi

# A failed temporary identity write must clean up the already launched process.
cp "$STATE_DIR/normal.json" "$SNAPSHOT"
mkdir "$LOG_DIR/.restore-example.identity"
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'restore accepted a failed temporary identity write' >&2; exit 1
fi
[ -s "$CHILD_DIR/example.pid.observed" ] || { echo 'temporary identity failure did not launch a child' >&2; exit 1; }
child="$(cat "$CHILD_DIR/example.pid.observed")"
if [ "$(live_supervisors)" -ne 0 ] ||
   { kill -0 "$child" 2>/dev/null && [ "$(ps -o stat= -p "$child" 2>/dev/null | cut -c1)" != 'Z' ]; }; then
    echo 'temporary identity failure left a supervisor or child running' >&2; exit 1
fi
[ ! -e "$PID_DIR/example.pid" ] || { echo 'temporary identity failure left a supervisor pidfile' >&2; exit 1; }
rmdir "$LOG_DIR/.restore-example.identity"
rm -f "$CHILD_DIR/example.pid" "$CHILD_DIR/example.pid.observed"

# The same failure must find a child even before its pidfile exists.
node - "$STATE_DIR/normal.json" "$SNAPSHOT" <<'NODE'
const fs = require('fs');
const entry = JSON.parse(fs.readFileSync(process.argv[2]))[0];
entry.name = entry.args[5] = 'nochild';
entry.args[8] = entry.args[8].replace('example.pid', 'nochild.pid');
fs.writeFileSync(process.argv[3], JSON.stringify([entry]));
NODE
mkdir "$LOG_DIR/.restore-nochild.identity"
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'restore accepted a missing child pidfile after identity failure' >&2; exit 1
fi
[ -s "$CHILD_DIR/nochild.pid.observed" ] || { echo 'unrecorded child was not launched' >&2; exit 1; }
child="$(cat "$CHILD_DIR/nochild.pid.observed")"
if [ "$(live_supervisors)" -ne 0 ] ||
   { kill -0 "$child" 2>/dev/null && [ "$(ps -o stat= -p "$child" 2>/dev/null | cut -c1)" != 'Z' ]; }; then
    echo 'identity failure left an unrecorded child running' >&2; exit 1
fi
rmdir "$LOG_DIR/.restore-nochild.identity"
rm -f "$CHILD_DIR/nochild.pid.observed"

# A later launch failure must remove the first supervisor and its child.
for fail_position in 2 3; do
node - "$STATE_DIR/normal.json" "$SNAPSHOT" "$fail_position" <<'NODE'
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2]))[0];
const second = JSON.parse(JSON.stringify(first));
second.name = second.args[5] = 'second';
second.args[8] = second.args[8].replace('example.pid', 'second.pid');
const fail = JSON.parse(JSON.stringify(first));
fail.name = fail.args[5] = 'fail';
fail.args[8] = fail.args[8].replace('example.pid', 'fail.pid');
fs.writeFileSync(process.argv[3], JSON.stringify(process.argv[4] === '2' ? [first, fail] : [first, second, fail]));
NODE
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'partial restore was accepted' >&2; exit 1
fi
[ ! -e "$PID_DIR/example.pid" ] || { echo 'partial restore kept the first supervisor' >&2; exit 1; }
[ ! -e "$CHILD_DIR/example.pid" ] || { echo 'partial restore kept the first child' >&2; exit 1; }
[ ! -e "$PID_DIR/second.pid" ] || { echo 'partial restore kept the second supervisor' >&2; exit 1; }
[ "$(live_supervisors)" -eq 0 ] || { echo 'partial restore left a supervisor running' >&2; exit 1; }
done

# A failed identity record cannot strand a launched supervisor.
node - "$STATE_DIR/normal.json" "$SNAPSHOT" <<'NODE'
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2]))[0];
const blocked = JSON.parse(JSON.stringify(first));
blocked.name = blocked.args[5] = 'blocked';
blocked.args[8] = blocked.args[8].replace('example.pid', 'blocked.pid');
fs.writeFileSync(process.argv[3], JSON.stringify([first, blocked]));
NODE
mkdir "$PID_DIR/blocked.pid"
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'failed identity record was accepted' >&2; exit 1
fi
rmdir "$PID_DIR/blocked.pid"
[ ! -e "$PID_DIR/example.pid" ] || { echo 'record failure kept the first supervisor' >&2; exit 1; }
[ ! -e "$CHILD_DIR/example.pid" ] || { echo 'record failure kept the first child' >&2; exit 1; }
[ "$(live_supervisors)" -eq 0 ] || { echo 'record failure left a supervisor running' >&2; exit 1; }

# A child without a pidfile is found only while still descended from this launch.
node - "$STATE_DIR/normal.json" "$SNAPSHOT" <<'NODE'
const fs = require('fs');
const first = JSON.parse(fs.readFileSync(process.argv[2]))[0];
const nochild = JSON.parse(JSON.stringify(first));
nochild.name = nochild.args[5] = 'nochild';
nochild.args[8] = nochild.args[8].replace('example.pid', 'nochild.pid');
fs.writeFileSync(process.argv[3], JSON.stringify([first, nochild]));
NODE
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'missing child pidfile was accepted' >&2; exit 1
fi
[ ! -e "$PID_DIR/example.pid" ] || { echo 'missing-child rollback kept first supervisor' >&2; exit 1; }
[ "$(live_supervisors)" -eq 0 ] || { echo 'missing-child rollback left a supervisor running' >&2; exit 1; }
if [ -s "$CHILD_DIR/nochild.pid.observed" ]; then
    orphan="$(cat "$CHILD_DIR/nochild.pid.observed")"
    if [ "$(ps -o stat= -p "$orphan" 2>/dev/null | cut -c1)" != 'Z' ] && kill -0 "$orphan" 2>/dev/null; then
        echo 'unrecorded child survived failed restore' >&2; exit 1
    fi
fi

# A live new runtime must be stopped before the old snapshot is restored.
ucode -L "$LIB_DIR" "$SUPERVISOR" supervisor new 4000 new "$CHILD_DIR/new.pid" >"$LOG_DIR/new.log" 2>&1 &
current_pid=$!
ucode -L "$LIB_DIR" "$CLI" record-test "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT" "$current_pid" new
sleep 1
cp "$STATE_DIR/normal.json" "$SNAPSHOT"
ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"
[ ! -e "$PID_DIR/new.pid" ] || { echo 'new runtime pidfile survived replacement' >&2; exit 1; }
kill -0 "$(head -n 1 "$PID_DIR/example.pid")"

# A foreign PID blocks replacement without receiving a signal.
sleep 300 &
foreign=$!
printf '%s\n' "$foreign" > "$PID_DIR/foreign.pid"
if ucode -L "$LIB_DIR" "$CLI" restore "$LIB_DIR" "$SUPERVISOR" "$PID_DIR" "$CHILD_DIR" "$LOG_DIR" "$SNAPSHOT"; then
    echo 'foreign runtime allowed restore' >&2; exit 1
fi
kill -0 "$foreign"
kill "$foreign"
wait "$foreign" 2>/dev/null || true
rm -f "$PID_DIR/foreign.pid"

printf 'dpi_runtime_snapshot: PASS\n'
