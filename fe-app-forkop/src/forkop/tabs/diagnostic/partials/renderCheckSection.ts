import {
  renderCheckIcon24,
  renderCircleAlertIcon24,
  renderCircleCheckIcon24,
  renderCircleSlashIcon24,
  renderCircleXIcon24,
  renderLoaderCircleIcon24,
  renderTriangleAlertIcon24,
  renderXIcon24,
} from '../../../../icons';
import type { IDiagnosticsChecksStoreItem } from '../../../services';
import { copyToClipboard } from '../../../../helpers/copyToClipboard';
import { openForkopPage } from '../../../helpers/navigation';
import { isReadonlyMode } from '../../../services/accessMode.service';
import { checkStatus, renderStatusBadge } from '../statusLabels';
import {
  checkAdvice,
  checkSummary,
  provenFacts,
  type AdviceLink,
} from '../checkCards';

type Check = IDiagnosticsChecksStoreItem;

export interface CheckHandlers {
  onRetry: (code: string) => void;
  // A full run or another retry is in progress.
  busy: boolean;
}

export function diagnosticActionSummary(props: Check) {
  return [
    props.title,
    props.description,
    ...props.items.map((item) => `${item.key}: ${item.value}`),
  ].join('\n');
}

function itemIcon(state: Check['items'][number]['state']) {
  const icon = E('span', { class: 'fkp-check__item-icon' });
  if (state === 'success') icon.appendChild(renderCheckIcon24());
  if (state === 'warning') icon.appendChild(renderTriangleAlertIcon24());
  if (state === 'error') icon.appendChild(renderXIcon24());
  return icon;
}

function stateIcon(state: Check['state']) {
  switch (state) {
    case 'success':
      return renderCircleCheckIcon24();
    case 'warning':
      return renderCircleAlertIcon24();
    case 'error':
      return renderCircleXIcon24();
    case 'loading':
      return renderLoaderCircleIcon24();
    default:
      return renderCircleSlashIcon24();
  }
}

export function checkDetailsOpen(state: Check['state']) {
  return state === 'error' || state === 'warning';
}

function renderHead(props: Check) {
  const icon = E('span', { class: 'fkp-check__icon' });
  icon.appendChild(stateIcon(props.state));
  return E('div', { class: 'fkp-check__head' }, [
    icon,
    E('b', { class: 'fkp-check__title' }, props.title),
    renderStatusBadge(checkStatus(props.state)),
  ]);
}

function renderItems(props: Check) {
  return props.items.map((item) =>
    E('div', { class: `fkp-check__item fkp-diag-text--${item.state}` }, [
      itemIcon(item.state),
      E('b', {}, item.key),
      E('span', {}, item.value),
    ]),
  );
}

function adviceLink(link: AdviceLink | undefined) {
  // Read-only sessions have no Rules or Settings page and cannot restart the service.
  if (!link || (isReadonlyMode() && link !== 'nodes')) return '';
  const [label, open] =
    link === 'settings'
      ? [_('Open settings'), () => openForkopPage('settings')]
      : link === 'rules'
        ? [_('Open rules'), () => openForkopPage('rules')]
        : link === 'nodes'
          ? [
              _('Nodes and groups'),
              () => openForkopPage('monitoring', { view: 'nodes' }),
            ]
          : [_('Overview'), () => openForkopPage('overview')];
  return E('button', { type: 'button', class: 'btn cbi-button', click: open }, [
    label,
  ]);
}

// Error or warning: what it means, what was proven, what to do.
export function renderCheckSection(props: Check, handlers: CheckHandlers) {
  const status = checkStatus(props.state);
  const advice = checkAdvice(props);
  return E('div', { class: `fkp-check fkp-check--${status.tone}` }, [
    renderHead(props),
    E('div', { class: 'fkp-check__items' }, renderItems(props)),
    ...(advice
      ? [
          E('dl', { class: 'fkp-check__advice' }, [
            E('dt', {}, _('What it means')),
            E('dd', {}, advice.meaning),
            E('dt', {}, _('What was proven')),
            E(
              'dd',
              {},
              E(
                'ul',
                {},
                provenFacts(props).map((fact) => E('li', {}, fact)),
              ),
            ),
            E('dt', {}, _('What to do')),
            E('dd', {}, advice.action),
          ]),
        ]
      : [E('div', { class: 'fkp-check__description' }, props.description)]),
    E('div', { class: 'fkp-check__actions' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          disabled: handlers.busy ? true : undefined,
          click: () => handlers.onRetry(props.code),
        },
        _('Retry this check'),
      ),
      adviceLink(advice?.link),
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () =>
            // navigator.clipboard needs a secure context; LuCI is usually plain HTTP.
            copyToClipboard(diagnosticActionSummary(props)),
        },
        _('Copy details'),
      ),
    ]),
  ]);
}

// Passed checks are also visible: a user should not have to expand a group
// to see which DNS, sing-box or nftables checks succeeded.
export function renderCheckRow(props: Check) {
  const status = checkStatus(props.state);
  return E(
    'div',
    { class: `fkp-check fkp-check--compact fkp-check--${status.tone}` },
    [
      renderHead(props),
      // An unsupported check explains why instead of pretending to have run.
      props.state === 'unsupported'
        ? E('div', { class: 'fkp-check__description' }, props.description)
        : '',
      ...(props.state === 'success'
        ? [
            E('div', { class: 'fkp-check__description' }, props.description),
            E('div', { class: 'fkp-check__items' }, renderItems(props)),
          ]
        : []),
    ],
  );
}

export function renderChecks(checks: Check[], handlers: CheckHandlers) {
  const summary = checkSummary(checks);
  return [
    ...(summary.text
      ? [E('p', { class: 'fkp-diag-summary', role: 'status' }, summary.text)]
      : []),
    ...[...checks]
      .sort((a, b) => a.order - b.order)
      .map((check) =>
        check.state === 'error' || check.state === 'warning'
          ? renderCheckSection(check, handlers)
          : renderCheckRow(check),
      ),
  ];
}
