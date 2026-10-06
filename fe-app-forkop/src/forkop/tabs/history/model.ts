import { Forkop } from '../../types';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type StatusTone,
} from '../../ui/status';
import { formatRelativeTime } from '../../ui/time';

// Pure view model of the History & Recovery page.

export interface RecoveryRow {
  label: string;
  value: string;
  tone: StatusTone;
}

function formatTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleString();
}

// A plain reload is not a recovery: only restores, recovery runs and events
// that ended in a rollback ("recovered") count.
export function lastRecoveryEvent(health: Forkop.HealthStatus) {
  const events = [
    ...health.recent_activity,
    ...(health.recovery.last_event ? [health.recovery.last_event] : []),
  ].filter(
    (event) =>
      event.kind === 'restore' ||
      event.kind === 'recovery' ||
      event.status === 'recovered',
  );
  return events.sort((a, b) => b.timestamp - a.timestamp)[0] ?? null;
}

function eventText(event: { kind: string; status: string; timestamp: number }) {
  const outcome = eventOutcomeView(toEventOutcome(event.status));
  return {
    value: `${eventKindLabel(event.kind)}: ${outcome.label} · ${formatTime(event.timestamp)}`,
    tone: outcome.tone,
  };
}

// The DPI guard by what ends it (diagnostics/health.uc recovery.action):
// only one that a change still holds is transient (UC-019, UC-066).
function guardRow(health: Forkop.HealthStatus) {
  if (!health.guard.active)
    return { value: _('Inactive'), tone: 'success' as const };
  switch (health.recovery.action) {
    case 'wait':
      return {
        value: _('Active: a change is being applied'),
        tone: 'loading' as const,
      };
    case 'restart':
      return {
        value: _('Active: kept by a failed change'),
        tone: 'error' as const,
      };
    case 'restore':
      return {
        value: _('Active: restore not finished'),
        tone: 'error' as const,
      };
    default:
      return {
        value: _('Active: DPI switch not confirmed'),
        tone: 'error' as const,
      };
  }
}

// recovery.pending means a guard is left or the last event failed: neither
// is in progress unless a change still holds its guard. A failed last event
// is named, with the previous configuration kept (UC-066).
function lastRecoveryRow(health: Forkop.HealthStatus) {
  if (health.guard.active)
    return health.recovery.action === 'wait'
      ? { value: _('In progress'), tone: 'loading' as const }
      : { value: _('Needs attention'), tone: 'error' as const };
  const failed = health.recovery.last_event;
  if (failed) return eventText(failed);
  return { value: _('Needs attention'), tone: 'error' as const };
}

// The step that ends a DPI guard that is left; none while a change holds it.
function nextStepRow(health: Forkop.HealthStatus): RecoveryRow[] {
  if (!health.guard.active) return [];
  switch (health.recovery.action) {
    case 'restart':
      return [
        {
          label: _('Next step'),
          value: _(
            'Restart Forkop X: the restart removes the DPI guard that a failed change left in place.',
          ),
          tone: 'warning',
        },
      ];
    case 'restore':
      return [
        {
          label: _('Next step'),
          value: _(
            'Restore the last known good snapshot: the restore finishes and removes the DPI guard.',
          ),
          tone: 'warning',
        },
      ];
    default:
      return [];
  }
}

export function recoveryRows(
  health: Forkop.HealthStatus,
  snapshots: Forkop.SnapshotMetadata[] | null,
): RecoveryRow[] {
  const last = lastRecoveryEvent(health);
  const reload = health.last_reload;
  const lkg = snapshots?.find((snapshot) => snapshot.is_lkg);
  const reloadOutcome = reload
    ? eventOutcomeView(toEventOutcome(reload.status))
    : null;

  return [
    {
      label: _('DPI guard'),
      ...guardRow(health),
    },
    {
      label: _('Last recovery'),
      ...(health.recovery.pending
        ? lastRecoveryRow(health)
        : last
          ? eventText(last)
          : { value: _('Not needed'), tone: 'success' as const }),
    },
    ...nextStepRow(health),
    {
      label: _('Package recovery'),
      ...(health.package_recovery.pending
        ? { value: _('Waiting to finish'), tone: 'warning' as const }
        : { value: _('Not needed'), tone: 'success' as const }),
    },
    {
      label: _('Last reload'),
      ...(reload && reloadOutcome
        ? {
            value: `${reloadOutcome.label} · ${formatTime(reload.timestamp)}`,
            tone: reloadOutcome.tone,
          }
        : { value: _('No reload recorded yet'), tone: 'neutral' as const }),
    },
    {
      label: _('Last known good configuration'),
      ...(lkg
        ? { value: formatTime(lkg.created_at), tone: 'success' as const }
        : snapshots
          ? { value: _('Not recorded yet'), tone: 'neutral' as const }
          : { value: _('Unknown'), tone: 'neutral' as const }),
    },
  ];
}

export type HistoryFilter = 'all' | 'config' | 'service' | 'autotune';

const CATEGORY: Record<string, Exclude<HistoryFilter, 'all'>> = {
  reload: 'config',
  restore: 'config',
  snapshot_create: 'config',
  snapshot_delete: 'config',
  start: 'service',
  recovery: 'service',
  autotune_apply: 'autotune',
  autotune_mode: 'autotune',
  autotune_recommendation: 'autotune',
  autotune_run: 'autotune',
};

export function historyFilterLabel(filter: HistoryFilter) {
  switch (filter) {
    case 'config':
      return _('Configuration');
    case 'service':
      return _('Service');
    case 'autotune':
      return _('Autotune');
    default:
      return _('All');
  }
}

export interface HistoryItem {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
  relative: string;
}

export const HISTORY_PAGE_SIZE = 8;

// Keep the full event history in memory; only limit what is mounted in the UI.
export function historyPage(
  items: HistoryItem[],
  shown = HISTORY_PAGE_SIZE,
): { visible: HistoryItem[]; remaining: number; nextCount: number } {
  const count = Number.isFinite(shown)
    ? Math.max(HISTORY_PAGE_SIZE, Math.floor(shown))
    : HISTORY_PAGE_SIZE;
  const visible = items.slice(0, count);
  return {
    visible,
    remaining: items.length - visible.length,
    nextCount: Math.min(items.length, count + HISTORY_PAGE_SIZE),
  };
}

// An autotune apply names its strategy and whether a person or the
// schedule started it; other events are named by their kind.
export function eventTitle(event: Forkop.HistoryEvent) {
  if (event.kind !== 'autotune_apply' || !event.trigger)
    return eventKindLabel(event.kind);
  const candidate = event.candidate ?? '';
  const manual = event.trigger === 'manual';
  if (!candidate)
    return manual
      ? _('Autotune: manual apply')
      : _('Autotune: automatic apply');
  if (event.status === 'success')
    return (
      manual
        ? _('Autotune: %s applied manually')
        : _('Autotune: %s applied automatically')
    ).replace('%s', candidate);
  return (
    manual
      ? _('Autotune: manual apply of %s')
      : _('Autotune: automatic apply of %s')
  ).replace('%s', candidate);
}

// Newest first.
export function historyItems(
  events: Forkop.HistoryEvent[],
  filter: HistoryFilter,
  nowMs = Date.now(),
): HistoryItem[] {
  return events
    .filter((event) => filter === 'all' || CATEGORY[event.kind] === filter)
    .slice()
    .sort((a, b) => b.timestamp - a.timestamp)
    .map((event) => ({
      title: eventTitle(event),
      outcome: eventOutcomeView(toEventOutcome(event.status)),
      time: formatTime(event.timestamp),
      relative: formatRelativeTime(event.timestamp, nowMs),
    }));
}

export function snapshotReasonLabel(reason: string) {
  switch (reason) {
    case 'manual':
      return _('Manual');
    case 'before-reload':
      return _('Before applying changes');
    case 'pre-restore':
      return _('Before restore');
    case 'last-known-working':
      return _('Last known good');
    case 'before-autotune':
      return _('Before autotune');
    // A configuration edited while a restore or an autotune change owned it:
    // kept, never rolled back or taken for the restored one
    // (config/snapshots.uc).
    case 'concurrent-change':
      return _('Concurrent edit');
    default:
      return _('Other');
  }
}

// Newest first; the last-known-good snapshot cannot be deleted.
export function snapshotRows(snapshots: Forkop.SnapshotMetadata[]) {
  return snapshots
    .slice()
    .sort((a, b) => b.created_at - a.created_at)
    .map((snapshot) => ({
      id: snapshot.id,
      time: formatTime(snapshot.created_at),
      // The badge already says "last known good" for such snapshots.
      reason:
        snapshot.is_lkg && snapshot.reason === 'last-known-working'
          ? ''
          : snapshotReasonLabel(snapshot.reason),
      lkg: Boolean(snapshot.is_lkg),
      protected: Boolean(snapshot.is_protected),
      canDelete: !snapshot.is_lkg && !snapshot.is_protected,
    }));
}

// Never offer bulk cleanup without exactly one verified recovery point.
// Each deletion is still checked against the current LKG by the backend.
export function snapshotCleanupIds(
  snapshots: Forkop.SnapshotMetadata[],
): string[] {
  if (snapshots.filter((snapshot) => snapshot.is_lkg).length !== 1) return [];
  return snapshots
    .filter((snapshot) => !snapshot.is_lkg && !snapshot.is_protected)
    .map((snapshot) => snapshot.id);
}

// null: the option is not set on that side, not a hidden value (D-2).
function diffValue(value: string | string[] | null | undefined) {
  if (value === null || value === undefined) return _('not set');
  if (Array.isArray(value)) return value.length ? value.join(', ') : '—';
  return value === '' ? '—' : value;
}

// `before` is the snapshot value, `after` the saved configuration now.
export function diffRows(changes: Forkop.SnapshotChange[]) {
  return changes.map((change) => ({
    where: `${change.section} · ${change.option}`,
    snapshot: diffValue(change.before),
    current: diffValue(change.after),
  }));
}

export interface SnapshotDiff {
  changes: Forkop.SnapshotChange[];
  // Every changed option: more than `changes` when the list is cut.
  total: number;
}

function isTruncation(
  entry: Forkop.SnapshotDiffEntry,
): entry is Forkop.SnapshotDiffTruncation {
  return (entry as Forkop.SnapshotDiffTruncation).truncated === true;
}

// UC-062: the backend lists a limited number of changes; a longer diff ends
// with { truncated, total } in place of the rest.
export function snapshotDiff(
  entries: Forkop.SnapshotDiffEntry[],
): SnapshotDiff {
  const changes = entries.filter(
    (entry): entry is Forkop.SnapshotChange => !isTruncation(entry),
  );
  const marker = entries.find(isTruncation);
  return {
    changes,
    total: Math.max(Number(marker?.total) || 0, changes.length),
  };
}

// Above a cut list in the Changes modal: the list is not the whole change.
export function diffTruncatedText(diff: SnapshotDiff) {
  return _('Only the first %d changes are listed; %d changes in total.')
    .replace('%d', String(diff.changes.length))
    .replace('%d', String(diff.total));
}

// The restore confirmation: the first `limit` changes, then how many more
// the restore changes, counted of all of them, not of the listed ones
// (UC-062).
export function restorePreview(diff: SnapshotDiff, limit: number) {
  const preview = diffRows(diff.changes.slice(0, limit)).map(
    (row) => `${row.where}: ${row.current} → ${row.snapshot}`,
  );
  const more = diff.total - preview.length;
  if (more > 0) preview.push(_('and %d more').replace('%d', String(more)));
  return preview;
}

export interface SnapshotToast {
  text: string;
  type: 'success' | 'warning' | 'error';
  duration: number;
}

// A snapshot operation refused before it changed anything. A reload that is
// only queued, with no live service action, never refuses a restore: the
// restore's own reload runs it.
export function snapshotBusyText(reason?: string) {
  if (reason === 'service_action_in_progress')
    return _(
      'The service is busy with another operation (list or subscription update, reload or start). Nothing was changed; try again when it finishes.',
    );
  return _(
    'Another snapshot operation is already in progress. Try again in a moment.',
  );
}

// Changes of this LuCI session that are saved but not applied (rpcd keeps
// them per session). The restore's reload does not read them, but a later
// Save & Apply would merge them into the restored configuration: they are
// applied or reverted first. Unknown changes (the call failed) block nothing.
export function unsavedChangesBlockRestore(
  changes: Record<string, unknown> | null | undefined,
  uciPackage: string,
): boolean {
  const pending = changes?.[uciPackage];
  return Array.isArray(pending) && pending.length > 0;
}

export function unsavedChangesText() {
  return _(
    'There are unsaved changes of Forkop X in this session. Save & Apply or revert them, then restore the snapshot.',
  );
}

// What the restore will do, said before the user confirms it. Forkop X
// stopped by the user, or not started since boot, is not started by a
// restore (D-15): the configuration is replaced and checked, and takes
// effect at the next start.
export function restoreConfirmMessage(staysStopped: boolean): string {
  return staysStopped
    ? _(
        'Forkop X is stopped: the configuration is replaced and checked, but Forkop X is not started. It takes effect when you start Forkop X.',
      )
    : _(
        'Forkop X reloads the configuration. If the reload fails, the previous configuration is restored automatically.',
      );
}

// What a finished restore means. A reload that the service only queued
// behind another operation never ran, so it is never reported as restored.
export function restoreResultToast(
  result: Forkop.SnapshotResult | undefined,
): SnapshotToast {
  switch (result?.status) {
    case 'busy':
      return {
        text: snapshotBusyText(result.reason),
        type: 'warning',
        duration: 6000,
      };
    case 'success':
      return {
        text: _('Configuration restored and reloaded'),
        type: 'success',
        duration: 6000,
      };
    // Forkop X was stopped by the user: only a start brings it back.
    case 'restored_not_started':
      return {
        text: _(
          'Configuration restored, but Forkop X is stopped: it was not started or checked. The restored configuration takes effect when Forkop X is started.',
        ),
        type: 'warning',
        duration: 10000,
      };
    case 'recovered':
      return {
        text:
          result.reason === 'target_reload_queued'
            ? _(
                'Restore was not applied: the service was busy and only queued the reload. The previous configuration is kept.',
              )
            : _('Restore failed; previous configuration and runtime recovered'),
        type: 'warning',
        duration: 8000,
      };
    case 'failed':
      // A failed lifecycle transition kept its DPI guard: no reload runs
      // until a restart removes it, so nothing was changed (UC-019).
      if (result.reason === 'runtime_guard_active')
        return {
          text: _(
            'Restore was not started: a failed change left the DPI guard in place, and nothing can be reloaded until Forkop X is restarted. Restart Forkop X, then restore the snapshot if it is still needed.',
          ),
          type: 'warning',
          duration: 12000,
        };
      // Changes staged on the router with uci but not committed would ride
      // along the reload (UC-068): nothing was changed.
      if (result.reason === 'uncommitted_uci_changes')
        return {
          text: _(
            'Restore was not started: the router has uncommitted uci changes of Forkop X (made with "uci set" without a commit). Commit or revert them, then restore again.',
          ),
          type: 'warning',
          duration: 10000,
        };
      if (result.runtime === 'stopped')
        return {
          text:
            result.reason === 'target_invalid'
              ? _(
                  'Restore was not applied: the snapshot configuration did not pass validation. The previous configuration is kept; Forkop X stays stopped.',
                )
              : _(
                  'Restore was not applied: Forkop X was stopped during the restore. The previous configuration is kept.',
                ),
          type: 'warning',
          duration: 10000,
        };
      break;
    case 'needs_attention':
      // Someone saved the configuration while the snapshot was being
      // reloaded: the change was kept instead of rolled back, and never
      // taken for the restored snapshot (UC-023). A snapshot of it is named
      // only when one was saved (not with the snapshot list full).
      if (result.reason === 'config_changed_during_transaction') {
        const kept = result.saved_snapshot
          ? _('The change is kept and saved as a snapshot ("Concurrent edit").')
          : _(
              'The change is kept in the configuration, but no snapshot of it could be saved.',
            );
        return {
          text:
            // Forkop X was stopped: the snapshot was not reloaded, no
            // guard is left.
            result.runtime === 'stopped'
              ? `${_('Restore was not applied: Forkop X was stopped, and the configuration was changed during the restore.')} ${kept}`
              : // The reload ran, but it may have read the change.
                result.guard === 'inactive'
                ? `${_('Restore did not finish: the configuration was changed while the snapshot was being applied. Forkop X was reloaded, but it is not known whether with the snapshot or with the change.')} ${kept} ${_('Restore the snapshot you need to finish.')}`
                : `${_('Restore did not finish: the configuration was changed while the snapshot was being applied.')} ${kept} ${_('The DPI guard stays active. Restore the snapshot you need to finish.')}`,
          type: 'error',
          duration: 12000,
        };
      }
      // The reload left, or met, a DPI guard that a failed transition kept:
      // the restore's own guard stays until a restore after the restart.
      if (result.reason === 'runtime_guard_active')
        return {
          text: _(
            'Restore did not finish: a failed change left the DPI guard in place, and the DPI guard stays active. Restart Forkop X, then restore the snapshot again.',
          ),
          type: 'error',
          duration: 12000,
        };
      if (result.reason === 'rollback_reload_queued')
        return {
          text: _(
            'Restore did not finish: the service was busy and only queued the reload. The DPI guard stays active; restore again when the service is idle.',
          ),
          type: 'error',
          duration: 10000,
        };
      break;
  }
  return {
    text: _('Restore failed; check the recovery state before retrying'),
    type: 'error',
    duration: 8000,
  };
}
