import {
  activeForkopController,
  setDelegatedController,
  setStandalonePage,
} from './forkopPage';
import { switchLuciTab, readPageParams } from '../helpers/navigation';

type TabInfo = {
  el: HTMLElement;
  id: string;
  active: boolean;
};

type TabChangeCallback = (activeId: string | null, allTabs: TabInfo[]) => void;

export function setForkopPage(pageId: string | null) {
  setStandalonePage(pageId);
  TabService.getInstance().refresh();
}

// A tab that hands its turn to another controller while one of its views is
// open (Monitoring's node selection runs the dashboard controller).
export function delegateTabController(host: string, controller: string | null) {
  setDelegatedController(host, controller);
  TabService.getInstance().refresh();
}

class TabService {
  private static instance: TabService;
  private observer: MutationObserver | null = null;
  private callback?: TabChangeCallback;
  private lastActiveId: string | null = null;
  private requestedTabApplied = false;

  private constructor() {
    this.init();
  }

  public static getInstance(): TabService {
    if (!TabService.instance) {
      TabService.instance = new TabService();
    }
    return TabService.instance;
  }

  private init() {
    this.observer = new MutationObserver(() => this.handleMutations());
    this.observer.observe(document.body, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ['class'],
    });

    // initial check
    this.notify();
  }

  private handleMutations() {
    this.notify();
  }

  private getTabsInfo(): TabInfo[] {
    const tabs = Array.from(
      document.querySelectorAll<HTMLElement>('.cbi-tab, .cbi-tab-disabled'),
    );
    return tabs.map((el) => ({
      el,
      id: el.dataset.tab || '',
      active:
        el.classList.contains('cbi-tab') &&
        !el.classList.contains('cbi-tab-disabled'),
    }));
  }

  private getActiveTabId(): string | null {
    return activeForkopController();
  }

  // A link into another tab (Diagnostics -> Monitoring and back) leaves
  // "tab" in the hash so the same URL opens there after a reload. The tab
  // menu is built by LuCI after the view has rendered, so this waits for it
  // and then opens the tab once.
  private applyRequestedTab() {
    if (this.requestedTabApplied) {
      return;
    }

    const requested = readPageParams().tab;

    if (!requested) {
      this.requestedTabApplied = true;
      return;
    }

    if (switchLuciTab(requested)) {
      this.requestedTabApplied = true;
    }
  }

  private notify() {
    this.applyRequestedTab();

    const tabs = this.getTabsInfo();
    const activeId = this.getActiveTabId();

    if (activeId !== this.lastActiveId) {
      this.lastActiveId = activeId;
      this.callback?.(activeId, tabs);
    }
  }

  public refresh() {
    this.notify();
  }

  // A new subscriber always gets the current tab, even when it was already
  // known before (a page registered before the subscription).
  public onChange(callback: TabChangeCallback) {
    this.callback = callback;
    this.lastActiveId = this.getActiveTabId();
    callback(this.lastActiveId, this.getTabsInfo());
  }
}

export const TabServiceInstance = TabService.getInstance();
