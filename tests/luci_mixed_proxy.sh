#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.lastIndexOf('o = section.taboption(', source.indexOf('"mixed_proxy_enabled"'));
const end = source.lastIndexOf('o = section.taboption(', source.indexOf('"resolve_real_ip_for_routing"'));
assert(start >= 0 && end > start, 'mixed proxy form not found');
const options = {};
vm.runInNewContext(source.slice(start, end), {
  _: text => text,
  form: { Flag: 'Flag', Value: 'Value' },
  section: {
    taboption(tab, type, name) {
      return options[name] = {
        tab, type, dependencies: [],
        depends(key, value) {
          this.dependencies.push(typeof key === 'string' ? { [key]: value } : key);
        },
      };
    },
  },
});
const visible = (name, state) => options[name].dependencies.some(dependency =>
  Object.entries(dependency).every(([key, value]) => state[key] === value));
const names = ['mixed_proxy_enabled', 'mixed_proxy_port', 'mixed_proxy_auth_enabled',
  'mixed_proxy_username', 'mixed_proxy_password'];
assert.deepEqual(Object.keys(options), names);
for (const action of ['connection', 'proxy', 'vpn', 'outbound', 'byedpi', 'zapret', 'zapret2']) {
  for (const enabled of ['0', '1']) {
    for (const auth of ['0', '1']) {
      const state = { action, mixed_proxy_enabled: enabled, mixed_proxy_auth_enabled: auth };
      for (const name of names) {
        const expected = name === 'mixed_proxy_enabled' ||
          (enabled === '1' && (!['mixed_proxy_username', 'mixed_proxy_password'].includes(name) || auth === '1'));
        assert.equal(visible(name, state), expected, `${action}/${enabled}/${auth}: ${name}`);
      }
    }
  }
}
for (const action of ['block', 'bypass', 'dns']) {
  for (const name of names)
    assert.equal(visible(name, { action, mixed_proxy_enabled: '1', mixed_proxy_auth_enabled: '1' }), false);
}
assert.equal(options.mixed_proxy_enabled.default, '0', 'proxy must remain opt-in');
assert.equal(options.mixed_proxy_password.password, true, 'mask password in the form');
for (const port of ['1', '2080', '65535'])
  assert.equal(options.mixed_proxy_port.validate('test', port), true);
for (const port of ['', '0', '65536', '-1', '2080oops', '2080.5', '1e3', ' 2080'])
  assert.notEqual(options.mixed_proxy_port.validate('test', port), true, `reject ${port}`);
for (const name of ['mixed_proxy_username', 'mixed_proxy_password']) {
  assert.notEqual(options[name].validate('test', ''), true);
  assert.equal(options[name].validate('test', 'example'), true);
}
console.log('LuCI mixed proxy visibility, authentication and validation checks passed');
NODE
