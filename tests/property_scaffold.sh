#!/usr/bin/env bash
set -euo pipefail

# The seeded property-test scaffold (tests/helpers/property/scaffold.js) is
# reproducible and loud: one seed always gives the same cases, a failing
# property names its seed and case, a property no case exercised fails, and
# ucode evaluates a whole batch in input order.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
export PROPERTY_WORK="$WORK"

node - "$ROOT_DIR/tests/helpers/property/scaffold.js" "$ROOT_DIR/forkop/files/usr/lib" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const [scaffoldPath, lib] = process.argv.slice(2);
const { Rng, seedFrom, casesFrom, ucodeBatch, forAll, exercised } = require(scaffoldPath);

const draw = (seed) => { const r = new Rng(seed); return Array.from({ length: 50 }, () => r.u32()); };
assert.deepEqual(draw(7), draw(7), 'one seed gives one sequence');
assert.notDeepEqual(draw(7), draw(8), 'another seed gives another sequence');
const r = new Rng(1);
const ints = Array.from({ length: 2000 }, () => r.int(3, 5));
assert.deepEqual([...new Set(ints)].sort(), [3, 4, 5], 'int() covers both bounds and nothing else');
assert.deepEqual(new Rng(2).shuffle([1, 2, 3, 4, 5]).sort(), [1, 2, 3, 4, 5], 'shuffle keeps the items');

delete process.env.PROPERTY_SEED;
assert.equal(seedFrom(42), 42);
process.env.PROPERTY_SEED = '9';
assert.equal(seedFrom(42), 9, 'PROPERTY_SEED replays another seed');
process.env.PROPERTY_CASES = 'x';
assert.throws(() => casesFrom(10), /PROPERTY_CASES/);
delete process.env.PROPERTY_CASES;

const messages = [];
const error = console.error;
console.error = (line) => messages.push(line);
try {
  assert.throws(() => forAll('even', 1234, [2, 4, 5], (n) => assert.equal(n % 2, 0)), assert.AssertionError);
} finally {
  console.error = error;
}
assert.match(messages[0], /property "even" failed for case 2 \(replay: PROPERTY_SEED=1234\)/);
assert.equal(messages[1], 'case: 5');
assert.throws(() => exercised('rare', 1, 2), /exercised by 1 cases, want at least 2/);

const out = ucodeBatch(lib, 'let identity = require("core.process_identity");\nfunction evaluate(input) { return [ input.n * 2, type(identity) ]; }',
  Array.from({ length: 100 }, (_, n) => ({ n })));
assert.deepEqual(out.map((o) => o[0]), Array.from({ length: 100 }, (_, n) => n * 2), 'results in input order');
assert.equal(out[0][1], 'object', 'production modules are on the module path');
assert.deepEqual(fs.readdirSync(process.env.PROPERTY_WORK), [], 'batch files are removed');
console.log('property scaffold checks passed');
NODE
