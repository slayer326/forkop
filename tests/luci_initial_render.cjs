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
    'dashboard', 'monitoring', 'diagnostic', 'updates', 'history', 'autotune', '_',
    source,
  )(
    { extend: (value) => value }, {}, {}, shell, {}, {}, {}, {}, {}, {}, {}, {}, {},
    (value) => value,
  );
  const access = await Promise.race([
    entry.load(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('LuCI load waited for capability probe')), 100)),
  ]);
  assert.equal(access, readonly);
  assert.equal(startPageCalled, true);
}

async function checkRuleGrid() {
  let resolveAvailability;
  const env = createEnvironment({
    config: { rule: { '.name': 'rule', '.type': 'section', enabled: '1', action: 'zapret' } },
    providerAvailabilityLoader: () => new Promise((resolve) => { resolveAvailability = resolve; }),
  });
  await Promise.race([
    env.grid.map.render(),
    new Promise((_, reject) => setTimeout(() => reject(new Error('Rule grid waited for provider probe')), 100)),
  ]);
  const modal = env.openRule('rule');
  await Promise.resolve();
  assert.equal(typeof resolveAvailability, 'function');
  resolveAvailability({ zapretInstalled: true, zapret2Installed: false, byedpiInstalled: false });
  const rule = await modal;
  assert.ok(rule.option('action').keylist.includes('zapret'));
}

Promise.all([check(false), check(true), checkRuleGrid()])
  .then(() => console.log('luci_initial_render: PASS'))
  .catch((error) => { console.error(error); process.exitCode = 1; });
