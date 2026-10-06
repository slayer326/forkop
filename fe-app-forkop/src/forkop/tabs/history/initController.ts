import { onMount, preserveScrollForPage } from '../../../helpers';
import { showToast } from '../../../helpers/showToast';
import { ForkopShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { isReadonlyMode } from '../../services/accessMode.service';
import { refreshRuntimeUiState } from '../../services/runtimeUiState.service';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { Forkop } from '../../types';
import { confirmAction } from '../../ui/confirmAction';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus } from '../../ui/status';
import {
  renderEmptyState,
  renderErrorState,
  renderLoadingState,
} from '../../ui/states';
import {
  diffRows,
  diffTruncatedText,
  historyFilterLabel,
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
  snapshotRows,
  unsavedChangesBlockRestore,
  unsavedChangesText,
  type HistoryFilter,
  type SnapshotDiff,
} from './model';
import { FORKOP_UCI_PACKAGE } from '../../../constants';
import { cleanupOldSnapshots } from './cleanupSnapshots';

const REFRESH_INTERVAL_MS = 15000;
const FILTERS: HistoryFilter[] = ['all', 'config', 'service', 'autotune'];
const MAX_RESTORE_PREVIEW = 8;

let mounted = false;
let mountId = 0;
let refreshTimer: ReturnType<typeof setInterval> | null = null;
let filter: HistoryFilter = 'all';
let visibleHistoryCount = HISTORY_PAGE_SIZE;
let health: Forkop.HealthStatus | null = null;
let healthFailed = false;
let history: Forkop.HistoryResult | null = null;
let historyFailed = false;
let snapshots: Forkop.SnapshotMetadata[] | null = null;
let snapshotsFailed = false;
let snapshotBusy = false;

async function loadAll() {
  const id = mountId;
  const [healthResponse, historyResponse, snapshotResponse] =
    await Promise.allSettled([
      ForkopShellMethods.getHealthStatus(),
      ForkopShellMethods.getHistory(),
      ForkopShellMethods.snapshotList(),
    ]);
  if (!mounted || id !== mountId) return;

  const value = <T>(result: PromiseSettledResult<Forkop.MethodResponse<T>>) =>
    result.status === 'fulfilled' && result.value.success
      ? result.value.data
      : null;

  health = value(healthResponse);
  healthFailed = !health;
  history = value(historyResponse);
  historyFailed = !history || !Array.isArray(history.events);
  const list = value(snapshotResponse);
  snapshots = Array.isArray(list) ? list : null;
  snapshotsFailed = !snapshots;
  renderAll();
}

function replace(id: string, ...nodes: Node[]) {
  const container = document.getElementById(id);
  if (container)
    preserveScrollForPage(() => container.replaceChildren(...nodes));
}

function renderState() {
  if (healthFailed || !health) {
    replace(
      'history-state',
      healthFailed
        ? renderErrorState(
            _('Recovery state is unavailable'),
            () => void loadAll(),
          )
        : renderLoadingState(),
    );
    return;
  }

  replace(
    'history-state',
    E(
      'dl',
      { class: 'fkp-history__facts' },
      recoveryRows(health, snapshots).flatMap((row) => [
        E('dt', {}, row.label),
        E('dd', {}, renderStatus({ label: row.value, tone: row.tone })),
      ]),
    ),
  );
}

function renderHistory() {
  replace(
    'history-filter',
    ...FILTERS.map((item) =>
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          'aria-pressed': item === filter ? 'true' : 'false',
          click: () => {
            filter = item;
            visibleHistoryCount = HISTORY_PAGE_SIZE;
            renderHistory();
          },
        },
        historyFilterLabel(item),
      ),
    ),
  );

  if (historyFailed || !history) {
    replace(
      'history-events',
      historyFailed
        ? renderErrorState(_('History is unavailable'), () => void loadAll())
        : renderLoadingState(),
    );
    return;
  }

  const items = historyItems(history.events, filter);
  const page = historyPage(items, visibleHistoryCount);
  const notes = history.persistent
    ? []
    : [
        E(
          'p',
          { class: 'fkp-history__hint' },
          _('History is kept in memory until the router restarts.'),
        ),
      ];

  replace(
    'history-events',
    ...notes,
    ...(items.length
      ? [
          E(
            'ul',
            { class: 'fkp-history__list' },
            page.visible.map((item) =>
              E('li', { class: 'fkp-history__event' }, [
                E(
                  'span',
                  { class: 'fkp-history__time', title: item.time },
                  item.relative,
                ),
                E('span', { class: 'fkp-history__what' }, item.title),
                renderStatus(item.outcome),
              ]),
            ),
          ),
          ...(page.remaining
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button fkp-history__more',
                    click: () => {
                      visibleHistoryCount = page.nextCount;
                      renderHistory();
                    },
                  },
                  `${_('Show more events')} (+${Math.min(page.remaining, HISTORY_PAGE_SIZE)})`,
                ),
              ]
            : []),
        ]
      : [
          renderEmptyState(
            filter === 'all'
              ? _('No events recorded yet')
              : _('No events of this kind'),
          ),
        ]),
  );
}

function renderDiffTable(diff: SnapshotDiff) {
  const rows = diffRows(diff.changes);
  if (!diff.total) {
    return E('p', {}, _('No saved changes since this snapshot'));
  }

  return E('div', { class: 'fkp-history__diff-wrap' }, [
    // UC-062: a cut list says it is not the whole change.
    ...(diff.total > rows.length ? [E('p', {}, diffTruncatedText(diff))] : []),
    E('table', { class: 'table fkp-history__diff' }, [
      E('tr', { class: 'tr table-titles' }, [
        E('th', { class: 'th' }, _('Setting')),
        E('th', { class: 'th' }, _('In snapshot')),
        E('th', { class: 'th' }, _('Now')),
      ]),
      ...rows.map((row) =>
        E('tr', { class: 'tr' }, [
          E('td', { class: 'td' }, row.where),
          E('td', { class: 'td' }, row.snapshot),
          E('td', { class: 'td' }, row.current),
        ]),
      ),
    ]),
  ]);
}

async function loadDiff(id: string) {
  const response = await ForkopShellMethods.snapshotDiff(id);
  return response.success && Array.isArray(response.data)
    ? snapshotDiff(response.data)
    : null;
}

async function showChanges(id: string) {
  const diff = await loadDiff(id);
  if (!diff) {
    showToast(_('Could not compare configurations'), 'error');
    return;
  }

  ui.showModal(_('Changes since this snapshot'), [
    renderDiffTable(diff),
    E('div', { class: 'fkp-confirm__actions' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => ui.hideModal(),
        },
        _('Close'),
      ),
    ]),
  ] as unknown as HTMLElement);
}

async function runSnapshotAction(action: () => Promise<void>) {
  if (snapshotBusy) return;
  snapshotBusy = true;
  renderSnapshots();
  try {
    await action();
  } catch (error) {
    logger.error('[HISTORY]', 'snapshot action failed', error);
    showToast(_('Could not load data'), 'error');
  } finally {
    snapshotBusy = false;
    await loadAll();
  }
}

async function restoreSnapshot(id: string, label: string) {
  // UC-068: unsaved changes of this session would be merged into the
  // restored configuration by a later Save & Apply.
  const sessionChanges = await Promise.resolve(uci.changes?.()).catch(
    () => null,
  );
  if (unsavedChangesBlockRestore(sessionChanges, FORKOP_UCI_PACKAGE)) {
    showToast(unsavedChangesText(), 'warning', 8000);
    return;
  }

  const diff = await loadDiff(id);

  // Whether Forkop X is stopped by the user or not started since boot now
  // decides what the restore does (D-15).
  await refreshRuntimeUiState({ force: true }).catch(() => undefined);
  const services = store.get().servicesInfoWidget.data;
  const staysStopped = Boolean(
    services.forkopStoppedByUser || services.forkopNotStarted,
  );

  const confirmed = await confirmAction({
    title: _('Restore configuration snapshot?'),
    message: `${label}. ${restoreConfirmMessage(staysStopped)}`,
    consequences: diff
      ? diff.total
        ? restorePreview(diff, MAX_RESTORE_PREVIEW)
        : [_('No saved changes since this snapshot')]
      : [_('Could not compare configurations')],
    confirmLabel: _('Restore'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ForkopShellMethods.snapshotRestore(id);
    const toast = restoreResultToast(result.success ? result.data : undefined);
    showToast(toast.text, toast.type, toast.duration);
  });
}

async function deleteSnapshot(id: string, label: string) {
  const confirmed = await confirmAction({
    title: _('Delete snapshot?'),
    message: `${label}. ${_('Delete this configuration snapshot?')}`,
    confirmLabel: _('Delete'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await ForkopShellMethods.snapshotDelete(id);
    const status = result.success ? result.data.status : undefined;
    if (status === 'busy') showToast(snapshotBusyText(), 'warning', 6000);
    else if (status === 'deleted') showToast(_('Snapshot deleted'), 'success');
    else showToast(_('Could not delete snapshot'), 'error');
  });
}

async function deleteOldSnapshots() {
  if (!snapshots) return;
  const expected = snapshots;
  const ids = snapshotCleanupIds(expected);
  if (ids.length === 0) return;

  const confirmed = await confirmAction({
    title: _('Delete unneeded snapshots?'),
    message: _(
      'Delete %d unneeded snapshots? Snapshots needed for recovery will be kept.',
    ).replace('%d', String(ids.length)),
    confirmLabel: _('Delete'),
    danger: true,
  });
  if (!confirmed) return;

  await runSnapshotAction(async () => {
    const result = await cleanupOldSnapshots(
      expected,
      async () => {
        const response = await ForkopShellMethods.snapshotList();
        return response.success && Array.isArray(response.data)
          ? response.data
          : null;
      },
      async (id) => {
        const response = await ForkopShellMethods.snapshotDelete(id);
        const status = response.success ? response.data.status : undefined;
        return status === 'deleted' || status === 'busy' ? status : 'failed';
      },
    );
    if (result.status === 'deleted') {
      showToast(_('Old snapshots deleted'), 'success');
    } else if (result.status === 'changed') {
      showToast(_('Snapshot list changed. Refresh and try again.'), 'warning');
    } else if (result.status === 'load-failed') {
      showToast(_('Could not load configuration snapshots'), 'error');
    } else if (result.deleted > 0) {
      showToast(
        _('Deleted %d snapshots; the rest were not removed.').replace(
          '%d',
          String(result.deleted),
        ),
        'warning',
      );
    } else {
      showToast(
        result.status === 'busy'
          ? snapshotBusyText()
          : _('Could not delete snapshot'),
        result.status === 'busy' ? 'warning' : 'error',
      );
    }
  });
}

async function createSnapshot() {
  await runSnapshotAction(async () => {
    const result = await ForkopShellMethods.snapshotCreate('manual');
    const status = result.success ? result.data.status : undefined;
    if (status === 'busy') showToast(snapshotBusyText(), 'warning', 6000);
    else if (status === 'created') showToast(_('Snapshot saved'), 'success');
    else showToast(_('Could not create snapshot'), 'error');
  });
}

function renderSnapshots() {
  const readonly = isReadonlyMode();
  const cleanupIds = snapshots ? snapshotCleanupIds(snapshots) : [];
  replace(
    'history-snapshot-actions',
    ...(readonly
      ? []
      : [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled: snapshotBusy ? true : undefined,
              click: () => void createSnapshot(),
            },
            _('Create snapshot'),
          ),
          ...(cleanupIds.length
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button',
                    disabled: snapshotBusy ? true : undefined,
                    click: () => void deleteOldSnapshots(),
                  },
                  _('Delete unneeded snapshots'),
                ),
              ]
            : []),
        ]),
  );

  if (snapshotsFailed || !snapshots) {
    replace(
      'history-snapshots',
      snapshotsFailed
        ? renderErrorState(
            _('Could not load configuration snapshots'),
            () => void loadAll(),
          )
        : renderLoadingState(),
    );
    return;
  }

  const rows = snapshotRows(snapshots);
  replace(
    'history-snapshots',
    rows.length
      ? E(
          'ul',
          { class: 'fkp-history__list' },
          rows.map((row) => {
            const label = row.reason ? `${row.time} · ${row.reason}` : row.time;
            return E('li', { class: 'fkp-history__snapshot' }, [
              E('span', { class: 'fkp-history__what' }, [
                label,
                ...(row.lkg
                  ? [
                      ' ',
                      E(
                        'span',
                        { class: 'fkp-history__lkg' },
                        _('Last known good'),
                      ),
                    ]
                  : []),
                ...(row.protected
                  ? [
                      ' ',
                      E(
                        'span',
                        { class: 'fkp-history__lkg' },
                        _('Protected for recovery'),
                      ),
                    ]
                  : []),
              ]),
              E('span', { class: 'fkp-actions' }, [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button',
                    click: () => void showChanges(row.id),
                  },
                  _('Changes'),
                ),
                ...(readonly
                  ? []
                  : [
                      renderOverflowMenu(_('Snapshot actions'), [
                        {
                          label: _('Restore…'),
                          onClick: () => void restoreSnapshot(row.id, label),
                          disabled: snapshotBusy,
                          danger: true,
                        },
                        {
                          label: row.canDelete
                            ? _('Delete…')
                            : row.protected
                              ? _('This snapshot is needed for recovery')
                              : _(
                                  'The last known good snapshot cannot be deleted',
                                ),
                          onClick: () => void deleteSnapshot(row.id, label),
                          disabled: snapshotBusy || !row.canDelete,
                          danger: row.canDelete,
                        },
                      ]),
                    ]),
              ]),
            ]);
          }),
        )
      : renderEmptyState(_('No snapshots yet')),
  );
}

function renderAll() {
  renderState();
  renderHistory();
  renderSnapshots();
}

function onPageMount() {
  onPageUnmount();
  mounted = true;
  mountId += 1;
  visibleHistoryCount = HISTORY_PAGE_SIZE;
  renderAll();
  void loadAll();
  refreshTimer = setInterval(() => {
    if (!snapshotBusy) void loadAll();
  }, REFRESH_INTERVAL_MS);
}

function onPageUnmount() {
  mounted = false;
  mountId += 1;
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}

let initialized = false;

export async function initController(): Promise<void> {
  if (initialized) return;
  initialized = true;

  onMount('history-status').then(() => {
    store.subscribe(
      (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
        if (
          diff.tabService &&
          next.tabService.current !== prev.tabService.current
        ) {
          if (next.tabService.current === 'history') onPageMount();
          else onPageUnmount();
        }
      },
    );
    if (
      store.get().tabService.current === 'history' ||
      isActiveLuciTab('history')
    ) {
      onPageMount();
    }
  });
}
