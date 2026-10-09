import { onMount, preserveScrollForPage } from '../../../helpers';
import { showToast } from '../../../helpers/showToast';
import { runDnsCheck } from './checks/runDnsCheck';
import { runSingBoxCheck } from './checks/runSingBoxCheck';
import { runNftCheck } from './checks/runNftCheck';
import { runFakeIPCheck } from './checks/runFakeIPCheck';
import { runZapretCheck } from './checks/runZapretCheck';
import { runZapret2Check } from './checks/runZapret2Check';
import { runByedpiCheck } from './checks/runByedpiCheck';
import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import {
  DiagnosticsProviderOptions,
  getDiagnosticsChecks,
  getLoadingDiagnosticsChecks,
} from './diagnostic.store';
import {
  logger,
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  setLocalServiceAction,
  store,
  StoreType,
  subscribeRuntimeUiState,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  renderAvailableActions,
  renderChecks,
  renderRunAction,
  renderServiceActions,
  renderSystemInfo,
} from './partials';
import { ForkopShellMethods } from '../../methods';
import { fetchServicesInfo } from '../../fetchers/fetchServicesInfo';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { renderModal } from '../../../partials';
import { FORKOP_LUCI_APP_VERSION } from '../../../constants';
import { lastRunText, saveLastRun } from './partials/renderRunAction';
import { isReadonlyMode } from '../../services/accessMode.service';
import { runSectionsCheck } from './checks/runSectionsCheck';
import { Forkop } from '../../types';
import { initSiteCheck } from './siteCheck';
import {
  confirmStopForkop,
  runForkopServiceAction,
  setForkopAutostart,
} from '../shared/serviceControl';
import { initConnectivityMatrix } from './connectivityMatrix';
import { initDpiPlayground } from './dpiPlayground';
import {
  getAvailableActionsDisabledState,
  hasComponentActionLoading,
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
  shouldResetDiagnosticsChecks,
  shouldDisableDiagnosticRunAction,
  shouldShowRestartAction,
  shouldShowStartAction,
  shouldShowStopAction,
  shouldSkipServicesInfoAutoRefresh,
  serviceActionErrorText,
} from './serviceTransition';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import {
  formatSingBoxVersion,
  normalizeSingBoxVariantFields,
} from '../../helpers/singBoxVariant';
import {
  clearPersistedDiagnosticRun,
  PersistedDiagnosticRun,
  readPersistedDiagnosticRun,
  savePersistedDiagnosticRun,
} from './diagnosticRunPersistence';
import {
  formatMaskedSingBoxConfig,
  maskGlobalCheckText,
  stringifySingBoxConfig,
} from './helpers/maskDiagnostics';

let latestProviderInfoRequestId = 0;
let diagnosticLifecycleRegistered = false;
let diagnosticControllerInitialized = false;
let diagnosticMounted = false;
let diagnosticMountId = 0;
let diagnosticCompletedWhileHidden = false;
let servicesInfoStateUnsubscribe: (() => void) | null = null;
let servicesInfoRefreshPromise: Promise<void> | null = null;
const followedServiceActionJobs = new Set<string>();
const handledServiceActionJobs = new Set<string>();

type ServiceRuntimeAction = 'restart' | 'start' | 'stop';
type DiagnosticRunner = {
  code: DIAGNOSTICS_CHECKS;
  run: () => Promise<void>;
};

function getDiagnosticsProviderOptions(
  systemInfo: Pick<
    StoreType['diagnosticsSystemInfo'],
    'zapret_installed' | 'zapret2_installed' | 'byedpi_installed'
  > = store.get().diagnosticsSystemInfo,
): DiagnosticsProviderOptions {
  return {
    includeZapret: Boolean(systemInfo.zapret_installed),
    includeZapret2: Boolean(systemInfo.zapret2_installed),
    includeByedpi: Boolean(systemInfo.byedpi_installed),
  };
}

function getNotRunningDiagnosticsChecks() {
  return getDiagnosticsChecks(
    _('Not running'),
    getDiagnosticsProviderOptions(),
  );
}

function resetDiagnosticsChecks() {
  store.set({
    diagnosticsChecks: getNotRunningDiagnosticsChecks(),
  });
}

function setDiagnosticActionLoading(
  action: keyof StoreType['diagnosticsActions'],
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalServiceAction(action, loading && local);
  }

  const diagnosticsActions = store.get().diagnosticsActions;

  store.set({
    diagnosticsActions: {
      ...diagnosticsActions,
      [action]: { loading },
    },
  });
}

function isDiagnosticMountActive(mountId = diagnosticMountId) {
  return diagnosticMounted && diagnosticMountId === mountId;
}

function isLocalMutatingServiceActionLoading() {
  const actions = store.get().diagnosticsActions;

  return hasLocalMutatingServiceActionLoading(actions);
}

function isMutatingServiceActionLoading() {
  return (
    isLocalMutatingServiceActionLoading() ||
    isServiceTransitionStatus(store.get().servicesInfoWidget.data.forkopStatus)
  );
}

function downloadSupportReport(text: string) {
  const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  link.href = url;
  link.download = `forkop-support-report-${stamp}.txt`;
  link.style.display = 'none';
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

async function handleDownloadSupportReport() {
  setDiagnosticActionLoading('supportReport', true);

  try {
    const report = await ForkopShellMethods.supportReport();
    if (!report.success) {
      throw new Error(report.error || 'Support report collection failed');
    }

    downloadSupportReport(String(report.data ?? ''));
    showToast(
      _(
        'Support report contains confidential information. Do not share it in public chats.',
      ),
      'warning',
      10000,
    );
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'handleDownloadSupportReport - e', error);
    showToast(_('Failed to create support report'), 'error');
  } finally {
    setDiagnosticActionLoading('supportReport', false);
  }
}

async function refreshDiagnosticServicesInfo({
  force = false,
  mountId = diagnosticMountId,
  allowInactive = false,
}: {
  force?: boolean;
  mountId?: number;
  allowInactive?: boolean;
} = {}) {
  if (!allowInactive && !isDiagnosticMountActive(mountId)) {
    return;
  }

  if (
    shouldSkipServicesInfoAutoRefresh({
      force,
      localMutatingActionLoading: isLocalMutatingServiceActionLoading(),
    })
  ) {
    return;
  }

  if (servicesInfoRefreshPromise) {
    return servicesInfoRefreshPromise;
  }

  const promise = fetchServicesInfo()
    .then((uiState) => {
      followServiceActionsFromUiState(uiState);
    })
    .catch((error) => {
      logger.error(
        '[DIAGNOSTIC]',
        'refreshDiagnosticServicesInfo failed',
        error,
      );
    })
    .finally(() => {
      if (servicesInfoRefreshPromise === promise) {
        servicesInfoRefreshPromise = null;
      }
    });

  servicesInfoRefreshPromise = promise;
  return promise;
}

function startServiceActionStateWatcher() {
  if (servicesInfoStateUnsubscribe) {
    return;
  }

  servicesInfoStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (diagnosticMounted) {
      followServiceActionsFromUiState(uiState);
    }
  });
}

function stopServiceActionStateWatcher() {
  if (!servicesInfoStateUnsubscribe) {
    return;
  }

  servicesInfoStateUnsubscribe();
  servicesInfoStateUnsubscribe = null;
}

function isVisibleServiceRuntimeAction(
  action: Forkop.ServiceActionState['action'],
): action is ServiceRuntimeAction {
  return action === 'restart' || action === 'start' || action === 'stop';
}

function setServiceActionStateLoading(
  state: Forkop.ServiceActionState,
  loading: boolean,
) {
  if (!isVisibleServiceRuntimeAction(state.action)) {
    return;
  }

  setDiagnosticActionLoading(state.action, loading);
}

async function followServiceActionState(state: Forkop.ServiceActionState) {
  const jobId = state.job_id;

  if (!jobId || followedServiceActionJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledServiceActionJobs.has(jobId)) {
    return;
  }

  followedServiceActionJobs.add(jobId);
  if (state.running) {
    setServiceActionStateLoading(state, true);
  }

  try {
    if (state.running) {
      await ForkopShellMethods.waitServiceActionJob(jobId);
    }
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'followServiceActionState failed', error);
  } finally {
    handledServiceActionJobs.add(jobId);
    setServiceActionStateLoading(state, false);
    await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });
    void ForkopShellMethods.uiActionAck('service', jobId);
    followedServiceActionJobs.delete(jobId);
    resetDiagnosticsChecks();
  }
}

function followServiceActionsFromUiState(uiState?: Forkop.UiState) {
  if (!uiState) {
    return;
  }

  for (const action of uiState.actions.service || []) {
    if (action.job_id) {
      void followServiceActionState(action);
    }
  }
}

async function fetchSystemInfo() {
  const systemInfo = await ensureSystemInfo();

  if (store.get().diagnosticsRunAction.loading) {
    return;
  }

  store.set({
    diagnosticsChecks: getDiagnosticsChecks(
      _('Not running'),
      getDiagnosticsProviderOptions(systemInfo),
    ),
  });
}

async function fetchDiagnosticsProviderInfo({
  resetChecks = true,
}: { resetChecks?: boolean } = {}) {
  const requestId = ++latestProviderInfoRequestId;

  try {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (requestId !== latestProviderInfoRequestId) {
      return;
    }

    if (uiState) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = normalizeSingBoxVariantFields({
        ...currentSystemInfo,
        providerInfoLoaded: true,
        sing_box_extended: uiState.capabilities.sing_box_extended,
        sing_box_tiny: uiState.capabilities.sing_box_tiny,
        sing_box_compressed: uiState.capabilities.sing_box_compressed,
        sing_box_tailscale: uiState.capabilities.sing_box_tailscale,
        zapret_installed: uiState.capabilities.zapret_installed,
        zapret2_installed: uiState.capabilities.zapret2_installed,
        byedpi_installed: uiState.capabilities.byedpi_installed,
      });

      if (!nextSystemInfo.zapret_installed) {
        nextSystemInfo.zapret_version = 'not installed';
      }

      if (!nextSystemInfo.zapret2_installed) {
        nextSystemInfo.zapret2_version = 'not installed';
      }

      if (!nextSystemInfo.byedpi_installed) {
        nextSystemInfo.byedpi_version = 'not installed';
      }

      const nextState: Partial<StoreType> = {
        diagnosticsSystemInfo: nextSystemInfo,
      };

      if (
        shouldResetDiagnosticsChecks({
          resetChecks,
          diagnosticsRunLoading: store.get().diagnosticsRunAction.loading,
        })
      ) {
        nextState.diagnosticsChecks = getDiagnosticsChecks(
          _('Not running'),
          getDiagnosticsProviderOptions(nextSystemInfo),
        );
      }

      store.set(nextState);
      return;
    }

    const [zapretRuntime, zapret2Runtime, byedpiRuntime] = await Promise.all([
      ForkopShellMethods.checkZapretRuntime(),
      ForkopShellMethods.checkZapret2Runtime(),
      ForkopShellMethods.checkByedpiRuntime(),
    ]);

    if (requestId !== latestProviderInfoRequestId) {
      return;
    }

    const currentSystemInfo = store.get().diagnosticsSystemInfo;
    const nextSystemInfo = {
      ...currentSystemInfo,
      providerInfoLoaded: true,
      zapret_installed: zapretRuntime.success
        ? zapretRuntime.data.zapret_installed
        : currentSystemInfo.zapret_installed,
      zapret2_installed: zapret2Runtime.success
        ? zapret2Runtime.data.zapret2_installed
        : currentSystemInfo.zapret2_installed,
      byedpi_installed: byedpiRuntime.success
        ? byedpiRuntime.data.byedpi_installed
        : currentSystemInfo.byedpi_installed,
    };

    if (!zapretRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchZapretRuntime failed', zapretRuntime);
    }

    if (!zapret2Runtime.success) {
      logger.error(
        '[DIAGNOSTIC]',
        'fetchZapret2Runtime failed',
        zapret2Runtime,
      );
    }

    if (!byedpiRuntime.success) {
      logger.error('[DIAGNOSTIC]', 'fetchByedpiRuntime failed', byedpiRuntime);
    }

    if (!nextSystemInfo.zapret_installed) {
      nextSystemInfo.zapret_version = 'not installed';
    }

    if (!nextSystemInfo.zapret2_installed) {
      nextSystemInfo.zapret2_version = 'not installed';
    }

    if (!nextSystemInfo.byedpi_installed) {
      nextSystemInfo.byedpi_version = 'not installed';
    }

    const nextState: Partial<StoreType> = {
      diagnosticsSystemInfo: nextSystemInfo,
    };

    if (
      shouldResetDiagnosticsChecks({
        resetChecks,
        diagnosticsRunLoading: store.get().diagnosticsRunAction.loading,
      })
    ) {
      nextState.diagnosticsChecks = getDiagnosticsChecks(
        _('Not running'),
        getDiagnosticsProviderOptions(nextSystemInfo),
      );
    }

    store.set(nextState);
  } catch (error) {
    logger.error('[DIAGNOSTIC]', 'fetchDiagnosticsProviderInfo failed', error);

    if (requestId === latestProviderInfoRequestId) {
      const currentSystemInfo = store.get().diagnosticsSystemInfo;

      store.set({
        diagnosticsSystemInfo: {
          ...currentSystemInfo,
          providerInfoLoaded: true,
        },
      });
    }
  }
}

let retryingCheck: DIAGNOSTICS_CHECKS | null = null;

function renderDiagnosticsChecks() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticsChecks');
  const container = document.getElementById('fkp_diagnostic-page-checks');
  if (!container) return;

  const rendered = renderChecks(store.get().diagnosticsChecks, {
    onRetry: (code) => void retryCheck(code as DIAGNOSTICS_CHECKS),
    busy: store.get().diagnosticsRunAction.loading || retryingCheck !== null,
  });

  return preserveScrollForPage(() => {
    container.replaceChildren(...rendered);
  });
}

// Re-runs one check instead of the whole diagnostics.
async function retryCheck(code: DIAGNOSTICS_CHECKS) {
  if (store.get().diagnosticsRunAction.loading || retryingCheck) return;
  const runner = getDiagnosticRunners(getDiagnosticsProviderOptions()).find(
    (item) => item.code === code,
  );
  if (!runner) return;

  retryingCheck = code;
  setDiagnosticCheckLoading(code);
  try {
    await runner.run();
  } catch (e) {
    logger.error('[DIAGNOSTIC]', `retryCheck - ${code} failed`, e);
  } finally {
    retryingCheck = null;
    renderDiagnosticsChecks();
  }
}

function renderDiagnosticRunActionWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticRunActionWidget');

  const { loading } = store.get().diagnosticsRunAction;
  const container = document.getElementById('fkp_diagnostic-page-run-check');

  const renderedAction = renderRunAction({
    loading,
    disabled: shouldDisableDiagnosticRunAction({
      mutatingServiceActionLoading: isMutatingServiceActionLoading(),
    }),
    click: () => runChecks(),
  });

  const lastRun = document.getElementById('fkp_diagnostic-last-run');
  const reason = document.getElementById('fkp_diagnostic-run-reason');
  // A disabled run button always says why.
  const blocked =
    !loading && isMutatingServiceActionLoading()
      ? _('Waiting for the service action to finish.')
      : null;

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedAction);
    if (lastRun) lastRun.textContent = lastRunText(localStorage);
    reason?.replaceChildren(...(blocked ? [E('span', {}, blocked)] : []));
  });
}

async function handleDiagnosticServiceAction(action: ServiceRuntimeAction) {
  if (isReadonlyMode()) return;
  const { servicesInfoWidget, updatesActions } = store.get();
  const { serviceControlsDisabled } = getAvailableActionsDisabledState({
    servicesInfoLoading: servicesInfoWidget.loading,
    mutatingServiceActionLoading: isMutatingServiceActionLoading(),
    componentActionLoading: hasComponentActionLoading(updatesActions),
  });
  if (serviceControlsDisabled) return;

  const service = servicesInfoWidget.data;
  if (
    (action === 'start' &&
      !shouldShowStartAction({
        forkopRunning: Boolean(service.forkopRunning),
        stopAvailable: Boolean(service.forkopStopAvailable),
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      })) ||
    (action === 'restart' &&
      !shouldShowRestartAction({
        forkopRunning: Boolean(service.forkopRunning),
        restartBlocked: Boolean(service.forkopRestartBlocked),
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      })) ||
    (action === 'stop' &&
      !shouldShowStopAction({
        forkopRunning: Boolean(service.forkopRunning),
        stopAvailable: Boolean(service.forkopStopAvailable),
        restartLoading: false,
        startLoading: false,
        stopLoading: false,
      }))
  )
    return;
  if (action === 'stop' && !(await confirmStopForkop())) return;

  setDiagnosticActionLoading(action, true, true);
  try {
    await runForkopServiceAction(action);
  } catch (error) {
    showToast(serviceActionErrorText(error), 'error', 6000);
  } finally {
    setDiagnosticActionLoading(action, false);
    await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });
    resetDiagnosticsChecks();
  }
}

async function handleDiagnosticAutostart() {
  if (isReadonlyMode()) return;
  const { servicesInfoWidget, updatesActions } = store.get();
  const { serviceControlsDisabled } = getAvailableActionsDisabledState({
    servicesInfoLoading: servicesInfoWidget.loading,
    mutatingServiceActionLoading: isMutatingServiceActionLoading(),
    componentActionLoading: hasComponentActionLoading(updatesActions),
  });
  if (serviceControlsDisabled) return;

  const wanted = !servicesInfoWidget.data.forkopEnabled;
  const action = wanted ? 'enable' : 'disable';
  setDiagnosticActionLoading(action, true, true);
  try {
    if ((await setForkopAutostart(wanted)) !== wanted) {
      showToast(_('Could not change autostart'), 'error', 6000);
    }
  } catch (_error) {
    showToast(_('Could not change autostart'), 'error', 6000);
  } finally {
    setDiagnosticActionLoading(action, false);
    await refreshDiagnosticServicesInfo({ force: true, allowInactive: true });
  }
}

async function handleShowGlobalCheck() {
  setDiagnosticActionLoading('globalCheck', true);

  try {
    // The read-only ACL grants only the masked variant; there is nothing
    // to unmask, so the toggle is not offered.
    const readonly = isReadonlyMode();
    const globalCheck = await ForkopShellMethods.globalCheck(readonly);

    if (globalCheck.success) {
      const rawGlobalCheckText = (globalCheck.data as string) ?? '';
      const maskedGlobalCheckText = maskGlobalCheckText(rawGlobalCheckText);

      ui.showModal(
        _('Global check'),
        renderModal(rawGlobalCheckText, 'global_check', {
          maskText: () => maskedGlobalCheckText,
          initialAutoRefresh: false,
          showMaskValuesToggle: !readonly,
        }),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', globalCheck);
      showToast(_('Could not load data'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowGlobalCheck - e', e);
    showToast(_('Could not load data'), 'error');
  } finally {
    setDiagnosticActionLoading('globalCheck', false);
  }
}

async function handleViewLogs() {
  setDiagnosticActionLoading('viewLogs', true);

  try {
    const viewLogs = await ForkopShellMethods.checkLogs();

    if (viewLogs.success) {
      const getLatestLogs = async () => {
        const latestLogs = await ForkopShellMethods.checkLogs();

        if (!latestLogs.success) {
          throw latestLogs;
        }

        return (latestLogs.data as string) ?? '';
      };

      ui.showModal(
        _('View logs'),
        renderModal(viewLogs.data as string, 'view_logs', {
          getText: getLatestLogs,
          refreshMs: 250,
          initialAutoRefresh: true,
          showAutoRefreshToggle: true,
          startAtEnd: true,
        }),
      );
    } else {
      logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', viewLogs);
      showToast(_('Could not load data'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleViewLogs - e', e);
    showToast(_('Could not load data'), 'error');
  } finally {
    setDiagnosticActionLoading('viewLogs', false);
  }
}

async function handleShowSingBoxConfig() {
  setDiagnosticActionLoading('showSingBoxConfig', true);

  try {
    const readonly = isReadonlyMode();
    const showSingBoxConfig =
      await ForkopShellMethods.showSingBoxConfig(readonly);

    if (showSingBoxConfig.success) {
      const rawSingBoxConfigText = stringifySingBoxConfig(
        showSingBoxConfig.data,
      );
      const maskedSingBoxConfigText = formatMaskedSingBoxConfig(
        showSingBoxConfig.data,
      );

      ui.showModal(
        _('Show sing-box config'),
        renderModal(rawSingBoxConfigText, 'show_sing_box_config', {
          maskText: () => maskedSingBoxConfigText,
          initialAutoRefresh: false,
          showMaskValuesToggle: !readonly,
        }),
      );
    } else {
      logger.error(
        '[DIAGNOSTIC]',
        'handleShowSingBoxConfig - e',
        showSingBoxConfig,
      );
      showToast(_('Could not load data'), 'error');
    }
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'handleShowSingBoxConfig - e', e);
    showToast(_('Could not load data'), 'error');
  } finally {
    setDiagnosticActionLoading('showSingBoxConfig', false);
  }
}

function renderDiagnosticAvailableActionsWidget() {
  const diagnosticsActions = store.get().diagnosticsActions;
  const updatesActions = store.get().updatesActions;
  const servicesInfoWidget = store.get().servicesInfoWidget;
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticAvailableActionsWidget');

  const { serviceControlsDisabled, utilityActionsDisabled, viewLogsDisabled } =
    getAvailableActionsDisabledState({
      servicesInfoLoading: servicesInfoWidget.loading,
      mutatingServiceActionLoading: isMutatingServiceActionLoading(),
      componentActionLoading: hasComponentActionLoading(updatesActions),
    });

  const container = document.getElementById('fkp_diagnostic-page-actions');
  const serviceContainer = document.getElementById(
    'fkp_diagnostic-page-service-actions',
  );
  // The read-only ACL cannot build a support report (it holds raw data).
  const readonly = isReadonlyMode();

  const renderedActions = renderAvailableActions({
    globalCheck: {
      loading: diagnosticsActions.globalCheck.loading,
      visible: true,
      onClick: handleShowGlobalCheck,
      disabled: utilityActionsDisabled,
    },
    viewLogs: {
      loading: diagnosticsActions.viewLogs.loading,
      visible: true,
      onClick: handleViewLogs,
      disabled: viewLogsDisabled,
    },
    showSingBoxConfig: {
      loading: diagnosticsActions.showSingBoxConfig.loading,
      visible: true,
      onClick: handleShowSingBoxConfig,
      disabled: utilityActionsDisabled,
    },
    supportReport: {
      loading: diagnosticsActions.supportReport.loading,
      visible: !readonly,
      onClick: () => void handleDownloadSupportReport(),
      disabled: utilityActionsDisabled,
    },
  });

  const service = servicesInfoWidget.data;
  const renderedServiceActions =
    !readonly && serviceContainer
      ? renderServiceActions({
          start: {
            loading: diagnosticsActions.start.loading,
            visible: shouldShowStartAction({
              forkopRunning: Boolean(service.forkopRunning),
              stopAvailable: Boolean(service.forkopStopAvailable),
              restartLoading: diagnosticsActions.restart.loading,
              startLoading: diagnosticsActions.start.loading,
              stopLoading: diagnosticsActions.stop.loading,
            }),
            disabled: serviceControlsDisabled,
            onClick: () => void handleDiagnosticServiceAction('start'),
          },
          restart: {
            loading: diagnosticsActions.restart.loading,
            visible: shouldShowRestartAction({
              forkopRunning: Boolean(service.forkopRunning),
              restartBlocked: Boolean(service.forkopRestartBlocked),
              restartLoading: diagnosticsActions.restart.loading,
              startLoading: diagnosticsActions.start.loading,
              stopLoading: diagnosticsActions.stop.loading,
            }),
            disabled: serviceControlsDisabled,
            onClick: () => void handleDiagnosticServiceAction('restart'),
          },
          stop: {
            loading: diagnosticsActions.stop.loading,
            visible: shouldShowStopAction({
              forkopRunning: Boolean(service.forkopRunning),
              stopAvailable: Boolean(service.forkopStopAvailable),
              restartLoading: diagnosticsActions.restart.loading,
              startLoading: diagnosticsActions.start.loading,
              stopLoading: diagnosticsActions.stop.loading,
            }),
            disabled: serviceControlsDisabled,
            onClick: () => void handleDiagnosticServiceAction('stop'),
          },
          autostart: {
            enabled: Boolean(service.forkopEnabled),
            loading:
              diagnosticsActions.enable.loading ||
              diagnosticsActions.disable.loading,
            visible: true,
            disabled: serviceControlsDisabled,
            onClick: () => void handleDiagnosticAutostart(),
          },
        })
      : null;

  return preserveScrollForPage(() => {
    if (renderedServiceActions) {
      serviceContainer?.replaceChildren(renderedServiceActions);
    }
    container?.replaceChildren(renderedActions);
  });
}

// Placeholders the backend or the store report as raw words.
function displayValue(value: string) {
  switch (
    String(value ?? '')
      .trim()
      .toLowerCase()
  ) {
    case '':
    case 'unknown':
      return _('unknown');
    case 'loading':
      return _('Loading…');
    case 'not installed':
      return _('Not installed');
    default:
      return value;
  }
}

function renderDiagnosticSystemInfoWidget() {
  logger.debug('[DIAGNOSTIC]', 'renderDiagnosticSystemInfoWidget');
  const diagnosticsSystemInfo = store.get().diagnosticsSystemInfo;

  const container = document.getElementById('fkp_diagnostic-page-system-info');

  const items = [
    {
      key: 'Forkop X',
      value: normalizeCompiledVersion(diagnosticsSystemInfo.forkop_version),
    },
    {
      key: _('LuCI app'),
      value: normalizeCompiledVersion(FORKOP_LUCI_APP_VERSION),
    },
    {
      key: 'sing-box',
      value: formatSingBoxVersion(diagnosticsSystemInfo),
    },
  ];

  if (diagnosticsSystemInfo.zapret_installed) {
    items.push({
      key: 'Zapret',
      value: diagnosticsSystemInfo.zapret_version,
    });
  }

  if (diagnosticsSystemInfo.zapret2_installed) {
    items.push({
      key: 'Zapret2',
      value: diagnosticsSystemInfo.zapret2_version,
    });
  }

  if (diagnosticsSystemInfo.byedpi_installed) {
    items.push({
      key: 'ByeDPI',
      value: diagnosticsSystemInfo.byedpi_version,
    });
  }

  items.push(
    {
      key: _('OS'),
      value: diagnosticsSystemInfo.openwrt_version,
    },
    {
      key: _('Device'),
      value: diagnosticsSystemInfo.device_model,
    },
  );

  const renderedSystemInfo = renderSystemInfo({
    items: items.map((item) => ({ ...item, value: displayValue(item.value) })),
  });

  return preserveScrollForPage(() => {
    container!.replaceChildren(renderedSystemInfo);
  });
}

async function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  // Retry buttons are disabled while a full run is in progress.
  if (diff.diagnosticsChecks || diff.diagnosticsRunAction) {
    renderDiagnosticsChecks();
  }

  if (diff.diagnosticsRunAction) {
    renderDiagnosticRunActionWidget();
  }

  if (
    diff.diagnosticsActions ||
    diff.servicesInfoWidget ||
    diff.updatesActions
  ) {
    renderDiagnosticAvailableActionsWidget();
  }

  if (diff.diagnosticsActions || diff.servicesInfoWidget) {
    renderDiagnosticRunActionWidget();
  }

  if (diff.diagnosticsSystemInfo) {
    renderDiagnosticSystemInfoWidget();
    renderDiagnosticRunActionWidget();
  }
}

function persistDiagnosticRunProgress({
  providerOptions,
  nextRunnerIndex,
}: {
  providerOptions: DiagnosticsProviderOptions;
  nextRunnerIndex: number;
}) {
  savePersistedDiagnosticRun({
    providerOptions,
    nextRunnerIndex,
    diagnosticsChecks: store.get().diagnosticsChecks,
  });
}

function setDiagnosticCheckLoading(code: DIAGNOSTICS_CHECKS) {
  const meta = DIAGNOSTICS_CHECKS_MAP[code];
  const diagnosticsChecks = store.get().diagnosticsChecks;
  const other = diagnosticsChecks.filter((item) => item.code !== code);

  store.set({
    diagnosticsChecks: [
      ...other,
      {
        order: meta.order,
        code: meta.code,
        title: meta.title,
        description: _('Checking, please wait'),
        state: 'loading',
        items: [],
      },
    ],
  });
}

function getDiagnosticRunners(
  providerOptions: DiagnosticsProviderOptions,
): DiagnosticRunner[] {
  return [
    { code: DIAGNOSTICS_CHECKS.DNS, run: runDnsCheck },
    { code: DIAGNOSTICS_CHECKS.SINGBOX, run: runSingBoxCheck },
    { code: DIAGNOSTICS_CHECKS.NFT, run: runNftCheck },
    ...(providerOptions.includeZapret
      ? [{ code: DIAGNOSTICS_CHECKS.ZAPRET, run: runZapretCheck }]
      : []),
    ...(providerOptions.includeZapret2
      ? [{ code: DIAGNOSTICS_CHECKS.ZAPRET2, run: runZapret2Check }]
      : []),
    ...(providerOptions.includeByedpi
      ? [{ code: DIAGNOSTICS_CHECKS.BYEDPI, run: runByedpiCheck }]
      : []),
    { code: DIAGNOSTICS_CHECKS.OUTBOUNDS, run: runSectionsCheck },
    { code: DIAGNOSTICS_CHECKS.FAKEIP, run: runFakeIPCheck },
  ];
}

async function runChecks({ resume }: { resume?: PersistedDiagnosticRun } = {}) {
  if (store.get().diagnosticsRunAction.loading && !resume) {
    return;
  }

  let providerOptions =
    resume?.providerOptions ?? getDiagnosticsProviderOptions();
  let nextRunnerIndex = resume?.nextRunnerIndex ?? 0;

  store.set({
    diagnosticsRunAction: { loading: true },
    diagnosticsChecks:
      resume?.diagnosticsChecks ??
      getLoadingDiagnosticsChecks(providerOptions).diagnosticsChecks,
  });
  persistDiagnosticRunProgress({
    providerOptions,
    nextRunnerIndex,
  });

  try {
    if (!resume) {
      await fetchDiagnosticsProviderInfo({ resetChecks: false });

      providerOptions = getDiagnosticsProviderOptions();
      nextRunnerIndex = 0;

      store.set({
        diagnosticsChecks:
          getLoadingDiagnosticsChecks(providerOptions).diagnosticsChecks,
      });
      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex,
      });
    }

    const runners = getDiagnosticRunners(providerOptions);

    for (let index = nextRunnerIndex; index < runners.length; index += 1) {
      const runner = runners[index];

      setDiagnosticCheckLoading(runner.code);
      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex: index,
      });

      try {
        await runner.run();
      } catch (e) {
        logger.error(
          '[DIAGNOSTIC]',
          `runChecks - ${runner.run.name} failed`,
          e,
        );
      }

      persistDiagnosticRunProgress({
        providerOptions,
        nextRunnerIndex: index + 1,
      });
    }
    saveLastRun(localStorage);
  } catch (e) {
    logger.error('[DIAGNOSTIC]', 'runChecks - e', e);
  } finally {
    clearPersistedDiagnosticRun();
    store.set({ diagnosticsRunAction: { loading: false } });
    if (!diagnosticMounted) {
      diagnosticCompletedWhileHidden = true;
    }
  }
}

async function loadInitialDiagnosticData() {
  const diagnosticStatus = document.getElementById('diagnostic-status');

  if (diagnosticStatus?.isConnected && diagnosticStatus.offsetParent !== null) {
    if (store.get().diagnosticsRunAction.loading) {
      return;
    }

    await fetchSystemInfo();
    await fetchDiagnosticsProviderInfo();
  }
}

function restorePersistedDiagnosticRun() {
  const persistedRun = readPersistedDiagnosticRun();

  if (!persistedRun) {
    return false;
  }

  store.set({
    diagnosticsRunAction: { loading: true },
    diagnosticsChecks: persistedRun.diagnosticsChecks,
  });
  void runChecks({ resume: persistedRun });
  return true;
}

async function onPageMount() {
  const preserveHiddenResult = diagnosticCompletedWhileHidden;

  // Cleanup before mount
  onPageUnmount({
    preserveCompletedResult: preserveHiddenResult,
    preservePersistedRun: true,
  });

  diagnosticMounted = true;
  diagnosticMountId += 1;
  const mountId = diagnosticMountId;
  const hasRuntimeSnapshot = Boolean(getCachedRuntimeUiState());

  if (!hasRuntimeSnapshot) {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!diagnosticMounted || mountId !== diagnosticMountId) {
      return;
    }

    if (!uiState) {
      void refreshDiagnosticServicesInfo({ force: true });
    }
  }

  const restoredPersistedRun =
    !preserveHiddenResult && restorePersistedDiagnosticRun();

  if (preserveHiddenResult) {
    diagnosticCompletedWhileHidden = false;
  } else if (
    !restoredPersistedRun &&
    !store.get().diagnosticsRunAction.loading
  ) {
    store.reset(['diagnosticsRunAction']);
    resetDiagnosticsChecks();
  }

  // Add new listener
  store.subscribe(onStoreUpdate);
  startServiceActionStateWatcher();

  // Initial checks render
  renderDiagnosticsChecks();

  // Initial run checks action render
  renderDiagnosticRunActionWidget();

  // Initial available actions render
  renderDiagnosticAvailableActionsWidget();

  // Initial system info render
  renderDiagnosticSystemInfoWidget();

  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
  if (!preserveHiddenResult && !restoredPersistedRun) {
    void loadInitialDiagnosticData();
  }
}

function onPageUnmount({
  preserveCompletedResult = false,
  preservePersistedRun = false,
}: {
  preserveCompletedResult?: boolean;
  preservePersistedRun?: boolean;
} = {}) {
  diagnosticMounted = false;
  diagnosticMountId += 1;
  stopServiceActionStateWatcher();
  servicesInfoRefreshPromise = null;

  // Remove old listener
  store.unsubscribe(onStoreUpdate);

  if (!preserveCompletedResult && !store.get().diagnosticsRunAction.loading) {
    if (!preservePersistedRun) {
      clearPersistedDiagnosticRun();
    }
    store.reset(['diagnosticsRunAction']);
    resetDiagnosticsChecks();
    diagnosticCompletedWhileHidden = false;
  }
}

function registerLifecycleListeners() {
  if (diagnosticLifecycleRegistered) {
    return;
  }

  diagnosticLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      logger.debug(
        '[DIAGNOSTIC]',
        'active tab diff event, active tab:',
        diff.tabService.current,
      );
      const isDIAGNOSTICVisible = next.tabService.current === 'diagnostic';

      if (isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageMount',
        );
        return onPageMount();
      }

      if (!isDIAGNOSTICVisible) {
        logger.debug(
          '[DIAGNOSTIC]',
          'registerLifecycleListeners',
          'onPageUnmount',
        );
        return onPageUnmount();
      }
    }
  });
}

export async function initController(
  dependencies: {
    loadLocalDeviceChoices?: () => Promise<Record<string, string>>;
  } = {},
): Promise<void> {
  if (diagnosticControllerInitialized) {
    return;
  }

  diagnosticControllerInitialized = true;

  onMount('diagnostic-status').then(() => {
    initSiteCheck(dependencies.loadLocalDeviceChoices);
    initConnectivityMatrix();
    initDpiPlayground();
    logger.debug('[DIAGNOSTIC]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'diagnostic' ||
      isActiveLuciTab('diagnostic')
    ) {
      onPageMount();
    }
  });
}
