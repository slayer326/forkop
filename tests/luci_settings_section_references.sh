#!/usr/bin/env bash
set -euo pipefail

# Settings "through a section" selects (DNS, lists and components downloads)
# keep a saved section that is disabled, still has a retired action (a
# Zapret rule the migration has not turned into a bypass rule yet), or no
# longer exists: the value stays selected with a label and Save is refused
# until the user picks another section, instead of silently re-pointing to
# the first eligible rule (UC-008). Every selected section is checked as the
# save leaves it: the Enable checkbox of its rules grid row, its removal. A rule removal that
# such a refusal blocks is undone and reported instead of failing silently
# or staying staged for the next save.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/tests/helpers/luci_form_harness.js" <<'NODE'
const assert = require('node:assert/strict');
const { createEnvironment } = require(process.argv[2]);

function section(name, values) {
  return Object.assign({ '.name': name, '.type': 'section', '.anonymous': false, enabled: '1',
    label: name.toUpperCase() }, values);
}
const baseConfig = {
  vpn: section('vpn', { action: 'connection', selector_proxy_links: ['socks5://10.0.0.1:1080'] }),
  off: section('off', { enabled: '0', action: 'connection', selector_proxy_links: ['socks5://10.0.0.2:1080'] }),
  dpi: section('dpi', { action: 'zapret', community_lists: ['youtube'] }),
};
function settingsConfig(values) {
  return Object.assign({}, baseConfig, {
    settings: Object.assign({ '.name': 'settings', '.type': 'settings', '.anonymous': false,
      yacd_secret_key: 'secret-0123456789' }, values),
  });
}
const installed = { loaded: true };

const failures = [];
async function check(label, fn) {
  try {
    await fn();
  } catch (error) {
    failures.push(`${label}: ${error.stack || error.message}`);
  }
}

const references = [
  ['dns_detour_enabled', 'dns_detour_section'],
  ['download_lists_via_proxy', 'download_lists_via_proxy_section'],
  ['download_components_via_proxy', 'download_components_via_proxy_section'],
];

(async () => {
  for (const version of ['24.10', '25.12']) {
    for (const [flag, option] of references)
      for (const [label, value, mark] of [
        ['disabled section', 'off', /^OFF \(disabled\)$/],
        ['retired action', 'dpi', /^DPI \(unavailable\)$/],
        ['deleted section', 'gone', /^gone \(unavailable\)$/],
      ]) await check(`${version} ${option}: ${label}`, async () => {
        const env = createEnvironment({ version, config: settingsConfig({ [flag]: '1', [option]: value }) });
        const settings = await env.openSettings(installed);
        const select = settings.option(option);
        assert.equal(select.formvalue('settings'), value, 'the widget must keep the saved section');
        assert.match(select.vallist[select.keylist.indexOf(value)], mark);
        assert.equal(select.keylist.includes('vpn'), true, 'eligible sections are still offered');
        await assert.rejects(settings.save());
        assert.equal(env.uci.data.settings[option], value, 'a refused save re-pointed the section');

        select.getUIElement('settings').setValue('vpn');
        await settings.save();
        assert.equal(env.uci.data.settings[option], 'vpn', 'an explicit choice is saved');
      });

    // An available saved section saves unchanged.
    await check(`${version} available section`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'vpn' }) });
      const settings = await env.openSettings(installed);
      await settings.save();
      assert.equal(env.uci.data.settings.dns_detour_section, 'vpn');
    });

    // The selected section is checked as this save leaves it, whether or not
    // it was offered when the form loaded. LuCI's uci.state.values is the
    // config as loaded (edits staged on the page stay in state.changes until
    // a successful save reloads it), and the Enable checkbox of a rules grid
    // row is parsed in the same save, after LuCI validated the Settings
    // fields (Map.save -> checkDepends -> triggerValidation, then parse).
    const loadedValues = (env) => {
      env.uci.state.values = { forkop: JSON.parse(JSON.stringify(env.uci.data)) };
    };
    for (const [label, value, enable, accepted] of [
      ['enabling the disabled section', 'off', '1', true],
      ['disabling the selected section', 'vpn', '0', false],
    ]) await check(`${version} rules grid Enable: ${label}`, async () => {
      const env = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: value }) });
      loadedValues(env);
      const settings = await env.openSettings(installed);
      const select = settings.option('dns_detour_section');
      const [enabled, row] = settings.map.lookupOption('enabled', value);
      enabled.getUIElement(row).setValue(enable);
      assert.equal(select.isValid('settings'), accepted, 'the Enable checkbox of the row was not honoured');
      if (accepted) {
        await settings.save();
        assert.equal(env.uci.data[value].enabled, '1');
        await settings.save();
      } else {
        await assert.rejects(settings.save(), /The selected section is disabled/);
      }
      assert.equal(env.uci.data.settings.dns_detour_section, value);
    });

    // Deleting the selected rule: the save that follows the removal is
    // refused and reported instead of leaving Settings pointing to a rule
    // that the backend then rejects as missing. The removal and the cleanup
    // of the rule's child items are undone: the next save (a rule modal Save
    // sends the whole package through uci.save) must not apply them.
    await check(`${version} removing the selected rule is refused and undone`, async () => {
      const config = settingsConfig({ dns_detour_enabled: '1', dns_detour_section: 'vpn' });
      config.vpn = Object.assign({}, config.vpn, { subscription_url: ['vpnsub'] });
      config.vpnsub = { '.name': 'vpnsub', '.type': 'subscription_url', '.anonymous': false, section: 'vpn',
        url: 'https://example.com/sub', subscription_update_enabled: '1', subscription_update_interval: '4h' };
      const env = createEnvironment({ version, config });
      loadedValues(env);
      const notifications = [];
      env.ui.addNotification = (_title, node, type) => notifications.push({ type, text: node.textContent });
      const settings = await env.openSettings(installed);
      await settings.removeRule('vpn');
      assert.equal(notifications.length, 1, 'the refused save after the removal must be reported');
      assert.equal(notifications[0].type, 'error');
      assert.match(notifications[0].text, /The rule was not removed/);
      assert.match(notifications[0].text, /The selected section no longer exists/);
      assert.deepEqual(env.uci.data, config, 'a refused removal stayed staged');

      const modal = await env.openRule('off');
      await modal.saveButton();
      assert.deepEqual(env.uci.data.vpn, config.vpn, 'the next save applied the refused removal');
      assert.deepEqual(env.uci.data.vpnsub, config.vpnsub, 'the next save removed the child items');
      assert.equal(env.uci.data.settings.dns_detour_section, 'vpn');
    });

    // Deleting a rule saves the whole Settings page silently in LuCI. When a
    // kept section refuses that save, the row stays, the removal is undone
    // and the user is told why.
    await check(`${version} rule removal refused by a kept section`, async () => {
      const config = settingsConfig({ dns_detour_enabled: '1', dns_detour_section: 'gone' });
      const env = createEnvironment({ version, config });
      const notifications = [];
      env.ui.addNotification = (_title, node, type) => notifications.push({ type, text: node.textContent });
      const settings = await env.openSettings(installed);
      await settings.removeRule('off');
      assert.equal(notifications.length, 1, 'a refused removal must be reported');
      assert.equal(notifications[0].type, 'error');
      assert.match(notifications[0].text, /The rule was not removed/);
      assert.match(notifications[0].text, /The selected section no longer exists/);
      assert.deepEqual(env.uci.data, config, 'a refused removal stayed staged');

      // Control: a removal that saves reports nothing.
      const ok = createEnvironment({ version, config: settingsConfig({ dns_detour_enabled: '1',
        dns_detour_section: 'vpn' }) });
      ok.ui.addNotification = () => notifications.push('unexpected');
      await (await ok.openSettings(installed)).removeRule('off');
      assert.equal(ok.uci.data.off, undefined);
      assert.equal(notifications.length, 1, 'a saved removal must not report an error');
    });

  }
  if (failures.length) {
    console.error(failures.join('\n\n'));
    process.exit(1);
  }
  console.log('luci_settings_section_references: PASS');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE
