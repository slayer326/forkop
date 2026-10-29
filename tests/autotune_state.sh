#!/usr/bin/env bash
set -euo pipefail

# Stage 6.8.1: autotune policy and targets from UCI (defaults when absent,
# invalid values never make it more aggressive), the persistent state on
# flash (atomic, written only when changed, no raw user strategies) and the
# full last tune output in tmpfs; read-only autotune_status/autotune_target.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export FORKOP_LIB="$LIB"
export FORKOP_AUTOTUNE_STATE_FILE="$WORK/etc/autotune/state.json"
export FORKOP_AUTOTUNE_LAST_DIR="$WORK/run/last"
export FORKOP_CONFIG_FILE="$WORK/forkop"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$WORK/forkop" <<'CONF'
config settings 'settings'
config section 'youtube'
	option action 'zapret'
	option nfqws_opt '--filter-tcp=443 --dpi-desync=fake --hostlist=/etc/private-user-list'
CONF

manager() { ucode -L "$LIB" "$LIB/autotune/manager.uc" "$@"; }

# No autotune section: defaults, mode off, nothing written.
manager status >"$WORK/defaults.json"
[ ! -e "$FORKOP_AUTOTUNE_STATE_FILE" ] || fail "reading the status must not create the state"

cat >>"$WORK/forkop" <<'CONF'
config autotune 'autotune'
	option mode 'auto'
	option interval '30m'
	option confirmations '99'
	option min_confidence 'low'
	option max_applies_per_day '2'
	option cooldown '12h'
config autotune_target 'yt'
	option host 'YouTube.com'
config autotune_target 'ds'
	option host 'discord.com'
	option enabled '0'
	option resolver '192.0.2.53'
config autotune_target 'bad'
	option host 'not a host'
config autotune_target 'res'
	option host 'example.org'
	option resolver 'dns.example'
CONF
manager status >"$WORK/policy.json"
if manager target '../etc' >"$WORK/invalid.json"; then fail "an invalid target id must be refused"; fi
if manager target nosuch >"$WORK/unknown.json"; then fail "an unknown target must be refused"; fi

cat >"$WORK/state.uc" <<'UC'
let state = require("autotune.state");
let fs = require("fs");
let out = {};
out.empty = state.read();
let s = state.read();
let tune = {
  status: "selected", reason: "direct_failed_candidate_stable", selected: "multisplit", confidence: "high",
  target: { host: "youtube.com", ip: "142.250.1.1", resolver: "192.0.2.53" },
  candidates: [
    { id: "direct", stability: "failed", success: 0, attempted: 5, success_ratio: 0, median_tls_ms: null,
      failure_classes: [ { class: "tls_reset", count: 5 } ], median_connect_ms: 11, complexity: 0 },
    { id: "multisplit", stability: "stable", success: 5, attempted: 5, success_ratio: 1.0, median_tls_ms: 180,
      failure_classes: [], median_connect_ms: 12, complexity: 1 }
  ],
  probes: [ { candidate: "multisplit", time_appconnect_ms: 180 } ],
  isolation: { queues: [ 4600 ], argv: [ "nfqws", "--dpi-desync=multisplit" ] }
};
out.summary = state.record_tune(s, "yt", tune, { host: "youtube.com", group: "youtube", fingerprint: "abc" }, 1000);
out.invalid = state.record_tune(s, "../x", tune, {}, 1000);
out.written = state.write(s);
let first = fs.stat(state.STATE_FILE);
out.rewritten = state.write(state.read());
let second = fs.stat(state.STATE_FILE);
out.same_inode = first.inode == second.inode && first.mtime == second.mtime;
out.full = state.load_full("yt");
out.reread = state.read();
state.prune(s, [], null);
out.pruned = s.targets;
fs.writefile(state.STATE_FILE, "{ not json");
out.corrupt = state.read();
fs.writefile(state.STATE_FILE, sprintf("%J", { version: 99, targets: { yt: {} } }));
out.foreign = state.read();
print(sprintf("%J\n", out));
UC
ucode -L "$LIB" "$WORK/state.uc" >"$WORK/state.json"

node - "$WORK" "$FORKOP_AUTOTUNE_STATE_FILE" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [work] = process.argv.slice(2);
const read = (name) => JSON.parse(fs.readFileSync(`${work}/${name}.json`, 'utf8'));

const defaults = read('defaults');
assert.deepEqual([defaults.policy.mode, defaults.policy.interval, defaults.policy.confirmations,
  defaults.policy.min_confidence, defaults.policy.max_applies_per_day, defaults.policy.cooldown, defaults.policy.probes],
  ['off', '6h', 3, 'high', 1, '24h', 5], 'defaults without an autotune section');
assert.deepEqual(defaults.targets, []);

const policy = read('policy');
assert.equal(policy.policy.mode, 'recommend', 'a stored auto reads as recommend: autonomous apply is off');
assert.equal(policy.policy.interval, '6h', 'an interval below 1h falls back to the default');
assert.equal(policy.policy.confirmations, 3, 'out-of-range confirmations fall back to the default');
assert.equal(policy.policy.min_confidence, 'high', 'an invalid confidence falls back to high');
assert.equal(policy.policy.apply_min_confidence, 'high', 'autonomous apply always needs high confidence');
assert.deepEqual([policy.policy.max_applies_per_day, policy.policy.cooldown, policy.policy.cooldown_seconds], [2, '12h', 43200]);
assert.deepEqual(policy.errors.map((e) => e.option || e.target).sort(), ['bad', 'confirmations', 'interval', 'min_confidence', 'res']);
assert.deepEqual(policy.targets.map((t) => [t.id, t.host, t.enabled, t.resolver]),
  [['yt', 'youtube.com', true, null], ['ds', 'discord.com', false, '192.0.2.53']]);
assert.equal(read('invalid').reason, 'invalid_target');
assert.equal(read('unknown').reason, 'unknown_target');

const s = read('state');
assert.deepEqual(s.empty.targets, {});
assert.equal(s.empty.version, 1);
assert.deepEqual(Object.keys(s.summary).sort(),
  ['at', 'candidates', 'confidence', 'fingerprint', 'group', 'host', 'ip', 'leading', 'reason', 'selected', 'status']);
assert.deepEqual(s.summary.candidates[1], { id: 'multisplit', stability: 'stable', success: 5, attempted: 5,
  success_ratio: 1, median_tls_ms: 180, failure_classes: [] });
assert.equal(s.invalid, null, 'invalid target ids are refused');
assert.equal(s.written, true);
assert.equal(s.same_inode, true, 'an unchanged state is not written to flash again');
assert.equal(s.full.probes.length, 1, 'the full tune output is kept in tmpfs');
assert.equal(s.reread.targets.yt.selected, 'multisplit');
assert.deepEqual(s.pruned, {}, 'targets removed from the policy are forgotten');
assert.deepEqual(s.corrupt.targets, {}, 'a corrupt state reads as empty');
assert.deepEqual(s.foreign.targets, {}, 'a state of another version reads as empty');

for (const name of ['defaults', 'policy', 'state'])
  assert.doesNotMatch(fs.readFileSync(`${work}/${name}.json`, 'utf8'), /private-user-list/, `${name}: no raw user strategy`);
console.log('autotune state checks passed');
NODE
mode=$(stat -c %a "$FORKOP_AUTOTUNE_STATE_FILE"); [ "$mode" = 600 ] || fail "state file must be private (got $mode)"
