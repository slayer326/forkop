const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createEnvironment } = require('./helpers/luci_form_harness.js');

const source = fs.readFileSync(
  path.join(__dirname, '../luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js'),
  'utf8',
);

async function check(readonly) {
  let startPageCalled = false;
  const shell = {
    detectAccess: async () => readonly,
    startPage: () => {
      startPageCalled = true;
      return new Promise(() => {});
    },
  };
  const entry = new Function(
    'view', 'form', 'main', 'shell', 'configform', 'settings', 'section',
    'dashboard', 'monitoring', 'diagnostic', 'updates', 'history', '_',
    source,
  )(
    { extend: (value) => value }, {}, {}, shell, {}, {}, {}, {}, {}, {}, {}, {},
    (value) => value,
  );
  const access = await Promise.race([
    entry.load(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('LuCI load waited for capability probe')), 100)),
  ]);
  assert.equal(access, readonly);
  assert.equal(startPageCalled, true);
}

// The rule grid and its editor render without waiting for any probe.
async function checkRuleGrid() {
  const env = createEnvironment({
    config: { rule: { '.name': 'rule', '.type': 'section', enabled: '1', action: 'connection' } },
  });
  const timeout = (what) => new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`${what} waited for a probe`)), 100));
  await Promise.race([env.grid.map.render(), timeout('Rule grid')]);
  const rule = await Promise.race([env.openRule('rule'), timeout('Rule editor')]);
  const actions = rule.option('action').keylist;
  assert.ok(actions.includes('connection'));
  for (const retired of ['zapret', 'zapret2', 'byedpi'])
    assert.equal(actions.includes(retired), false, `${retired} is not offered`);
}

Promise.all([check(false), check(true), checkRuleGrid()])
  .then(() => console.log('luci_initial_render: PASS'))
  .catch((error) => { console.error(error); process.exitCode = 1; });
