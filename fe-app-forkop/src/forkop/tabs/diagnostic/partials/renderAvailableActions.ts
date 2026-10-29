import { renderButton } from '../../../../partials';
import {
  renderCircleCheckBigIcon24,
  renderCogIcon24,
  renderDownloadIcon24,
  renderSquareChartGanttIcon24,
} from '../../../../icons';
import { insertIf } from '../../../../helpers';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  disabled: boolean;
  onClick: () => void;
}

interface IRenderAvailableActionsProps {
  globalCheck: ActionProps;
  viewLogs: ActionProps;
  showSingBoxConfig: ActionProps;
  supportReport: ActionProps;
}

// Engineering evidence: checks, logs, the sing-box config, the report. Service control lives on the
// Overview page.
export function renderAvailableActions({
  globalCheck,
  viewLogs,
  showSingBoxConfig,
  supportReport,
}: IRenderAvailableActionsProps) {
  return E('div', { class: 'fkp_diagnostic-page__right-bar__actions' }, [
    ...insertIf(globalCheck.visible, [
      renderButton({
        onClick: globalCheck.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('Get global check'),
        loading: globalCheck.loading,
        disabled: globalCheck.disabled,
      }),
    ]),
    ...insertIf(viewLogs.visible, [
      renderButton({
        onClick: viewLogs.onClick,
        icon: renderSquareChartGanttIcon24,
        text: _('View logs'),
        loading: viewLogs.loading,
        disabled: viewLogs.disabled,
      }),
    ]),
    ...insertIf(showSingBoxConfig.visible, [
      renderButton({
        onClick: showSingBoxConfig.onClick,
        icon: renderCogIcon24,
        text: _('Show sing-box config'),
        loading: showSingBoxConfig.loading,
        disabled: showSingBoxConfig.disabled,
      }),
    ]),
    ...insertIf(supportReport.visible, [
      renderButton({
        onClick: supportReport.onClick,
        icon: renderDownloadIcon24,
        text: _('Download support report'),
        loading: supportReport.loading,
        disabled: supportReport.disabled,
      }),
    ]),
  ]);
}
