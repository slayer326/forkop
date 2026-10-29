import { openForkopPage } from '../../helpers/navigation';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus, statusTone } from '../../ui/status';
import type { SemanticStatus } from '../../ui/status';
import type {
  OverviewEvent,
  OverviewLine,
  OverviewRecovery,
  OverviewRouting,
  OverviewState,
  OverviewWarning,
} from './overview';

export interface OverviewViewModel {
  warning: OverviewWarning | null;
  state: OverviewState;
  routing: OverviewRouting;
  recovery: OverviewRecovery;
  event: OverviewEvent | null;
}

export interface OverviewActions {
  readonly: boolean;
  serviceBusy: boolean;
  autostart: boolean;
  // Several sing-box processes, or ownership unclear: a restart cannot prove
  // which one it would replace, so only Stop is offered.
  restartBlocked?: boolean;
  // Something may still intercept traffic although Forkop is not healthy:
  // Stop stays reachable and Start waits for it.
  stopAvailable?: boolean;
  onStart: () => void;
  onRestart: () => void;
  onStop: () => void;
  onToggleAutostart: () => void;
}

function statusView(status: SemanticStatus, label: string) {
  return { label, tone: statusTone(status) };
}

function linkButton(label: string, onClick: () => void) {
  return E(
    'button',
    {
      type: 'button',
      class: 'btn cbi-button fkp-overview__link',
      click: onClick,
    },
    label,
  );
}

function renderLines(lines: OverviewLine[]) {
  return E(
    'ul',
    { class: 'fkp-overview__lines' },
    lines.map((line) =>
      E(
        'li',
        { class: line.tone ? `fkp-overview__line--${line.tone}` : '' },
        line.text,
      ),
    ),
  );
}

function card(
  title: string,
  body: Node[],
  footer: Node[] = [],
  headerExtra: Node[] = [],
) {
  return E('section', { class: 'fkp-overview__card' }, [
    E('div', { class: 'fkp-overview__head' }, [
      E('h3', { class: 'fkp-overview__title' }, title),
      ...headerExtra,
    ]),
    ...body,
    ...(footer.length
      ? [E('div', { class: 'fkp-overview__footer fkp-actions' }, footer)]
      : []),
  ]);
}

function renderWarning(warning: OverviewWarning) {
  return E('section', { class: 'fkp-overview__warning', role: 'alert' }, [
    E('strong', {}, warning.title),
    E('p', {}, warning.text),
    linkButton(warning.link.label, () => openForkopPage(warning.link.page)),
  ]);
}

function renderStateCard(
  state: OverviewState,
  actions: OverviewActions,
  restartRequired: boolean,
) {
  const footer: Node[] = [];
  const menu: Node[] = [];

  if (!actions.readonly) {
    const stopOffered = !state.stopped || actions.stopAvailable === true;
    const restartOffered = actions.restartBlocked !== true;
    if (actions.restartBlocked)
      footer.push(
        E(
          'p',
          { class: 'fkp-overview__hint' },
          _(
            'Multiple sing-box processes were found or their ownership is unclear. Restart is unavailable; traffic routing was not changed. To stop all sing-box processes, use Stop Forkop X, then start Forkop X again.',
          ),
        ),
      );
    // Down, but something still intercepts traffic: the way out is Stop.
    if (state.stopped && actions.stopAvailable) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-remove',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onStop,
          },
          _('Stop Forkop X…'),
        ),
      );
    }
    // A start is refused while a failed change keeps its safety guard: only a
    // restart removes it (UC-019).
    else if (state.stopped && restartRequired && restartOffered) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onRestart,
          },
          _('Restart Forkop X'),
        ),
      );
    } else if (state.stopped) {
      footer.push(
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button cbi-button-action',
            disabled: actions.serviceBusy ? true : undefined,
            click: actions.onStart,
          },
          actions.serviceBusy ? _('Starting…') : _('Start Forkop X'),
        ),
      );
    }
    menu.push(
      renderOverflowMenu(_('Service actions'), [
        ...(!state.stopped && restartOffered
          ? [
              {
                label: _('Restart Forkop X'),
                onClick: actions.onRestart,
                disabled: actions.serviceBusy,
              },
            ]
          : []),
        ...(stopOffered
          ? [
              {
                label: _('Stop Forkop X…'),
                onClick: actions.onStop,
                disabled: actions.serviceBusy,
                danger: true,
              },
            ]
          : []),
        {
          label: actions.autostart
            ? _('Disable autostart')
            : _('Enable autostart'),
          onClick: actions.onToggleAutostart,
          disabled: actions.serviceBusy,
        },
      ]),
    );
  }

  return card(
    _('State'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(state.status, state.title)),
      ]),
      renderLines(state.lines),
    ],
    [
      ...footer,
      linkButton(_('Diagnostics'), () => openForkopPage('diagnostics')),
    ],
    menu,
  );
}

function renderRoutingCard(routing: OverviewRouting, readonly: boolean) {
  return card(
    _('Routing'),
    [
      ...(routing.summary
        ? [E('p', { class: 'fkp-overview__summary' }, routing.summary)]
        : []),
      ...(routing.live
        ? [E('p', { class: 'fkp-overview__hint' }, routing.live)]
        : []),
      ...(routing.groups.length
        ? [
            E(
              'ul',
              { class: 'fkp-overview__groups' },
              routing.groups.map((group) =>
                E('li', {}, [
                  E('span', { class: 'fkp-overview__group-name' }, group.name),
                  E('span', { class: 'fkp-overview__group-node' }, [
                    `${group.node} · `,
                    E(
                      'span',
                      { class: `fkp-status--${group.tone}` },
                      group.latency,
                    ),
                  ]),
                ]),
              ),
            ),
          ]
        : []),
      ...(routing.more
        ? [
            E(
              'p',
              { class: 'fkp-overview__hint' },
              _('%d more groups').replace('%d', String(routing.more)),
            ),
          ]
        : []),
    ],
    [
      linkButton(_('Nodes and groups'), () =>
        openForkopPage('monitoring', { view: 'nodes' }),
      ),
      linkButton(_('Connections'), () => openForkopPage('monitoring')),
      ...(readonly
        ? []
        : [linkButton(_('Rules'), () => openForkopPage('rules'))]),
    ],
  );
}

function renderRecoveryCard(
  recovery: OverviewRecovery,
  actions: OverviewActions,
) {
  // The restart that removes a safety guard a failed change kept (UC-019),
  // whether the runtime runs or not.
  const restart =
    !actions.readonly && recovery.step === 'restart'
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button cbi-button-action',
              disabled: actions.serviceBusy ? true : undefined,
              click: actions.onRestart,
            },
            _('Restart Forkop X'),
          ),
        ]
      : [];
  return card(
    _('Recovery'),
    [
      E('div', { class: 'fkp-overview__status' }, [
        renderStatus(statusView(recovery.status, recovery.title)),
      ]),
      renderLines(recovery.lines),
    ],
    [
      ...restart,
      linkButton(_('Recovery details'), () => openForkopPage('history')),
    ],
  );
}

function renderEventCard(event: OverviewEvent | null) {
  return card(
    _('Last important event'),
    event
      ? [
          E('p', { class: 'fkp-overview__summary' }, [
            `${event.title}: `,
            E(
              'span',
              { class: `fkp-status--${event.outcome.tone}` },
              event.outcome.label,
            ),
          ]),
          E('p', { class: 'fkp-overview__hint' }, event.time),
        ]
      : [E('p', { class: 'fkp-overview__hint' }, _('No events recorded yet'))],
    [linkButton(_('All events'), () => openForkopPage('history'))],
  );
}

export function renderOverview(
  vm: OverviewViewModel,
  actions: OverviewActions,
) {
  return E('div', { class: 'fkp-overview' }, [
    ...(vm.warning ? [renderWarning(vm.warning)] : []),
    E('div', { class: 'fkp-overview__grid' }, [
      renderStateCard(vm.state, actions, vm.recovery.step === 'restart'),
      renderRoutingCard(vm.routing, actions.readonly),
      renderRecoveryCard(vm.recovery, actions),
      renderEventCard(vm.event),
    ]),
  ]);
}
