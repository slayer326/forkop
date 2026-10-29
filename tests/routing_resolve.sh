#!/usr/bin/env bash
set -euo pipefail

# routing/resolve.uc is the one route/owner resolver. Run on the recorded
# route/owner cases it must give the recorded answers (first-match, FakeIP,
# undecidable matchers) and a structured result: status, kind, section,
# action, outbound, scope, provenance.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPERS="$ROOT_DIR/tests/helpers/route_owner"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

node "$HELPERS/run_resolver.js" "$ROOT_DIR/forkop/files/usr/lib" "$WORK" "$HELPERS/cases.js" > "$WORK/resolved.json"
node - "$WORK/resolved.json" "$HELPERS/owner.golden.json" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const resolved = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const golden = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
assert.deepEqual(Object.keys(resolved), Object.keys(golden), 'every recorded case ran');

for (const [name, want] of Object.entries(golden)) {
  const got = resolved[name];
  assert(got, `${name}: resolved`);
  assert.equal(got.route_rule, want.rule, `${name}: first-match rule index`);
  if (!want.decided) {
    assert.equal(got.reason, want.reason, `${name}: reason`);
    assert.notEqual(got.status, 'decided', `${name}: never guessed`);
    assert.equal(got.provenance, 'unknown', `${name}: no provenance without an answer`);
    for (const key of ['kind', 'section', 'action', 'outbound'])
      assert.equal(got[key], null, `${name}: ${key} stays empty when undecided`);
    continue;
  }
  assert.equal(got.status, 'decided', `${name}: decided`);
  assert.equal(got.provenance, 'simulated', `${name}: calculated, not observed`);
  assert.equal(got.outbound, want.outbound, `${name}: outbound`);
  assert.equal(got.route, want.kind, `${name}: route kind`);
}

// Status classes: undecidable (the config does not say), unsupported (a rule
// shape the resolver does not evaluate), unavailable (nothing to read).
const status = (name) => resolved[name].status;
for (const name of ['rule_set_before_owner', 'domain_regex', 'source_scoped', 'resolve_above_owner_fakeip'])
  assert.equal(status(name), 'undecidable', name);
for (const name of ['logical', 'unknown_field', 'tls_protocol']) assert.equal(status(name), 'unsupported', name);
assert.equal(status('singbox_config_missing'), 'unavailable');

// Canonical kinds and identity of the owning rule.
const yt = resolved.rule_owner;
assert.deepEqual([yt.kind, yt.section, yt.label, yt.action], ['rule', 'youtube', 'youtube', 'connection']);
assert.deepEqual(yt.scope, { rule: 'youtube', matchers: {} });
assert.deepEqual([resolved.second_rule.kind, resolved.second_rule.section], ['rule', 'discord']);
assert.deepEqual([resolved.first_match_connection.kind, resolved.first_match_connection.section,
  resolved.first_match_connection.action], ['rule', 'main', 'connection']);
assert.deepEqual([resolved.reject.kind, resolved.reject.action], ['block', 'block']);
assert.deepEqual([resolved.final.kind, resolved.final.action], ['direct', 'direct']);
console.log(`routing_resolve: PASS (${Object.keys(golden).length} cases)`);
NODE
