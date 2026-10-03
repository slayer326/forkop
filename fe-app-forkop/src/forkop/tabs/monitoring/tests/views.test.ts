import { describe, expect, it, vi } from 'vitest';

const { delegateTabController } = vi.hoisted(() => ({
  delegateTabController: vi.fn(),
}));

vi.mock('../../../services/tab.service', () => ({ delegateTabController }));

import {
  controllerForView,
  readMonitoringView,
  showMonitoringView,
} from '../views';

describe('monitoring views', () => {
  it('opens node selection from monitoring#view=nodes', () => {
    expect(readMonitoringView('#view=nodes')).toBe('nodes');
    expect(readMonitoringView('#search=example.com')).toBe('connections');
    expect(readMonitoringView('')).toBe('connections');
  });

  it('runs node selection with the dashboard controller', () => {
    expect(controllerForView('nodes')).toBe('dashboard');
    expect(controllerForView('connections')).toBe('monitoring');
  });

  it('hands the Monitoring tab over to the controller of the view', () => {
    const g = globalThis as unknown as { document?: unknown; window?: unknown };
    const panes: Record<string, { hidden: boolean }> = {
      'monitoring-view-connections': { hidden: false },
      'monitoring-view-nodes': { hidden: true },
    };
    g.document = {
      getElementById: (id: string) => panes[id] ?? null,
      querySelectorAll: () => [],
    };
    g.window = { location: { pathname: '/forkop', search: '' } };

    showMonitoringView('nodes', false);

    expect(panes['monitoring-view-nodes'].hidden).toBe(false);
    expect(delegateTabController).toHaveBeenLastCalledWith(
      'monitoring',
      'dashboard',
    );

    showMonitoringView('connections', false);

    // Back to its own controller: the tab keeps no stale handover.
    expect(delegateTabController).toHaveBeenLastCalledWith(
      'monitoring',
      'monitoring',
    );

    delete g.document;
    delete g.window;
  });
});
