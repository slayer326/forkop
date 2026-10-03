// Which Forkop controller is in front. Forkop X is one LuCI view whose
// features are CBI tabs, so that is normally the tab the user opened. Two
// things can override it:
//
//   - a standalone page registers the single controller it hosts (a layout
//     with a view per feature, where there are no CBI tabs to read);
//   - a tab hands its turn to another controller for as long as one of its
//     views is open. Monitoring's node selection is run by the dashboard
//     controller, so while that view is shown the Monitoring tab resolves to
//     "dashboard" and its own connections polling stays off.
let standalonePage: string | null = null;
let delegated: { host: string; controller: string } | null = null;

export function setStandalonePage(pageId: string | null) {
  standalonePage = pageId || null;
}

export function getForkopPage() {
  return standalonePage;
}

// `controller` equal to `host`, or null, gives the tab its own controller back.
export function setDelegatedController(
  host: string,
  controller: string | null,
) {
  delegated = controller && controller !== host ? { host, controller } : null;
}

function activeCbiTab(): string | null {
  if (typeof document === 'undefined') {
    return null;
  }

  // The tab menu entry carries cbi-tab while its pane is shown; the panes
  // themselves are marked with data-tab-active.
  const active = document.querySelector<HTMLElement>(
    '.cbi-tab[data-tab]:not(.cbi-tab-disabled)',
  );

  return active?.dataset.tab || null;
}

export function activeForkopController(): string | null {
  const host = activeCbiTab() ?? standalonePage;

  if (host && delegated?.host === host) {
    return delegated.controller;
  }

  return host;
}
