import { isReadonlyMode } from '../../services/accessMode.service';

function card(id: string, title: string, hint: string, body: Node[]) {
  return E('section', { class: 'fkp-diag-card', id }, [
    E('h3', { class: 'fkp-diag-card__title' }, title),
    hint ? E('p', { class: 'fkp-diag-hint' }, hint) : '',
    ...body,
  ]);
}

function renderDpiValidator() {
  const explanation = E(
    'p',
    { class: 'fkp-diag-hint' },
    _(
      'Checks that the parameters are valid. It does not test site reachability or bypass effectiveness.',
    ),
  );
  if (isReadonlyMode())
    return [
      explanation,
      E(
        'p',
        { class: 'fkp-diag-hint' },
        _('Available to administrators only.'),
      ),
    ];
  return [
    explanation,
    E('div', { class: 'fkp-diag-form' }, [
      E('label', { class: 'fkp-diag-field' }, [
        E('span', {}, _('Provider')),
        E('select', { id: 'dpi-provider', class: 'cbi-input-select' }, [
          E('option', { value: 'zapret' }, 'Zapret'),
          E('option', { value: 'zapret2' }, 'Zapret2'),
          E('option', { value: 'byedpi' }, 'ByeDPI'),
        ]),
      ]),
      E('label', { class: 'fkp-diag-field fkp-diag-field--wide' }, [
        E('span', {}, _('Strategy')),
        E('textarea', {
          id: 'dpi-strategy',
          class: 'cbi-input-textarea',
          maxLength: 4096,
          rows: 3,
          spellcheck: false,
        }),
      ]),
    ]),
    E('div', { class: 'fkp-diag-actions' }, [
      E(
        'button',
        { id: 'dpi-validate', type: 'button', class: 'btn cbi-button' },
        _('Check'),
      ),
      E('span', { id: 'dpi-playground-result', role: 'status' }),
    ]),
  ];
}

const HELP_URL = 'https://github.com/slayer326/forkop#readme';

function renderSiteCheck() {
  return card(
    'site-check',
    _('Check a site or app'),
    _(
      'The route is calculated from the configuration; DNS and the HTTPS request are made by the router itself.',
    ),
    [
      E('div', { class: 'fkp-route__form' }, [
        E('label', { class: 'fkp-diag-field fkp-diag-field--wide' }, [
          E('span', {}, _('Domain or IP address')),
          E('input', {
            id: 'site-check-target',
            class: 'cbi-input-text',
            placeholder: 'youtube.com',
            maxLength: 253,
          }),
        ]),
        E('label', { class: 'fkp-diag-field' }, [
          E('span', {}, _('Device')),
          E('select', { id: 'site-check-device', class: 'cbi-input-select' }, [
            E('option', { value: '' }, _('Any device')),
          ]),
        ]),
        E(
          'button',
          {
            id: 'site-check-run',
            class: 'btn cbi-button cbi-button-apply',
            type: 'button',
          },
          _('Check'),
        ),
      ]),
      E('div', { id: 'site-check-result', role: 'status' }),
    ],
  );
}

export function render() {
  return E('div', { id: 'diagnostic-status', class: 'fkp-diag' }, [
    E('div', { class: 'fkp-diag-primary' }, [
      E('section', { class: 'fkp-diag-card fkp-diag-system' }, [
        E('div', { class: 'fkp-diag-card__head' }, [
          E('div', {}, [
            E('h3', { class: 'fkp-diag-card__title' }, _('System check')),
            E('span', {
              id: 'fkp_diagnostic-last-run',
              class: 'fkp-diag-hint',
              role: 'status',
            }),
          ]),
        ]),
        E('div', { id: 'fkp_diagnostic-page-run-check' }),
        E('div', {
          id: 'fkp_diagnostic-run-reason',
          class: 'fkp-diag-run-reason',
          role: 'status',
        }),
        E('div', {
          class: 'fkp-diag-checks',
          id: 'fkp_diagnostic-page-checks',
        }),
      ]),
      renderSiteCheck(),
      E(
        'details',
        { class: 'fkp-diag-card fkp-diag-details', id: 'connectivity-matrix' },
        [
          E('summary', {}, _('Address set for checking')),
          E(
            'p',
            { class: 'fkp-diag-hint' },
            _(
              'Checks run on the router and do not prove the path of a LAN client.',
            ),
          ),
          E('div', { id: 'connectivity-rows', class: 'fkp-conn' }),
          E('div', { class: 'fkp-diag-actions' }, [
            E(
              'button',
              {
                id: 'connectivity-add',
                type: 'button',
                class: 'btn cbi-button',
              },
              `+ ${_('Add address')}`,
            ),
            E(
              'button',
              {
                id: 'connectivity-run',
                type: 'button',
                class: 'btn cbi-button cbi-button-apply',
              },
              _('Check all'),
            ),
          ]),
        ],
      ),
    ]),
    E('aside', { class: 'fkp-diag-sidebar' }, [
      E('section', { class: 'fkp-diag-card fkp-diag-help' }, [
        E('h3', { class: 'fkp-diag-card__title' }, _('Troubleshooting')),
        E(
          'a',
          { href: HELP_URL, target: '_blank', rel: 'noopener noreferrer' },
          _('Help'),
        ),
      ]),
      E('section', { class: 'fkp-diag-card' }, [
        E('h3', { class: 'fkp-diag-card__title' }, _('Available actions')),
        E('div', { id: 'fkp_diagnostic-page-actions' }),
      ]),
      E('section', { class: 'fkp-diag-card' }, [
        E('div', { id: 'fkp_diagnostic-page-system-info' }),
      ]),
    ]),
    E(
      'details',
      { class: 'fkp-diag-card fkp-diag-details', id: 'technical-data' },
      [
        E('summary', {}, _('Technical data')),
        E('div', { class: 'fkp-diag-subsection', id: 'dpi-playground' }, [
          E('h4', {}, _('DPI strategy syntax check')),
          ...renderDpiValidator(),
        ]),
      ],
    ),
  ]);
}
