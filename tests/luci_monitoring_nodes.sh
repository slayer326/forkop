#!/usr/bin/env bash
set -euo pipefail

# Stage 6.5: node selection lives in Monitoring (monitoring#view=nodes), the
# Overview only summarizes it; Monitoring names routes and DPI strategies from
# the derived read-only section view, never from raw strategy options.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const root = process.argv[2];
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const src = 'fe-app-forkop/src/forkop/tabs/';

const dashboardRender = read(src + 'dashboard/render.ts');
const overview = dashboardRender.slice(0, dashboardRender.indexOf('export function renderNodes'));
assert.doesNotMatch(overview, /dashboard-sections-grid/, 'Overview must not host node selection');
assert.match(dashboardRender.slice(dashboardRender.indexOf('export function renderNodes')), /dashboard-sections-grid/,
  'the Nodes view renders the node selection grid');

const monitoringRender = read(src + 'monitoring/render.ts');
const monitoringInit = read(src + 'monitoring/initController.ts');
assert.match(monitoringRender, /renderNodes\(\)/, 'Monitoring hosts the Nodes view');
// Node selection is rendered by the dashboard module inside the Monitoring
// view, so the dashboard controller is the one that has to run while it is
// shown. Both are tabs of the one Forkop X view, and the tab in front decides
// which controller runs - so the Monitoring tab hands its turn to the
// dashboard controller for as long as the nodes view is open, and takes it
// back for the connections view.
const mount = read('luci-app-forkop/htdocs/luci-static/resources/view/forkop/dashboard.js');
assert.match(mount, /main\.DashboardTab\.initController\(\)/, 'the Dashboard tab starts the node selection controller');
const view = read('luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js');
for (const tab of ['dashboard', 'monitoring'])
  assert(view.includes(`"${tab}"`), `the view must mount the ${tab} tab`);
const views = read(src + 'monitoring/views.ts');
assert.match(views, /delegateTabController\('monitoring', controllerForView\(view\)\)/,
  'switching the Monitoring view switches the controller that runs');
assert.match(views, /export function controllerForView[\s\S]*?'dashboard'/,
  'the nodes view is run by the dashboard controller');
// A link into #view=nodes only changes the hash, because the tabs of one view
// are not reloaded; the tab has to follow it.
assert.match(monitoringInit, /addEventListener\('hashchange', followRequestedView\)/,
  'Monitoring must follow a view requested through the hash');

const cards = read(src + 'dashboard/overviewCards.ts');
assert.match(cards, /openForkopPage\('monitoring', \{ view: 'nodes' \}\)/, 'Overview links to Monitoring → Nodes');

const monitoring = monitoringInit;
assert.match(monitoring, /ForkopShellMethods\.getReadonlyConfigSections\(\)/,
  'Monitoring reads the derived section view for both roles');
assert.doesNotMatch(monitoring, /nfqws2?_opt|byedpi_cmd_opts/, 'Monitoring never shows raw strategy options');
assert.doesNotMatch(monitoring, /fkp-monitoring-trace/, 'the fake per-row trace action is gone');
assert.match(monitoring, /renderProvenance\('observed'\)/, 'the route is marked as observed');
assert.match(monitoring, /renderProvenance\('configured'\)/, 'the DPI strategy is marked as from configuration');

console.log('Monitoring hosts node selection and names paths safely');
NODE
