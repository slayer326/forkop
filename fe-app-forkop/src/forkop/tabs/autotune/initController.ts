import { onMount, preserveScrollForPage } from '../../../helpers';
import { showToast } from '../../../helpers/showToast';
import { openForkopPage } from '../../helpers/navigation';
import { createDomainPicker } from './domainPicker';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { ForkopShellMethods } from '../../methods';
import { logger, store, StoreType } from '../../services';
import { isReadonlyMode } from '../../services/accessMode.service';
import { Forkop } from '../../types';
import { confirmAction } from '../../ui/confirmAction';
import { renderOverflowMenu } from '../../ui/overflowMenu';
import { renderStatus } from '../../ui/status';
import {
  renderEmptyState,
  renderErrorState,
  renderLoadingState,
} from '../../ui/states';
import { formatRelativeTime } from '../../ui/time';
import { historyItems } from '../history/model';
import {
  applyConfirmation,
  applyPhaseLabel,
  applyResultView,
  candidateRows,
  confidenceLabel,
  COOLDOWN_CHOICES,
  durationChoices,
  durationLabel,
  groupCards,
  INTERVAL_CHOICES,
  modeDescription,
  modeLabel,
  MODES,
  mutationErrorText,
  outsideReasonText,
  recordedApplyView,
  rollbackConfirmation,
  rollbackResultView,
  strategyLabel,
  targetIdFor,
  targetRows,
  ruleListLabel,
  listErrorText,
  runProgressView,
  type RunProgressView,
  workerView,
  type ApplyResultView,
  type GroupCard,
  type TargetRow,
} from './model';

const REFRESH_INTERVAL_MS = 15000;
// While a check runs (a scheduled one too) its progress is followed closely.
const RUNNING_REFRESH_INTERVAL_MS = 3000;
let statusLoadedAt = 0;
// Group membership needs a DNS lookup per target on the router: refreshed
// less often, and after every change.
const GROUPS_REFRESH_INTERVAL_MS = 120000;
const JOB_POLL_INTERVAL_MS = 2000;
// A run measures every candidate of every target of the chosen groups.
const JOB_TIMEOUT_MS = 20 * 60 * 1000;
const HISTORY_LIMIT = 5;

let mounted = false;
let mountId = 0;
let refreshTimer: ReturnType<typeof setInterval> | null = null;
let status: Forkop.AutotuneStatus | null = null;
let statusFailed = false;
let live: Forkop.AutotuneGroups | null = null;
let liveFailed = false;
let liveLoadedAt = 0;
let liveLoading = false;
let history: Forkop.HistoryResult | null = null;
let historyFailed = false;
let busy = false;
// Scope of the check started from this page ("all" or a group), if any.
let runningScope: string | null = null;
// The manual apply running now (started here or found running on load).
let applying: {
  group: string;
  candidate: string | null;
  job: string;
  progress: Forkop.AutotuneJob['progress'] | null;
} | null = null;
// The outcome of the last manual apply, shown on its group card.
let applyNotice: { group: string; view: ApplyResultView } | null = null;
// The administrator's rollback of the recorded apply is running.
let rollingBack = false;

// No other change while a change, a check, an apply or a rollback runs.
function locked() {
  return busy || Boolean(runningScope) || Boolean(applying) || rollingBack;
}

function replace(id: string, ...nodes: Node[]) {
  const container = document.getElementById(id);
  if (container)
    preserveScrollForPage(() => container.replaceChildren(...nodes));
}

function formatTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleString();
}

function timeNode(timestamp: number) {
  return E(
    'span',
    { class: 'fkp-autotune__time', title: formatTime(timestamp) },
    formatRelativeTime(timestamp),
  );
}

async function loadStatus() {
  const id = mountId;
  statusLoadedAt = Date.now();
  const [statusResponse, historyResponse] = await Promise.allSettled([
    ForkopShellMethods.autotuneStatus(),
    ForkopShellMethods.getHistory(),
  ]);
  if (!mounted || id !== mountId) return;

  const next =
    statusResponse.status === 'fulfilled' && statusResponse.value.success
      ? statusResponse.value.data
      : null;
  status = next && next.status === 'ok' && next.policy ? next : null;
  statusFailed = !status;
  const events =
    historyResponse.status === 'fulfilled' && historyResponse.value.success
      ? historyResponse.value.data
      : null;
  history = events && Array.isArray(events.events) ? events : null;
  historyFailed = !history;
  resumeApply();
  renderAll();
}

async function loadGroups() {
  if (liveLoading) return;
  const id = mountId;
  liveLoading = true;
  try {
    const response = await ForkopShellMethods.autotuneGroups();
    if (!mounted || id !== mountId) return;
    const data = response.success ? response.data : null;
    live = data && data.status === 'ok' && data.groups ? data : null;
    liveFailed = !live;
    liveLoadedAt = Date.now();
  } finally {
    liveLoading = false;
  }
  if (mounted && id === mountId) renderAll();
}

async function loadAll() {
  await Promise.all([loadStatus(), loadGroups()]);
}

// ---- actions -----------------------------------------------------------

async function mutate(
  action: () => Promise<Forkop.MethodResponse<Forkop.AutotuneMutationResult>>,
  success: string,
) {
  if (locked()) return false;
  busy = true;
  renderAll();
  let ok = false;
  try {
    const result = await action();
    const data = result.success ? result.data : null;
    ok = data?.status === 'ok';
    if (ok) showToast(success, 'success');
    else showToast(mutationErrorText(data?.reason), 'error', 8000);
  } catch (error) {
    logger.error('[AUTOTUNE]', 'action failed', error);
    showToast(mutationErrorText(undefined), 'error');
  } finally {
    busy = false;
  }
  await loadAll();
  return ok;
}

async function setMode(mode: Forkop.AutotuneMode) {
  if (!status || status.policy.mode === mode) return;
  await mutate(
    () => ForkopShellMethods.autotunePolicySet('mode', mode),
    _('Autotune mode changed'),
  );
}

async function pollJob(jobId: string) {
  const started = Date.now();
  while (mounted && Date.now() - started < JOB_TIMEOUT_MS) {
    await new Promise((resolve) => setTimeout(resolve, JOB_POLL_INTERVAL_MS));
    const response = await ForkopShellMethods.autotuneRunStatus(jobId);
    const job = response.success ? response.data.job : undefined;
    if (!job) continue;
    if (job.state === 'finished') {
      const result = job.result;
      if (result?.status === 'ok' && result.result === 'completed')
        showToast(_('Check completed'), 'success');
      else if (result?.status === 'busy')
        showToast(_('A check is already running.'), 'warning', 6000);
      else if (result?.result === 'skipped')
        showToast(
          _('The check was postponed. See the state above.'),
          'warning',
          8000,
        );
      else showToast(_('The check did not complete'), 'error', 8000);
      return;
    }
    if (job.state === 'lost') {
      showToast(_('The check stopped unexpectedly'), 'error', 8000);
      return;
    }
    if (mounted) void loadStatus();
  }
}

// ---- manual apply ------------------------------------------------------

function toastType(tone: ApplyResultView['tone']) {
  return tone === 'neutral' ? 'info' : tone;
}

async function pollApply() {
  const started = Date.now();
  while (mounted && applying && Date.now() - started < JOB_TIMEOUT_MS) {
    const current = applying;
    const response = await ForkopShellMethods.autotuneRunStatus(current.job);
    const job = response.success ? response.data.job : undefined;
    if (!mounted || applying !== current) return;
    if (job && (job.state === 'finished' || job.state === 'lost')) {
      const view = applyResultView(
        job.state === 'finished' ? job.result : null,
        job.result?.candidate ?? current.candidate,
      );
      applying = null;
      applyNotice = { group: current.group, view };
      showToast(
        view.text,
        toastType(view.tone),
        view.attention ? 15000 : 10000,
      );
      await loadAll();
      return;
    }
    if (job?.progress) {
      current.progress = job.progress;
      renderAll();
    }
    await new Promise((resolve) => setTimeout(resolve, JOB_POLL_INTERVAL_MS));
  }
}

// A page opened (or reloaded) while a manual apply runs follows it.
function resumeApply() {
  const worker = status?.worker;
  if (
    applying ||
    !worker ||
    worker.state !== 'running' ||
    worker.kind !== 'apply' ||
    !worker.job
  )
    return;
  applying = {
    group: worker.group ?? worker.scope ?? '',
    candidate: worker.candidate ?? null,
    job: worker.job,
    progress: null,
  };
  void pollApply();
}

async function applyGroup(card: GroupCard) {
  if (locked() || !card.applyCandidate) return;
  const confirmed = await confirmAction(applyConfirmation(card));
  if (!confirmed || locked()) return;
  applyNotice = null;
  busy = true;
  renderAll();
  try {
    const response = await ForkopShellMethods.autotuneApplyAsync(card.id);
    const data = response.success ? response.data : null;
    if (data?.status === 'ok' && data.job) {
      applying = {
        group: card.id,
        candidate: card.applyCandidate,
        job: data.job,
        progress: null,
      };
    } else if (data?.status === 'busy') {
      showToast(_('Another autotune operation is running.'), 'warning', 6000);
    } else {
      showToast(_('Could not start the apply'), 'error', 8000);
    }
  } catch (error) {
    logger.error('[AUTOTUNE]', 'apply failed', error);
    showToast(_('Could not start the apply'), 'error', 8000);
  } finally {
    busy = false;
  }
  renderAll();
  if (applying) await pollApply();
}

// ---- rollback of the recorded apply ---------------------------------------

function recordedGroupTitle(apply: Forkop.AutotuneRecordedApply) {
  if (!apply.group) return null;
  return (
    live?.groups[apply.group]?.label ??
    status?.groups?.[apply.group]?.label ??
    apply.group
  );
}

async function rollbackApply() {
  const apply = status?.apply;
  if (locked() || !apply?.rollback) return;
  const confirmed = await confirmAction(
    rollbackConfirmation(apply, recordedGroupTitle(apply)),
  );
  if (!confirmed || locked()) return;
  rollingBack = true;
  renderAll();
  try {
    const response = await ForkopShellMethods.autotuneRollback();
    const view = rollbackResultView(response.success ? response.data : null);
    showToast(view.text, toastType(view.tone), view.attention ? 15000 : 10000);
  } catch (error) {
    logger.error('[AUTOTUNE]', 'rollback failed', error);
    // No answer: the rollback may still run on the router.
    const view = rollbackResultView(null);
    showToast(view.text, toastType(view.tone), 10000);
  } finally {
    rollingBack = false;
  }
  if (mounted) await loadAll();
}

async function runCheck(scope: string) {
  if (locked()) return;
  runningScope = scope;
  renderAll();
  try {
    const response = await ForkopShellMethods.autotuneRunAsync(scope);
    const data = response.success ? response.data : null;
    if (data?.status === 'ok' && data.job) {
      showToast(
        _(
          'Check started. Targets are measured in isolation; production traffic is not changed.',
        ),
        'info',
        6000,
      );
      await pollJob(data.job);
    } else if (data?.status === 'busy') {
      showToast(_('A check is already running.'), 'warning', 6000);
    } else {
      showToast(_('Could not start the check'), 'error', 8000);
    }
  } catch (error) {
    logger.error('[AUTOTUNE]', 'run failed', error);
    showToast(_('Could not start the check'), 'error', 8000);
  } finally {
    runningScope = null;
  }
  if (mounted) await loadAll();
}

function field(label: string, control: HTMLElement, hint?: string) {
  return [
    E('label', {}, label),
    control,
    ...(hint ? [E('div', { class: 'fkp-autotune__field-hint' }, hint)] : []),
  ];
}

function select(name: string, choices: [string, string][], value: string) {
  return E(
    'select',
    { class: 'cbi-input-select', name },
    choices.map(([key, label]) =>
      E(
        'option',
        { value: key, selected: key === value ? true : undefined },
        label,
      ),
    ),
  ) as HTMLSelectElement;
}

function numberInput(name: string, value: number, min: number, max: number) {
  return E('input', {
    class: 'cbi-input-text',
    type: 'number',
    name,
    min: String(min),
    max: String(max),
    step: '1',
    value: String(value),
  }) as HTMLInputElement;
}

function modalActions(onSave: () => void, saveLabel: string) {
  return E('div', { class: 'fkp-confirm__actions' }, [
    E(
      'button',
      { type: 'button', class: 'btn cbi-button', click: () => ui.hideModal() },
      _('Cancel'),
    ),
    E(
      'button',
      { type: 'button', class: 'btn cbi-button-action', click: onSave },
      saveLabel,
    ),
  ]);
}

function showPolicyEditor() {
  if (!status) return;
  const policy = status.policy;
  const controls = {
    interval: select(
      'interval',
      durationChoices(INTERVAL_CHOICES, policy.interval).map((v) => [
        v,
        durationLabel(v),
      ]),
      policy.interval,
    ),
    confirmations: numberInput('confirmations', policy.confirmations, 2, 10),
    min_confidence: select(
      'min_confidence',
      [
        ['high', confidenceLabel('high')],
        ['medium', confidenceLabel('medium')],
      ],
      policy.min_confidence,
    ),
    cooldown: select(
      'cooldown',
      durationChoices(COOLDOWN_CHOICES, policy.cooldown).map((v) => [
        v,
        durationLabel(v),
      ]),
      policy.cooldown,
    ),
    probes: numberInput('probes', policy.probes, 3, 7),
  };

  const save = async () => {
    const changes: [string, string][] = [];
    for (const [key, control] of Object.entries(controls)) {
      const current = String(policy[key as keyof Forkop.AutotunePolicy]);
      if (control.value !== current) changes.push([key, control.value]);
    }
    ui.hideModal();
    if (!changes.length) return;
    // One option per call: each is validated and committed on its own.
    for (const [key, value] of changes) {
      const ok = await mutate(
        () => ForkopShellMethods.autotunePolicySet(key, value),
        _('Policy saved'),
      );
      if (!ok) break;
    }
  };

  ui.showModal(_('Autotune policy'), [
    E('div', { class: 'fkp-autotune__form' }, [
      ...field(_('Check every'), controls.interval),
      ...field(
        _('Confirmations'),
        controls.confirmations,
        _('The same result this many checks in a row (2–10).'),
      ),
      ...field(_('Minimum confidence'), controls.min_confidence),
      ...field(
        _('Pause after a rollback'),
        controls.cooldown,
        _(
          'A rolled back strategy is not applied again before this time passes.',
        ),
      ),
      ...field(
        _('Probes per strategy'),
        controls.probes,
        _('3–7 attempts per strategy and target in each check.'),
      ),
    ]),
    modalActions(() => void save(), _('Save')),
  ] as unknown as HTMLElement);
}

function showTargetEditor(target?: Forkop.AutotuneTarget) {
  if (!status) return;
  const lists = status.lists ?? [];
  // A domain, or a list of a DPI rule measured through a few of its domains.
  const kind = E('select', { class: 'cbi-input-select', name: 'kind' }, [
    E('option', { value: 'host' }, _('Domain')),
    E(
      'option',
      { value: 'list', disabled: lists.length ? undefined : true },
      _('List of a rule'),
    ),
  ]) as HTMLSelectElement;
  kind.value = target?.rule_set ? 'list' : 'host';
  const ruleSet = E('select', { class: 'cbi-input-select', name: 'rule_set' }, [
    ...lists.map((l) =>
      E('option', { value: l.tag }, ruleListLabel(l.tag, lists)),
    ),
    // A configured list the routing no longer sends to a DPI rule.
    ...(target?.rule_set && !lists.some((l) => l.tag === target.rule_set)
      ? [
          E(
            'option',
            { value: target.rule_set },
            ruleListLabel(target.rule_set, lists),
          ),
        ]
      : []),
  ]) as HTMLSelectElement;
  if (target?.rule_set) ruleSet.value = target.rule_set;
  const sample = E('input', {
    class: 'cbi-input-text',
    type: 'number',
    min: '1',
    max: '8',
    name: 'sample',
    value: String(target?.sample ?? 3),
  }) as HTMLInputElement;
  // Domains of the list: a sample taken automatically, or chosen by hand.
  const choice = select(
    'domain_choice',
    [
      ['auto', _('Automatically')],
      ['manual', _('Choose from the list')],
    ],
    target?.pins?.length ? 'manual' : 'auto',
  ) as HTMLSelectElement;
  const picker = createDomainPicker(
    target?.pins ?? [],
    async (tag) => {
      const response = await ForkopShellMethods.autotuneListDomains(tag);
      const data = response.success ? response.data : null;
      return data?.status === 'ok'
        ? {
            domains: data.domains ?? [],
            truncated: data.truncated === true,
            error: null,
          }
        : {
            domains: [],
            truncated: false,
            error: data?.reason ?? 'list_unreadable',
          };
    },
    listErrorText,
  );
  const host = E('input', {
    class: 'cbi-input-text',
    type: 'text',
    name: 'host',
    value: target?.host ?? '',
    placeholder: 'youtube.com',
    autocomplete: 'off',
  }) as HTMLInputElement;
  const resolver = E('input', {
    class: 'cbi-input-text',
    type: 'text',
    name: 'resolver',
    value: target?.resolver ?? '',
    placeholder: _('Router DNS'),
    autocomplete: 'off',
  }) as HTMLInputElement;
  const enabled = E('input', {
    type: 'checkbox',
    name: 'enabled',
    checked: target ? (target.enabled ? true : undefined) : true,
  }) as HTMLInputElement;

  const save = async () => {
    const isList = kind.value === 'list';
    const value = host.value.trim().toLowerCase();
    if (!isList && !value) {
      showToast(mutationErrorText('invalid_host'), 'error');
      return;
    }
    if (isList && !ruleSet.value) {
      showToast(mutationErrorText('invalid_rule_set'), 'error');
      return;
    }
    const manual = choice.value === 'manual';
    if (isList && manual && !picker.selected().length) {
      showToast(_('Choose at least one domain of the list.'), 'error');
      return;
    }
    ui.hideModal();
    const taken = status?.targets.map((t) => t.id) ?? [];
    const id =
      target?.id ??
      (isList
        ? targetIdFor(ruleSet.value.replace(/-ruleset$/, ''), taken, 'l_')
        : targetIdFor(value, taken));
    await mutate(
      () =>
        ForkopShellMethods.autotuneTargetSet(
          id,
          isList ? '' : value,
          enabled.checked,
          resolver.value.trim(),
          isList
            ? {
                ruleSet: ruleSet.value,
                sample: sample.value.trim(),
                pins: manual ? picker.selected() : [],
              }
            : undefined,
        ),
      _('Target saved'),
    );
  };

  const hostFields = field(
    _('Domain'),
    host,
    _('A site or service checked through the DPI rule that routes it.'),
  );
  const listFields = [
    ...field(
      _('List'),
      ruleSet,
      _(
        'A list of a DPI rule. Each check takes a few of its domains; keywords and regular expressions are skipped.',
      ),
    ),
    ...field(_('Which domains to check'), choice),
  ];
  const autoFields = field(
    _('Domains to check'),
    sample,
    _(
      '1–8 domains, spread evenly over the list; a domain without an address is replaced by the next one.',
    ),
  );
  const manualFields = field(
    _('Domains of the list'),
    picker.element,
    _('Up to 8 domains; exactly these are checked.'),
  );
  const show = (els: Node[], visible: boolean) => {
    for (const el of els)
      (el as HTMLElement).style.display = visible ? '' : 'none';
  };
  const showKind = () => {
    const isList = kind.value === 'list';
    const manual = choice.value === 'manual';
    show(hostFields, !isList);
    show(listFields, isList);
    show(autoFields, isList && !manual);
    show(manualFields, isList && manual);
    if (isList && manual && ruleSet.value) void picker.show(ruleSet.value);
  };
  kind.addEventListener('change', showKind);
  choice.addEventListener('change', showKind);
  ruleSet.addEventListener('change', showKind);
  showKind();

  ui.showModal(target ? _('Edit target') : _('Add target'), [
    E('div', { class: 'fkp-autotune__form' }, [
      ...field(
        _('What to check'),
        kind,
        lists.length
          ? _(
              'A domain, or a list of a DPI rule measured through a few of its domains.',
            )
          : _('No DPI rule has a downloaded list; only domains can be added.'),
      ),
      ...hostFields,
      ...listFields,
      ...autoFields,
      ...manualFields,
      ...field(
        _('DNS server for checks'),
        resolver,
        _(
          'Optional IPv4 address. By default the first IPv4 DNS server of Forkop X is used.',
        ),
      ),
      ...field(_('Enabled'), enabled),
    ]),
    modalActions(() => void save(), _('Save')),
  ] as unknown as HTMLElement);
}

async function removeTarget(target: Forkop.AutotuneTarget) {
  const confirmed = await confirmAction({
    title: _('Remove target?'),
    message: `${target.host ?? ruleListLabel(target.rule_set ?? target.id, status?.lists)}. ${_('Its measurements are deleted as well. Routing rules are not changed.')}`,
    confirmLabel: _('Remove'),
    danger: true,
  });
  if (!confirmed) return;
  await mutate(
    () => ForkopShellMethods.autotuneTargetRemove(target.id),
    _('Target removed'),
  );
}

function showCandidates(target: Forkop.AutotuneTarget) {
  const last = target.last;
  if (!last) return;
  const rows = candidateRows(last);
  ui.showModal(`${target.host ?? target.id}: ${_('last check')}`, [
    E(
      'p',
      { class: 'fkp-autotune__muted' },
      `${formatTime(last.at)} · ${_('measured in isolation from production traffic')}`,
    ),
    rows.length
      ? E('div', { class: 'fkp-autotune__table-wrap' }, [
          E('table', { class: 'table fkp-autotune__table' }, [
            E('tr', { class: 'tr table-titles' }, [
              E('th', { class: 'th' }, _('Strategy')),
              E('th', { class: 'th' }, _('Successful')),
              E('th', { class: 'th' }, _('Stability')),
              E('th', { class: 'th' }, _('TLS, median')),
            ]),
            ...rows.map((row) =>
              E('tr', { class: 'tr' }, [
                E(
                  'td',
                  { class: 'td' },
                  row.selected ? `${row.name} ★` : row.name,
                ),
                E('td', { class: 'td' }, row.result),
                E('td', { class: 'td' }, renderStatus(row.stability)),
                E('td', { class: 'td' }, row.latency),
              ]),
            ),
          ]),
        ])
      : E('p', {}, _('No strategies were measured')),
    E('div', { class: 'fkp-confirm__actions' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => ui.hideModal(),
        },
        _('Close'),
      ),
    ]),
  ] as unknown as HTMLElement);
}

// ---- rendering ---------------------------------------------------------

function policySummary(policy: Forkop.AutotunePolicy) {
  return [
    _('every %s').replace('%s', durationLabel(policy.interval)),
    _('%d confirmations').replace('%d', String(policy.confirmations)),
    _('pause after a rollback %s').replace(
      '%s',
      durationLabel(policy.cooldown),
    ),
  ].join(' · ');
}

function renderState() {
  const readonly = isReadonlyMode();
  if (!status) {
    replace(
      'autotune-state',
      statusFailed
        ? renderErrorState(
            _('Autotune state is unavailable'),
            () => void loadAll(),
          )
        : renderLoadingState(),
    );
    replace('autotune-state-actions');
    return;
  }

  const policy = status.policy;
  const worker = workerView(status.worker);
  const facts: [string, Node | string][] = [
    [
      _('Mode'),
      readonly
        ? modeLabel(policy.mode)
        : E(
            'div',
            {
              class: 'fkp-autotune__modes',
              role: 'group',
              'aria-label': _('Mode'),
            },
            MODES.map((mode) =>
              E(
                'button',
                {
                  type: 'button',
                  class: 'btn cbi-button',
                  'aria-pressed': mode === policy.mode ? 'true' : 'false',
                  disabled: locked() ? true : undefined,
                  click: () => void setMode(mode),
                },
                modeLabel(mode),
              ),
            ),
          ),
    ],
    [
      '',
      E('p', { class: 'fkp-autotune__muted' }, modeDescription(policy.mode)),
    ],
    [_('Policy'), policySummary(policy)],
  ];
  if (rollingBack)
    facts.push([
      _('State'),
      renderStatus({
        label: _('Rolling back the last change'),
        tone: 'loading',
      }),
    ]);
  else if (applying)
    facts.push([
      _('State'),
      renderStatus({ label: _('Applying a strategy'), tone: 'loading' }),
    ]);
  else if (runningScope || status.worker?.state === 'running') {
    const run = runProgressView(status.worker, Math.floor(Date.now() / 1000));
    facts.push([
      _('State'),
      run
        ? renderRunProgress(run)
        : renderStatus(
            worker ?? { label: _('Checking targets'), tone: 'loading' },
          ),
    ]);
  } else if (worker && status.worker?.finished_at)
    facts.push([
      _('Last check'),
      E('span', { class: 'fkp-autotune__row' }, [
        renderStatus(worker),
        timeNode(status.worker.finished_at),
      ]),
    ]);
  else if (worker) facts.push([_('Last check'), renderStatus(worker)]);
  else facts.push([_('Last check'), _('Not checked yet')]);
  if (policy.mode !== 'off' && status.next_run_at)
    facts.push([_('Next scheduled check'), formatTime(status.next_run_at)]);
  if (status.recovered_at)
    facts.push([
      _('Warning'),
      renderStatus({
        label: _(
          'The autotune state was damaged and has been reset; automatic changes wait for the pause after a rollback.',
        ),
        tone: 'warning',
      }),
    ]);
  const recorded = status.apply
    ? recordedApplyView(status.apply, recordedGroupTitle(status.apply))
    : null;
  if (recorded)
    facts.push([
      _('Last change'),
      recorded.attention
        ? E('div', { class: 'fkp-autotune__alert', role: 'alert' }, [
            E('strong', {}, _('Action required')),
            E('p', {}, recorded.text),
            ...(readonly && status.apply?.rollback
              ? [
                  E(
                    'p',
                    { class: 'fkp-autotune__muted' },
                    _('An administrator can roll it back.'),
                  ),
                ]
              : []),
          ])
        : renderStatus({ label: recorded.text, tone: recorded.tone }),
    ]);
  if (status.errors.length)
    facts.push([
      _('Warning'),
      renderStatus({
        label: _(
          'Some autotune settings are invalid; safe defaults are used for them.',
        ),
        tone: 'warning',
      }),
    ]);

  replace(
    'autotune-state',
    E(
      'dl',
      { class: 'fkp-autotune__facts' },
      facts.flatMap(([label, value]) => [
        E('dt', {}, label),
        E('dd', {}, value),
      ]),
    ),
  );

  replace(
    'autotune-state-actions',
    ...(readonly
      ? []
      : [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled: locked() ? true : undefined,
              click: () => showPolicyEditor(),
            },
            _('Policy…'),
          ),
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button-action',
              disabled: locked() || !status.targets.length ? true : undefined,
              title: !status.targets.length
                ? _('Add a target first')
                : undefined,
              click: () => void runCheck('all'),
            },
            runningScope === 'all' ? _('Checking…') : _('Check all now'),
          ),
          ...(status.apply?.rollback
            ? [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button-negative',
                    disabled: locked() ? true : undefined,
                    click: () => void rollbackApply(),
                  },
                  rollingBack
                    ? _('Rolling back…')
                    : _('Roll back the last change…'),
                ),
              ]
            : []),
        ]),
  );
}

// A running check: a bar, the target measured now and its phase, the time
// left, and every target of the run with its result as it comes.
function renderRunProgress(run: RunProgressView) {
  const icon: Record<string, string> = {
    done: '✓',
    skipped: '!',
    running: '…',
    pending: '·',
  };
  const bar = E('div', { class: 'fkp-autotune__bar' }, [
    E('div', { style: `width: ${run.percent}%` }),
  ]) as HTMLElement;
  bar.setAttribute('role', 'progressbar');
  bar.setAttribute('aria-valuemin', '0');
  bar.setAttribute('aria-valuemax', '100');
  bar.setAttribute('aria-valuenow', String(run.percent));
  return E('div', { class: 'fkp-autotune__run' }, [
    E('div', { class: 'fkp-autotune__row' }, [
      renderStatus({ label: _('Checking targets'), tone: 'loading' }),
      E('strong', {}, `${run.percent}%`),
      ...(run.remaining
        ? [
            E(
              'span',
              { class: 'fkp-autotune__muted' },
              `${_('left')}: ${run.remaining}`,
            ),
          ]
        : []),
    ]),
    bar,
    E('div', {}, [
      E('strong', {}, run.title),
      ...(run.phase ? [' — ', run.phase] : []),
    ]),
    E(
      'ul',
      { class: 'fkp-autotune__run-items' },
      run.items.map((item) =>
        E(
          'li',
          {
            class: `fkp-autotune__run-item fkp-autotune__run-item--${item.state}`,
          },
          [
            E(
              'span',
              { class: 'fkp-autotune__run-icon' },
              icon[item.state] ?? '·',
            ),
            E('span', { class: 'fkp-autotune__what' }, item.host),
            renderStatus({ label: item.text, tone: item.tone }),
          ],
        ),
      ),
    ),
    E(
      'p',
      { class: 'fkp-autotune__muted' },
      _(
        'Each target is measured in isolation; production traffic is not changed. After the probes Forkop X waits until their connections close, which can take a few minutes on a blocked site.',
      ),
    ),
  ]);
}

function renderProgress(progress: NonNullable<GroupCard['progress']>) {
  return E('span', { class: 'fkp-autotune__row' }, [
    E(
      'span',
      { class: 'fkp-autotune__progress' },
      Array.from({ length: progress.required }, (_unused, index) =>
        E('span', {
          class: `fkp-autotune__dot${index < progress.count ? ' fkp-autotune__dot--on' : ''}`,
        }),
      ),
    ),
    _('Confirmation %d / %d')
      .replace('%d', String(progress.count))
      .replace('%d', String(progress.required)),
  ]);
}

function renderApplyNotice(view: ApplyResultView) {
  if (!view.attention)
    return renderStatus({ label: view.text, tone: view.tone });
  return E('div', { class: 'fkp-autotune__alert', role: 'alert' }, [
    E('strong', {}, _('Action required')),
    E('p', {}, view.text),
    E(
      'button',
      {
        type: 'button',
        class: 'btn cbi-button-action',
        click: () => openForkopPage('history'),
      },
      _('Open History and recovery'),
    ),
  ]);
}

function renderGroup(card: GroupCard) {
  const readonly = isReadonlyMode();
  const facts: [string, Node | string][] = [[_('Now'), card.current]];
  if (card.recommended)
    facts.push([_('Recommended'), strategyLabel(card.recommended)]);
  if (card.confidence)
    facts.push([_('Confidence'), confidenceLabel(card.confidence)]);
  if (card.progress)
    facts.push([_('Confirmation'), renderProgress(card.progress)]);
  if (card.checkedAt) facts.push([_('Checked'), timeNode(card.checkedAt)]);
  if (card.lastApply)
    facts.push([
      _('Last change'),
      E('span', { class: 'fkp-autotune__row' }, [
        `${card.lastApply.candidate}:`,
        renderStatus(card.lastApply.outcome),
        timeNode(card.lastApply.at),
      ]),
    ]);
  for (const cooldown of card.cooldowns)
    facts.push([
      _('Pause'),
      _('%s is not applied again before %t')
        .replace('%s', cooldown.candidate)
        .replace('%t', formatTime(cooldown.until)),
    ]);
  facts.push([_('Targets'), card.targets.join(', ') || '—']);

  return E('li', { class: 'fkp-autotune__group' }, [
    E('div', { class: 'fkp-autotune__row' }, [
      E(
        'span',
        { class: 'fkp-autotune__name' },
        `${card.title} · ${_('Zapret rule')}`,
      ),
      renderStatus(card.badge),
    ]),
    E(
      'dl',
      { class: 'fkp-autotune__facts' },
      facts.flatMap(([label, value]) => [
        E('dt', {}, label),
        E('dd', {}, value),
      ]),
    ),
    ...card.explanation.map((text) =>
      E('p', { class: 'fkp-autotune__text' }, text),
    ),
    ...(card.manualHint
      ? [
          E(
            'p',
            { class: 'fkp-autotune__muted' },
            _(
              'Autotune is off. To apply the recommendation, switch to "Recommendations only" and apply it here.',
            ),
          ),
        ]
      : []),
    ...(applying?.group === card.id
      ? [
          renderStatus({
            label: applyPhaseLabel(applying.progress),
            tone: 'loading',
          }),
        ]
      : []),
    ...(applyNotice?.group === card.id
      ? [renderApplyNotice(applyNotice.view)]
      : []),
    ...(readonly
      ? []
      : [
          E('div', { class: 'fkp-actions' }, [
            ...(card.applyCandidate
              ? [
                  E(
                    'button',
                    {
                      type: 'button',
                      class: 'btn cbi-button-action',
                      disabled: locked() ? true : undefined,
                      click: () => void applyGroup(card),
                    },
                    _('Apply %s').replace(
                      '%s',
                      strategyLabel(card.applyCandidate),
                    ),
                  ),
                ]
              : []),
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button',
                disabled: locked() ? true : undefined,
                click: () => void runCheck(card.id),
              },
              runningScope === card.id ? _('Checking…') : _('Check now'),
            ),
            E(
              'button',
              {
                type: 'button',
                class: 'btn cbi-button',
                click: () => openForkopPage('rules'),
              },
              _('Open rules'),
            ),
          ]),
        ]),
  ]);
}

function renderGroups() {
  if (!status) {
    replace(
      'autotune-groups',
      statusFailed ? renderEmptyState(_('No data')) : renderLoadingState(),
    );
    return;
  }

  const cards = groupCards(status, live);
  const notes: Node[] = [];
  if (!live && liveLoading)
    notes.push(
      E(
        'p',
        { class: 'fkp-autotune__muted' },
        _('Determining which rule routes each target…'),
      ),
    );
  if (liveFailed)
    notes.push(
      E(
        'p',
        { class: 'fkp-autotune__muted' },
        _(
          'Could not determine the current rule of each target; results of the last check are shown.',
        ),
      ),
    );

  const outside = live?.outside ?? [];
  replace(
    'autotune-groups',
    ...notes,
    cards.length
      ? E('ul', { class: 'fkp-autotune__list' }, cards.map(renderGroup))
      : renderEmptyState(
          status.targets.length
            ? live || liveFailed
              ? _('No target is routed through a Zapret DPI rule')
              : _('Loading…')
            : _('No targets yet'),
          status.targets.length
            ? undefined
            : _(
                'Add the sites that go through your DPI rules, for example youtube.com.',
              ),
        ),
    ...(outside.length
      ? [
          E('details', {}, [
            E(
              'summary',
              {},
              _('Targets outside DPI rules (%d)').replace(
                '%d',
                String(outside.length),
              ),
            ),
            E(
              'ul',
              { class: 'fkp-autotune__list' },
              outside.map((item) =>
                E('li', { class: 'fkp-autotune__item' }, [
                  E('span', { class: 'fkp-autotune__what' }, [
                    E(
                      'strong',
                      {},
                      status?.targets.find((t) => t.id === item.id)?.rule_set
                        ? ruleListLabel(item.host, status?.lists)
                        : item.host,
                    ),
                    ' — ',
                    outsideReasonText(item.reason),
                  ]),
                ]),
              ),
            ),
          ]),
        ]
      : []),
  );
}

function renderTargets() {
  const readonly = isReadonlyMode();
  replace(
    'autotune-target-actions',
    ...(readonly || !status
      ? []
      : [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button',
              disabled: locked() ? true : undefined,
              click: () => showTargetEditor(),
            },
            _('Add target'),
          ),
        ]),
  );
  if (!status) {
    replace(
      'autotune-targets',
      statusFailed ? renderEmptyState(_('No data')) : renderLoadingState(),
    );
    return;
  }

  const byId = new Map(status.targets.map((t) => [t.id, t]));
  const rows = targetRows(status.targets, status.lists);
  // A member of a list: its domain, result and details, no actions.
  const memberItem = (row: TargetRow) => {
    const target = byId.get(row.id)!;
    return E('li', { class: 'fkp-autotune__item' }, [
      E('span', { class: 'fkp-autotune__what' }, [row.host]),
      renderStatus({ label: row.result, tone: row.tone }),
      ...(row.checkedAt ? [timeNode(row.checkedAt)] : []),
      ...(target.last && target.last.candidates.length
        ? [
            E('span', { class: 'fkp-actions' }, [
              E(
                'button',
                {
                  type: 'button',
                  class: 'btn cbi-button',
                  click: () => showCandidates(target),
                },
                _('Details'),
              ),
            ]),
          ]
        : []),
    ]);
  };
  replace(
    'autotune-targets',
    rows.length
      ? E(
          'ul',
          { class: 'fkp-autotune__list' },
          rows.map((row) => {
            const target = byId.get(row.id)!;
            return E('li', { class: 'fkp-autotune__item' }, [
              E('span', { class: 'fkp-autotune__what' }, [
                E('strong', {}, row.host),
                ...(row.resolver
                  ? [
                      ' ',
                      E(
                        'span',
                        { class: 'fkp-autotune__muted' },
                        `DNS ${row.resolver}`,
                      ),
                    ]
                  : []),
              ]),
              renderStatus({ label: row.result, tone: row.tone }),
              ...(row.checkedAt ? [timeNode(row.checkedAt)] : []),
              E('span', { class: 'fkp-actions' }, [
                ...(target.last && target.last.candidates.length
                  ? [
                      E(
                        'button',
                        {
                          type: 'button',
                          class: 'btn cbi-button',
                          click: () => showCandidates(target),
                        },
                        _('Details'),
                      ),
                    ]
                  : []),
                ...(readonly
                  ? []
                  : [
                      renderOverflowMenu(_('Target actions'), [
                        {
                          label: _('Edit…'),
                          onClick: () => showTargetEditor(target),
                          disabled: locked(),
                        },
                        {
                          label: _('Remove…'),
                          onClick: () => void removeTarget(target),
                          disabled: locked(),
                          danger: true,
                        },
                      ]),
                    ]),
              ]),
              ...(row.list
                ? [
                    E('div', { class: 'fkp-autotune__members' }, [
                      ...(row.list.note
                        ? [
                            E(
                              'p',
                              { class: 'fkp-autotune__muted' },
                              row.list.note,
                            ),
                          ]
                        : []),
                      ...(row.list.members.length
                        ? [
                            E(
                              'ul',
                              { class: 'fkp-autotune__list' },
                              row.list.members.map(memberItem),
                            ),
                          ]
                        : []),
                    ]),
                  ]
                : []),
            ]);
          }),
        )
      : renderEmptyState(
          _('No targets yet'),
          readonly
            ? undefined
            : _('Autotune checks only the sites listed here.'),
        ),
  );
}

function renderHistory() {
  if (!history) {
    replace(
      'autotune-history',
      historyFailed
        ? renderErrorState(_('History is unavailable'), () => void loadAll())
        : renderLoadingState(),
    );
    return;
  }
  const items = historyItems(history.events, 'autotune').slice(
    0,
    HISTORY_LIMIT,
  );
  replace(
    'autotune-history',
    items.length
      ? E(
          'ul',
          { class: 'fkp-autotune__list' },
          items.map((item) =>
            E('li', { class: 'fkp-autotune__item' }, [
              E(
                'span',
                { class: 'fkp-autotune__time', title: item.time },
                item.relative,
              ),
              E('span', { class: 'fkp-autotune__what' }, item.title),
              renderStatus(item.outcome),
            ]),
          ),
        )
      : renderEmptyState(_('No autotune events yet')),
    E('div', { class: 'fkp-actions' }, [
      E(
        'button',
        {
          type: 'button',
          class: 'btn cbi-button',
          click: () => openForkopPage('history'),
        },
        _('All events'),
      ),
    ]),
  );
}

function renderAll() {
  renderState();
  renderGroups();
  renderTargets();
  renderHistory();
}

function onPageMount() {
  onPageUnmount();
  mounted = true;
  mountId += 1;
  renderAll();
  void loadAll();
  refreshTimer = setInterval(() => {
    if (busy) return;
    const running = status?.worker?.state === 'running';
    if (
      Date.now() - statusLoadedAt >=
      (running ? RUNNING_REFRESH_INTERVAL_MS : REFRESH_INTERVAL_MS)
    )
      void loadStatus();
    if (Date.now() - liveLoadedAt > GROUPS_REFRESH_INTERVAL_MS)
      void loadGroups();
  }, RUNNING_REFRESH_INTERVAL_MS);
}

function onPageUnmount() {
  mounted = false;
  mountId += 1;
  // Followed again from the status when the page comes back.
  applying = null;
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = null;
}

let initialized = false;

export async function initController(): Promise<void> {
  if (initialized) return;
  initialized = true;

  onMount('autotune-status').then(() => {
    store.subscribe(
      (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
        if (
          diff.tabService &&
          next.tabService.current !== prev.tabService.current
        ) {
          if (next.tabService.current === 'autotune') onPageMount();
          else onPageUnmount();
        }
      },
    );
    if (
      store.get().tabService.current === 'autotune' ||
      isActiveLuciTab('autotune')
    ) {
      onPageMount();
    }
  });
}
