#!/usr/bin/env bash
set -euo pipefail

# The Forkop X view shows the settings on one tab: createSettingsContent is
# given the same section for all four groups (DNS, Network, Lists and updates,
# Service) instead of a section per tab, so they are laid out one after another
# where the old interface had them.
#
# That makes the "Advanced settings" fold load-bearing. It is built by moving
# the siblings that follow the DNS TTL field into a <details>, and with one
# shared section every later group is such a sibling: unbounded, the fold would
# swallow Network, Lists and Service and hide the whole page behind one
# collapsed summary. So the fold is checked here as it ends up in the DOM, in
# both layouts - the shared section, and a section per group.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const viewDir = path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop');

// Just enough DOM for the fold: children in order, insertBefore/appendChild,
// nextElementSibling, and the [id$="..."] lookups the fold uses.
class Element {
  constructor(tag, attrs = {}) {
    this.tag = tag;
    this.id = attrs.id;
    this.className = attrs.class;
    this.children = [];
    this.parentNode = null;
  }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.children.push(child);
    return child;
  }
  removeChild(child) {
    this.children.splice(this.children.indexOf(child), 1);
    child.parentNode = null;
    return child;
  }
  insertBefore(node, ref) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.children.splice(this.children.indexOf(ref), 0, node);
    return node;
  }
  get nextElementSibling() {
    if (!this.parentNode) return null;
    const siblings = this.parentNode.children;
    return siblings[siblings.indexOf(this) + 1] || null;
  }
  querySelector(selector) {
    const suffix = /^\[id\$="([^"]+)"\]$/.exec(selector);
    assert(suffix, `the DOM double does not implement ${selector}`);
    for (const child of this.children) {
      if (typeof child.id === 'string' && child.id.endsWith(suffix[1])) return child;
      const found = child.querySelector(selector);
      if (found) return found;
    }
    return null;
  }
  addEventListener() {}
}

function E(tag, attrs, children) {
  const node = new Element(tag, attrs && typeof attrs === 'object' ? attrs : {});
  for (const child of [].concat(children == null ? [] : children))
    if (child instanceof Element) node.appendChild(child);
  return node;
}

// An option double: settings.js declares 34 of them, and only their order and
// names matter here.
function optionDouble(name) {
  return {
    option: name,
    keylist: [],
    vallist: [],
    map: { data: { state: { values: { forkop: {} } } } },
    value(key, label) { this.keylist.push(key); this.vallist.push(label); },
    depends() {},
    remove() {},
    load() {},
    write() {},
    cfgvalue() {},
    formvalue() {},
    checkDepends() { return true; },
    validate() { return true; },
  };
}

// A section double whose render() builds what LuCI would: a wrapper per
// option, in declaration order, under the section container.
function sectionDouble(type) {
  const section = { type, order: [] };
  section.option = (Type, name) => {
    const option = optionDouble(name);
    section.order.push(name);
    return option;
  };
  section.render = function () {
    const node = E('div', { class: 'cbi-section' }, [E('h3', {}, [])]);
    for (const name of section.order)
      node.appendChild(new Element('div', { id: `cbi-forkop-settings-${name}` }));
    return Promise.resolve(node);
  };
  return section;
}

const source = fs.readFileSync(path.join(viewDir, 'settings.js'), 'utf8');
function loadSettings() {
  const form = new Proxy({}, { get: (target, name) => `form.${String(name)}` });
  const widgets = new Proxy({}, { get: (target, name) => `widgets.${String(name)}` });
  const main = {
    FORKOP_UCI_PACKAGE: 'forkop',
    DNS_SERVER_OPTIONS: [], BOOTSTRAP_DNS_SERVER_OPTIONS: [],
    LATENCY_TEST_URL_OPTIONS: ['https://www.gstatic.com/generate_204'],
    DEFAULT_LATENCY_TEST_URL: 'https://www.gstatic.com/generate_204',
    getClashUIUrl: () => '', validateDNS: () => true,
    validateBootstrapDNS: () => true, validateUrl: () => true,
  };
  const uci = { get() {}, set() {}, unset() {}, state() {} };
  const baseclass = { extend: value => value };
  return new Function('form', 'uci', 'baseclass', 'widgets', 'main', '_', 'E', 'L', source)(
    form, uci, baseclass, widgets, main, value => value, E,
    { toArray: value => (Array.isArray(value) ? value : value == null ? [] : [value]) });
}

const idsOf = node => node.children.filter(child => child.id)
  .map(child => child.id.replace('cbi-forkop-settings-', ''));
const foldOf = node => node.children.find(child => child.className === 'forkop-advanced-settings');

(async () => {
  // 1. One shared section, as the Forkop X view wires it.
  {
    const settings = loadSettings();
    const shared = sectionDouble('settings');
    settings.createSettingsContent(
      { dns: shared, network: shared, lists: shared, service: shared }, {});
    const declared = shared.order.slice();
    assert(declared.length > 30,
      `expected every settings option on the one section, got ${declared.length}`);

    const node = await shared.render();
    const fold = foldOf(node);
    assert(fold, 'the "Advanced settings" fold is missing');

    const ttl = declared.indexOf('dns_rewrite_ttl');
    const lastDns = declared.indexOf('dns_detour_section');
    assert(ttl >= 0 && lastDns > ttl, 'the DNS group is not where this test expects it');
    assert.deepEqual(idsOf(fold), declared.slice(ttl, lastDns + 1),
      'the fold must hold the rarely changed DNS options and stop at the end of the DNS group');

    // Everything the fold must NOT have taken is still on the tab itself.
    const onTab = idsOf(node);
    assert.deepEqual(onTab, declared.filter((name, index) => index < ttl || index > lastDns),
      'the groups after DNS must stay on the tab, not inside the fold');
    for (const name of ['source_network_interfaces', 'list_update_enabled', 'log_level'])
      assert(onTab.includes(name), `${name} was swallowed by the "Advanced settings" fold`);
  }

  // 2. A section per group still folds the same DNS tail, and the other groups
  //    are untouched on their own sections.
  {
    const settings = loadSettings();
    const tabs = {
      dns: sectionDouble('settings_dns'), network: sectionDouble('settings_network'),
      lists: sectionDouble('settings_lists'), service: sectionDouble('settings_service'),
    };
    settings.createSettingsContent(tabs, {});
    const dnsGroup = tabs.dns.order.slice();
    assert.equal(dnsGroup[dnsGroup.length - 1], 'dns_detour_section',
      'the DNS group no longer ends where the fold stops');
    const node = await tabs.dns.render();
    const fold = foldOf(node);
    assert(fold, 'the "Advanced settings" fold is missing from the DNS tab');
    assert.deepEqual(idsOf(fold), dnsGroup.slice(dnsGroup.indexOf('dns_rewrite_ttl')),
      'the DNS tab folds its rarely changed options');
    for (const group of ['network', 'lists', 'service']) {
      const other = await tabs[group].render();
      assert.equal(foldOf(other), undefined, `the ${group} tab must have no fold`);
    }
  }

  // 3. The view gives the four groups one and the same section.
  const view = fs.readFileSync(path.join(viewDir, 'forkop.js'), 'utf8');
  const call = /settings\.createSettingsContent\(\s*\{([^}]*)\}/.exec(view);
  assert(call, 'the view must pass the settings groups as an object');
  const groups = [...call[1].matchAll(/(\w+):\s*(\w+)/g)];
  assert.deepEqual(groups.map(m => m[1]), ['dns', 'network', 'lists', 'service']);
  assert.equal(new Set(groups.map(m => m[2])).size, 1,
    'the settings are one tab: every group takes the same section');

  console.log('luci_settings_single_tab: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
NODE
