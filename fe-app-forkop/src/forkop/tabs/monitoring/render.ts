import { isReadonlyMode } from '../../services/accessMode.service';
import { renderNodes } from '../dashboard/render';
import { readMonitoringView, showMonitoringView } from './views';

function renderViewSwitch(current: string) {
  return E(
    'div',
    {
      class: 'fkp_monitoring-page__views',
      role: 'group',
      'aria-label': _('Monitoring view'),
    },
    [
      ['connections', _('Connections')],
      ['nodes', _('Nodes and groups')],
    ].map(([view, label]) =>
      E(
        'button',
        {
          type: 'button',
          class: `btn cbi-button fkp_monitoring-page__tab fkp_monitoring-page__view${current === view ? ' fkp_monitoring-page__tab--active' : ''}`,
          'data-view': view,
          'aria-pressed': current === view ? 'true' : 'false',
          click: () => showMonitoringView(view as 'connections' | 'nodes'),
        },
        label,
      ),
    ),
  );
}

function renderConnectionsView(hidden: boolean) {
  return E(
    'div',
    {
      id: 'monitoring-view-connections',
      class: 'fkp_monitoring-page__panel',
      ...(hidden ? { hidden: true } : {}),
    },
    [
      E('div', { class: 'fkp_monitoring-page__controls' }, [
        E('div', { class: 'fkp_monitoring-page__tabs' }, [
          E(
            'button',
            {
              id: 'monitoring-tab-active',
              class:
                'btn cbi-button fkp_monitoring-page__tab fkp_monitoring-page__tab--active',
              type: 'button',
            },
            `${_('Active')} 0`,
          ),
          E(
            'button',
            {
              id: 'monitoring-tab-closed',
              class: 'btn cbi-button fkp_monitoring-page__tab',
              type: 'button',
            },
            `${_('Closed')} 0`,
          ),
          E(
            'button',
            {
              id: 'monitoring-follow-toggle',
              class: 'btn cbi-button fkp_monitoring-page__tab',
              type: 'button',
              'aria-pressed': 'false',
              title: _(
                'Show only connections that start from now on, active and closed',
              ),
            },
            _('Follow new'),
          ),
        ]),
        E('label', { class: 'fkp_monitoring-page__search' }, [
          E('span', { class: 'fkp_monitoring-page__search-icon' }, []),
          E('input', {
            id: 'monitoring-search',
            class: 'cbi-input-text fkp_monitoring-page__search-input',
            type: 'search',
            placeholder: _('Site, IP, device or rule'),
            'aria-label': _('Search'),
            autocomplete: 'off',
          }),
        ]),
        E('div', { class: 'fkp_monitoring-page__actions' }, [
          ...(isReadonlyMode()
            ? []
            : [
                E(
                  'button',
                  {
                    id: 'monitoring-close-all',
                    class: 'btn cbi-button fkp_monitoring-page__icon-button',
                    title: _('Close all connections'),
                    'aria-label': _('Close all connections'),
                    type: 'button',
                    disabled: true,
                  },
                  [],
                ),
              ]),
          E(
            'button',
            {
              id: 'monitoring-pause-toggle',
              class: 'btn cbi-button fkp_monitoring-page__icon-button',
              title: _('Pause updates'),
              'aria-label': _('Pause updates'),
              type: 'button',
            },
            [],
          ),
        ]),
      ]),
      E(
        'details',
        {
          id: 'monitoring-extra-filters',
          class: 'fkp_monitoring-page__filter-disclosure',
        },
        [
          E('summary', { class: 'fkp_monitoring-page__filter-summary' }, [
            _('Filters and sorting'),
            E('span', {
              id: 'monitoring-extra-filter-count',
              class: 'fkp_monitoring-page__filter-count',
              hidden: true,
            }),
          ]),
          E('div', { class: 'fkp_monitoring-page__filters' }, [
            E(
              'select',
              {
                id: 'monitoring-device-filter',
                class: 'cbi-input-select fkp_monitoring-page__device-filter',
                'aria-label': _('Device'),
              },
              [E('option', { value: 'all' }, _('All devices'))],
            ),
            E('select', {
              id: 'monitoring-path-filter',
              class: 'cbi-input-select',
              'aria-label': _('Path'),
            }),
            E(
              'select',
              {
                id: 'monitoring-sort',
                class: 'cbi-input-select',
                'aria-label': _('Sort connections'),
              },
              [
                E('option', { value: 'start' }, _('Start time')),
                E('option', { value: 'duration' }, _('Duration')),
                E('option', { value: 'download' }, _('Download')),
                E('option', { value: 'upload' }, _('Upload')),
                E('option', { value: 'total' }, _('Total traffic')),
              ],
            ),
          ]),
        ],
      ),
      E('div', {
        id: 'monitoring-filter-bar',
        class: 'fkp_monitoring-page__filter-bar',
        role: 'status',
        hidden: true,
      }),
      E(
        'div',
        { id: 'monitoring-connections', class: 'fkp_monitoring-page__body' },
        [
          E(
            'div',
            {
              class:
                'fkp_monitoring-page__state fkp_monitoring-page__state--loading',
            },
            _('Loading connections'),
          ),
        ],
      ),
      E('div', { id: 'monitoring-connection-details', role: 'region' }),
    ],
  );
}

export function render() {
  const view = readMonitoringView();
  return E(
    'div',
    {
      id: 'monitoring-status',
      class: 'fkp_monitoring-page',
    },
    [
      renderViewSwitch(view),
      renderConnectionsView(view !== 'connections'),
      E(
        'div',
        {
          id: 'monitoring-view-nodes',
          class: 'fkp_monitoring-page__nodes',
          ...(view !== 'nodes' ? { hidden: true } : {}),
        },
        [renderNodes()],
      ),
    ],
  );
}
