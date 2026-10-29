import { Forkop } from '../../types';
import type { StatusTone } from '../../ui/status';

// Pure view model of the Autotune page (autotune/manager.uc status and
// groups). Every backend code becomes words here; raw codes never reach the
// page.

// The automatic mode is off: a strategy changes only when an administrator
// applies a recommendation (autotune/policy.uc).
export const MODES: Forkop.AutotuneMode[] = ['off', 'recommend'];

export function modeLabel(mode: string) {
  switch (mode) {
    case 'recommend':
      return _('Recommendations only');
    default:
      return _('Off');
  }
}

export function modeDescription(mode: string) {
  switch (mode) {
    case 'recommend':
      return _(
        'Forkop X measures the targets on schedule and shows recommendations. It does not change rules.',
      );
    default:
      return _(
        'Scheduled measurements are off. An administrator can still check targets manually.',
      );
  }
}

// Catalog candidate ids are strategy names users see in zapret; "direct" is
// the control without any bypass.
export function strategyLabel(id: string | null | undefined) {
  if (!id) return '—';
  if (id === 'direct') return _('No bypass (direct)');
  if (id === 'default') return _('Default strategy');
  return id;
}

export function currentStrategyLabel(
  current: string | null | undefined,
  custom: boolean | null | undefined,
) {
  if (custom) return _('Custom strategy');
  if (!current) return _('Not determined');
  return strategyLabel(current);
}

export function confidenceLabel(confidence: string | null | undefined) {
  switch (confidence) {
    case 'high':
      return _('high');
    case 'medium':
      return _('medium');
    case 'low':
      return _('low');
    default:
      return '—';
  }
}

export function stabilityView(stability: string | undefined): {
  label: string;
  tone: StatusTone;
} {
  switch (stability) {
    case 'stable':
      return { label: _('Stable'), tone: 'success' };
    case 'unstable':
      return { label: _('Unstable'), tone: 'warning' };
    case 'failed':
      return { label: _('Failed'), tone: 'error' };
    case 'unsupported':
      return { label: _('Not supported'), tone: 'muted' };
    default:
      return { label: _('Not checked'), tone: 'neutral' };
  }
}

// Why the measurement of a target ended the way it did (select.uc,
// isolation.uc and manager.uc reason codes).
export function targetReasonText(reason: string | null | undefined) {
  switch (reason) {
    case 'direct_stable':
      return _('Works without bypass.');
    case 'direct_failed_candidate_stable':
      return _('Does not work without bypass; a stable strategy was found.');
    case 'direct_unstable_candidate_stable':
      return _('Unstable without bypass; a stable strategy was found.');
    case 'candidate_more_reliable_than_direct':
      return _('The strategy is more reliable than no bypass.');
    case 'materially_faster_than_direct':
    case 'materially_faster':
      return _('The strategy is noticeably faster.');
    case 'simplest_stable':
      return _(
        'Several strategies are stable with similar latency; the simplest one was chosen.',
      );
    case 'candidate_bypassed':
      return _('The target is reachable only through a bypass strategy.');
    case 'no_stable_candidate':
      return _('No strategy is stable. The current strategy is kept.');
    case 'all_failed':
    case 'target_unreachable':
      return _(
        'The target is unreachable in every way; the problem may not be DPI.',
      );
    case 'target_ip_mismatch':
    case 'target_unresolved':
      return _(
        'The target address could not be determined reliably during the check.',
      );
    case 'isolation_unavailable':
    case 'route_unavailable':
      return _('A safe isolated check is not possible right now.');
    case 'autotune_in_progress':
    case 'lock_unavailable':
      return _('Another check was running.');
    case 'resolver_missing':
      return _(
        'No DNS server for measurements: set a plain IPv4 DNS server in Forkop X or on the target.',
      );
    default:
      return reason ? _('The check gave no usable result.') : '';
  }
}

// Why a target has no DPI group (groups.uc classify).
export function outsideReasonText(reason: string) {
  switch (reason) {
    case 'target_disabled':
      return _('The target is disabled.');
    case 'target_unresolved':
      return _('The router could not resolve the address.');
    case 'target_not_fakeip_routed':
      return _(
        'The router does not route this address through FakeIP, so Forkop X cannot check a strategy change for it.',
      );
    case 'rule_owner_undecidable':
      return _(
        'The rule that routes it cannot be determined unambiguously (for example, a remote list comes first).',
      );
    case 'dpi_identity_unproven':
      return _('The DPI rule that routes it could not be identified safely.');
    case 'provider_not_supported':
      return _(
        'It goes through a Zapret2 or ByeDPI rule; autotune supports Zapret rules only.',
      );
    case 'routed_through_connection':
      return _(
        'It goes through a proxy or VPN rule. DPI autotune does not apply.',
      );
    case 'no_dpi_rule':
      return _(
        'It goes directly and is not in a DPI rule. No bypass is configured for it.',
      );
    case 'bypassed':
      return _('It is excluded from Forkop X routing.');
    case 'blocked':
      return _('It is blocked by a rule.');
    case 'not_a_dpi_rule':
    case 'outbound_without_rule':
      return _('It is not routed by a DPI rule.');
    case 'list_not_local':
    case 'list_file_missing':
    case 'list_unreadable':
    case 'list_has_no_domains':
    case 'list_domains_unresolved':
      return listErrorText(reason);
    default:
      return _('It is not in a DPI rule.');
  }
}

// A rule limited to devices: sing-box sends nothing of the router into it,
// so a change is verified with router requests marked for the queue of the
// rule.
const DEVICE_LIMITED_TEXT = () =>
  _(
    'The rule is limited to devices: the result holds for them. Forkop X checks a change with router requests sent through the queue of this rule.',
  );

// The candidate failed its check, but the configuration was edited while it
// was checked: the automatic rollback kept the edit instead of restoring the
// "Before autotune" snapshot (autotune/apply.uc, UC-017).
const CONFIG_EDITED_DURING_CHECK =
  'verification_failed:config_changed_during_transaction';
// The candidate failed its check, and the configuration was edited while
// the automatic rollback itself restored the "Before autotune" snapshot and
// reloaded: the edit was kept, and the runtime may run either (UC-017).
const CONFIG_EDITED_DURING_ROLLBACK =
  'verification_failed:config_changed_during_rollback';
// The candidate's reload did not succeed, and the configuration was edited
// meanwhile: the apply's own transaction kept the edit instead of putting
// the previous configuration back (config/snapshots.uc, UC-023).
const CONFIG_EDITED_DURING_APPLY = 'apply_config_changed_during_transaction';

export function applyOutcomeView(
  status: string,
  reason?: string | null,
): {
  label: string;
  tone: StatusTone;
} {
  switch (status) {
    case 'applied':
      return { label: _('Applied, check passed'), tone: 'success' };
    case 'rolled_back':
      if (reason === 'operator_rollback')
        return { label: _('Rolled back by an administrator'), tone: 'neutral' };
      return {
        label: _('Check failed, rolled back automatically'),
        tone: 'warning',
      };
    case 'no_change_required':
      return { label: _('No change was needed'), tone: 'neutral' };
    case 'not_applied':
    case 'stale':
    case 'busy':
      return { label: _('Not applied'), tone: 'neutral' };
    case 'needs_attention':
      if (reason === CONFIG_EDITED_DURING_CHECK)
        return {
          label: _('Check failed, not rolled back: configuration edited'),
          tone: 'error',
        };
      if (reason === CONFIG_EDITED_DURING_ROLLBACK)
        return {
          label: _(
            'Check failed, rollback did not finish: configuration edited',
          ),
          tone: 'error',
        };
      if (reason === CONFIG_EDITED_DURING_APPLY)
        return {
          label: _('Apply did not finish: configuration edited'),
          tone: 'error',
        };
      return { label: _('Rollback did not finish'), tone: 'error' };
    default:
      return { label: _('Outcome unknown'), tone: 'error' };
  }
}

export interface GroupCard {
  id: string;
  title: string;
  targetCount: number;
  badge: { label: string; tone: StatusTone };
  current: string;
  recommended: string | null;
  confidence: string | null;
  explanation: string[];
  progress: { count: number; required: number } | null;
  checkedAt: number | null;
  lastApply: {
    at: number;
    candidate: string;
    outcome: { label: string; tone: StatusTone };
  } | null;
  cooldowns: { candidate: string; until: number }[];
  // The confirmed recommendation an administrator may apply now (mode
  // "recommend" only); the backend checks everything again.
  applyCandidate: string | null;
  // The rule is limited to devices (source_ip_cidr).
  deviceLimited: boolean;
  // Mode "off" with a confirmed recommendation: how to apply it.
  manualHint: boolean;
  targets: string[];
}

function conflictText(
  result: Forkop.AutotuneGroupResult,
  hosts: Record<string, string>,
) {
  const parts = (result.conflict ?? []).map(
    (item) =>
      `${hosts[item.target] ?? item.target}: ${strategyLabel(item.selected)}`,
  );
  const base =
    result.reason === 'candidate_not_stable_for_all'
      ? _('The best strategy is not stable for every target of the rule.')
      : _('Targets of this rule need different strategies.');
  return [
    base,
    ...(parts.length ? [parts.join('; ') + '.'] : []),
    _(
      'A strategy is set for the whole rule, so Forkop X does not change it. You can split the targets into separate rules.',
    ),
  ];
}

function inconclusiveText(reason: string | null) {
  if (reason === 'not_measured' || reason === 'no_targets' || !reason)
    return _('No measurements yet.');
  if (reason === 'no_conclusive_result')
    return _(
      'The last check gave no usable result. The current strategy is kept.',
    );
  return `${targetReasonText(reason)} ${_('The current strategy is kept.')}`;
}

// One card per DPI rule. `live` is the membership calculated now (null
// while it loads or when it failed), `state` what the worker recorded.
export function groupCards(
  status: Forkop.AutotuneStatus,
  live: Forkop.AutotuneGroups | null,
): GroupCard[] {
  const hosts = Object.fromEntries(
    status.targets.map((t) => [t.id, t.host ?? t.id]),
  );
  const ids = new Set<string>([
    ...Object.keys(live?.groups ?? {}),
    ...(live ? [] : Object.keys(status.groups ?? {})),
  ]);

  return [...ids].sort().map((id) => {
    const state = status.groups?.[id] ?? null;
    const now = live?.groups[id] ?? null;
    const targets = now?.targets ?? state?.targets ?? [];
    const current = now?.current ?? state?.current ?? null;
    const custom = now?.custom ?? null;
    const deviceLimited =
      (now?.source_scoped ?? state?.source_scoped ?? false) === true;
    // The worker result belongs to the last run; the live result is built
    // from cached target results and may be newer (another group's run).
    const result = state?.result ?? now?.result ?? null;
    const required = state?.required ?? status.policy.confirmations;
    const pending = state?.pending ?? null;
    const ready = state?.ready === true;
    const explanation: string[] = [];
    let badge: GroupCard['badge'];
    let recommended: string | null = null;

    if (!result || !state?.last) {
      badge = { label: _('Not checked'), tone: 'neutral' };
      explanation.push(_('No measurements yet.'));
    } else if (result.status === 'recommendation') {
      recommended = result.candidate;
      badge = ready
        ? { label: _('Recommendation confirmed'), tone: 'warning' }
        : { label: _('Confirming'), tone: 'loading' };
      const why = targetReasonText(result.reason);
      if (why) explanation.push(why);
      if (!ready)
        explanation.push(
          _(
            'The strategy is changed only after %d checks in a row with the same result.',
          ).replace('%d', String(required)),
        );
    } else if (result.status === 'no_change') {
      badge = { label: _('No change needed'), tone: 'success' };
      explanation.push(_('The current strategy is already the best.'));
    } else if (result.status === 'direct_stable') {
      badge = { label: _('Bypass not needed'), tone: 'success' };
      explanation.push(
        _('The targets work without bypass.'),
        _(
          'Forkop X never turns DPI bypass off by itself; remove the targets from the rule manually if you want.',
        ),
      );
    } else if (result.status === 'conflict') {
      badge = { label: _('Conflict'), tone: 'warning' };
      explanation.push(...conflictText(result, hosts));
    } else {
      badge = { label: _('No data'), tone: 'neutral' };
      explanation.push(inconclusiveText(result.reason));
    }

    if (custom && result?.status === 'recommendation')
      explanation.push(_('The rule has a custom strategy; Forkop X keeps it.'));
    if (deviceLimited && !explanation.includes(DEVICE_LIMITED_TEXT()))
      explanation.push(DEVICE_LIMITED_TEXT());

    const apply = state?.last_apply ?? null;
    const nowSeconds = Math.floor(Date.now() / 1000);
    const cooling = (candidate: string | null) =>
      Boolean(candidate && (state?.cooldowns?.[candidate] ?? 0) > nowSeconds);
    const applyCandidate =
      status.policy.mode === 'recommend' &&
      result?.status === 'recommendation' &&
      ready &&
      !custom &&
      result.candidate &&
      result.candidate !== 'direct' &&
      !cooling(result.candidate)
        ? result.candidate
        : null;

    return {
      id,
      title: now?.label || state?.label || id,
      targetCount: targets.length,
      badge,
      current: currentStrategyLabel(current, custom),
      deviceLimited,
      recommended,
      confidence:
        result?.status === 'recommendation' || result?.status === 'no_change'
          ? result.confidence
          : null,
      explanation,
      progress:
        pending && result?.status === 'recommendation'
          ? { count: Math.min(pending.count, required), required }
          : null,
      checkedAt: state?.last?.at ?? null,
      lastApply:
        apply && apply.status !== 'not_applied'
          ? {
              at: apply.at,
              candidate:
                apply.trigger === 'manual'
                  ? `${strategyLabel(apply.candidate)} (${_('manually')})`
                  : strategyLabel(apply.candidate),
              outcome: applyOutcomeView(apply.status, apply.reason),
            }
          : null,
      cooldowns: Object.entries(state?.cooldowns ?? {})
        .filter(([, until]) => until > nowSeconds)
        .map(([candidate, until]) => ({
          candidate: strategyLabel(candidate),
          until,
        })),
      applyCandidate,
      manualHint:
        status.policy.mode === 'off' &&
        result?.status === 'recommendation' &&
        ready,
      targets: targets.map((target) => hosts[target] ?? target),
    };
  });
}

export interface CandidateRow {
  name: string;
  result: string;
  stability: { label: string; tone: StatusTone };
  latency: string;
  selected: boolean;
}

// Candidates of one target's last check, best first as select.uc ranks
// them: stable, then success ratio. Latency only exists for successes.
export function candidateRows(
  summary: Forkop.AutotuneTargetSummary,
): CandidateRow[] {
  const order: Record<string, number> = {
    stable: 0,
    unstable: 1,
    failed: 2,
  };
  return summary.candidates
    .slice()
    .sort(
      (a, b) =>
        (order[a.stability ?? ''] ?? 3) - (order[b.stability ?? ''] ?? 3) ||
        (b.success_ratio ?? -1) - (a.success_ratio ?? -1),
    )
    .map((candidate) => ({
      name: strategyLabel(candidate.id),
      result:
        typeof candidate.attempted === 'number' && candidate.attempted > 0
          ? `${candidate.success ?? 0} / ${candidate.attempted}`
          : '—',
      stability: stabilityView(candidate.stability),
      latency:
        typeof candidate.median_tls_ms === 'number'
          ? _('%d ms').replace(
              '%d',
              String(Math.round(candidate.median_tls_ms)),
            )
          : '—',
      selected: candidate.id === summary.selected,
    }));
}

export interface TargetRow {
  id: string;
  host: string;
  enabled: boolean;
  resolver: string | null;
  result: string;
  tone: StatusTone;
  checkedAt: number | null;
  // A rule-list target: what is measured and its members' rows.
  list: { note: string; members: TargetRow[] } | null;
}

// The name of a list from its sing-box tag: "<rule>-<list>-community-ruleset"
// reads "<list>"; a list written in the rule itself is a custom list.
export function ruleListName(tag: string, rule?: string | null) {
  if (/^inline-/.test(tag)) return _('custom list');
  let name = tag.replace(/-ruleset$/, '').replace(/-community$/, '');
  if (rule && name.startsWith(`${rule}-`)) name = name.slice(rule.length + 1);
  return name || tag;
}

// "YouTube: youtube" for the list of a rule, as the target editor and the
// target list show it.
export function ruleListLabel(
  tag: string,
  lists: Forkop.AutotuneRuleList[] | undefined,
) {
  const known = lists?.find((l) => l.tag === tag);
  return known
    ? `${known.label}: ${ruleListName(tag, known.rule)}`
    : ruleListName(tag);
}

// Why a rule-list target measures nothing (autotune/lists.uc).
export function listErrorText(reason: string | null | undefined) {
  switch (reason) {
    case 'list_not_local':
    case 'list_file_missing':
      return _(
        'The list is not downloaded on the router; update the lists or save the rule.',
      );
    case 'list_unreadable':
      return _('The list could not be read.');
    case 'list_has_no_domains':
      return _(
        'The list has no domain names to check (only keywords, regular expressions or addresses).',
      );
    case 'list_domains_unresolved':
      return _('No domain of the list has an address at the DNS server.');
    default:
      return reason ? _('The list could not be read.') : '';
  }
}

function listNote(list: Forkop.AutotuneListView) {
  if (list.error) return listErrorText(list.error);
  const parts = [
    list.pinned
      ? _('Pinned domains: %d').replace('%d', String(list.members.length))
      : _('Checked %d of %d domains')
          .replace('%d', String(list.members.length))
          .replace('%d', String(list.total)),
  ];
  if (list.missing.length)
    parts.push(`${_('not in the list')}: ${list.missing.join(', ')}`);
  if (list.skipped)
    parts.push(
      _('%d entries without a domain name are skipped').replace(
        '%d',
        String(list.skipped),
      ),
    );
  return parts.join('; ');
}

// Rows of the configured targets; the members of a rule-list target are
// the rows of its list.
export function targetRows(
  targets: Forkop.AutotuneTarget[],
  lists?: Forkop.AutotuneRuleList[],
): TargetRow[] {
  const members = (parent: string) =>
    targets
      .filter((t) => t.parent === parent)
      .map((t) => targetRow(t, lists, members));
  return targets
    .filter((t) => t.parent === undefined)
    .map((t) => targetRow(t, lists, members));
}

function listRow(
  target: Forkop.AutotuneTarget,
  lists: Forkop.AutotuneRuleList[] | undefined,
  members: (parent: string) => TargetRow[],
): TargetRow {
  const list = target.list ?? null;
  let result = _('Not checked');
  let tone: StatusTone = 'neutral';
  if (!target.enabled) {
    result = _('Disabled');
    tone = 'muted';
  } else if (list?.error) {
    result = _('Nothing to check');
    tone = 'warning';
  } else if (list) {
    result = _('Domains: %d').replace('%d', String(list.members.length));
  }
  return {
    id: target.id,
    host: `${_('List')} ${ruleListLabel(target.rule_set ?? '', lists)}`,
    enabled: target.enabled,
    resolver: target.resolver,
    result,
    tone,
    checkedAt: null,
    list: {
      note: target.enabled && list ? listNote(list) : '',
      members: target.enabled ? members(target.id) : [],
    },
  };
}

function targetRow(
  target: Forkop.AutotuneTarget,
  lists: Forkop.AutotuneRuleList[] | undefined,
  members: (parent: string) => TargetRow[],
): TargetRow {
  if (target.rule_set) return listRow(target, lists, members);
  const last = target.last;
  let result: string;
  let tone: StatusTone = 'neutral';
  if (!target.enabled) {
    result = _('Disabled');
    tone = 'muted';
  } else if (!last) {
    result = _('Not checked');
  } else if (last.status === 'selected' && last.selected) {
    result = `${_('Best')}: ${strategyLabel(last.selected)} (${_('confidence')} ${confidenceLabel(last.confidence)})`;
    tone = 'success';
  } else {
    result = targetReasonText(last.reason) || _('No usable result');
    tone = 'warning';
  }
  return {
    id: target.id,
    host: target.host ?? target.id,
    enabled: target.enabled,
    resolver: target.resolver,
    result,
    tone,
    checkedAt: last?.at ?? null,
    list: null,
  };
}

export interface RunProgressItem {
  host: string;
  state: string;
  text: string;
  tone: StatusTone;
}

export interface RunProgressView {
  // 0..100, weighted by how long each target is expected to take.
  percent: number;
  // "Target 2 of 3: youtube.com".
  title: string;
  // What the running target does now.
  phase: string;
  // "about 3 min left", or '' when nothing can be estimated.
  remaining: string;
  items: RunProgressItem[];
}

// Share of a target's check done at a tune phase: probes are most of it;
// the wait for probe connections to close can take minutes on a blocked site.
function phaseShare(tune: Forkop.AutotuneTuneProgress | null | undefined) {
  if (!tune) return 0;
  const done = Number(tune.done) || 0;
  const total = Number(tune.total) || 0;
  switch (tune.phase) {
    case 'preparing':
      return 0.05;
    case 'measuring':
      return 0.05 + (total ? 0.75 * Math.min(done / total, 1) : 0);
    case 'cleaning':
      return 0.8;
    case 'holding':
      return (
        0.8 +
        0.15 *
          Math.min(
            (Number(tune.waited_s) || 0) / (Number(tune.timeout_s) || 300),
            1,
          )
      );
    default:
      return 0;
  }
}

function tunePhaseText(tune: Forkop.AutotuneTuneProgress | null | undefined) {
  switch (tune?.phase) {
    case 'preparing':
      return _('preparing the isolated check');
    case 'measuring':
      return _('probes: %d of %d')
        .replace('%d', String(tune.done ?? 0))
        .replace('%d', String(tune.total ?? 0));
    case 'cleaning':
      return _('probes done, removing the temporary rules');
    case 'holding':
      return _('waiting for probe connections to close: %d s (up to %d s)')
        .replace('%d', String(tune.waited_s ?? 0))
        .replace('%d', String(tune.timeout_s ?? 300));
    default:
      return _('starting');
  }
}

export function durationText(seconds: number) {
  if (seconds < 60) return _('less than a minute');
  return _('about %d min').replace('%d', String(Math.round(seconds / 60)));
}

function runItemText(item: Forkop.AutotuneRunItem): {
  text: string;
  tone: StatusTone;
} {
  switch (item.state) {
    case 'running':
      return { text: _('Checking now'), tone: 'loading' };
    case 'pending':
      return { text: _('Waiting'), tone: 'neutral' };
    case 'skipped':
      return { text: targetReasonText(item.reason), tone: 'warning' };
    default:
      if (item.status === 'selected' && item.selected)
        return {
          text: `${_('Best')}: ${strategyLabel(item.selected)} (${_('confidence')} ${confidenceLabel(item.confidence ?? null)})`,
          tone: 'success',
        };
      return {
        text: targetReasonText(item.reason) || _('No usable result'),
        tone: 'warning',
      };
  }
}

// A running check as the page shows it; null when the worker reports no
// progress (an older worker, or an apply).
export function runProgressView(
  worker: Forkop.AutotuneWorker | null | undefined,
  nowSeconds: number,
): RunProgressView | null {
  const progress = worker?.state === 'running' ? worker.progress : undefined;
  if (!progress || !progress.items.length) return null;
  const items = progress.items;
  const weight = items.reduce((sum, i) => sum + Math.max(i.expected_s, 1), 0);
  const running = items.find((i) => i.state === 'running') ?? null;
  const share = phaseShare(worker?.tune);
  let doneWeight = 0;
  for (const item of items)
    if (item.state === 'done' || item.state === 'skipped')
      doneWeight += Math.max(item.expected_s, 1);
    else if (item === running)
      doneWeight += Math.max(item.expected_s, 1) * share;
  const elapsed =
    running?.started_at !== undefined
      ? Math.max(nowSeconds - running.started_at, 0)
      : 0;
  const left =
    items
      .filter((i) => i.state === 'pending')
      .reduce((sum, i) => sum + i.expected_s, 0) +
    (running ? Math.max(running.expected_s - elapsed, 15) : 0);
  const position = running
    ? items.indexOf(running) + 1
    : Math.min(progress.done + 1, items.length);
  return {
    percent: Math.min(Math.round((100 * doneWeight) / weight), 99),
    title:
      _('Target %d of %d')
        .replace('%d', String(position))
        .replace('%d', String(items.length)) +
      (running ? `: ${running.host}` : ''),
    phase: running ? tunePhaseText(worker?.tune) : '',
    remaining: left > 0 ? durationText(left) : '',
    items: items.map((item) => ({
      host: item.host,
      state: item.state,
      ...runItemText(item),
    })),
  };
}

// Worker state for the summary line.
export function workerView(
  worker: Forkop.AutotuneWorker | null,
): { label: string; tone: StatusTone } | null {
  if (!worker) return null;
  if (worker.state === 'running')
    return worker.phase === 'applying'
      ? { label: _('Applying a strategy'), tone: 'loading' }
      : { label: _('Checking targets'), tone: 'loading' };
  if (worker.state === 'crashed')
    return {
      label: _('The last check was interrupted'),
      tone: 'warning',
    };
  switch (worker.result) {
    case 'completed':
      return { label: _('Last check completed'), tone: 'success' };
    case 'interrupted':
      return { label: _('The last check was interrupted'), tone: 'warning' };
    case 'skipped':
      return {
        label: `${_('Last check postponed')}: ${blockerText(worker.reason)}`,
        tone: 'neutral',
      };
    default:
      return { label: _('The last check failed'), tone: 'error' };
  }
}

// Why a run did not measure (manager.uc blocker()).
export function blockerText(reason: string | null | undefined) {
  switch (reason) {
    case 'dpi_guard_present':
      return _('DPI protection is active');
    // A guard a failed service change kept: only a restart removes it
    // (UC-019).
    case 'runtime_guard_active':
      return _('a failed change left the DPI guard in place; restart Forkop X');
    case 'snapshot_operation_active':
      return _('a snapshot operation is in progress');
    case 'autotune_in_progress':
      return _('another check is running');
    case 'apply_unresolved':
      return _('a previous apply is not resolved');
    case 'service_stopped':
      return _('Forkop X is stopped; start it first');
    default:
      return reason ? _('the service is busy') : _('unknown reason');
  }
}

// Errors of mutations for toasts.
export function mutationErrorText(reason: string | undefined) {
  switch (reason) {
    case 'uncommitted_uci_changes':
      return _(
        'There are unsaved configuration changes. Save or reset them in Settings first.',
      );
    case 'autotune_worker_running':
      return _('A check is already running.');
    case 'invalid_host':
      return _('Enter a domain name, for example youtube.com.');
    case 'invalid_resolver':
      return _('The DNS server must be an IPv4 address.');
    case 'too_many_targets':
      return _('The maximum number of targets is reached.');
    case 'invalid_rule_set':
    case 'host_and_rule_set':
      return _('Choose a list of a DPI rule.');
    case 'invalid_sample':
      return _('Check 1 to 8 domains of the list.');
    case 'invalid_pin':
      return _('Pinned domains must be domain names, at most 8.');
    case 'number_out_of_range':
    case 'duration_out_of_range':
    case 'invalid_number':
    case 'invalid_duration':
      return _('The value is outside the allowed range.');
    default:
      return _('The change was not saved.');
  }
}

// A target id from its host (or "l_<list>" for a rule list): letters, digits
// and "_", unique among `taken`.
export function targetIdFor(host: string, taken: string[], prefix = 't_') {
  const base = (prefix + host.toLowerCase().replace(/[^a-z0-9]+/g, '_'))
    .slice(0, 28)
    .replace(/_+$/, '');
  let id = base || 't';
  for (let n = 2; taken.includes(id); n++) id = `${base}_${n}`;
  return id;
}

export const INTERVAL_CHOICES = ['1h', '3h', '6h', '12h', '1d'];
export const COOLDOWN_CHOICES = ['6h', '12h', '1d', '2d', '7d'];

export function durationLabel(value: string) {
  const match = /^(\d+)([hd])$/.exec(value);
  if (!match) return value;
  return match[2] === 'h'
    ? _('%d h').replace('%d', match[1])
    : _('%d d').replace('%d', match[1]);
}

// Choices of a select: the presets plus the configured value, if custom.
export function durationChoices(presets: string[], current: string) {
  return presets.includes(current) ? presets : [...presets, current];
}

// ---- manual apply ----------------------------------------------------------

// The confirmation of a manual apply: what changes, for which targets, and
// what Forkop X does to keep it safe. Strategy names only, never options.
export function applyConfirmation(card: GroupCard) {
  const candidate = strategyLabel(card.applyCandidate);
  return {
    title: _('Apply %s?').replace('%s', candidate),
    message: `${_('The strategy of the DPI rule "%s" will be changed.').replace('%s', card.title)} ${_('The change affects the whole group:')}`,
    consequences: card.targets.length ? card.targets : ['—'],
    notes: [
      `${_('Now')}: ${card.current}. ${_('Will be')}: ${candidate}.`,
      card.deviceLimited
        ? _(
            'Forkop X will create a configuration snapshot, reload the service and check the new strategy with router requests sent through the queue of this rule. If the check fails, the previous configuration is restored automatically.',
          )
        : _(
            'Forkop X will create a configuration snapshot, reload the service and check the real production path. If the check fails, the previous configuration is restored automatically.',
          ),
    ],
    confirmLabel: _('Apply'),
  };
}

// The step a running manual apply reports (manager.uc apply progress and
// the Stage 5 transaction phase). Only reported steps are shown.
export function applyPhaseLabel(
  progress: { phase: string; apply_phase: string | null } | null | undefined,
) {
  switch (progress?.apply_phase) {
    case 'checking':
      return _('Checking the configuration before the change');
    case 'applying':
      return _('Creating a snapshot and reloading the service');
    case 'verifying':
      return _('Checking the real production path');
    case 'rolling_back':
      return _('Restoring the previous configuration');
  }
  if (progress?.phase === 'applying') return _('Preparing the change');
  return _('Checking the recommendation');
}

// Refusals and Stage 5 results that mean the measurement no longer fits
// the configuration: the check must run again.
const STALE_REASONS = [
  'recommendation_stale',
  'rule_changed',
  'strategy_changed',
  'targets_changed',
  'owner_changed',
  'recommendation_changed',
  'measurement_unavailable',
  'plan_candidate_differs',
];

// A service action (list or subscription update, reload, start) owned the
// reload lock or a reload was queued: the apply was refused unchanged.
const BUSY_REASONS = ['service_action_in_progress', 'reload_pending'];

export interface ApplyResultView {
  tone: 'success' | 'warning' | 'error' | 'neutral';
  text: string;
  // Recovery did not finish: the user must act (History & Recovery).
  attention: boolean;
}

// Why the strategy of the rule cannot take the recommendation: autotune
// replaces only the TCP/443 profile of the rule strategy (autotune/apply.uc).
function strategyShapeText(reason: string) {
  switch (reason) {
    case 'tcp443_profile_shared':
      return _(
        'The rule strategy handles HTTPS together with other traffic in one profile; Forkop X does not split it. Give HTTPS (--filter-tcp=443) its own profile.',
      );
    case 'no_tcp443_profile':
      return _('The rule strategy has no HTTPS (TCP/443) profile.');
    case 'strategy_unparsed':
      return _(
        'The rule strategy writes a filter as two words (--filter-tcp 443); write it as --filter-tcp=443.',
      );
    case 'strategy_empty':
      return _('The rule has no strategy.');
    case 'candidate_not_tcp443':
      return _('The recommended strategy is not an HTTPS (TCP/443) strategy.');
    default:
      return null;
  }
}

function refusalText(reason: string | null | undefined) {
  const shape = strategyShapeText(
    (reason ?? '').replace(/^plan_not_applicable:/, ''),
  );
  if (shape) return `${_('The strategy was not applied')}. ${shape}`;
  switch (reason) {
    case 'not_confirmed':
      return _('The recommendation is not confirmed yet.');
    case 'no_recommendation':
      return _('There is no recommendation to apply.');
    case 'conflict':
      return _('Targets of this rule need different strategies.');
    case 'direct_not_applicable':
      return _('Forkop X never turns DPI bypass off by itself.');
    case 'candidate_unsupported':
      return _('This strategy is not supported by the installed Zapret.');
    case 'confidence_too_low':
      return _(
        'The confidence of the recommendation is below the policy minimum.',
      );
    case 'candidate_in_cooldown':
      return _(
        'This strategy was rolled back recently; it waits for the cooldown.',
      );
    case 'custom_strategy_kept':
      return _('The rule has a custom strategy; Forkop X keeps it.');
    case 'mode_off':
    case 'mode_not_recommend':
    case 'mode_changed':
      return _(
        'Manual apply is available only in "Recommendations only" mode.',
      );
    case 'state_recovered':
      return _(
        'The autotune state was restored after damage. Run the check again.',
      );
    case 'resolver_missing':
      return targetReasonText(reason);
    case 'autotune_worker_running':
    case 'autotune_in_progress':
      return _('Another autotune operation is running.');
    case 'dpi_guard_present':
    case 'runtime_guard_active':
    case 'snapshot_operation_active':
    case 'apply_unresolved':
      return `${_('The strategy was not applied')}: ${blockerText(reason)}.`;
    default:
      return reason &&
        /^(reload|restart|start|stop|service)_|_pending$|_running$/.test(reason)
        ? `${_('The strategy was not applied')}: ${blockerText(reason)}.`
        : `${_('The strategy was not applied')}.`;
  }
}

// What the finished apply job means for the user.
export function applyResultView(
  result: { status: string; result?: string; reason?: string | null } | null,
  candidate: string | null,
): ApplyResultView {
  const name = strategyLabel(candidate);
  const outcome = result?.result ?? '';
  const reason = result?.reason ?? null;
  const stale = {
    tone: 'warning' as const,
    text: _(
      'The recommendation is outdated: the configuration changed after the check. Run the check again.',
    ),
    attention: false,
  };
  switch (outcome) {
    case 'applied':
      return {
        tone: 'success',
        text: _('Strategy %s applied and checked.').replace('%s', name),
        attention: false,
      };
    case 'rolled_back':
      return {
        tone: 'warning',
        text: _(
          'The new strategy did not pass the check. Forkop X restored the previous configuration automatically.',
        ),
        attention: false,
      };
    case 'no_change_required':
      return {
        tone: 'neutral',
        text: _('This strategy is already active; nothing was changed.'),
        attention: false,
      };
    case 'stale':
      // A lifecycle action took the reload lock after the checks: nothing
      // was changed and the recommendation still stands.
      // So is a guard a failed service change kept: the configuration did
      // not change, a restart is needed (UC-019).
      if (
        BUSY_REASONS.includes(reason ?? '') ||
        reason === 'service_stopped' ||
        reason === 'runtime_guard_active'
      )
        return { tone: 'warning', text: refusalText(reason), attention: false };
      // Production must run the last known working configuration; running
      // the check again does not change that.
      if (reason === 'config_not_last_known_good')
        return {
          tone: 'warning',
          text: _(
            'The strategy was not applied: the current configuration is not yet the last known working one. Forkop X records it once it starts or reloads with it; while a rule still uses a strategy that did not pass its check, it is not recorded.',
          ),
          attention: false,
        };
      return stale;
    case 'failed':
      if (reason === 'reload_queued_recovered')
        return {
          tone: 'warning',
          text: _(
            'The new strategy was not applied: the service was busy and only queued the reload. The previous configuration is kept.',
          ),
          attention: false,
        };
      if (reason === 'reload_failed_recovered')
        return {
          tone: 'warning',
          text: _(
            'The new strategy was not applied: the service reload failed and the previous configuration was restored automatically.',
          ),
          attention: false,
        };
      if (reason !== 'interrupted_after_apply')
        return {
          tone: 'error',
          text: _(
            'The strategy could not be applied. The previous configuration is kept.',
          ),
          attention: false,
        };
      break;
    case 'refused':
    case 'not_applied':
      if (STALE_REASONS.includes(reason ?? '')) return stale;
      return { tone: 'warning', text: refusalText(reason), attention: false };
    case 'needs_attention':
      if (reason === CONFIG_EDITED_DURING_CHECK)
        return {
          tone: 'error',
          text: _(
            'The new strategy did not pass the check, but the configuration was changed during the check, so Forkop X kept that change and did not roll back. The rule may still use the new strategy: check it, or restore the "Before autotune" snapshot in History and recovery.',
          ),
          attention: true,
        };
      if (reason === CONFIG_EDITED_DURING_ROLLBACK)
        return {
          tone: 'error',
          text: _(
            'The new strategy did not pass the check. Forkop X began to restore the "Before autotune" snapshot, but the configuration was changed meanwhile, and Forkop X kept that change. It is not known whether Forkop X now runs the snapshot or the change: check the rule, or restore the snapshot you need in History and recovery.',
          ),
          attention: true,
        };
      if (reason === CONFIG_EDITED_DURING_APPLY)
        return {
          tone: 'error',
          text: _(
            'Applying the new strategy did not finish: its reload did not succeed, and the configuration was changed meanwhile. Forkop X kept that change instead of rolling back. Check the rule, or restore the snapshot you need in History and recovery.',
          ),
          attention: true,
        };
      break;
    case 'unknown':
      break;
    default:
      if (result?.status === 'busy')
        return {
          tone: 'warning',
          text: refusalText('autotune_worker_running'),
          attention: false,
        };
      // Refused before the transaction (invalid request, no configuration).
      if (!outcome && result)
        return { tone: 'error', text: refusalText(reason), attention: false };
  }
  return {
    tone: 'error',
    text: _('Automatic recovery did not finish.'),
    attention: true,
  };
}

// ---- the recorded apply and its rollback -----------------------------------

export interface RecordedApplyView {
  tone: 'neutral' | 'warning' | 'error';
  text: string;
  // It blocks autotune until an administrator decides.
  attention: boolean;
}

function changeName(
  apply: Forkop.AutotuneRecordedApply,
  groupTitle: string | null,
) {
  const candidate = strategyLabel(apply.candidate);
  return groupTitle
    ? _('%s in the rule "%t"')
        .replace('%s', candidate)
        .replace('%t', groupTitle)
    : candidate;
}

// What happened to a candidate that still waits for a decision
// (autotune/apply.uc reasons): verified in production but not recorded as
// last known working, failed its check without a finished rollback, an
// administrator's rollback that did not finish, or a check that never ended.
function unresolvedChangeText(
  apply: Forkop.AutotuneRecordedApply,
  groupTitle: string | null,
) {
  const reason = apply.reason ?? '';
  const text =
    reason === 'lkg_confirm_failed'
      ? _(
          'The last change (%s) passed its check, but it could not be recorded as the last known working configuration.',
        )
      : reason.startsWith('verification_failed')
        ? _(
            'The last change (%s) failed its check, and the automatic rollback did not finish.',
          )
        : reason.startsWith('operator_rollback')
          ? _('The rollback of the last change (%s) did not finish.')
          : _('The last change (%s) was not checked to the end.');
  return text.replace('%s', changeName(apply, groupTitle));
}

// What the page says about the last Stage 5 apply (manager.uc status
// apply): nothing while it is settled and cannot be rolled back, or while
// it still runs (the apply itself reports its steps). An unresolved record
// without a snapshot to return to (rollback: false) points to History: a
// restored snapshot replaces the candidate and becomes last known working.
export function recordedApplyView(
  apply: Forkop.AutotuneRecordedApply | null | undefined,
  groupTitle: string | null,
): RecordedApplyView | null {
  if (!apply || apply.in_progress) return null;
  if (apply.resolved === null)
    return {
      tone: 'warning',
      text: _('The state of the last autotune change could not be read.'),
      attention: false,
    };
  if (apply.diagnosis === 'state_unreadable')
    return {
      tone: 'error',
      text: apply.rollback
        ? _(
            'The record of the last autotune change is damaged. Checks and changes wait until an administrator rolls it back: Forkop X then makes sure the last known working configuration is active.',
          )
        : _(
            'The record of the last autotune change is damaged, and the last known working configuration is missing. Restore a snapshot in History and recovery: it becomes the last known working one, and the change can then be rolled back here.',
          ),
      attention: true,
    };
  if (apply.resolved === false) {
    if (apply.diagnosis === 'candidate_active')
      return {
        tone: 'error',
        text: `${unresolvedChangeText(apply, groupTitle)} ${
          apply.rollback
            ? _('Checks and changes wait until it is rolled back.')
            : _(
                'The snapshot to return to is missing: restore a snapshot in History and recovery. Checks and changes wait until then.',
              )
        }`,
        attention: true,
      };
    if (apply.diagnosis === 'in_transaction')
      return {
        tone: 'error',
        text: _(
          'A configuration change did not finish and its protection is still active. Restore a snapshot in History and recovery.',
        ),
        attention: true,
      };
    return {
      tone: 'warning',
      text: _('The last autotune change is not resolved.'),
      attention: true,
    };
  }
  // The record blocks nothing any more, but the rule still runs a strategy
  // that never passed its check, so the configuration is never recorded as
  // last known working and every apply waits (autotune/apply.uc status).
  if (apply.unverified_strategy)
    return {
      tone: 'warning',
      text: _(
        'The last change (%s) was not confirmed by its check, and the configuration was changed since; the rule still uses that strategy. Until you choose another strategy for the rule, turn the rule off or restore a snapshot in History and recovery, Forkop X does not record this configuration as the last known working one, and autotune applies nothing.',
      ).replace('%s', changeName(apply, groupTitle)),
      attention: true,
    };
  if (apply.rollback)
    return {
      tone: 'neutral',
      text: _(
        'The last change (%s) can be rolled back to the configuration before it.',
      ).replace('%s', changeName(apply, groupTitle)),
      attention: false,
    };
  return null;
}

// The confirmation of the rollback: what returns, never options.
export function rollbackConfirmation(
  apply: Forkop.AutotuneRecordedApply,
  groupTitle: string | null,
) {
  if (apply.diagnosis === 'state_unreadable' || !apply.candidate)
    return {
      title: _('Roll back the last autotune change?'),
      message: _('The record of the last autotune change is damaged.'),
      consequences: [
        _(
          'Forkop X restores the last known working configuration if the current one differs from it, and reloads the service.',
        ),
        _(
          'Every change made since the last known working configuration is undone, your own edits included. The current configuration is kept as a "Before restore" snapshot in History and recovery.',
        ),
        _('The damaged record is kept aside for inspection.'),
      ],
      notes: [] as string[],
      confirmLabel: _('Roll back'),
    };
  return {
    title: _('Roll back %s?').replace('%s', strategyLabel(apply.candidate)),
    message: groupTitle
      ? _(
          'The strategy of the DPI rule "%s" returns to the one before autotune.',
        ).replace('%s', groupTitle)
      : _('The strategy returns to the one before autotune.'),
    consequences: [
      _(
        'Forkop X restores the "Before autotune" snapshot, reloads the service and checks that the previous strategy works.',
      ),
      _(
        'This strategy is not applied again during the pause after a rollback.',
      ),
    ],
    notes: [] as string[],
    confirmLabel: _('Roll back'),
  };
}

// What the finished rollback means for the user. No result: the router
// did not answer (the request timed out); the rollback may still run.
export function rollbackResultView(
  result: Forkop.AutotuneRollbackResult | null,
): ApplyResultView {
  if (!result)
    return {
      tone: 'warning',
      text: _(
        'The router did not report the outcome of the rollback; it may still be running. This page shows it once the rollback ends.',
      ),
      attention: false,
    };
  if (result.status === 'ok' && result.reason === 'apply_state_unreadable')
    return {
      tone: 'success',
      text: result.restored
        ? _(
            'The last known working configuration is restored; the damaged record is set aside.',
          )
        : _(
            'The damaged record is set aside; the configuration already was the last known working one.',
          ),
      attention: false,
    };
  if (result.status === 'ok')
    return {
      tone: 'success',
      text: _('The configuration before the change is restored.'),
      attention: false,
    };
  if (result.status === 'busy')
    return {
      tone: 'warning',
      text: refusalText('autotune_worker_running'),
      attention: false,
    };
  // An edit committed while the rollback's own reload ran was kept; the
  // runtime may run either configuration (autotune/apply.uc).
  if (
    result.result === 'needs_attention' &&
    result.reason === 'operator_rollback:config_changed_during_rollback'
  )
    return {
      tone: 'error',
      text: _(
        'The rollback did not finish: the configuration was changed while the "Before autotune" snapshot was being restored, and Forkop X kept that change. It is not known whether Forkop X now runs the snapshot or the change: check the rule, or restore the snapshot you need in History and recovery.',
      ),
      attention: true,
    };
  if (result.result === 'needs_attention')
    return {
      tone: 'error',
      text: _('The rollback did not finish. Open History and recovery.'),
      attention: true,
    };
  switch (result.reason) {
    // Also when the configuration was edited right before the restore
    // (UC-017): the restore refused before any change.
    case 'rollback_needs_candidate_config':
    case 'rollback_not_started:config_changed_during_transaction':
      return {
        tone: 'warning',
        text: _(
          'The configuration was changed after the apply, so nothing was rolled back. Restore a snapshot in History and recovery if needed.',
        ),
        attention: false,
      };
    case 'pre_apply_snapshot_missing':
      return {
        tone: 'error',
        text: _(
          'The snapshot to return to is missing; nothing was rolled back.',
        ),
        attention: false,
      };
    case 'last_known_working_missing':
      return {
        tone: 'error',
        text: _(
          'The last known working configuration is missing; nothing was rolled back. Restore a snapshot in History and recovery first.',
        ),
        attention: false,
      };
    // Changes staged on the router with uci would ride along (UC-068);
    // also the rollback of an unreadable record, which names the refusal
    // without the prefix.
    case 'rollback_not_started:uncommitted_uci_changes':
    case 'rollback_uncommitted_uci_changes':
      return {
        tone: 'warning',
        text: _(
          'Nothing was rolled back: the router has uncommitted uci changes of Forkop X (made with "uci set" without a commit). Commit or revert them, then roll back again.',
        ),
        attention: false,
      };
    case 'nothing_to_roll_back':
    case 'no_recorded_apply':
      return {
        tone: 'neutral',
        text: _('There is nothing to roll back.'),
        attention: false,
      };
    case 'service_stopped':
    case 'service_action_in_progress':
      return {
        tone: 'warning',
        text: `${_('Nothing was rolled back')}: ${blockerText(result.reason)}.`,
        attention: false,
      };
    case 'restore_guard_active':
      return {
        tone: 'warning',
        text: `${_('Nothing was rolled back')}: ${blockerText('dpi_guard_present')}.`,
        attention: false,
      };
    // The restore refuses before any change while a failed service change
    // keeps its guard; a restart removes it (UC-019).
    case 'runtime_guard_active':
    case 'rollback_not_started:runtime_guard_active':
      return {
        tone: 'warning',
        text: `${_('Nothing was rolled back')}: ${blockerText('runtime_guard_active')}.`,
        attention: false,
      };
    case 'snapshot_operation_in_progress':
      return {
        tone: 'warning',
        text: `${_('Nothing was rolled back')}: ${blockerText('snapshot_operation_active')}.`,
        attention: false,
      };
  }
  // The restore refused before it changed anything.
  if (result.reason?.startsWith('rollback_not_started'))
    return {
      tone: 'warning',
      text: `${_('Nothing was rolled back')}.`,
      attention: false,
    };
  return { tone: 'error', text: _('The rollback failed.'), attention: false };
}
