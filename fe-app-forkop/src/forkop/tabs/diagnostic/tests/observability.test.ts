import { beforeEach, describe, expect, it, vi } from 'vitest';

const connectivityTest = vi.fn();
vi.mock('../../../methods', () => ({
  ForkopShellMethods: {
    connectivityTest: (...args: unknown[]) => connectivityTest(...args),
  },
}));
vi.mock('../../../../icons', () => {
  const icon = () => 'svg';
  return {
    renderCheckIcon24: icon,
    renderCircleAlertIcon24: icon,
    renderCircleCheckIcon24: icon,
    renderCircleSlashIcon24: icon,
    renderCircleXIcon24: icon,
    renderLoaderCircleIcon24: icon,
    renderTriangleAlertIcon24: icon,
    renderXIcon24: icon,
    renderSearchIcon24: icon,
  };
});
vi.mock('../../../../partials', () => ({ renderButton: () => 'button' }));
const copyToClipboard = vi.fn();
vi.mock('../../../../helpers/copyToClipboard', () => ({
  copyToClipboard: (text: string) => copyToClipboard(text),
}));

(globalThis as unknown as { document: unknown }).document = {
  querySelector: () => null,
};

interface FakeNode {
  tag: string;
  attrs: Record<string, unknown>;
  children: unknown[];
  appendChild(child: unknown): void;
}
(globalThis as unknown as { E: unknown }).E = (
  tag: string,
  attrs: Record<string, unknown> = {},
  children: unknown = [],
): FakeNode => ({
  tag,
  attrs,
  children: Array.isArray(children) ? children : [children],
  appendChild(child) {
    this.children.push(child);
  },
});

function walk(node: unknown, visit: (node: FakeNode) => void) {
  if (!node || typeof node !== 'object') return;
  const fake = node as FakeNode;
  visit(fake);
  for (const child of fake.children || []) walk(child, visit);
}
function ids(node: unknown) {
  const found: string[] = [];
  walk(
    node,
    (n) => typeof n.attrs?.id === 'string' && found.push(n.attrs.id as string),
  );
  return found;
}
function text(node: unknown): string {
  if (typeof node === 'string') return node;
  if (!node || typeof node !== 'object') return '';
  return ((node as FakeNode).children || []).map(text).join(' ');
}

import {
  changeType,
  loadTargets,
  probe,
  resultView,
  validateTarget,
  type Target,
} from '../connectivityMatrix';
import {
  dnsRow,
  probeRow,
  routeRow,
  routeTraceFailureText,
  siteConclusion,
} from '../siteCheck';
import { validationView } from '../dpiPlayground';
import { checkStatus, eventStatus, healthStatus } from '../statusLabels';
import {
  diagnosticActionSummary,
  renderCheckRow,
  renderCheckSection,
  renderChecks,
} from '../partials/renderCheckSection';
import { checkAdvice, checkSummary, provenFacts } from '../checkCards';
import { lastRunText, saveLastRun } from '../partials/renderRunAction';
import { render } from '../renderDiagnostic';
import { styles } from '../styles';
import { setReadonlyMode } from '../../../services/accessMode.service';
import type { Forkop } from '../../../types';

const target = (overrides: Partial<Target> = {}): Target => ({
  host: 'example.org',
  type: 'HTTPS',
  port: '443',
  ...overrides,
});
const result = (
  overrides: Partial<Forkop.ConnectivityResult> = {},
): Forkop.ConnectivityResult => ({
  host: 'example.org',
  type: 'HTTPS',
  port: 443,
  status: 'ok',
  error: null,
  latency_ms: 42,
  origin: 'router',
  ...overrides,
});

describe('connectivity rows', () => {
  it('defaults to HTTPS targets and migrates stored TLS rows', () => {
    expect(loadTargets({ getItem: () => null })).toEqual([
      { host: 'cloudflare.com', type: 'HTTPS', port: '443' },
      { host: 'telegram.org', type: 'HTTPS', port: '443' },
    ]);
    const stored = [{ host: 'a.example', type: 'TLS', port: '443' }];
    expect(loadTargets({ getItem: () => JSON.stringify(stored) })[0].type).toBe(
      'HTTPS',
    );
    const many = Array.from({ length: 12 }, (_, i) => ({
      host: `h${i}.example`,
      type: 'TCP',
      port: '443',
    }));
    many[1].host = 'x'.repeat(254);
    expect(loadTargets({ getItem: () => JSON.stringify(many) })).toHaveLength(
      9,
    );
    expect(loadTargets({ getItem: () => '{broken' })).toHaveLength(2);
  });

  it('follows type defaults but keeps a port the user typed', () => {
    expect(changeType(target({ type: 'HTTP', port: '80' }), 'HTTPS').port).toBe(
      '443',
    );
    expect(
      changeType(target({ type: 'HTTPS', port: '443' }), 'HTTP').port,
    ).toBe('80');
    expect(
      changeType(target({ type: 'HTTP', port: '8080' }), 'HTTPS').port,
    ).toBe('8080');
    expect(changeType(target({ type: 'HTTPS', port: '443' }), 'DNS').port).toBe(
      '',
    );
    expect(changeType(target({ type: 'DNS', port: '' }), 'HTTPS').port).toBe(
      '443',
    );
    expect(changeType(target({ type: 'HTTPS', port: '443' }), 'TCP').port).toBe(
      '443',
    );
    expect(changeType(target({ type: 'DNS', port: '' }), 'TCP').port).toBe('');
  });

  it('validates input before calling the router', () => {
    expect(validateTarget(target({ host: ' ' }))).toBe('Enter an address');
    expect(
      validateTarget(target({ type: 'DNS', host: '192.0.2.1', port: '' })),
    ).toBe('DNS check needs a domain name');
    expect(validateTarget(target({ type: 'DNS', port: '' }))).toBeNull();
    expect(validateTarget(target({ type: 'TCP', port: '' }))).toBe(
      'Enter a port',
    );
    expect(validateTarget(target({ port: '70000' }))).toBe(
      'Port must be between 1 and 65535',
    );
    expect(validateTarget(target({ host: '2001:db8::1' }))).toBeNull();
  });

  it('renders human-readable results without raw enums or JSON', () => {
    expect(resultView({ state: 'idle' })).toEqual({
      text: 'Not checked',
      tone: 'neutral',
    });
    expect(resultView({ state: 'running' })).toEqual({
      text: 'Checking…',
      tone: 'loading',
    });
    const ok = resultView({
      state: 'done',
      result: result({ http_code: 301 }),
    });
    expect(ok).toEqual({
      text: '✓ Reachable · 42 ms · HTTP 301',
      tone: 'success',
    });
    const dns = resultView({
      state: 'done',
      result: result({ type: 'DNS', port: null, address: '93.184.216.34' }),
    });
    expect(dns.text).toContain('93.184.216.34');
    const cases: Array<[Forkop.ConnectivityResult['error'], string]> = [
      ['timeout', 'Timed out'],
      ['nxdomain', 'Domain does not exist'],
      ['dns_failed', 'DNS name did not resolve'],
      ['connect_failed', 'Connection refused or host unreachable'],
      ['tls_failed', 'TLS or certificate error'],
      ['no_response', 'Server closed the connection without a response'],
      ['tool_missing', 'Probe tool is missing on the router'],
    ];
    for (const [error, message] of cases) {
      const view = resultView({
        state: 'done',
        result: result({
          status: error === 'timeout' ? 'timeout' : 'error',
          error,
        }),
      });
      expect(view.text).toBe(`✕ ${message}`);
      expect(view.text).not.toMatch(
        /[{}]|\b(connect_failed|tls_failed|nxdomain|no_response)\b/,
      );
    }
  });

  beforeEach(() => connectivityTest.mockReset());

  it('never calls the router for invalid rows and sends DNS without a port', async () => {
    expect(await probe(target({ host: '' }))).toEqual({
      state: 'invalid',
      message: 'Enter an address',
    });
    expect(connectivityTest).not.toHaveBeenCalled();
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ type: 'DNS', port: null }),
    });
    await probe(target({ type: 'DNS', port: '' }));
    expect(connectivityTest).toHaveBeenCalledWith('example.org', 'DNS', '');
  });

  it('only accepts a result whose type and port match the request', async () => {
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ type: 'TCP' }),
    });
    expect(await probe(target())).toEqual({ state: 'idle' });
    connectivityTest.mockResolvedValue({
      success: true,
      data: result({ port: 8443 }),
    });
    expect(await probe(target())).toEqual({ state: 'idle' });
    connectivityTest.mockResolvedValue({ success: true, data: result() });
    expect(await probe(target())).toMatchObject({ state: 'done' });
    connectivityTest.mockResolvedValue({ success: false, error: 'denied' });
    expect(await probe(target())).toEqual({
      state: 'invalid',
      message: 'The router rejected this check',
    });
  });
});

describe('route check', () => {
  const unknown = { value: null, provenance: 'unknown' as const };
  const trace = (
    overrides: Partial<Forkop.RouteTrace> = {},
  ): Forkop.RouteTrace => ({
    target: {
      value: 'example.org',
      source: '',
      source_applied: false,
      protocol: 'TCP',
      port: '',
      provenance: 'simulated',
    },
    dns: { address: '93.184.216.34', provenance: 'observed' },
    rule: unknown,
    action: unknown,
    outbound: unknown,
    dpi: unknown,
    interface: {
      value: 'pppoe-wan',
      provenance: 'observed',
      context: 'router',
    },
    runtime: unknown,
    ...overrides,
  });

  it('names the calculated route with the rule and DPI strategy', () => {
    const row = routeRow(
      trace({
        rule: { value: 'YouTube', section: 'youtube', provenance: 'simulated' },
        action: { value: 'zapret', provenance: 'simulated' },
        outbound: { value: 'youtube-out', provenance: 'simulated' },
        dpi: {
          value: 'zapret',
          strategy: 'multisplit',
          strategy_custom: false,
          provenance: 'configured',
        },
      }),
    );
    expect(row).toMatchObject({
      value: 'DPI · rule «YouTube» · Zapret · multisplit',
      provenance: 'simulated',
    });
    expect(
      routeRow(
        trace({
          rule: {
            value: null,
            provenance: 'simulated',
            reason: 'no_rule_matched',
          },
          action: { value: 'direct', provenance: 'simulated' },
        }),
      ),
    ).toMatchObject({ value: 'Direct', note: 'No rule matched' });
  });

  it('says why the route is not calculated instead of hiding it', () => {
    const row = routeRow(
      trace({
        rule: {
          value: null,
          provenance: 'unknown',
          reason: 'source_scoped_rule',
        },
      }),
    );
    expect(row).toMatchObject({
      value: 'Rule not calculated',
      provenance: 'unknown',
    });
    expect(row.note).toContain('choose a device');
    expect(
      routeRow(
        trace({
          rule: {
            value: null,
            provenance: 'unknown',
            reason: 'undecidable_matcher',
          },
        }),
      ).note,
    ).toContain('cannot be checked here');
  });

  it('marks DNS as observed and an IP literal as needing no DNS', () => {
    expect(dnsRow(trace())).toMatchObject({
      value: '93.184.216.34',
      provenance: 'observed',
    });
    expect(
      dnsRow(trace({ dns: { address: '198.18.0.5', provenance: 'observed' } }))
        .value,
    ).toBe('198.18.0.5 (FakeIP)');
    expect(
      dnsRow(trace({ dns: { address: null, provenance: 'unknown' } })),
    ).toMatchObject({ value: 'Not resolved', tone: 'error' });
    expect(
      dnsRow(trace({ dns: { address: '1.1.1.1', provenance: 'simulated' } }))
        .note,
    ).toBe('An IP address needs no DNS');
  });

  it('concludes no more than the router established', () => {
    const ok = { state: 'done' as const, result: result() };
    const failed = {
      state: 'done' as const,
      result: result({ status: 'error', error: 'connect_failed' }),
    };
    expect(probeRow(ok).provenance).toBe('observed');
    expect(siteConclusion(trace(), ok)).toContain('opens from the router');
    const dpi = trace({ action: { value: 'zapret', provenance: 'simulated' } });
    expect(siteConclusion(dpi, failed)).toContain('strategy does not work');
    expect(siteConclusion(dpi, failed)).toContain(
      'different path than devices',
    );
    expect(
      siteConclusion(
        trace({ dns: { address: null, provenance: 'unknown' } }),
        ok,
      ),
    ).toContain('does not resolve');
  });
});

describe('route check failures', () => {
  it('asks to fix the input only when the target was rejected', () => {
    expect(
      routeTraceFailureText({
        success: true,
        data: { error: 'invalid_input' },
      }),
    ).toBe('Enter a valid domain or IP address');
  });

  it('reports a failed check as a failure, not as a typing mistake', () => {
    for (const response of [
      { success: false },
      { success: true, data: {} },
      { success: true, data: { error: 'something_else' } },
    ]) {
      expect(routeTraceFailureText(response)).toBe(
        'The route check did not complete. Try again.',
      );
    }
  });
});

describe('statuses', () => {
  it('uses the shared status vocabulary', () => {
    expect(eventStatus('success').text).toBe('Succeeded');
    expect(eventStatus('failure').text).toBe('Failed');
    expect(eventStatus('recovered').text).toBe('Recovered');
    expect(eventStatus('needs_attention').text).toBe('Needs attention');
    expect(healthStatus('ok').text).toBe('Healthy');
    expect(healthStatus('unknown').text).toBe('Not available for checking');
    expect(checkStatus('skipped').text).toBe('Not checked');
    expect(checkStatus('loading').text).toBe('Checking…');
    expect(checkStatus('warning').text).toBe('Needs attention');
  });
});

describe('DPI syntax check', () => {
  it('reports a human-readable verdict', () => {
    expect(
      validationView({ success: true, data: { valid: true, message: '' } }),
    ).toEqual({
      text: '✓ Syntax is correct',
      tone: 'success',
    });
    expect(
      validationView({
        success: true,
        data: { valid: false, message: "Unknown NFQWS flag '--x'." },
      }).text,
    ).toBe("✕ Unknown NFQWS flag '--x'.");
    expect(validationView({ success: false }).text).toBe(
      'Syntax check is unavailable',
    );
    expect(validationView({ success: true, data: 'garbage' }).tone).toBe(
      'error',
    );
  });
});

describe('system checks', () => {
  const handlers = { onRetry: vi.fn(), busy: false };
  const dnsFailed = {
    order: 1,
    code: 'DNS',
    title: 'DNS checks',
    description: 'Checks failed',
    state: 'error' as const,
    items: [
      { key: 'Bootstrap', value: 'timeout', state: 'error' as const },
      { key: 'Main DNS', value: 'ok', state: 'success' as const },
    ],
  };

  it('explains a failed check: meaning, proof and what to do', () => {
    const card = renderCheckSection(dnsFailed, handlers);
    const body = text(card);
    for (const heading of ['What it means', 'What was proven', 'What to do'])
      expect(body).toContain(heading);
    expect(provenFacts(dnsFailed)).toEqual(['Bootstrap: timeout']);
    expect(checkAdvice(dnsFailed)?.link).toBe('settings');
    expect(checkAdvice({ ...dnsFailed, state: 'success' })).toBeNull();
    expect(
      provenFacts({
        ...dnsFailed,
        items: [{ key: 'Package missing', value: '', state: 'error' }],
      }),
    ).toEqual(['Package missing']);
  });

  it('does not blame devices when the FakeIP check could not run', () => {
    const fakeip = {
      ...dnsFailed,
      code: 'FAKEIP',
      state: 'warning' as const,
      description: 'Browser FakeIP check could not be completed',
    };
    expect(checkAdvice(fakeip)?.meaning).toContain('not proven');
    expect(
      checkAdvice({ ...fakeip, description: 'Checks failed' })?.meaning,
    ).toContain('bypass the router DNS');
  });

  it('retries only the failed check', () => {
    const card = renderCheckSection(dnsFailed, handlers);
    let retry: FakeNode | undefined;
    walk(card, (n) => {
      if (n.tag === 'button' && text(n).includes('Retry this check')) retry = n;
    });
    (retry?.attrs.click as () => void)();
    expect(handlers.onRetry).toHaveBeenCalledWith('DNS');
    let busyRetry: FakeNode | undefined;
    walk(renderCheckSection(dnsFailed, { ...handlers, busy: true }), (n) => {
      if (n.tag === 'button' && text(n).includes('Retry this check'))
        busyRetry = n;
    });
    expect(busyRetry?.attrs.disabled).toBe(true);
  });

  it('keeps diagnostic groups in their configured order with passed details visible', () => {
    const passed = {
      ...dnsFailed,
      code: 'NFT',
      order: 3,
      state: 'success' as const,
    };
    const nodes = renderChecks([passed, dnsFailed], handlers);
    expect(text(nodes[0])).toBe('Errors: 1 · Passed: 1');
    expect(text(nodes[1])).toContain('What it means');
    expect((nodes[2] as unknown as FakeNode).tag).toBe('div');
    expect(text(nodes[2])).toContain('Main DNS');
    expect(text(nodes[2])).not.toContain('Passed checks: 1');
    expect(checkSummary([passed]).text).toBe('Passed: 1');
    const idle = renderCheckRow({ ...dnsFailed, state: 'skipped', items: [] });
    expect(text(idle)).toContain('Not checked');
    walk(idle, (n) => expect(n.tag).not.toBe('details'));
  });

  it('keeps failed detail available for copying and records the last run', () => {
    const value = diagnosticActionSummary({
      title: 'Bootstrap DNS failed',
      description: '8.8.8.8 timed out',
      items: [{ key: 'DNS', value: 'timeout', state: 'error' }],
    } as Parameters<typeof diagnosticActionSummary>[0]);
    expect(value).toContain('DNS: timeout');
    const store = new Map<string, string>();
    const storage = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
    };
    expect(lastRunText(storage)).toBe('No check has been run yet');
    saveLastRun(storage, Date.UTC(2026, 8, 27));
    expect(lastRunText(storage)).toMatch(/^Last check: /);
  });
});

describe('page layout', () => {
  it('keeps diagnostics and support in separate responsive columns without fake controls', () => {
    setReadonlyMode(false);
    const page = render();
    const found = ids(page);
    expect((page as unknown as FakeNode).attrs.class).toBe('fkp-diag');
    expect(styles).toContain(
      'grid-template-columns: minmax(0, 1.7fr) minmax(280px, 0.85fr)',
    );
    expect(text(page)).toContain('Troubleshooting');
    expect(text(page)).toContain('Service actions');
    expect(text(page)).toContain('Available actions');
    for (const id of [
      'fkp_diagnostic-page-checks',
      'fkp_diagnostic-page-service-actions',
      'fkp_diagnostic-run-reason',
      'site-check-target',
      'site-check-device',
      'connectivity-rows',
      'technical-data',
      'dpi-strategy',
    ])
      expect(found).toContain(id);
    for (const id of [
      'trace-target',
      'route-debugger',
      'fkp_diagnostic-page-wiki',
      'dpi-strategy-a',
      'dpi-strategy-b',
    ])
      expect(found).not.toContain(id);
    expect(text(page)).toContain('DPI strategy syntax check');
    expect(text(page)).not.toMatch(/Playground|compare/i);
  });

  it('replaces the DPI validator with an explanation for read-only sessions', () => {
    setReadonlyMode(true);
    const page = render();
    expect(ids(page)).not.toContain('fkp_diagnostic-page-service-actions');
    expect(ids(page)).not.toContain('dpi-strategy');
    expect(ids(page)).not.toContain('dpi-validate');
    expect(text(page)).toContain('Available to administrators only.');
    setReadonlyMode(false);
  });
});

describe('unsupported checks and responsive layout', () => {
  it('shows an unsupported check as not available, with its reason', () => {
    expect(checkStatus('unsupported')).toEqual({
      text: 'Not available for checking',
      tone: 'neutral',
    });
    const node = renderCheckRow({
      order: 8,
      code: 'OUTBOUNDS',
      title: 'Outbounds checks',
      description: 'Outbound checks need access to the Forkop configuration.',
      state: 'unsupported',
      items: [],
    });
    expect(text(node)).toContain('Not available for checking');
    expect(text(node)).toContain('need access to the Forkop configuration');
    expect(text(node)).not.toContain('Error');
    walk(node, (n) => expect(n.tag).not.toBe('details'));
  });

  it('lets the reachability actions size to translated labels', () => {
    const conn = styles.slice(styles.indexOf('.fkp-conn {'));
    expect(conn).toMatch(/grid-template-columns:[^;]*max-content;/);
    expect(styles).toMatch(
      /\.fkp-conn__head,\s*\.fkp-conn__row\s*\{\s*display: contents;/,
    );
    expect(styles).not.toMatch(/104px/);
  });

  it('keeps long check names and badges wrappable', () => {
    // Name and value stack, and words break only when they do not fit a line.
    expect(styles).toMatch(
      /\.fkp-check__item \{[^}]*grid-template-columns: 16px minmax\(0, 1fr\);/,
    );
    expect(styles).not.toContain('16px minmax(0, max-content) minmax(0, 1fr)');
    expect(styles).not.toMatch(
      /\.fkp-check[^{]*\{[^}]*overflow-wrap: anywhere/,
    );
    expect(styles).toMatch(/\.fkp-check__head \{[^}]*flex-wrap: wrap;/);
    expect(styles).toMatch(
      /\.fkp-diag-facts \.fkp-diag-badge[\s\S]*?white-space: normal/,
    );
  });
});

describe('copy over plain HTTP', () => {
  it('copies failed check details through the execCommand helper', () => {
    const node = renderCheckSection(
      {
        order: 1,
        code: 'DNS',
        title: 'DNS checks',
        description: 'Checks failed',
        state: 'error',
        items: [{ key: 'Bootstrap', value: 'timeout', state: 'error' }],
      },
      { onRetry: () => {}, busy: false },
    );
    let copy: FakeNode | undefined;
    walk(node, (n) => {
      if (n.tag === 'button' && text(n).includes('Copy details')) copy = n;
    });
    (copy?.attrs.click as () => void)();
    expect(copyToClipboard).toHaveBeenCalledWith(
      expect.stringContaining('Bootstrap: timeout'),
    );
  });
});
