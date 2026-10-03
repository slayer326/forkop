// Links between Forkop features. Forkop X is one LuCI view
// (admin/services/forkop) whose features are CBI tabs, so a link switches to
// the sibling tab instead of loading another page. Its parameters travel in
// the URL hash, together with the tab to open, so a reload or a shared link
// lands on the same place.
export type ForkopPage =
  | 'overview'
  | 'monitoring'
  | 'diagnostics'
  | 'autotune'
  | 'history'
  | 'rules'
  | 'settings';

const FORKOP_MENU_PATH = 'admin/services/forkop';

// LuCI keys a tab by the UCI section type the view gives it, which is what
// ends up in data-tab and what the controllers ask about.
const PAGE_TAB_IDS: Record<ForkopPage, string> = {
  overview: 'dashboard',
  monitoring: 'monitoring',
  diagnostics: 'diagnostic',
  autotune: 'autotune',
  history: 'history',
  rules: 'section',
  settings: 'settings',
};

interface LuciUrlBuilder {
  url?: (...parts: string[]) => string;
}

function luci(): LuciUrlBuilder | undefined {
  return (globalThis as unknown as { L?: LuciUrlBuilder }).L;
}

export function forkopTabId(page: ForkopPage) {
  return PAGE_TAB_IDS[page];
}

export function forkopPageUrl(
  page: ForkopPage,
  params: Record<string, string> = {},
) {
  const base =
    typeof luci()?.url === 'function'
      ? luci()!.url!(FORKOP_MENU_PATH)
      : `/cgi-bin/luci/${FORKOP_MENU_PATH}`;
  const query = new URLSearchParams({
    tab: PAGE_TAB_IDS[page],
    ...params,
  }).toString();

  return `${base}#${query}`;
}

// Clicks the tab menu entry LuCI built for this tab. Returns false when the
// menu is not there yet, or has no such tab - a session that may not read the
// Forkop configuration is offered fewer of them.
export function switchLuciTab(tabId: string) {
  if (typeof document === 'undefined') {
    return false;
  }

  const link = document.querySelector<HTMLElement>(
    `ul.cbi-tabmenu > li[data-tab="${tabId}"] > a`,
  );

  if (!link) {
    return false;
  }

  link.click();

  return true;
}

export function openForkopPage(
  page: ForkopPage,
  params: Record<string, string> = {},
) {
  // The parameters have to be in the hash before the tab mounts and reads
  // them, and replaceState keeps the link shareable without a reload. It
  // fires no hashchange of its own, so a tab that is already built - the one
  // this link points at may be - is told the hash moved.
  if (typeof history !== 'undefined' && history.replaceState) {
    history.replaceState(null, '', forkopPageUrl(page, params));

    if (typeof window !== 'undefined') {
      window.dispatchEvent(new Event('hashchange'));
    }
  }

  return switchLuciTab(PAGE_TAB_IDS[page]);
}

export function readPageParams(hash?: string) {
  // Read on every tab change, including before a page has a location to read.
  const source =
    hash ?? (typeof window === 'undefined' ? '' : window.location?.hash);

  return Object.fromEntries(
    new URLSearchParams((source ?? '').replace(/^#/, '')),
  );
}
