// A service action of the Overview (start, restart, stop) and the refresh
// that follows it. The buttons stay disabled until both the runtime state
// and the health report are read again: after the restart that removes a
// safety guard a failed change kept (UC-019), the Recovery card must not go on
// offering that restart until its next poll.
export async function runOverviewServiceAction(steps: {
  run: () => Promise<unknown>;
  onError: (error: unknown) => void;
  refreshRuntime: () => Promise<unknown>;
  refreshHealth: () => Promise<unknown>;
  setBusy: (busy: boolean) => void;
}): Promise<void> {
  steps.setBusy(true);
  try {
    await steps.run();
  } catch (error) {
    steps.onError(error);
  } finally {
    try {
      await steps.refreshRuntime();
      await steps.refreshHealth();
    } finally {
      steps.setBusy(false);
    }
  }
}
