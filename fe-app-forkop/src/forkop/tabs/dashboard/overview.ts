import { Forkop } from '../../types';
import { prettyBytes } from '../../../helpers/prettyBytes';
import {
  eventKindLabel,
  eventOutcomeView,
  toEventOutcome,
  type SemanticStatus,
  type StatusTone,
} from '../../ui/status';
import { formatRelativeTime } from '../../ui/time';

// View model of the overview page: short answers, each with a link to the
// page that has the details. Pure, so every state is covered by tests.

export type OverviewPage =
  | 'monitoring'
  | 'diagnostics'
  | 'history'
  | 'rules'
  | 'settings';

export interface OverviewInput {
  health: Forkop.HealthStatus | null;
  // The last health report is kept when a later poll fails, so a guard it
  // showed stays visible; it no longer proves the system healthy (UC-021).
  healthStale?: boolean;
  availability: 'loading' | 'running' | 'stopped' | 'unavailable';
  forkopEnabled: boolean;
  // Stopped by the user, as opposed to down after a failed start or a
  // crash (D-15).
  forkopStoppedByUser: boolean;
  // Not started since boot, as opposed to down after an explicit start
  // (D-15); null when the backend does not report it.
  forkopNotStarted: boolean | null;
  // The service status of the UI state: a start, restart or reload in
  // progress is reported here before the runtime is up.
  forkopStatus: string;
  singBoxRunning: boolean;
  groups: Forkop.OutboundGroup[];
  ruleCount: number | null;
  traffic: { up: number; down: number } | null;
  connections: number | null;
  snapshotCount: number | null;
  lastDiagnosticRun: number | null;
  nowMs: number;
}

export interface OverviewWarning {
  title: string;
  text: string;
  link: { page: OverviewPage; label: string };
}

export interface OverviewLine {
  text: string;
  tone?: StatusTone;
}

export interface OverviewState {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
  stopped: boolean;
}

export interface OverviewGroup {
  name: string;
  node: string;
  latency: string;
  tone: StatusTone;
}

export interface OverviewRouting {
  summary: string;
  live: string;
  groups: OverviewGroup[];
  more: number;
}

export interface OverviewRecovery {
  status: SemanticStatus;
  title: string;
  lines: OverviewLine[];
  // The step that ends a safety guard that is left (UC-019): the card offers
  // the restart itself, the restore is on the History page.
  step?: 'restart' | 'restore';
}

export interface OverviewEvent {
  title: string;
  outcome: { label: string; tone: StatusTone };
  time: string;
}

function lastEvent(health: Forkop.HealthStatus | null) {
  const events = health?.recent_activity || [];
  return events.length ? events[events.length - 1] : null;
}

// What the safety guard that is left means, by what ends it
// (diagnostics/health.uc recovery.action): it does not go on its own unless
// a change still holds it (UC-019, UC-066).
function guardWarningText(action: Forkop.HealthStatus['recovery']['action']) {
  switch (action) {
    case 'restart':
      return _(
        'A failed change left the safety guard in place. Restart Forkop X to remove it.',
      );
    case 'restore':
      return _(
        'A configuration restore did not finish. Restore the last known good snapshot to finish it.',
      );
    case 'wait':
      return _(
        'A configuration change is being applied. Wait until it finishes.',
      );
    default:
      return _(
        'A configuration change was not confirmed. See the recovery details for the next step.',
      );
  }
}

export function overviewWarning(
  health: Forkop.HealthStatus | null,
): OverviewWarning | null {
  if (!health) return null;
  const details = {
    page: 'history' as const,
    label: _('Recovery details'),
  };

  if (health.guard?.active) {
    return {
      title: _('A safety guard is active'),
      text: guardWarningText(health.recovery?.action),
      link: details,
    };
  }
  if (health.package_recovery?.pending) {
    return {
      title: _('Package recovery has not finished'),
      text: _(
        'An interrupted package update is being recovered. Avoid changes until it completes.',
      ),
      link: details,
    };
  }
  if (lastEvent(health)?.status === 'failure') {
    return {
      title: _('The last configuration change failed'),
      text: _('Forkop X kept or restored the previous configuration.'),
      link: details,
    };
  }

  return null;
}

export function overviewState(input: OverviewInput): OverviewState {
  const { health, availability } = input;
  const lines: OverviewLine[] = [];
  let status: SemanticStatus;
  let title: string;

  if (
    availability === 'stopped' &&
    ['starting', 'restarting', 'reloading'].includes(input.forkopStatus)
  ) {
    // Not up yet, and nothing failed so far: a start (boot, Start, the
    // start half of Restart, the WAN retry) or a reload repairing it.
    status = 'busy';
    title =
      input.forkopStatus === 'reloading'
        ? _('Applying changes…')
        : _('Starting…');
  } else if (availability === 'stopped' && input.forkopStoppedByUser) {
    status = 'off';
    title = _('Stopped by user');
    lines.push({
      text: _(
        'Forkop X stays stopped until you start it: reloads, restores and updates do not start it.',
      ),
    });
    lines.push({
      text: _('Traffic goes through the router without Forkop X.'),
    });
  } else if (availability === 'stopped' && input.forkopNotStarted === true) {
    status = 'off';
    title = _('Not started');
    lines.push({
      text: _(
        'Forkop X was not started since the router booted: reloads, restores and updates do not start it.',
      ),
    });
    lines.push({
      text: _('Traffic goes through the router without Forkop X.'),
    });
  } else if (availability === 'stopped') {
    // Nobody stopped it: a start failed or the runtime went down after an
    // explicit start. A backend that does not report whether Forkop was
    // started since boot says so only with autostart on.
    const failed = input.forkopNotStarted === false || input.forkopEnabled;
    status = failed ? 'error' : 'off';
    title = _('Not running');
    if (failed) {
      lines.push({
        text: _(
          'Forkop X was not stopped by the user: its start failed or it stopped unexpectedly.',
        ),
        tone: 'error',
      });
    }
    lines.push({
      text: _('Traffic goes through the router without Forkop X.'),
    });
  } else if (availability === 'loading') {
    status = 'busy';
    title = _('Checking…');
  } else if (availability === 'unavailable') {
    status = 'unknown';
    title = _('State unavailable');
  } else if (health?.overall === 'transitioning') {
    status = 'busy';
    title = _('Applying changes…');
  } else if (health?.overall === 'error') {
    status = 'error';
    title = _('Forkop X needs attention');
  } else {
    // Running, but only a health report proves it healthy: none yet, one
    // that failed to load, or an unknown one is not (UC-021).
    const known =
      !input.healthStale &&
      (health?.overall === 'ok' || health?.overall === 'recovered');
    status =
      health?.overall === 'recovered'
        ? 'warning'
        : known
          ? 'healthy'
          : 'unknown';
    title = _('Forkop X is running');
    if (health?.overall === 'recovered') {
      lines.push({
        text: _('The last change was rolled back automatically.'),
        tone: 'warning',
      });
    }
    if (!known) lines.push({ text: _('Health state unavailable') });
  }

  if (availability === 'running') {
    lines.push(
      input.singBoxRunning
        ? { text: _('sing-box is running') }
        : { text: _('sing-box is not running'), tone: 'error' },
    );
    if (health?.dns?.status === 'warning') {
      lines.push({
        text: _('Router DNS is not pointed to Forkop X'),
        tone: 'warning',
      });
    }
  }
  lines.push({
    text: input.forkopEnabled ? _('Autostart is on') : _('Autostart is off'),
  });
  lines.push({
    text: input.lastDiagnosticRun
      ? _('Last diagnostics: %s').replace(
          '%s',
          formatRelativeTime(input.lastDiagnosticRun / 1000, input.nowMs),
        )
      : _('Diagnostics has not been run yet'),
  });

  return { status, title, lines, stopped: availability === 'stopped' };
}

function latencyTone(latency: number): StatusTone {
  if (!latency) return 'neutral';
  if (latency < 800) return 'success';
  return latency < 1500 ? 'warning' : 'error';
}

const MAX_GROUPS = 3;

export function overviewRouting(input: OverviewInput): OverviewRouting {
  const groups = input.groups.filter((group) => group.outbounds.length);
  // Node groups are only known while sing-box runs.
  const groupsKnown = input.availability === 'running' || groups.length > 0;
  let summary = '';
  if (input.ruleCount !== null && groupsKnown) {
    summary = _('%d rules · %d node groups')
      .replace('%d', String(input.ruleCount))
      .replace('%d', String(groups.length));
  } else if (input.ruleCount !== null) {
    summary = _('%d rules').replace('%d', String(input.ruleCount));
  } else if (groupsKnown) {
    summary = _('%d node groups').replace('%d', String(groups.length));
  }

  let live = '';
  if (input.availability === 'stopped') {
    live = _('Routing is paused while Forkop X is stopped.');
  } else if (input.connections !== null) {
    live = _('%d connections now').replace('%d', String(input.connections));
    if (input.traffic) {
      live += ` · ↓ ${prettyBytes(input.traffic.down)}/s ↑ ${prettyBytes(input.traffic.up)}/s`;
    }
  }

  return {
    summary,
    live,
    groups: groups.slice(0, MAX_GROUPS).map((group) => {
      const selected =
        group.outbounds.find((outbound) => outbound.selected) ||
        group.outbounds[0];
      return {
        name: group.displayName,
        node: selected.displayName,
        latency: selected.latency ? `${selected.latency} ms` : _('no data'),
        tone: latencyTone(selected.latency),
      };
    }),
    more: Math.max(0, groups.length - MAX_GROUPS),
  };
}

export function overviewRecovery(input: OverviewInput): OverviewRecovery {
  const { health } = input;
  if (!health) {
    return { status: 'unknown', title: _('State unavailable'), lines: [] };
  }

  const lines: OverviewLine[] = [];
  const reload = health.last_reload;
  if (reload) {
    const outcome = eventOutcomeView(toEventOutcome(reload.status));
    lines.push({
      text: _('Last reload: %s').replace(
        '%s',
        `${outcome.label} · ${formatRelativeTime(reload.timestamp, input.nowMs)}`,
      ),
      tone: outcome.tone,
    });
  } else {
    lines.push({ text: _('No reload recorded yet') });
  }
  if (input.snapshotCount !== null) {
    lines.push({
      text: _('Snapshots: %d').replace('%d', String(input.snapshotCount)),
    });
  }

  const state = recoveryState(health);
  // A stale report may still show what is left, never that nothing is.
  if (input.healthStale && state.status === 'healthy')
    return { status: 'unknown', title: _('State unavailable'), lines };
  return { ...state, lines: [...state.lines, ...lines] };
}

// Whatever is left is never "No recovery needed" (UC-021): a safety guard,
// named by what ends it (UC-019, UC-066), an unfinished package recovery,
// or a failed last change (health.uc recovery.pending without a guard: the
// previous configuration was kept, nothing is in progress).
function recoveryState(health: Forkop.HealthStatus): OverviewRecovery {
  if (health.guard?.active) {
    switch (health.recovery?.action) {
      case 'restart':
        return {
          status: 'needs_attention',
          title: _('Restart required'),
          step: 'restart',
          lines: [
            {
              text: _(
                'A failed change left the safety guard in place: restart Forkop X to remove it.',
              ),
              tone: 'error',
            },
          ],
        };
      case 'restore':
        return {
          status: 'needs_attention',
          title: _('Restore required'),
          step: 'restore',
          lines: [
            {
              text: _(
                'A configuration restore did not finish: restore the last known good snapshot to finish it.',
              ),
              tone: 'error',
            },
          ],
        };
      case 'wait':
        return { status: 'busy', title: _('Change in progress'), lines: [] };
      default:
        return {
          status: 'needs_attention',
          title: _('Protection is active'),
          lines: [],
        };
    }
  }
  if (health.package_recovery?.pending) {
    return {
      status: 'needs_attention',
      title: _('Package recovery has not finished'),
      lines: [],
    };
  }
  if (health.recovery?.pending) {
    return {
      status: 'error',
      title: _('The last configuration change failed'),
      lines: [
        {
          text: _('Forkop X kept or restored the previous configuration.'),
          tone: 'error',
        },
      ],
    };
  }
  return { status: 'healthy', title: _('No recovery needed'), lines: [] };
}

export function overviewLastEvent(input: OverviewInput): OverviewEvent | null {
  const event = lastEvent(input.health);
  if (!event) return null;

  return {
    title: eventKindLabel(event.kind),
    outcome: eventOutcomeView(toEventOutcome(event.status)),
    time: formatRelativeTime(event.timestamp, input.nowMs),
  };
}
