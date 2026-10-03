import { afterEach, describe, expect, it } from 'vitest';

import {
  forkopPageUrl,
  forkopTabId,
  openForkopPage,
  readPageParams,
  switchLuciTab,
} from '../navigation';
import { isActiveLuciTab } from '../isActiveLuciTab';
import {
  setDelegatedController,
  setStandalonePage,
} from '../../services/forkopPage';

type FakeTab = { tab: string; active: boolean };

const g = globalThis as unknown as {
  L?: unknown;
  document?: unknown;
  window?: unknown;
  history?: unknown;
};

// The selectors are luci-base's own markup for a tabbed CBI map: the menu is
// <ul class="cbi-tabmenu"><li data-tab="NAME" class="cbi-tab|cbi-tab-disabled">
// <a href="#">title</a></li></ul>, and clicking the anchor switches the tab.
function mockTabs(tabs: FakeTab[], clicked: string[] = []) {
  g.document = {
    querySelector(selector: string) {
      const entry = /^ul\.cbi-tabmenu > li\[data-tab="([^"]+)"\] > a$/.exec(
        selector,
      );

      if (entry) {
        const target = tabs.find((tab) => tab.tab === entry[1]);

        return target
          ? {
              click() {
                tabs.forEach((tab) => {
                  tab.active = tab === target;
                });
                clicked.push(target.tab);
              },
            }
          : null;
      }

      if (selector === '.cbi-tab[data-tab]:not(.cbi-tab-disabled)') {
        const active = tabs.find((tab) => tab.active);

        return active ? { dataset: { tab: active.tab } } : null;
      }

      throw new Error(`unexpected selector: ${selector}`);
    },
  };

  return clicked;
}

function mockLocation(hash = '') {
  const location = {
    hash,
    pathname: '/cgi-bin/luci/admin/services/forkop',
    search: '',
  };
  const events: string[] = [];

  g.window = {
    location,
    dispatchEvent: (event: { type: string }) => events.push(event.type),
  };
  g.history = {
    replaceState(_state: unknown, _title: string, url: string) {
      location.hash = url.slice(url.indexOf('#'));
    },
  };

  return { location, events };
}

afterEach(() => {
  delete g.L;
  delete g.document;
  delete g.window;
  delete g.history;
  setStandalonePage(null);
  setDelegatedController('monitoring', null);
});

describe('Forkop feature links', () => {
  it('points at the one Forkop X view and names the tab to open', () => {
    g.L = { url: (...parts: string[]) => `/cgi-bin/luci/${parts.join('/')}` };

    expect(forkopPageUrl('diagnostics')).toBe(
      '/cgi-bin/luci/admin/services/forkop#tab=diagnostic',
    );
  });

  it('carries parameters in the hash', () => {
    expect(forkopPageUrl('monitoring', { search: 'youtube.com' })).toBe(
      '/cgi-bin/luci/admin/services/forkop#tab=monitoring&search=youtube.com',
    );
    expect(readPageParams('#search=youtube.com&device=192.168.1.2')).toEqual({
      search: 'youtube.com',
      device: '192.168.1.2',
    });
    expect(readPageParams('')).toEqual({});
  });

  it('uses the tab id LuCI writes, not the page name', () => {
    expect(forkopTabId('diagnostics')).toBe('diagnostic');
    expect(forkopTabId('overview')).toBe('dashboard');
    expect(forkopTabId('rules')).toBe('section');
  });

  it('switches to the sibling tab and leaves the parameters behind', () => {
    const tabs = [
      { tab: 'diagnostic', active: true },
      { tab: 'monitoring', active: false },
    ];
    const clicked = mockTabs(tabs);
    const { location, events } = mockLocation();

    expect(openForkopPage('monitoring', { search: 'youtube.com' })).toBe(true);
    expect(clicked).toEqual(['monitoring']);
    expect(location.hash).toBe('#tab=monitoring&search=youtube.com');
    // A tab that is already built reads the hash again on this event.
    expect(events).toEqual(['hashchange']);
    expect(isActiveLuciTab('monitoring')).toBe(true);
  });

  it('reports a tab it cannot find, rather than leaving the page', () => {
    mockTabs([{ tab: 'diagnostic', active: true }]);
    mockLocation();

    // A read-only session is offered no Settings tab.
    expect(openForkopPage('settings')).toBe(false);
    expect(switchLuciTab('settings')).toBe(false);
  });
});

describe('the controller in front', () => {
  it('is the tab the user opened', () => {
    mockTabs([
      { tab: 'dashboard', active: false },
      { tab: 'monitoring', active: true },
    ]);

    expect(isActiveLuciTab('monitoring')).toBe(true);
    expect(isActiveLuciTab('dashboard')).toBe(false);
  });

  it('is the controller a tab handed its turn to', () => {
    mockTabs([
      { tab: 'dashboard', active: false },
      { tab: 'monitoring', active: true },
    ]);

    // Monitoring's node view is run by the dashboard controller, so while it
    // is open the connections polling of Monitoring itself must stay off.
    setDelegatedController('monitoring', 'dashboard');

    expect(isActiveLuciTab('dashboard')).toBe(true);
    expect(isActiveLuciTab('monitoring')).toBe(false);

    // The handover belongs to the Monitoring tab: another tab in front is
    // unaffected by it.
    mockTabs([
      { tab: 'dashboard', active: false },
      { tab: 'monitoring', active: false },
      { tab: 'diagnostic', active: true },
    ]);

    expect(isActiveLuciTab('diagnostic')).toBe(true);
    expect(isActiveLuciTab('dashboard')).toBe(false);
  });

  it('is the registered page when there are no tabs to read', () => {
    expect(isActiveLuciTab('monitoring')).toBe(false);

    setStandalonePage('monitoring');

    expect(isActiveLuciTab('monitoring')).toBe(true);
    expect(isActiveLuciTab('dashboard')).toBe(false);
  });
});
