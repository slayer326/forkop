#!/usr/bin/env bash
set -euo pipefail

# Forkop X is one LuCI view (admin/services/forkop) whose features are tabs of a
# single form. This test covers that view: a session that cannot read the Forkop
# UCI package is switched to read-only before any content renders and is offered
# only the tabs that read state, while the two that write - the rules and the
# settings - appear for an administrator alone.
#
# The tabs are recorded through a form double, so the set each role is offered
# is observed rather than matched in the source.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const viewDir = path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop');
const read = file => fs.readFileSync(path.join(viewDir, file), 'utf8');

// LuCI module: "require x as y" directives, then `return <class>`.
function load(file, modules) {
  const source = read(file);
  const names = [];
  const values = [];
  for (const [, dep, alias] of source.matchAll(/^"require ([\w.]+)(?: as (\w+))?";$/gm)) {
    const name = alias || dep.split('.').pop();
    assert(name in modules, `${file}: no stub for ${dep}`);
    names.push(name);
    values.push(modules[name]);
  }
  return new Function(...names, '_', 'E', 'window', 'CustomEvent', source)(
    ...values, value => value, (tag, attrs, children) => ({ tag, attrs, children }),
    { dispatchEvent() {}, setTimeout() {} }, class {});
}

// A form double that records the sections a map is given. The section types are
// what LuCI writes as data-tab, and the tab controllers ask about exactly those
// ids, so the recorded types are the tabs the role is offered.
function formDouble(record) {
  class MapDouble {
    constructor(_pkg, title) { this.title = title; record.maps.push(this); }
    section(Type, type, title) {
      const section = { Type, type, title, options: [] };
      section.option = (OptionType, name) => {
        const option = { OptionType, name };
        section.options.push(option);
        return option;
      };
      record.sections.push(section);
      return section;
    }
    // CBI resolves each option's cfgvalue when it renders it, and that is what
    // starts a tab's controller: a double that never calls it would let a tab
    // be mounted without one and still pass.
    render() {
      for (const section of record.sections)
        for (const option of section.options)
          if (typeof option.cfgvalue === 'function') option.cfgvalue();
      return `rendered:${this.title}`;
    }
  }
  class JSONMapDouble extends MapDouble {
    constructor(data, title) { super(null, title); this.data = data; }
  }
  return {
    Map: MapDouble,
    JSONMap: JSONMapDouble,
    TypedSection: 'TypedSection',
    GridSection: Object.assign('GridSection', { prototype: { renderSectionAdd() {} } }),
    DummyValue: 'DummyValue',
  };
}

function stubs(canReadUci, calls) {
  const record = { maps: [], sections: [] };
  const form = formDouble(record);
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop',
    injectGlobalStyles() {},
    coreService() { calls.push('core'); },
    setReadonlyMode(value) { calls.push(`readonly:${value}`); },
    setForkopPage(page) { calls.push(`page:${page}`); },
    store: { get: () => ({ diagnosticsSystemInfo: {} }), set() {} },
    FORKOP_ACTION_PROVIDERS_AVAILABILITY_EVENT: 'x',
    ForkopShellMethods: {
      getUiCapabilities: async () => ({ success: true, data: {} }),
      snapshotCreate: async () => ({ success: true, data: { status: 'created' } }),
    },
  };
  for (const tab of ['DashboardTab', 'MonitoringTab', 'DiagnosticTab', 'AutotuneTab', 'HistoryTab', 'UpdatesTab']) {
    main[tab] = {
      initController() { calls.push(`init:${tab}`); },
      render() {
        assert(!canReadUci ? calls.includes('readonly:true') : true,
          `${tab} rendered before the read-only mode was set`);
        calls.push(`render:${tab}`);
        return tab;
      },
    };
  }
  const baseclass = { extend: value => value };
  const uci = { load: async () => { if (!canReadUci) throw Error('Permission denied'); } };
  const ui = { addNotification() {} };
  const localDevices = { loadLocalDeviceChoices: async () => ({}) };
  const mountModules = {
    dashboard: 'dashboard.js', diagnostic: 'diagnostic.js', monitoring: 'monitoring.js',
    history: 'history.js', autotune: 'autotune.js', updates: 'updates.js',
  };
  const mounts = {};
  for (const [name, file] of Object.entries(mountModules))
    mounts[name] = load(file, { baseclass, form, ui, uci, fs: {}, main, localDevices });

  // The shell is the real one: it decides the role and starts the services.
  const shell = load('shell.js', { baseclass, uci, ui, main });
  return {
    record,
    modules: {
      view: { extend: value => value }, form, baseclass, uci, ui, main, shell, localDevices,
      ...mounts,
      configform: {
        createMap: (title, description) => new form.Map('forkop', title, description),
        configureGridSection() {},
      },
      settings: {
        createSettingsContent(sections) {
          calls.push('settings-content');
          record.settingsGroups = sections;
        },
      },
      section: { configureSectionSection() {}, createSectionContent() { calls.push('rules-content'); } },
    },
  };
}

const tabsOf = record => record.sections.map(section => section.type);

(async () => {
  // A read-only session: detected before anything renders, offered the tabs
  // that only read, and never the rules or the settings.
  {
    const calls = [];
    const context = stubs(false, calls);
    const view = load('forkop.js', context.modules);
    assert.equal(await view.load(), true, 'a read-only session was not detected');
    const rendered = await view.render(true);
    assert.match(String(rendered), /^rendered:/, 'the read-only view must render a map');
    assert.equal(calls.filter(call => call === 'readonly:true').length, 1,
      'read-only mode must be set exactly once');
    assert.deepEqual(tabsOf(context.record),
      ['dashboard', 'diagnostic', 'monitoring', 'history', 'autotune'],
      'the read-only role must be offered every reading tab and no other');
    assert.equal(context.record.maps.length, 1);
    assert.equal(context.record.maps[0].readonly, true, 'the read-only map must be read-only');
    assert.equal(context.record.maps[0].tabbed, true, 'the view is tabbed, not a page per feature');
    assert(!calls.includes('rules-content'), 'the read-only role must not be given the rules form');
    assert(!calls.includes('settings-content'), 'the read-only role must not be given the settings form');
  }

  // An administrator: the same reading tabs plus the two that write.
  {
    const calls = [];
    const context = stubs(true, calls);
    const view = load('forkop.js', context.modules);
    assert.equal(await view.load(), false, 'an administrator was detected as read-only');
    await view.render(false);
    assert(!calls.some(call => call.startsWith('readonly:')), 'an administrator must not be read-only');
    assert.deepEqual(tabsOf(context.record),
      ['section', 'settings', 'diagnostic', 'dashboard', 'monitoring', 'history', 'autotune', 'updates'],
      'the administrator tab set changed');
    assert.equal(context.record.maps[0].tabbed, true, 'the view is tabbed');
    assert(calls.includes('rules-content'), 'the rules form is missing');
    assert(calls.includes('settings-content'), 'the settings form is missing');
    // The four settings groups share the one "settings" tab, rather than
    // taking four more entries in the tab row.
    const groups = context.record.settingsGroups;
    assert.deepEqual(Object.keys(groups), ['dns', 'network', 'lists', 'service']);
    const settingsSection = context.record.sections.find(s => s.type === 'settings');
    for (const [name, given] of Object.entries(groups))
      assert.equal(given, settingsSection, `the ${name} group is not on the Settings tab`);
    for (const tab of ['DashboardTab', 'MonitoringTab', 'DiagnosticTab', 'AutotuneTab', 'HistoryTab', 'UpdatesTab'])
      assert(calls.includes(`init:${tab}`), `${tab} controller was not started`);
  }

  // Tab activity is the CBI tab's: no standalone page may register itself, or
  // every controller would believe its tab is in front and poll at once.
  {
    const calls = [];
    const context = stubs(true, calls);
    const view = load('forkop.js', context.modules);
    await view.load();
    assert(calls.includes('page:null'), 'the view must register no standalone page');
  }

  // Every Save & Apply takes a snapshot first, so History has something to
  // restore from.
  const formSource = read('configform.js');
  assert.match(formSource, /new form\.Map\(UCI_PACKAGE/, 'configform must build the form');
  assert.match(formSource, /map\.handleSaveApply = async function/,
    'configform must keep the snapshot-first Save & Apply');
  assert.match(formSource, /snapshotCreate\("automatic"\)[\s\S]*originalHandleSaveApply\.call/,
    'a snapshot must be taken before applying');
  assert.match(read('forkop.js'), /configform\.createMap\(/,
    'the view must build its form through configform, or it loses the snapshot');

  // One menu entry, opening the one view.
  const menu = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-forkop/root/usr/share/luci/menu.d/luci-app-forkop.json'), 'utf8'));
  assert.deepEqual(Object.keys(menu), ['admin/services/forkop'], 'Forkop X is one menu entry');
  const entry = menu['admin/services/forkop'];
  assert.deepEqual(entry.action, { type: 'view', path: 'forkop/forkop' });
  assert.deepEqual(entry.depends.acl, ['luci-app-forkop']);
  assert(fs.existsSync(path.join(viewDir, 'forkop.js')), 'the view the menu points at is missing');

  // The per-page entry points are gone.
  assert(!fs.existsSync(path.join(viewDir, 'page')), 'the per-page views should have been removed');

  // The read-only role is still gated by the UCI read permission: that is what
  // the view probes to decide the role.
  const acl = JSON.parse(fs.readFileSync(
    path.join(root, 'luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json'), 'utf8'));
  assert.deepEqual(acl['luci-app-forkop-admin'].read.uci, ['forkop'],
    'the administrator group must grant the Forkop UCI read access');

  console.log('luci_readonly_view: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
