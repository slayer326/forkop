import { readPageParams } from '../../helpers/navigation';
import { delegateTabController } from '../../services/tab.service';

// Monitoring has two views: live connections and node selection
// (monitoring#view=nodes). Node selection is run by the dashboard
// controller, so switching views switches the active controller.
export type MonitoringView = 'connections' | 'nodes';

export function readMonitoringView(hash?: string): MonitoringView {
  return readPageParams(hash).view === 'nodes' ? 'nodes' : 'connections';
}

export function controllerForView(view: MonitoringView) {
  return view === 'nodes' ? 'dashboard' : 'monitoring';
}

export function showMonitoringView(view: MonitoringView, updateUrl = true) {
  const connections = document.getElementById('monitoring-view-connections');
  const nodes = document.getElementById('monitoring-view-nodes');
  if (connections) connections.hidden = view !== 'connections';
  if (nodes) nodes.hidden = view !== 'nodes';

  document
    .querySelectorAll<HTMLButtonElement>('.fkp_monitoring-page__view')
    .forEach((button) => {
      const selected = button.dataset.view === view;
      button.setAttribute('aria-pressed', selected ? 'true' : 'false');
      button.classList.toggle('fkp_monitoring-page__tab--active', selected);
    });

  if (updateUrl && typeof history !== 'undefined' && history.replaceState) {
    const url = `${window.location.pathname}${window.location.search}`;
    history.replaceState(
      null,
      '',
      view === 'nodes' ? `${url}#tab=monitoring&view=nodes` : url,
    );
  }

  delegateTabController('monitoring', controllerForView(view));
}
