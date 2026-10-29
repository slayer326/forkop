import type { IDiagnosticsChecksStoreItem } from '../../services';
import { DIAGNOSTICS_CHECKS } from './checks/contstants';

// A failed check answers four questions: what broke (title), what it means,
// what was proven (the failing check items) and what to do.

type Check = IDiagnosticsChecksStoreItem;

export type AdviceLink = 'settings' | 'rules' | 'nodes' | 'overview';

export interface CheckAdvice {
  meaning: string;
  action: string;
  link?: AdviceLink;
}

export function checkAdvice(
  check: Pick<Check, 'code' | 'state' | 'description'>,
) {
  if (check.state !== 'error' && check.state !== 'warning') return null;
  switch (check.code) {
    case DIAGNOSTICS_CHECKS.DNS:
      return {
        meaning: _(
          'Domains in rules may not resolve, or resolve past Forkop, so their rules do not apply.',
        ),
        action: _(
          'Check the DNS server addresses in Settings or choose another server.',
        ),
        link: 'settings',
      } satisfies CheckAdvice;
    case DIAGNOSTICS_CHECKS.SINGBOX:
      return {
        meaning: _(
          'Traffic of the rules does not reach sing-box, so connections through rules fail.',
        ),
        action: _(
          'Restart Forkop X on the Overview. If it repeats, open the logs under Available actions.',
        ),
        link: 'overview',
      } satisfies CheckAdvice;
    case DIAGNOSTICS_CHECKS.NFT:
      return {
        meaning: _(
          'Firewall rules that send traffic to Forkop are missing or not hit, so rules may not apply.',
        ),
        action: _(
          'Restart Forkop X. If another add-on marks traffic, make sure it does not conflict.',
        ),
        link: 'overview',
      } satisfies CheckAdvice;
    case DIAGNOSTICS_CHECKS.OUTBOUNDS:
      return {
        meaning: _(
          'Some connections or nodes do not respond, so sites of their rules may not open.',
        ),
        action: _(
          'Test latency in Monitoring → Nodes and groups, choose a working node or update the subscription.',
        ),
        link: 'nodes',
      } satisfies CheckAdvice;
    case DIAGNOSTICS_CHECKS.FAKEIP:
      // The check itself could not finish: nothing is proven about devices.
      if (
        check.description === _('Browser FakeIP check could not be completed')
      )
        return {
          meaning: _(
            'This browser could not reach the check service, so FakeIP for devices is not proven either way.',
          ),
          action: _(
            'Retry the check when this device has internet access through the router.',
          ),
        } satisfies CheckAdvice;
      if (
        check.description ===
        _('FakeIP works; public IP comparison is inconclusive')
      )
        return {
          meaning: _(
            'FakeIP works; only the comparison with the control address did not give an answer.',
          ),
          action: _('Usually harmless. Retry the check later.'),
        } satisfies CheckAdvice;
      return {
        meaning: _(
          'Devices may bypass the router DNS, so domain rules do not apply to them.',
        ),
        action: _(
          'Make sure devices use the router as DNS: turn off secure DNS (DoH, Private DNS) in browsers and phones.',
        ),
      } satisfies CheckAdvice;
    default:
      return {
        meaning: _('Part of Forkop X does not work as expected.'),
        action: _(
          'Retry the check. If it repeats, open the logs under Available actions.',
        ),
      } satisfies CheckAdvice;
  }
}

// What the check established: its failing items, else its description.
export function provenFacts(check: Check) {
  const failing = check.items.filter(
    (item) => item.state === 'error' || item.state === 'warning',
  );
  return failing.length
    ? failing.map((item) =>
        item.value ? `${item.key}: ${item.value}` : item.key,
      )
    : [check.description].filter(Boolean);
}

const RANK: Record<string, number> = { error: 0, warning: 1 };

export function groupChecks(checks: Check[]) {
  const sorted = [...checks].sort((a, b) => a.order - b.order);
  return {
    attention: sorted
      .filter((check) => check.state === 'error' || check.state === 'warning')
      .sort((a, b) => RANK[a.state] - RANK[b.state] || a.order - b.order),
    other: sorted.filter(
      (check) => !['error', 'warning', 'success'].includes(check.state),
    ),
    passed: sorted.filter((check) => check.state === 'success'),
  };
}

export function checkSummary(checks: Check[]) {
  const count = (state: Check['state']) =>
    checks.filter((check) => check.state === state).length;
  const errors = count('error');
  const warnings = count('warning');
  const passed = count('success');
  const parts = [
    errors ? _('Errors: %d').replace('%d', String(errors)) : '',
    warnings ? _('Warnings: %d').replace('%d', String(warnings)) : '',
    passed ? _('Passed: %d').replace('%d', String(passed)) : '',
  ].filter(Boolean);
  return { errors, warnings, passed, text: parts.join(' · ') };
}
