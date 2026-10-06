import { describe, expect, it } from 'vitest';

import {
  diffRows,
  diffTruncatedText,
  historyItems,
  historyPage,
  HISTORY_PAGE_SIZE,
  recoveryRows,
  restoreConfirmMessage,
  restorePreview,
  restoreResultToast,
  snapshotBusyText,
  snapshotCleanupIds,
  snapshotDiff,
  snapshotReasonLabel,
  snapshotRows,
  unsavedChangesBlockRestore,
} from '../model';
import type { Forkop } from '../../../types';

const health = (
  overrides: Partial<Forkop.HealthStatus> = {},
): Forkop.HealthStatus => ({
  overall: 'ok',
  service: { forkop: 'ok', sing_box: 'ok' },
  dns: { status: 'unknown' },
  dpi: { status: 'unknown' },
  lists: { status: 'unknown' },
  guard: { active: false },
  recovery: {
    pending: false,
    last_event: { kind: 'start', status: 'success', timestamp: 1 },
  },
  package_recovery: { pending: false },
  last_reload: { status: 'success', timestamp: 2 },
  recent_activity: [
    { kind: 'start', status: 'success', timestamp: 1 },
    { kind: 'reload', status: 'success', timestamp: 2 },
  ],
  ...overrides,
});

const snapshot = (
  id: string,
  createdAt: number,
  reason: string,
  isLkg = false,
): Forkop.SnapshotMetadata => ({
  id,
  created_at: createdAt,
  kind: reason === 'manual' ? 'manual' : 'automatic',
  reason,
  forkop_version: '1.0.0',
  is_lkg: isLkg,
});

describe('recovery state', () => {
  it('shows recovery facts, localized, with the last known good snapshot', () => {
    const rows = recoveryRows(health(), [
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => row.label)).toEqual([
      'DPI guard',
      'Last recovery',
      'Package recovery',
      'Last reload',
      'Last known good configuration',
    ]);
    expect(rows[0].value).toBe('Inactive');
    expect(rows[1].value).toBe('Not needed');
    expect(rows[3].value).toMatch(/^Succeeded · /);
    expect(rows[4].tone).toBe('success');
    for (const row of rows)
      expect(row.value).not.toMatch(/^(ok|success|unknown|failure)$/);
  });

  it('says when no last known good snapshot exists or snapshots are unknown', () => {
    expect(recoveryRows(health(), [])[4].value).toBe('Not recorded yet');
    expect(recoveryRows(health(), null)[4].value).toBe('Unknown');
  });

  it('never presents an ordinary reload as the last recovery', () => {
    const reloadOnly = health({
      recovery: {
        pending: false,
        last_event: { kind: 'reload', status: 'success', timestamp: 9 },
      },
      recent_activity: [{ kind: 'reload', status: 'success', timestamp: 9 }],
    });
    expect(recoveryRows(reloadOnly, [])[1].value).toBe('Not needed');

    const rolledBack = health({
      recent_activity: [{ kind: 'reload', status: 'recovered', timestamp: 7 }],
    });
    expect(recoveryRows(rolledBack, [])[1].value).toMatch(
      /^Configuration reload: Recovered · /,
    );
  });

  it('maps an active guard and pending package recovery', () => {
    const rows = recoveryRows(
      health({
        guard: { active: true },
        package_recovery: { pending: true },
        last_reload: null,
      }),
      [],
    );

    expect(rows[0]).toMatchObject({
      value: 'Active: DPI switch not confirmed',
      tone: 'error',
    });
    expect(rows[2].value).toBe('Waiting to finish');
    expect(rows[3].value).toBe('No reload recorded yet');
  });
});

// UC-066, UC-019: a guard that is left or a failed last change is never
// shown as "In progress", and the step that ends a guard is named.
describe('recovery state that needs an action', () => {
  const guarded = (
    action: 'restart' | 'restore' | 'wait',
    kinds: { runtime?: boolean; restore?: boolean },
  ) =>
    health({
      overall: 'error',
      guard: { active: true, runtime: false, restore: false, ...kinds },
      recovery: { pending: true, last_event: null, action },
    });
  const row = (rows: ReturnType<typeof recoveryRows>, label: string) =>
    rows.find((item) => item.label === label);

  it('asks for a restart while a failed transition keeps its guard', () => {
    const rows = recoveryRows(guarded('restart', { runtime: true }), []);
    expect(row(rows, 'DPI guard')).toMatchObject({
      value: 'Active: kept by a failed change',
      tone: 'error',
    });
    expect(row(rows, 'Last recovery')).toMatchObject({
      value: 'Needs attention',
      tone: 'error',
    });
    expect(row(rows, 'Next step')?.value).toContain('Restart Forkop X');
  });

  it('asks for a snapshot restore while an unfinished restore keeps its guard', () => {
    const rows = recoveryRows(guarded('restore', { restore: true }), []);
    expect(row(rows, 'DPI guard')).toMatchObject({
      value: 'Active: restore not finished',
      tone: 'error',
    });
    expect(row(rows, 'Last recovery')?.value).toBe('Needs attention');
    expect(row(rows, 'Next step')?.value).toContain(
      'Restore the last known good snapshot',
    );
  });

  it('shows a guard that a running change holds as in progress', () => {
    const rows = recoveryRows(guarded('wait', { restore: true }), []);
    expect(row(rows, 'DPI guard')?.tone).toBe('loading');
    expect(row(rows, 'Last recovery')).toMatchObject({
      value: 'In progress',
      tone: 'loading',
    });
    expect(row(rows, 'Next step')).toBeUndefined();
  });

  it('names the failed last change instead of "In progress"', () => {
    const failed = { kind: 'reload', status: 'failure', timestamp: 9 };
    const rows = recoveryRows(
      health({
        overall: 'error',
        recovery: { pending: true, last_event: failed, action: null },
        recent_activity: [failed],
      }),
      [],
    );
    const last = row(rows, 'Last recovery');
    expect(last?.value).toMatch(/^Configuration reload: Failed · /);
    expect(last?.tone).toBe('error');
    expect(row(rows, 'Next step')).toBeUndefined();
  });
});

describe('history list', () => {
  const events: Forkop.HistoryEvent[] = [
    { kind: 'start', status: 'success', timestamp: 100 },
    { kind: 'reload', status: 'failure', timestamp: 200 },
    { kind: 'autotune_apply', status: 'recovered', timestamp: 300 },
    { kind: 'snapshot_delete', status: 'success', timestamp: 400 },
  ];

  it('shows recent events first and reveals older ones without deleting data', () => {
    const entries = historyItems(
      Array.from({ length: 19 }, (_, index) => ({
        kind: 'start',
        status: 'success',
        timestamp: index + 1,
      })),
      'all',
    );
    const first = historyPage(entries);
    expect(first.visible).toHaveLength(HISTORY_PAGE_SIZE);
    expect(first.visible[0].time).toBe(entries[0].time);
    expect(first.remaining).toBe(11);

    const second = historyPage(entries, first.nextCount);
    expect(second.visible).toHaveLength(16);
    expect(second.remaining).toBe(3);
    expect(historyPage(entries, second.nextCount).visible).toEqual(entries);
  });

  it('keeps small and invalid page requests bounded', () => {
    const entries = historyItems(events, 'all');
    expect(historyPage(entries).visible).toHaveLength(4);
    expect(historyPage(entries, Number.NaN).remaining).toBe(0);
  });

  it('lists the newest event first with its own words', () => {
    expect(historyItems(events, 'all').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Autotune apply',
      'Configuration reload',
      'Service start',
    ]);
    expect(historyItems(events, 'all')[1].outcome).toEqual({
      label: 'Recovered',
      tone: 'warning',
    });
  });

  it('names manual and automatic autotune applies', () => {
    const titles = historyItems(
      [
        {
          kind: 'autotune_apply',
          status: 'success',
          timestamp: 4,
          trigger: 'manual',
          candidate: 'multisplit',
        },
        {
          kind: 'autotune_apply',
          status: 'recovered',
          timestamp: 3,
          trigger: 'automatic',
          candidate: 'fake',
        },
        { kind: 'autotune_apply', status: 'success', timestamp: 2 },
      ],
      'autotune',
    ).map((item) => item.title);
    expect(titles).toEqual([
      'Autotune: multisplit applied manually',
      'Autotune: automatic apply of fake',
      'Autotune apply',
    ]);
  });

  it('filters by category', () => {
    expect(historyItems(events, 'config').map((item) => item.title)).toEqual([
      'Snapshot deleted',
      'Configuration reload',
    ]);
    expect(historyItems(events, 'autotune')).toHaveLength(1);
    expect(
      historyItems(
        [{ kind: 'autotune_mode', status: 'success', timestamp: 1 }],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune mode changed']);
    expect(
      historyItems(
        [
          { kind: 'autotune_run', status: 'failure', timestamp: 2 },
          { kind: 'autotune_recommendation', status: 'success', timestamp: 1 },
        ],
        'autotune',
      ).map((item) => item.title),
    ).toEqual(['Autotune run', 'Autotune recommendation confirmed']);
    expect(historyItems(events, 'service').map((item) => item.title)).toEqual([
      'Service start',
    ]);
  });
});

describe('snapshots', () => {
  it('only offers cleanup when exactly one last known good snapshot is present', () => {
    const old = snapshot('1_a', 10, 'manual');
    const working = snapshot('2_b', 20, 'last-known-working', true);
    const recent = snapshot('3_c', 30, 'before-reload');

    expect(snapshotCleanupIds([old, working, recent])).toEqual(['1_a', '3_c']);
    expect(
      snapshotCleanupIds([old, working, { ...recent, is_protected: true }]),
    ).toEqual(['1_a']);
    expect(snapshotCleanupIds([old, recent])).toEqual([]);
    expect(
      snapshotCleanupIds([old, working, { ...recent, is_lkg: true }]),
    ).toEqual([]);
    expect(snapshotCleanupIds([working])).toEqual([]);
  });

  it('labels every reason and marks the last known good one', () => {
    expect(snapshotReasonLabel('before-autotune')).toBe('Before autotune');
    expect(snapshotReasonLabel('concurrent-change')).toBe('Concurrent edit');
    expect(snapshotReasonLabel('unexpected')).toBe('Other');

    const rows = snapshotRows([
      snapshot('1_a', 10, 'manual'),
      snapshot('2_b', 20, 'last-known-working', true),
    ]);

    expect(rows.map((row) => [row.id, row.lkg, row.canDelete])).toEqual([
      ['2_b', true, false],
      ['1_a', false, true],
    ]);
    expect(rows[1].reason).toBe('Manual');
    expect(rows[0].reason).toBe('');
    const protectedRow = snapshotRows([
      { ...snapshot('3_c', 30, 'before-autotune'), is_protected: true },
    ])[0];
    expect(protectedRow.protected).toBe(true);
    expect(protectedRow.canDelete).toBe(false);
  });

  it('shows list changes readably', () => {
    expect(
      diffRows([
        {
          section: 'settings',
          option: 'dns_server',
          kind: 'list',
          before: ['1.1.1.1', '8.8.8.8'],
          after: [],
        },
        { section: 'youtube', option: 'nfqws_opt', before: 'a', after: '' },
      ]),
    ).toEqual([
      {
        where: 'settings · dns_server',
        snapshot: '1.1.1.1, 8.8.8.8',
        current: '—',
      },
      { where: 'youtube · nfqws_opt', snapshot: 'a', current: '—' },
    ]);
  });

  // D-2(a), UC-063: null is an option absent on that side; '***' is a
  // value that exists and is hidden.
  it('shows an absent side as not set and keeps hidden values masked', () => {
    expect(
      diffRows([
        { section: 'settings', option: 'password', before: null, after: '***' },
        {
          section: '@section_interface[0]',
          option: 'dns_type',
          before: 'udp',
          after: null,
        },
        {
          section: 'settings',
          option: 'subscription_urls',
          kind: 'list',
          before: null,
          after: ['***'],
        },
      ]),
    ).toEqual([
      { where: 'settings · password', snapshot: 'not set', current: '***' },
      {
        where: '@section_interface[0] · dns_type',
        snapshot: 'udp',
        current: 'not set',
      },
      {
        where: 'settings · subscription_urls',
        snapshot: 'not set',
        current: '***',
      },
    ]);
  });

  // UC-062: the backend lists at most 100 changes; a longer diff ends with
  // { truncated, total } in place of the rest.
  const changes = (count: number): Forkop.SnapshotChange[] =>
    Array.from({ length: count }, (_, i) => ({
      section: 'settings',
      option: `opt${i}`,
      before: 'a',
      after: 'b',
    }));

  it('counts every change of a cut diff, not only the listed ones', () => {
    const cut = snapshotDiff([
      ...changes(100),
      { truncated: true, total: 250 },
    ]);
    expect(cut.changes).toHaveLength(100);
    expect(cut.changes.some((change) => 'truncated' in change)).toBe(false);
    expect(cut.total).toBe(250);
    expect(diffTruncatedText(cut)).toBe(
      'Only the first 100 changes are listed; 250 changes in total.',
    );

    const whole = snapshotDiff(changes(3));
    expect(whole).toEqual({ changes: changes(3), total: 3 });
    expect(snapshotDiff([])).toEqual({ changes: [], total: 0 });
  });

  it('does not understate the scope of a restore', () => {
    const preview = restorePreview(
      snapshotDiff([...changes(100), { truncated: true, total: 250 }]),
      8,
    );
    expect(preview).toHaveLength(9);
    expect(preview[0]).toBe('settings · opt0: b → a');
    expect(preview[8]).toBe('and 242 more');

    expect(restorePreview(snapshotDiff(changes(10)), 8)[8]).toBe('and 2 more');
    expect(restorePreview(snapshotDiff(changes(8)), 8)).toHaveLength(8);
    expect(restorePreview(snapshotDiff(changes(3)), 8)).toEqual([
      'settings · opt0: b → a',
      'settings · opt1: b → a',
      'settings · opt2: b → a',
    ]);
  });
});

describe('restore result', () => {
  it('reports restored only for a reload that ran', () => {
    expect(restoreResultToast({ status: 'success' })).toEqual({
      text: 'Configuration restored and reloaded',
      type: 'success',
      duration: 6000,
    });
    expect(
      restoreResultToast({
        status: 'recovered',
        reason: 'target_reload_failed',
      }).text,
    ).toBe('Restore failed; previous configuration and runtime recovered');
  });

  it('does not promise a reload before a restore while Forkop is stopped', () => {
    const running = restoreConfirmMessage(false);
    expect(running).toContain('reloads the configuration');

    const stopped = restoreConfirmMessage(true);
    expect(stopped).toContain('Forkop X is stopped');
    expect(stopped).toContain('when you start Forkop X');
    expect(stopped).not.toContain('reloads');
  });

  it('never reports a restore while Forkop is stopped as reloaded', () => {
    const kept = restoreResultToast({
      status: 'restored_not_started',
      reason: 'service_stopped',
    });
    expect(kept.type).toBe('warning');
    expect(kept.text).toContain('Forkop X is stopped');
    expect(kept.text).toContain('when Forkop X is started');
    expect(kept.text).not.toContain('reloaded');

    const invalid = restoreResultToast({
      status: 'failed',
      reason: 'target_invalid',
      runtime: 'stopped',
    });
    expect(invalid.type).toBe('warning');
    expect(invalid.text).toContain('did not pass validation');
    expect(invalid.text).toContain('previous configuration is kept');

    const overtaken = restoreResultToast({
      status: 'failed',
      reason: 'service_stopped',
      runtime: 'stopped',
    });
    expect(overtaken.text).toContain('stopped during the restore');
    // Without the stop, a failure still points to the recovery state.
    expect(restoreResultToast({ status: 'failed' }).type).toBe('error');
  });

  it('names a reload that was only queued', () => {
    const recovered = restoreResultToast({
      status: 'recovered',
      reason: 'target_reload_queued',
    });
    expect(recovered.type).toBe('warning');
    expect(recovered.text).toContain('only queued the reload');
    expect(recovered.text).toContain('previous configuration is kept');

    const unfinished = restoreResultToast({
      status: 'needs_attention',
      reason: 'rollback_reload_queued',
    });
    expect(unfinished.type).toBe('error');
    expect(unfinished.text).toContain('did not finish');
    expect(unfinished.text).toContain('DPI guard stays active');
    expect(unfinished.text).not.toContain('restored');

    expect(
      restoreResultToast({
        status: 'needs_attention',
        reason: 'runtime_rollback_failed',
      }),
    ).toEqual({
      text: 'Restore failed; check the recovery state before retrying',
      type: 'error',
      duration: 8000,
    });
    expect(restoreResultToast(undefined).type).toBe('error');
  });

  it('explains why a restore was refused unchanged', () => {
    expect(
      restoreResultToast({
        status: 'busy',
        reason: 'service_action_in_progress',
      }),
    ).toEqual({
      text: snapshotBusyText('service_action_in_progress'),
      type: 'warning',
      duration: 6000,
    });
    expect(snapshotBusyText('service_action_in_progress')).toContain(
      'The service is busy',
    );
    expect(snapshotBusyText('service_action_in_progress')).toContain(
      'Nothing was changed',
    );
    expect(snapshotBusyText('snapshot_operation_in_progress')).toBe(
      'Another snapshot operation is already in progress. Try again in a moment.',
    );
    // UC-068: uci changes staged on the router would ride along.
    const staged = restoreResultToast({
      status: 'failed',
      reason: 'uncommitted_uci_changes',
    });
    expect(staged.type).toBe('warning');
    expect(staged.text).toContain('was not started');
    expect(staged.text).toContain('Commit or revert');
  });

  // UC-019: a guard that a failed lifecycle transition kept refuses the
  // restore, or ends it needs_attention; the restart comes first.
  it('asks for a restart when a kept runtime guard stops the restore', () => {
    const refused = restoreResultToast({
      status: 'failed',
      reason: 'runtime_guard_active',
    });
    expect(refused.type).toBe('warning');
    expect(refused.text).toContain('was not started');
    expect(refused.text).toContain('Restart Forkop X');
    const unfinished = restoreResultToast({
      status: 'needs_attention',
      reason: 'runtime_guard_active',
      guard: 'active',
    });
    expect(unfinished.type).toBe('error');
    expect(unfinished.text).toContain('did not finish');
    expect(unfinished.text).toContain('Restart Forkop X');
  });

  it('keeps an edit made during the restore instead of calling it restored', () => {
    const edited = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      saved_snapshot: '1790000000_1',
    });
    expect(edited.type).toBe('error');
    expect(edited.text).toContain('did not finish');
    expect(edited.text).toContain('The change is kept');
    expect(edited.text).toContain('Concurrent edit');
    expect(edited.text).toContain('DPI guard stays active');
    // UC-023: the reload ran, but it may have read the change: no success,
    // and no guard is left.
    const reloaded = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      guard: 'inactive',
      saved_snapshot: '1790000000_1',
    });
    expect(reloaded.type).toBe('error');
    expect(reloaded.text).toContain('did not finish');
    expect(reloaded.text).toContain('not known whether with the snapshot');
    expect(reloaded.text).toContain('The change is kept');
    expect(reloaded.text).toContain('Concurrent edit');
    expect(reloaded.text).not.toContain('DPI guard');
    // Forkop X stopped during the restore: nothing reloaded, no guard left.
    const stopped = restoreResultToast({
      status: 'needs_attention',
      reason: 'config_changed_during_transaction',
      runtime: 'stopped',
      saved_snapshot: '1790000000_1',
    });
    expect(stopped.text).toContain('was not applied');
    expect(stopped.text).toContain('The change is kept');
    expect(stopped.text).toContain('Concurrent edit');
    expect(stopped.text).not.toContain('DPI guard');
  });

  it('names a snapshot of the kept edit only when one was saved', () => {
    for (const extra of [
      {},
      { guard: 'inactive' as const },
      { runtime: 'stopped' as const },
    ]) {
      const unsaved = restoreResultToast({
        status: 'needs_attention',
        reason: 'config_changed_during_transaction',
        saved_snapshot: null,
        ...extra,
      });
      expect(unsaved.type).toBe('error');
      expect(unsaved.text).toContain('The change is kept in the configuration');
      expect(unsaved.text).toContain('no snapshot of it could be saved');
      expect(unsaved.text).not.toContain('Concurrent edit');
    }
  });

  it('asks for unsaved changes of this session to be applied first', () => {
    expect(
      unsavedChangesBlockRestore(
        { forkop: [['set', 'settings', 'dns_server', '9.9.9.9']] },
        'forkop',
      ),
    ).toBe(true);
    expect(unsavedChangesBlockRestore({ forkop: [] }, 'forkop')).toBe(false);
    expect(
      unsavedChangesBlockRestore({ network: [['set', 'lan']] }, 'forkop'),
    ).toBe(false);
    // Unknown (the call failed or LuCI lacks it): nothing is blocked.
    expect(unsavedChangesBlockRestore(null, 'forkop')).toBe(false);
    expect(unsavedChangesBlockRestore(undefined, 'forkop')).toBe(false);
  });
});
