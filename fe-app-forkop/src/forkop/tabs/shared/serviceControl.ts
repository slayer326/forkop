import { ForkopShellMethods } from '../../methods';
import { confirmAction } from '../../ui/confirmAction';
import { refreshRuntimeUiState } from '../../services/runtimeUiState.service';
import { store } from '../../services/store.service';

export type ForkopServiceAction = 'start' | 'restart' | 'stop';

// Runs a service action through the same job as Diagnostics; pages follow
// the resulting state through the runtime UI state poller.
export async function runForkopServiceAction(action: ForkopServiceAction) {
  const start = await ForkopShellMethods.serviceActionStart(action);
  if (!start.success) {
    throw new Error(start.error);
  }

  const jobId = start.data.job_id;
  try {
    const result = await ForkopShellMethods.waitServiceActionJob(jobId);
    if (!result.success) {
      throw new Error(result.error);
    }
    if (result.data.success === false) {
      throw new Error(result.data.message || '');
    }
  } finally {
    void ForkopShellMethods.uiActionAck('service', jobId);
  }
}

export function confirmStopForkop() {
  return confirmAction({
    title: _('Stop Forkop X?'),
    message: _('Forkop X stops handling traffic until it is started again.'),
    consequences: [
      _('Routing and DNS rules stop applying'),
      _('Devices keep using the router without Forkop X'),
    ],
    confirmLabel: _('Stop'),
    danger: true,
  });
}

// init.d enable/disable print nothing, so the result is judged by the
// autostart state read back afterwards. Resolves to that state.
export async function setForkopAutostart(enabled: boolean) {
  try {
    await (enabled
      ? ForkopShellMethods.enable()
      : ForkopShellMethods.disable());
  } finally {
    await refreshRuntimeUiState({ force: true });
  }

  return Boolean(store.get().servicesInfoWidget.data.forkopEnabled);
}
