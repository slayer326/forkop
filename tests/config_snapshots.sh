#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
SCRIPT="$LIB/config/snapshots.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_CONFIG_FILE="$WORK/forkop"
export FORKOP_SNAPSHOT_DIR="$WORK/snapshots"
# Changes staged with uci refuse a restore (UC-068): the test has its own
# save directory, never the host's /tmp/.uci.
export FORKOP_UCI_SAVEDIR="$WORK/uci-save"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK/run/config-snapshot.lock"
export FORKOP_LIB="$LIB"
export FORKOP_HISTORY_FILE="$WORK/history.jsonl"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_PENDING_RELOAD_FILE="$WORK/run/reload.pending"
export FORKOP_RELOAD_LOCK_DIR="$WORK/run/reload.lock"
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '1.1.1.1'
 option password 'top-secret'
UCI
ucode -L "$LIB" "$SCRIPT" create manual > "$WORK/create.json" || { cat "$WORK/create.json" >&2; exit 1; }
ucode -L "$LIB" "$SCRIPT" create automatic > "$WORK/duplicate.json"
ucode -L "$LIB" "$SCRIPT" list > "$WORK/list.json"
node - "$WORK" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const dir = process.argv[2];
const created = JSON.parse(fs.readFileSync(`${dir}/create.json`));
const duplicate = JSON.parse(fs.readFileSync(`${dir}/duplicate.json`));
const list = JSON.parse(fs.readFileSync(`${dir}/list.json`));
assert.equal(created.status, 'created');
assert.equal(duplicate.status, 'existing');
assert.equal(list.length, 1);
assert.equal(JSON.stringify(list).includes('top-secret'), false);
// UC-150: the read-only list carries no hash of the secret-bearing config.
assert.equal('config_hash' in list[0], false);
fs.writeFileSync(`${dir}/id`, created.snapshot.id);
JS
id="$(cat "$WORK/id")"
test "$(stat -c %a "$FORKOP_SNAPSHOT_DIR")" = 700
test "$(stat -c %a "$FORKOP_SNAPSHOT_DIR/$id.json")" = 600
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '8.8.8.8'
 option password 'new-secret'
UCI
ucode -L "$LIB" "$SCRIPT" diff "$id" > "$WORK/diff.json"
node - "$WORK/diff.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const rows = JSON.parse(fs.readFileSync(process.argv[2]));
assert.deepEqual(rows.find(row => row.option === 'dns_server'), {
  section: 'settings', option: 'dns_server', before: '1.1.1.1', after: '8.8.8.8'
});
assert.deepEqual(rows.find(row => row.option === 'password'), {
  section: 'settings', option: 'password', before: '***', after: '***'
});
assert.equal(JSON.stringify(rows).includes('secret'), false);
JS
if ucode -L "$LIB" "$SCRIPT" diff '../etc/passwd' >/dev/null; then exit 1; fi
mkdir "$WORK/bin"
cat > "$WORK/bin/ucode" <<'STUB'
#!/bin/sh
if [ "${FAIL_GUARD:-0}" = 1 ] && [ "${4:-}" = 'ensure-dpi-transition-guard' ]; then exit 1; fi
exit 0
STUB
cat > "$WORK/reload" <<'STUB'
#!/bin/sh
if [ "${FAIL_ALL:-0}" = 1 ]; then exit 1; fi
if [ "${FAIL_OLD_CONFIG:-0}" = 1 ] && grep -q '1.1.1.1' "$FORKOP_CONFIG_FILE"; then exit 1; fi
exit 0
STUB
chmod +x "$WORK/bin/ucode" "$WORK/reload"
export FORKOP_RELOAD_COMMAND="$WORK/reload"
REAL_UCODE="$(command -v ucode)"
PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore.json"
node - "$WORK/restore.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).status, 'success');
JS
grep -q '1.1.1.1' "$FORKOP_CONFIG_FILE"
test "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$id"
cat > "$FORKOP_CONFIG_FILE" <<'UCI'
config settings 'settings'
 option dns_server '8.8.8.8'
 option password 'new-secret'
UCI
FAIL_OLD_CONFIG=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-failed.json"
node - "$WORK/restore-failed.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).status, 'recovered');
JS
grep -q '8.8.8.8' "$FORKOP_CONFIG_FILE"
# The configuration put back (8.8.8.8) was never confirmed: last-known-working
# stays where it was, it does not move to that configuration (UC-059).
test "$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")" = "$id"
# Put back over the last-known-working configuration itself, it stays so.
"$REAL_UCODE" -L "$LIB" "$SCRIPT" confirm-working > /dev/null
confirmed_id="$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")"
test "$confirmed_id" != "$id"
FAIL_OLD_CONFIG=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-failed.json"
node - "$WORK/restore-failed.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
assert.equal(JSON.parse(fs.readFileSync(process.argv[2])).status, 'recovered');
JS
recovered_id="$(cat "$FORKOP_SNAPSHOT_DIR/last-known-working")"
grep -q '8.8.8.8' "$FORKOP_SNAPSHOT_DIR/$recovered_id.json"
if FAIL_ALL=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-unknown.json"; then exit 1; fi
node - "$WORK/restore-unknown.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.status, 'needs_attention');
assert.equal(result.guard, 'active');
JS
grep -q '8.8.8.8' "$FORKOP_CONFIG_FILE"
if FAIL_ALL=1 FAIL_GUARD=1 PATH="$WORK/bin:$PATH" "$REAL_UCODE" -L "$LIB" "$SCRIPT" restore "$id" > "$WORK/restore-unprotected.json"; then exit 1; fi
node - "$WORK/restore-unprotected.json" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const result = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(result.status, 'failed');
assert.equal(result.reason, 'guard_unavailable');
JS
test "$FORKOP_SNAPSHOT_LOCK_DIR" != "$FORKOP_SNAPSHOT_DIR/.lock"
mkdir -p "$WORK/run"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT/tests/helpers/wait.sh"
# The holder keeps the snapshot lock until the test releases it (bounded), so
# the checks below never race a fixed hold time.
export FORKOP_TEST_READY="$WORK/lock-ready" FORKOP_TEST_RELEASE="$WORK/lock-release"
cat > "$WORK/hold-version" <<'STUB'
#!/bin/sh
: > "$FORKOP_TEST_READY"
n=0
while [ ! -e "$FORKOP_TEST_RELEASE" ] && [ "$n" -lt 1200 ]; do sleep 0.05; n=$((n + 1)); done
printf 'test\n'
STUB
chmod +x "$WORK/hold-version"
FORKOP_BIN="$WORK/hold-version" ucode -L "$LIB" "$SCRIPT" create manual > "$WORK/held-create.json" &
holder=$!
wait_until 30 test -f "$FORKOP_TEST_READY" || exit 1
ls "$FORKOP_SNAPSHOT_LOCK_DIR"/owner.* >/dev/null || exit 1
if ucode -L "$LIB" "$SCRIPT" create manual > "$WORK/busy.json"; then exit 1; fi
node -e 'const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (r.status !== "busy" || r.reason !== "snapshot_operation_in_progress") process.exit(1);' "$WORK/busy.json"
ls "$FORKOP_SNAPSHOT_LOCK_DIR"/owner.* >/dev/null || exit 1
: > "$FORKOP_TEST_RELEASE"
wait "$holder"
[ ! -e "$FORKOP_SNAPSHOT_LOCK_DIR" ] || exit 1
node - "$LIB" "$SCRIPT" "$WORK" <<'JS'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const assert = require('node:assert/strict');
const [lib, script, work] = process.argv.slice(2);
function diff(before, after) {
  fs.writeFileSync(`${work}/before`, `config settings 'settings'\n${before}`);
  fs.writeFileSync(`${work}/after`, `config settings 'settings'\n${after}`);
  return JSON.parse(execFileSync('ucode', ['-L', lib, script, 'fixture-diff', `${work}/before`, `${work}/after`]));
}
const list = values => values.map(value => ` list dns_server '${value}'\n`).join('');
const a = ['1.1.1.1', '2.2.2.2'];
assert.deepEqual(diff(list(a), list([...a, '3.3.3.3']))[0].after, [...a, '3.3.3.3']);
assert.deepEqual(diff(list(a), list(['1.1.1.1']))[0].before, a);
assert.deepEqual(diff(list(a), list(['1.1.1.1', '3.3.3.3']))[0], {
  section: 'settings', option: 'dns_server', kind: 'list', before: a, after: ['1.1.1.1', '3.3.3.3']
});
assert.deepEqual(diff(list(a), list([...a].reverse()))[0].after, [...a].reverse());
assert.deepEqual(diff(list([...a, '2.2.2.2']), list(a))[0].before, [...a, '2.2.2.2']);
const secret = diff(" list subscription_urls 'https://user:pass@example.com/a'\n", " list subscription_urls 'https://token@example.com/b'\n");
assert.deepEqual(secret[0].before, ['***']);
assert.deepEqual(secret[0].after, ['***']);
assert.equal(JSON.stringify(secret).includes('pass'), false);
assert.equal(JSON.stringify(secret).includes('token@'), false);
const lines = (...items) => items.map(item => ` ${item}\n`).join('');
assert.deepEqual(diff(lines("option dns_server '1.1.1.1'"), lines("option dns_server '8.8.8.8'")), [
  { section: 'settings', option: 'dns_server', before: '1.1.1.1', after: '8.8.8.8' }
]);
assert.deepEqual(diff(list(a), list(a)), []);
const dup = values => lines(...values.map(value => `list action '${value}'`));
assert.deepEqual(diff(dup(['a', 'b']), dup(['a', 'a', 'b']))[0].after, ['a', 'a', 'b']);
assert.deepEqual(diff(dup(['a', 'a', 'b']), dup(['a', 'b']))[0].before, ['a', 'a', 'b']);
assert.deepEqual(diff(lines("option action 'a'"), lines("list action 'a'")), [
  { section: 'settings', option: 'action', kind: 'list', before: 'a', after: ['a'] }
]);
assert.deepEqual(diff(lines("list action 'a'"), lines("option action 'a'")), [
  { section: 'settings', option: 'action', kind: 'list', before: ['a'], after: 'a' }
]);
// An absent side is null ("not set"), not a hidden value (D-2, UC-063).
assert.deepEqual(diff('', list(a)), [
  { section: 'settings', option: 'dns_server', kind: 'list', before: null, after: a }
]);
assert.deepEqual(diff(list(a), ''), [
  { section: 'settings', option: 'dns_server', kind: 'list', before: a, after: null }
]);
assert.deepEqual(diff('', lines("option action 'x'")), [
  { section: 'settings', option: 'action', before: null, after: 'x' }
]);
assert.deepEqual(diff(lines("option action 'x'"), ''), [
  { section: 'settings', option: 'action', before: 'x', after: null }
]);
let before = '', after = '';
for (const option of ['password', 'passwd', 'secret', 'token', 'authorization', 'auth', 'uuid',
  'proxy_string', 'subscription_url', 'subscription_urls', 'private_key', 'credential']) {
  const value = `raw-${option}-s3cr3t`;
  before += lines(`option ${option} '${value}-old'`, `list ${option}_list '${value}-a'`);
  after += lines(`option ${option} '${value}-new'`, `list ${option}_list '${value}-a'`,
    `list ${option}_list '${value}-b'`);
}
const masked = JSON.stringify(diff(before, after));
assert.equal(masked.includes('s3cr3t'), false);
assert.equal(JSON.parse(masked).length, 24);

// Quoted values spanning several lines are compared as a whole.
const multi = (...values) => ` option action '${values.join('\n')}'\n option dns_type 'doh'\n`;
assert.deepEqual(diff(multi('a', 'b', 'c'), multi('a', 'b', 'c')), []);
for (const after of [multi('a', 'b', 'c', 'd'), multi('a', 'b'), multi('a', 'x', 'c')]) {
  const changes = diff(multi('a', 'b', 'c'), after);
  assert.equal(changes.length, 1);
  assert.equal(changes[0].option, 'action');
}
assert.deepEqual(diff(lines("option dns_type 'doh'"), lines("option dns_type 'dot'")), [
  { section: 'settings', option: 'dns_type', before: 'doh', after: 'dot' },
]);
// Quote characters inside values: libuci writes ' as '\'' and escapes in "...".
assert.equal(diff(lines("option dns_type 'a'\\''b'"), lines("option dns_type 'a'\\''b'")).length, 0);
assert.equal(diff(lines("option dns_type 'a'\\''b'"), lines("option dns_type 'a'\\''c'")).length, 1);
assert.equal(diff(lines('option dns_type "a\\"b"'), lines('option dns_type "a\\"c"')).length, 1);
// A later option after a multi-line value is still parsed correctly.
assert.deepEqual(diff(multi('a', 'b'), ` option action 'a\nb'\n option dns_type 'dot'\n`), [
  { section: 'settings', option: 'dns_type', before: 'doh', after: 'dot' },
]);
// A multi-line secret is masked as a whole, continuation lines included.
const secretMulti = (tail) => ` option subscription_url 'https://user:first-s3cr3t@example.com\n${tail}'\n`;
const secretChange = JSON.stringify(diff(secretMulti('second-s3cr3t'), secretMulti('third-s3cr3t')));
assert.equal(secretChange.includes('s3cr3t'), false);
assert.deepEqual(JSON.parse(secretChange), [
  { section: 'settings', option: 'subscription_url', before: '***', after: '***' },
]);
// A multi-line list entry is one list value.
assert.deepEqual(diff(" list dns_server 'x\ny'\n", " list dns_server 'x\nz'\n")[0].kind, 'list');
JS

(
# Lock scenarios use their own snapshot store so manual retention stays untouched.
export FORKOP_SNAPSHOT_DIR="$WORK/lock-snapshots"
LOCK_DIR="$FORKOP_SNAPSHOT_LOCK_DIR"
start_ticks() { sed 's/.*) //' "/proc/$1/stat" | awk '{print $20}'; }
no_lock_leftovers() {
  [ ! -e "$LOCK_DIR" ] || exit 1
  for leftover in "$LOCK_DIR".new.*; do [ ! -e "$leftover" ] || exit 1; done
  rm -f "$FORKOP_SNAPSHOT_DIR"/*.json
}
stale_lock() { mkdir "$LOCK_DIR"; printf '%s\n%s\n' "$1" "$2" > "$LOCK_DIR/owner.$1.$2"; }

# Dead PID.
stale_lock 999999 1
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers

# PID reuse: live PID, different start time; the process is never signalled.
sleep 30 &
reused_pid=$!
reused_ticks="$(start_ticks "$reused_pid")"
stale_lock "$reused_pid" 1
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
kill -0 "$reused_pid"

# Live PID with matching start time but a foreign executable is not an owner.
stale_lock "$reused_pid" "$reused_ticks"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
kill -0 "$reused_pid"

# Malformed records, a legacy record name and an empty (released mid-way) lock.
mkdir "$LOCK_DIR"
printf 'malformed\n' > "$LOCK_DIR/owner"
printf 'malformed\n' > "$LOCK_DIR/owner.x.1"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
mkdir "$LOCK_DIR"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
printf 'garbage\n' > "$LOCK_DIR"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
mkdir "$WORK/symlink-target"
: > "$WORK/symlink-target/keep"
ln -s "$WORK/symlink-target" "$LOCK_DIR"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
[ -f "$WORK/symlink-target/keep" ] || exit 1

# Release must not remove a lock that was replaced while the holder ran.
rm -f "$FORKOP_TEST_READY" "$FORKOP_TEST_RELEASE"
FORKOP_BIN="$WORK/hold-version" ucode -L "$LIB" "$SCRIPT" create manual >/dev/null &
holder=$!
wait_until 30 test -f "$FORKOP_TEST_READY" || exit 1
set -- "$LOCK_DIR"/owner.*
[ "$#" -eq 1 ] && [ -f "$1" ] || exit 1
mv "$LOCK_DIR" "$WORK/replaced-lock"
stale_lock "$reused_pid" "$reused_ticks"
: > "$FORKOP_TEST_RELEASE"
wait "$holder"
[ -f "$LOCK_DIR/owner.$reused_pid.$reused_ticks" ] || exit 1
rm -rf "$WORK/replaced-lock"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
no_lock_leftovers
kill -0 "$reused_pid"
kill "$reused_pid"
wait "$reused_pid" 2>/dev/null || true

# Another contender's unpublished lock is neither a blocker nor reclaimed.
mkdir "$LOCK_DIR.new.1.1"
ucode -L "$LIB" "$SCRIPT" create manual >/dev/null
[ -d "$LOCK_DIR.new.1.1" ] || exit 1
rmdir "$LOCK_DIR.new.1.1"
no_lock_leftovers

# Concurrent acquisition, from a free lock and from a stale one, never overlaps.
export FORKOP_TEST_CS="$WORK/critical" FORKOP_TEST_OVERLAP="$WORK/overlap"
cat > "$WORK/critical-version" <<'STUB'
#!/bin/sh
mkdir "$FORKOP_TEST_CS" 2>/dev/null || : > "$FORKOP_TEST_OVERLAP"
sleep 0.5
rmdir "$FORKOP_TEST_CS" 2>/dev/null
printf 'test\n'
STUB
chmod +x "$WORK/critical-version"
for round in free free stale stale stale stale; do
  if [ "$round" = stale ]; then stale_lock 999999 1; fi
  pids=""
  for n in 1 2 3 4 5 6 7 8; do
    FORKOP_BIN="$WORK/critical-version" ucode -L "$LIB" "$SCRIPT" create manual >/dev/null 2>&1 &
    pids="$pids $!"
  done
  won=0
  for pid in $pids; do if wait "$pid"; then won=$((won + 1)); fi; done
  [ "$won" -ge 1 ] || exit 1
  [ ! -e "$FORKOP_TEST_OVERLAP" ] || exit 1
  no_lock_leftovers
done
)
printf '{invalid' > "$FORKOP_SNAPSHOT_DIR/bad.json"
if ucode -L "$LIB" "$SCRIPT" diff bad >/dev/null; then exit 1; fi
for n in 1 2 3 4 5 6 7 8 9 10 11; do
  printf "config settings 'settings'\n option dns_server '10.0.0.%s'\n" "$n" > "$FORKOP_CONFIG_FILE"
  ucode -L "$LIB" "$SCRIPT" create automatic >/dev/null
done
ucode -L "$LIB" "$SCRIPT" list > "$WORK/retention.json"
node - "$WORK/retention.json" "$id" <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const rows = JSON.parse(fs.readFileSync(process.argv[2]));
assert.equal(rows.length, 10);
assert.ok(rows.some(row => row.id === process.argv[3] && row.kind === 'manual'));
JS
printf 'config_snapshots: PASS\n'
