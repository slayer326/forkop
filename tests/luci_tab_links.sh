#!/usr/bin/env bash
set -euo pipefail

# Forkop X is one LuCI view whose features are tabs, so a link from one feature
# to another (the Overview cards, the autotune hints, a diagnostic check, the
# per-connection actions) switches to the sibling tab. It must not navigate:
# there is one view and no page per feature to navigate to.
#
# Every link names its target by page name, and the tab ids they map to have to
# be the ones the view actually mounts - LuCI keys a tab by the section type -
# or the link would quietly do nothing.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR" <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.argv[2];
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

const navigation = read('fe-app-forkop/src/forkop/helpers/navigation.ts');
const view = read(
  'luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js',
);

// The tabs the view mounts: the section type is what LuCI writes as data-tab.
const mounted = new Set([
  ...[...view.matchAll(/mountTab\(\s*\w+,\s*"(\w+)"/g)].map((m) => m[1]),
  ...[...view.matchAll(/form\.(?:GridSection|TypedSection),\s*\n?\s*"(\w+)"/g)].map(
    (m) => m[1],
  ),
]);
assert(
  ['section', 'settings', 'diagnostic', 'dashboard', 'monitoring'].every((tab) =>
    mounted.has(tab),
  ),
  `the view mounts an unexpected set of tabs: ${[...mounted].join(', ')}`,
);

// Every page a link can name resolves to one of those tabs.
const mapping = [
  ...navigation.matchAll(/^\s{2}(\w+): '([\w-]+)',$/gm),
].map(([, page, tab]) => ({ page, tab }));
assert(mapping.length >= 7, 'the page-to-tab map was not found');
for (const { page, tab } of mapping)
  assert(
    mounted.has(tab),
    `the link target ${page} points at the tab "${tab}", which the view does not mount`,
  );

// Every page name used in a link is in the map.
const pages = new Set(
  [
    ...read('fe-app-forkop/src/forkop/tabs/dashboard/overviewCards.ts').matchAll(
      /openForkopPage\('([\w-]+)'/g,
    ),
    ...read('fe-app-forkop/src/forkop/tabs/autotune/initController.ts').matchAll(
      /openForkopPage\('([\w-]+)'/g,
    ),
    ...read(
      'fe-app-forkop/src/forkop/tabs/diagnostic/partials/renderCheckSection.ts',
    ).matchAll(/openForkopPage\('([\w-]+)'/g),
    ...read('fe-app-forkop/src/forkop/tabs/diagnostic/siteCheck.ts').matchAll(
      /openForkopPage\('([\w-]+)'/g,
    ),
    ...read('fe-app-forkop/src/forkop/tabs/monitoring/initController.ts').matchAll(
      /openForkopPage\('([\w-]+)'/g,
    ),
  ].map((match) => match[1]),
);
assert(pages.size > 0, 'no feature links were found');
for (const page of pages)
  assert(
    mapping.some((entry) => entry.page === page),
    `a link opens "${page}", which the page-to-tab map does not know`,
  );

// It switches the tab; it does not leave the view.
assert.match(
  navigation,
  /export function switchLuciTab[\s\S]*?ul\.cbi-tabmenu > li\[data-tab="\$\{tabId\}"\] > a[\s\S]*?link\.click\(\)/,
  'a link must switch the CBI tab by clicking its menu entry',
);
assert.doesNotMatch(
  navigation,
  /window\.location\.href\s*=/,
  'a link must not navigate away from the one Forkop X view',
);
// The URL a link puts in the hash is the view itself, with the tab named in it.
assert.match(
  navigation,
  /luci\(\)!\.url!\(FORKOP_MENU_PATH\)/,
  'the link URL must be the one Forkop X view, with no page under it',
);
assert.match(
  navigation,
  /new URLSearchParams\(\{\s*tab: PAGE_TAB_IDS\[page\],/,
  'the link URL must name the tab to open, so a reload lands on it again',
);

// Nothing refers to the views of the layout with a page per feature.
for (const file of fs.readdirSync(
  path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop'),
)) {
  if (!file.endsWith('.js')) continue;
  assert.doesNotMatch(
    read(`luci-app-forkop/htdocs/luci-static/resources/view/forkop/${file}`),
    /forkop\/page\//,
    `${file} still points at a per-feature page`,
  );
}

console.log('luci_tab_links: PASS');
NODE
