#!/usr/bin/env bash
set -euo pipefail

# Save & Apply on the Rules and Settings pages (configform.js) takes a snapshot first and, once the
# reload is confirmed, lists what changed since it (config_snapshot_diff).
# D-2(a), UC-063: an option absent on one side reads "not set", '***' only
# for a value that exists and is hidden. UC-062: a diff longer than the
# backend lists ends with { truncated, total } in place of the rest; the
# notification counts the rest instead of printing the marker as a change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const file = path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/configform.js');

if (typeof String.prototype.format !== 'function') {
  // LuCI's printf-like String.format(); only %s/%d are used here.
  // eslint-disable-next-line no-extend-native
  String.prototype.format = function (...args) {
    let index = 0;
    return this.replace(/%[sd]/g, () => `${args[index++]}`);
  };
}

// LuCI module: "require x as y" directives, then `return <class>`.
function load(modules) {
  const source = fs.readFileSync(file, 'utf8');
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split('.').pop();
    assert(name in modules, `no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  return new Function(...names, '_', 'E', 'window', source)(
    ...values, (value) => value, (tag, attrs, children) => ({ tag, attrs, children }),
    { setTimeout() {} });
}

async function saveApply(entries) {
  const notes = [];
  class Map {
    section() { return {}; }
    render() { return 'rendered'; }
  }
  let health = 0;
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop',
    ForkopShellMethods: {
      snapshotCreate: async () => ({ success: true, data: { status: 'created', snapshot: { id: '1_1' } } }),
      // Before the apply: no reload yet; after it: a confirmed one.
      getHealthStatus: async () => ({
        success: true,
        data: { last_reload: health++ ? { timestamp: Math.floor(Date.now() / 1000) + 5, status: 'success' } : null },
      }),
      snapshotDiff: async (id) => {
        assert.equal(id, '1_1');
        return { success: true, data: entries };
      },
      getUiState: async () => ({ success: false }),
    },
  };
  const configform = load({
    baseclass: { extend: (value) => value },
    form: { Map, GridSection: {}, TypedSection: {}, TableSection: { prototype: {} } },
    uci: { get() {} },
    ui: { addNotification(title, node, type) { notes.push({ node, type }); }, addValidator() {} },
    main,
  });
  assert.equal(await configform.saveApplyWithSnapshot(() => Promise.resolve('applied')), 'applied');
  assert.equal(notes.length, 1);
  assert.equal(notes[0].type, 'info');
  return notes[0].node.children.split('\n');
}

const change = (i) => ({ section: 'settings', option: `opt${i}`, before: 'a', after: 'b' });

(async () => {
  // D-2(a): absent sides read "not set"; hidden values stay '***'.
  assert.deepEqual(await saveApply([
    { section: 'settings', option: 'password', before: null, after: '***' },
    { section: '@section_interface[0]', option: 'dns_type', before: 'udp', after: null },
    { section: 'settings', option: 'dns_server', kind: 'list', before: null, after: ['1.1.1.1'] },
  ]), [
    'Configuration applied successfully',
    'settings.password: not set → ***',
    '@section_interface[0].dns_type: udp → not set',
    'settings.dns_server: not set → ["1.1.1.1"]',
  ]);

  // UC-062: 100 listed changes of 250; the marker is no change row.
  const lines = await saveApply([...Array.from({ length: 100 }, (_, i) => change(i)), { truncated: true, total: 250 }]);
  assert.equal(lines.length, 102);
  assert.equal(lines[1], 'settings.opt0: a → b');
  assert.equal(lines[100], 'settings.opt99: a → b');
  assert.equal(lines[101], 'and 150 more');
  assert.equal(lines.some((line) => line.includes('undefined')), false);

  // A whole diff has no "more" line.
  assert.deepEqual(await saveApply([change(0)]), ['Configuration applied successfully', 'settings.opt0: a → b']);

  // The snapshot is a hard precondition, not a notification after applying.
  let applied = false;
  const blocked = load({
    baseclass: { extend: value => value },
    form: { Map: class {}, GridSection: {}, TypedSection: {}, TableSection: { prototype: {} } },
    uci: { get() {} },
    ui: { addNotification() {}, addValidator() {} },
    main: { FORKOP_UCI_PACKAGE: 'forkop', ForkopShellMethods: {
      snapshotCreate: async () => ({ success: false, data: { status: 'busy' } }),
    } },
  });
  await blocked.saveApplyWithSnapshot(() => { applied = true; });
  assert.equal(applied, false, 'failed snapshot must prevent Save & Apply');

  console.log('luci_apply_diff_notice: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
