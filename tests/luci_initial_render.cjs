const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

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

Promise.all([check(false), check(true)])
  .then(() => console.log('luci_initial_render: PASS'))
  .catch((error) => { console.error(error); process.exitCode = 1; });
