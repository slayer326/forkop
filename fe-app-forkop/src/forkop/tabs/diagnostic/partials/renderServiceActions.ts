import { renderButton } from '../../../../partials';

interface ServiceAction {
  loading: boolean;
  disabled: boolean;
  visible: boolean;
  onClick: () => void;
}

interface ServiceActions {
  start: ServiceAction;
  restart: ServiceAction;
  stop: ServiceAction;
  autostart: ServiceAction & { enabled: boolean };
}

export function renderServiceActions(actions: ServiceActions) {
  return E('div', { class: 'fkp-diag-service-actions' }, [
    ...(actions.start.visible
      ? [
          renderButton({
            text: actions.start.loading ? _('Starting…') : _('Start Forkop X'),
            onClick: actions.start.onClick,
            loading: actions.start.loading,
            disabled: actions.start.disabled,
            classNames: ['cbi-button-action'],
          }),
        ]
      : []),
    ...(actions.restart.visible
      ? [
          renderButton({
            text: _('Restart Forkop X'),
            onClick: actions.restart.onClick,
            loading: actions.restart.loading,
            disabled: actions.restart.disabled,
          }),
        ]
      : []),
    ...(actions.stop.visible
      ? [
          renderButton({
            text: _('Stop Forkop X…'),
            onClick: actions.stop.onClick,
            loading: actions.stop.loading,
            disabled: actions.stop.disabled,
            classNames: ['cbi-button-remove'],
          }),
        ]
      : []),
    ...(actions.autostart.visible
      ? [
          renderButton({
            text: actions.autostart.enabled
              ? _('Disable autostart')
              : _('Enable autostart'),
            onClick: actions.autostart.onClick,
            loading: actions.autostart.loading,
            disabled: actions.autostart.disabled,
          }),
        ]
      : []),
  ]);
}
