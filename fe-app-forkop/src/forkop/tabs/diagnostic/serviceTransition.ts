type LoadingActionState = {
  loading: boolean;
};

type DiagnosticServiceActions = {
  restart: LoadingActionState;
  start: LoadingActionState;
  stop: LoadingActionState;
  enable: LoadingActionState;
  disable: LoadingActionState;
};

type ComponentActions = Record<string, LoadingActionState>;

export function isServiceTransitionStatus(status: string) {
  return ['starting', 'stopping', 'restarting', 'reloading'].includes(status);
}

export function hasLocalMutatingServiceActionLoading(
  actions: DiagnosticServiceActions,
) {
  return (
    actions.restart.loading ||
    actions.start.loading ||
    actions.stop.loading ||
    actions.enable.loading ||
    actions.disable.loading
  );
}

export function shouldSkipServicesInfoAutoRefresh({
  force,
  localMutatingActionLoading,
}: {
  force: boolean;
  localMutatingActionLoading: boolean;
}) {
  return !force && localMutatingActionLoading;
}

export function shouldResetDiagnosticsChecks({
  resetChecks,
  diagnosticsRunLoading,
}: {
  resetChecks: boolean;
  diagnosticsRunLoading: boolean;
}) {
  return resetChecks && !diagnosticsRunLoading;
}

export function shouldDisableDiagnosticRunAction({
  mutatingServiceActionLoading,
}: {
  mutatingServiceActionLoading: boolean;
}) {
  return mutatingServiceActionLoading;
}

export function hasComponentActionLoading(actions: ComponentActions) {
  return Object.values(actions).some((action) => action.loading);
}

export function getAvailableActionsDisabledState({
  servicesInfoLoading,
  mutatingServiceActionLoading,
  componentActionLoading,
}: {
  servicesInfoLoading: boolean;
  mutatingServiceActionLoading: boolean;
  componentActionLoading: boolean;
}) {
  return {
    serviceControlsDisabled:
      servicesInfoLoading ||
      mutatingServiceActionLoading ||
      componentActionLoading,
    utilityActionsDisabled:
      mutatingServiceActionLoading || componentActionLoading,
    viewLogsDisabled: false,
  };
}

export function serviceActionErrorText(error: unknown) {
  const detail = error instanceof Error ? error.message.trim() : '';
  return detail
    ? `${_('Service action failed')}: ${detail}`
    : _('Service action failed');
}

export function shouldShowRestartAction({
  forkopRunning,
  restartBlocked = false,
  restartLoading,
  startLoading,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartBlocked?: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopLoading: boolean;
}) {
  // A restart cannot prove which sing-box it would be replacing, so it is
  // withheld until the runtime has been stopped outright.
  return (
    restartLoading ||
    (forkopRunning && !restartBlocked && !startLoading && !stopLoading)
  );
}

export function shouldShowStartAction({
  forkopRunning,
  restartLoading,
  startLoading,
  stopAvailable = false,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopAvailable?: boolean;
  stopLoading: boolean;
}) {
  return (
    startLoading ||
    (!restartLoading && !forkopRunning && !stopAvailable && !stopLoading)
  );
}

export function shouldShowStopAction({
  forkopRunning,
  restartLoading,
  startLoading,
  stopAvailable = false,
  stopLoading,
}: {
  forkopRunning: boolean;
  restartLoading: boolean;
  startLoading: boolean;
  stopAvailable?: boolean;
  stopLoading: boolean;
}) {
  // Traffic may still be intercepted while Forkop reports unhealthy. Stop is
  // the way out of that state, so it stays reachable.
  return (
    stopLoading ||
    restartLoading ||
    ((forkopRunning || stopAvailable) && !startLoading)
  );
}
