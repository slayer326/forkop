import { describe, expect, it, vi } from 'vitest';

vi.mock('../../../helpers/navigation', () => ({ openForkopPage: vi.fn() }));

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  appendChild(child: unknown): void;
}
(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs: attrs || {},
  children: Array.isArray(children) ? children : [children],
  appendChild(child) {
    this.children.push(child);
  },
});

function labels(node: unknown): string[] {
  if (!node || typeof node !== 'object') return [];
  const fake = node as FakeNode;
  return [
    ...(typeof fake.attrs?.['aria-label'] === 'string'
      ? [fake.attrs['aria-label'] as string]
      : []),
    ...(fake.children || []).flatMap(labels),
  ];
}

function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

import {
  overviewLastEvent,
  overviewRecovery,
  overviewRouting,
  overviewState,
  overviewWarning,
  type OverviewInput,
} from '../overview';
import { renderOverview } from '../overviewCards';
import type { Forkop } from '../../../types';

const NOW = 1_800_000_000_000;
const ts = (secondsAgo: number) => NOW / 1000 - secondsAgo;

function health(patch: Partial<Forkop.HealthStatus> = {}): Forkop.HealthStatus {
  return {
    overall: 'ok',
    service: { forkop: 'ok', sing_box: 'ok' },
    dns: { status: 'unknown', configured: true },
    lists: { status: 'unknown' },
    guard: { active: false },
    recovery: { pending: false, last_event: null },
    package_recovery: { pending: false },
    last_reload: { status: 'success', timestamp: ts(300) },
    recent_activity: [
      { kind: 'start', status: 'success', timestamp: ts(7200) },
      { kind: 'reload', status: 'success', timestamp: ts(300) },
    ],
    ...patch,
  };
}

function group(name: string, nodes: Array<[string, number, boolean]>) {
  return {
    withTagSelect: true,
    code: `${name}-out`,
    sectionName: name,
    displayName: name,
    outbounds: nodes.map(([node, latency, selected]) => ({
      code: node,
      displayName: node,
      latency,
      type: 'vless',
      selected,
    })),
  } as Forkop.OutboundGroup;
}

function input(patch: Partial<OverviewInput> = {}): OverviewInput {
  return {
    health: health(),
    availability: 'running',
    forkopEnabled: true,
    forkopStoppedByUser: false,
    forkopNotStarted: null,
    forkopStatus: 'running',
    singBoxRunning: true,
    groups: [
      group('VPN', [
        ['NL-1', 62, false],
        ['NL-2', 48, true],
      ]),
    ],
    ruleCount: 4,
    traffic: { up: 1000, down: 4_200_000 },
    connections: 146,
    snapshotCount: 7,
    lastDiagnosticRun: NOW - 3_600_000,
    nowMs: NOW,
    ...patch,
  };
}

describe('overview warning', () => {
  it('is empty on a healthy system', () => {
    expect(overviewWarning(health())).toBeNull();
  });

  it('puts the safety guard first, then package recovery, then a failed change', () => {
    expect(
      overviewWarning(
        health({
          guard: { active: true },
          package_recovery: { pending: true },
        }),
      )?.title,
    ).toBe('A safety guard is active');
    expect(
      overviewWarning(health({ package_recovery: { pending: true } }))?.title,
    ).toBe('Package recovery has not finished');
    expect(
      overviewWarning(
        health({
          recent_activity: [
            { kind: 'reload', status: 'failure', timestamp: ts(10) },
          ],
        }),
      )?.title,
    ).toBe('The last configuration change failed');
  });
});

describe('overview state', () => {
  it('reports a running system with only reliable signals', () => {
    const state = overviewState(input());

    expect(state.status).toBe('healthy');
    expect(state.title).toBe('Forkop X is running');
    const lines = state.lines.map((line) => line.text);
    expect(lines).toContain('sing-box is running');
    expect(lines).toContain('Autostart is on');
    expect(lines.join(' ')).not.toMatch(/Unknown|DPI|Lists/);
  });

  it('marks a stopped service as an error only when autostart is on', () => {
    expect(overviewState(input({ availability: 'stopped' })).status).toBe(
      'error',
    );
    const off = overviewState(
      input({ availability: 'stopped', forkopEnabled: false }),
    );
    expect(off.status).toBe('off');
    expect(off.stopped).toBe(true);
  });

  it('tells a stop by the user from a runtime that is down (D-15)', () => {
    const byUser = overviewState(
      input({ availability: 'stopped', forkopStoppedByUser: true }),
    );
    expect(byUser.status).toBe('off');
    expect(byUser.title).toBe('Stopped by user');
    expect(byUser.stopped).toBe(true);
    expect(byUser.lines.map((line) => line.text)).toContain(
      'Forkop X stays stopped until you start it: reloads, restores and updates do not start it.',
    );
    expect(byUser.lines.some((line) => line.tone === 'error')).toBe(false);

    const down = overviewState(input({ availability: 'stopped' }));
    expect(down.status).toBe('error');
    expect(down.title).toBe('Not running');
    expect(down.lines).toContainEqual({
      text: 'Forkop X was not stopped by the user: its start failed or it stopped unexpectedly.',
      tone: 'error',
    });
    // Autostart off and nobody stopped it: not running, no failure claimed.
    const idle = overviewState(
      input({ availability: 'stopped', forkopEnabled: false }),
    );
    expect(idle.title).toBe('Not running');
    expect(idle.lines.some((line) => line.tone === 'error')).toBe(false);
  });

  it('tells Forkop not started since boot from a failed one (D-15)', () => {
    // After a reboot with autostart off nobody started it: no failure, and
    // reloads, restores and updates leave it down.
    const idle = overviewState(
      input({
        availability: 'stopped',
        forkopEnabled: false,
        forkopNotStarted: true,
      }),
    );
    expect(idle.status).toBe('off');
    expect(idle.title).toBe('Not started');
    expect(idle.stopped).toBe(true);
    expect(idle.lines.map((line) => line.text)).toContain(
      'Forkop X was not started since the router booted: reloads, restores and updates do not start it.',
    );
    expect(idle.lines.some((line) => line.tone === 'error')).toBe(false);
    // Autostart on and not started yet (enabled after the boot): the same.
    expect(
      overviewState(input({ availability: 'stopped', forkopNotStarted: true }))
        .title,
    ).toBe('Not started');

    // Started since boot and down now: a failure, autostart on or off.
    for (const forkopEnabled of [true, false]) {
      const failed = overviewState(
        input({
          availability: 'stopped',
          forkopEnabled,
          forkopNotStarted: false,
        }),
      );
      expect(failed.status).toBe('error');
      expect(failed.title).toBe('Not running');
      expect(failed.lines).toContainEqual({
        text: 'Forkop X was not stopped by the user: its start failed or it stopped unexpectedly.',
        tone: 'error',
      });
    }

    // Stopped by the user stays that, whatever else is reported.
    expect(
      overviewState(
        input({
          availability: 'stopped',
          forkopStoppedByUser: true,
          forkopNotStarted: false,
        }),
      ).title,
    ).toBe('Stopped by user');
  });

  it('does not call a start in progress a failed one', () => {
    // Boot, Start, the start half of Restart, the WAN retry: the runtime is
    // not up yet and no stop holds it down.
    for (const forkopStatus of ['starting', 'restarting']) {
      const state = overviewState(
        input({ availability: 'stopped', forkopStatus }),
      );
      expect(state.status).toBe('busy');
      expect(state.title).toBe('Starting…');
      expect(state.lines.some((line) => line.tone === 'error')).toBe(false);
    }
    // A reload that repairs a runtime that went down.
    const repair = overviewState(
      input({ availability: 'stopped', forkopStatus: 'reloading' }),
    );
    expect(repair.status).toBe('busy');
    expect(repair.lines.some((line) => line.tone === 'error')).toBe(false);
    // Once the start is over and nothing runs, it failed.
    expect(
      overviewState(
        input({ availability: 'stopped', forkopStatus: 'stopped but enabled' }),
      ).title,
    ).toBe('Not running');
  });

  it('warns about router DNS and an automatic rollback', () => {
    const state = overviewState(
      input({
        health: health({
          overall: 'recovered',
          dns: { status: 'warning', configured: false },
        }),
      }),
    );

    expect(state.status).toBe('warning');
    expect(state.lines.map((line) => line.text)).toEqual(
      expect.arrayContaining([
        'The last change was rolled back automatically.',
        'Router DNS is not pointed to Forkop X',
      ]),
    );
  });

  // UC-021: missing or unknown health is never shown as healthy.
  it('does not call a running Forkop X healthy while its health is unknown', () => {
    for (const value of [null, health({ overall: 'unknown' })]) {
      const state = overviewState(input({ health: value }));
      expect(state.status).toBe('unknown');
      expect(state.title).toBe('Forkop X is running');
      expect(state.lines.map((line) => line.text)).toContain(
        'Health state unavailable',
      );
    }
  });

  // A failed health poll keeps the last report: a guard it showed stays
  // visible, but it no longer proves anything healthy.
  it('does not call a stale health report healthy', () => {
    const stale = overviewState(input({ healthStale: true }));
    expect(stale.status).toBe('unknown');
    expect(stale.lines.map((line) => line.text)).toContain(
      'Health state unavailable',
    );
    expect(overviewRecovery(input({ healthStale: true }))).toMatchObject({
      status: 'unknown',
      title: 'State unavailable',
    });
    const guarded = health({
      overall: 'error',
      guard: { active: true, runtime: true, restore: false },
      recovery: { pending: true, last_event: null, action: 'restart' },
    });
    expect(
      overviewRecovery(input({ health: guarded, healthStale: true })).title,
    ).toBe('Restart required');
    expect(
      overviewState(input({ health: guarded, healthStale: true })).status,
    ).toBe('error');
    expect(overviewWarning(guarded)?.title).toBe('A safety guard is active');
  });

  it('says when diagnostics has never run', () => {
    expect(
      overviewState(input({ lastDiagnosticRun: null })).lines.map(
        (l) => l.text,
      ),
    ).toContain('Diagnostics has not been run yet');
  });
});

describe('overview routing', () => {
  it('summarises rules, connections and the active node per group', () => {
    const routing = overviewRouting(input());

    expect(routing.summary).toBe('4 rules · 1 node groups');
    expect(routing.live).toBe('146 connections now · ↓ 4.2 MB/s ↑ 1 KB/s');
    expect(routing.groups).toEqual([
      { name: 'VPN', node: 'NL-2', latency: '48 ms', tone: 'success' },
    ]);
  });

  it('shows at most three groups and counts the rest', () => {
    const groups = ['A', 'B', 'C', 'D', 'E'].map((name) =>
      group(name, [[`${name}-1`, 2000, true]]),
    );
    const routing = overviewRouting(input({ groups }));

    expect(routing.groups).toHaveLength(3);
    expect(routing.more).toBe(2);
    expect(routing.groups[0].tone).toBe('error');
  });

  it('explains that routing is paused while stopped', () => {
    const routing = overviewRouting(
      input({ availability: 'stopped', groups: [] }),
    );

    expect(routing.live).toBe('Routing is paused while Forkop X is stopped.');
    expect(routing.summary).toBe('4 rules');
  });
});

describe('overview recovery and last event', () => {
  it('reports the last reload and snapshot count', () => {
    const recovery = overviewRecovery(input());

    expect(recovery.status).toBe('healthy');
    expect(recovery.lines.map((line) => line.text)).toEqual([
      'Last reload: Succeeded · 5 min ago',
      'Snapshots: 7',
    ]);
  });

  it('needs attention while the guard is active', () => {
    expect(
      overviewRecovery(input({ health: health({ guard: { active: true } }) }))
        .status,
    ).toBe('needs_attention');
  });

  it('describes the last event with its outcome', () => {
    expect(overviewLastEvent(input())).toEqual({
      title: 'Configuration reload',
      outcome: { label: 'Succeeded', tone: 'success' },
      time: '5 min ago',
    });
    expect(
      overviewLastEvent(input({ health: health({ recent_activity: [] }) })),
    ).toBeNull();
  });
});

// Every recovery state the backend reports (diagnostics/health.uc): the
// Recovery card and the warning never read "No recovery needed" or
// "healthy" while something is left, and name the step that ends it
// (UC-019, UC-021, UC-066).
describe('overview recovery states', () => {
  const guard = (
    action: 'restart' | 'restore' | 'wait' | null,
    kinds: { runtime?: boolean; restore?: boolean },
  ) =>
    health({
      overall: 'error',
      guard: { active: true, runtime: false, restore: false, ...kinds },
      recovery: { pending: true, last_event: null, action },
    });
  const texts = (lines: Array<{ text: string }>) =>
    lines.map((line) => line.text).join(' | ');

  it('asks for a restart while a failed transition keeps its guard', () => {
    const value = guard('restart', { runtime: true });
    const recovery = overviewRecovery(input({ health: value }));
    expect(recovery.status).toBe('needs_attention');
    expect(recovery.title).toBe('Restart required');
    expect(texts(recovery.lines)).toContain('restart Forkop X');
    const warning = overviewWarning(value);
    expect(warning?.title).toBe('A safety guard is active');
    expect(warning?.text).toContain('Restart Forkop X to remove it');
    expect(warning?.text).not.toContain('until recovery completes');
  });

  it('asks for a snapshot restore while an unfinished restore keeps its guard', () => {
    const value = guard('restore', { restore: true });
    const recovery = overviewRecovery(input({ health: value }));
    expect(recovery.status).toBe('needs_attention');
    expect(recovery.title).toBe('Restore required');
    expect(texts(recovery.lines)).toContain('last known good snapshot');
    expect(overviewWarning(value)?.text).toContain(
      'Restore the last known good snapshot to finish it',
    );
  });

  it('shows a guard that a running change holds as in progress', () => {
    const value = guard('wait', { restore: true });
    const recovery = overviewRecovery(input({ health: value }));
    expect(recovery.status).toBe('busy');
    expect(recovery.title).toBe('Change in progress');
    expect(overviewWarning(value)?.text).toContain('is being applied');
  });

  it('needs attention for a guard whose recovery the backend does not name', () => {
    const recovery = overviewRecovery(
      input({ health: guard(null, { runtime: true }) }),
    );
    expect(recovery.status).toBe('needs_attention');
    expect(recovery.title).toBe('Protection is active');
  });

  it('does not call an unfinished package recovery "No recovery needed"', () => {
    const recovery = overviewRecovery(
      input({
        health: health({
          overall: 'error',
          package_recovery: { pending: true },
        }),
      }),
    );
    expect(recovery.status).toBe('needs_attention');
    expect(recovery.title).toBe('Package recovery has not finished');
  });

  it('reports a failed last change as an error, not as in progress', () => {
    const failed = { kind: 'reload', status: 'failure', timestamp: ts(60) };
    const recovery = overviewRecovery(
      input({
        health: health({
          overall: 'error',
          recovery: { pending: true, last_event: failed, action: null },
          last_reload: failed,
          recent_activity: [failed],
        }),
      }),
    );
    expect(recovery.status).toBe('error');
    expect(recovery.title).toBe('The last configuration change failed');
    expect(texts(recovery.lines)).toContain(
      'Forkop X kept or restored the previous configuration.',
    );
  });

  it('says "No recovery needed" only when nothing is left', () => {
    const recovery = overviewRecovery(input());
    expect(recovery.status).toBe('healthy');
    expect(recovery.title).toBe('No recovery needed');
    expect(overviewRecovery(input({ health: null }))).toMatchObject({
      status: 'unknown',
      title: 'State unavailable',
    });
  });
});

describe('overview cards', () => {
  const actions = {
    serviceBusy: false,
    autostart: true,
    onStart: vi.fn(),
    onRestart: vi.fn(),
    onStop: vi.fn(),
    onToggleAutostart: vi.fn(),
  };
  const vm = (patch: Partial<OverviewInput> = {}) => {
    const value = input(patch);
    return {
      warning: overviewWarning(value.health),
      state: overviewState(value),
      routing: overviewRouting(value),
      recovery: overviewRecovery(value),
      event: overviewLastEvent(value),
    };
  };

  it('offers service control and rules to administrators', () => {
    const node = renderOverview(vm({ availability: 'stopped' }), {
      ...actions,
      readonly: false,
    });

    expect(text(node)).toContain('Start Forkop X');
    expect(labels(node)).toContain('Service actions');
    expect(text(node)).toContain('Rules');
  });

  it('offers Stop, not Start, while a stray runtime still intercepts traffic', () => {
    const node = renderOverview(vm({ availability: 'stopped' }), {
      ...actions,
      readonly: false,
      stopAvailable: true,
    });

    expect(text(node)).toContain('Stop Forkop X…');
    expect(text(node)).not.toContain('Start Forkop X');
  });

  it('withholds restart and says why while sing-box ownership is unclear', () => {
    const node = renderOverview(vm({}), {
      ...actions,
      readonly: false,
      restartBlocked: true,
      stopAvailable: true,
    });

    expect(text(node)).toContain('Restart is unavailable');
    expect(text(node)).toContain('Stop Forkop X…');
    expect(text(node)).not.toContain('Restart Forkop X');
  });

  it('offers the restart that removes a kept safety guard, to administrators only', () => {
    const kept = health({
      overall: 'error',
      guard: { active: true, runtime: true, restore: false },
      recovery: { pending: true, last_event: null, action: 'restart' },
    });
    const recoveryCard = (readonly: boolean) =>
      (
        renderOverview(vm({ availability: 'stopped', health: kept }), {
          ...actions,
          readonly,
        }) as unknown as FakeNode
      ).children
        .flatMap((child) => (child as FakeNode).children || [])
        .find((node) => text(node).includes('Restart required'));

    expect(text(recoveryCard(false))).toContain('Restart Forkop X');
    expect(recoveryCard(true)).toBeDefined();
    expect(text(recoveryCard(true))).not.toContain('Restart Forkop X');
  });

  it('offers a stopped Forkop X with a kept safety guard a restart, not a start', () => {
    // A start is refused while a failed change keeps its safety guard (UC-019):
    // only the restart removes it.
    const kept = health({
      overall: 'error',
      guard: { active: true, runtime: true, restore: false },
      recovery: { pending: true, last_event: null, action: 'restart' },
    });
    const onStart = vi.fn();
    const onRestart = vi.fn();
    const stateCard = (
      renderOverview(vm({ availability: 'stopped', health: kept }), {
        ...actions,
        onStart,
        onRestart,
        readonly: false,
      }) as unknown as FakeNode
    ).children
      .flatMap((child) => (child as FakeNode).children || [])
      .find((node) => text(node).includes('State')) as FakeNode;
    const buttons = (node: unknown): FakeNode[] =>
      !node || typeof node !== 'object'
        ? []
        : [
            ...((node as FakeNode).tag === 'button' ? [node as FakeNode] : []),
            ...((node as FakeNode).children || []).flatMap(buttons),
          ];

    expect(text(stateCard)).not.toContain('Start Forkop X');
    const restart = buttons(stateCard).find((button) =>
      text(button).includes('Restart Forkop X'),
    );
    expect(restart).toBeDefined();
    (restart!.attrs.click as () => void)();
    expect(onRestart).toHaveBeenCalledOnce();
    expect(onStart).not.toHaveBeenCalled();
  });

  it('gives a read-only session the same answers without controls', () => {
    const node = renderOverview(vm({ availability: 'stopped' }), {
      ...actions,
      readonly: true,
    });

    expect(text(node)).toContain('Not running');
    expect(text(node)).not.toContain('Start Forkop X');
    expect(labels(node)).not.toContain('Service actions');
    expect(text(node)).not.toContain('Rules');
  });
});
