import { describe, expect, it } from 'vitest';
import {
  connectionActions,
  connectionPath,
  formatEndpoint,
  matchesPathFilter,
  pathSummary,
  routeTagFromRule,
  trafficSortValue,
  type RouteRule,
} from '../connectionView';

const rules: Record<string, RouteRule> = {
  'main-out': { name: 'main', label: 'Main VPN', action: 'connection' },
  'main-urltest-out': { name: 'main', label: 'Main VPN', action: 'connection' },
  'youtube-out': {
    name: 'youtube',
    label: 'YouTube',
    action: 'zapret',
    dpiProvider: 'zapret',
    dpiStrategy: 'multisplit',
    dpiCustom: false,
  },
  'discord-out': {
    name: 'discord',
    label: 'Discord',
    action: 'byedpi',
    dpiProvider: 'byedpi',
    dpiStrategy: '',
    dpiCustom: true,
  },
};
const byTag = (tag: string) => rules[tag] || null;

describe('connection path', () => {
  it('finds the rule from the end of the chain and names the chosen node', () => {
    const path = connectionPath(
      ['node-latvia', 'main-urltest-out', 'main-out'],
      'domain_suffix=example.com => route(main-out)',
      byTag,
    );
    expect(path).toMatchObject({ kind: 'connection', node: 'node-latvia' });
    expect(pathSummary(path)).toEqual({
      kind: 'connection',
      kindLabel: 'Connection',
      primary: 'Main VPN',
      secondary: 'node-latvia',
    });
  });

  it('names the DPI provider and strategy, never raw options', () => {
    expect(
      pathSummary(connectionPath(['youtube-out'], '', byTag)),
    ).toMatchObject({
      kindLabel: 'DPI',
      primary: 'YouTube',
      secondary: 'Zapret · multisplit',
    });
    expect(
      pathSummary(connectionPath(['discord-out'], '', byTag)).secondary,
    ).toBe('ByeDPI · custom strategy');
  });

  it('falls back to the route() of the matched rule', () => {
    expect(routeTagFromRule("rule_set=x => route('youtube-out')")).toBe(
      'youtube-out',
    );
    expect(
      connectionPath([], 'rule_set=x => route(youtube-out)', byTag).rule?.name,
    ).toBe('youtube');
  });

  it('classifies bypass, block, direct and unknown outbounds', () => {
    expect(connectionPath(['bypass-out'], '', byTag).kind).toBe('bypass');
    expect(connectionPath([], 'ip_cidr=1.2.3.4 => reject', byTag).kind).toBe(
      'block',
    );
    expect(connectionPath(['direct-out'], 'final', byTag).kind).toBe('direct');
    expect(pathSummary(connectionPath([], '', byTag)).secondary).toBe(
      'No rule matched',
    );
    expect(connectionPath(['mystery-out'], '', byTag)).toMatchObject({
      kind: 'unknown',
      tag: 'mystery-out',
    });
  });

  it('filters by path kind or by rule', () => {
    const path = connectionPath(['youtube-out'], '', byTag);
    expect(matchesPathFilter(path, 'all')).toBe(true);
    expect(matchesPathFilter(path, 'kind:dpi')).toBe(true);
    expect(matchesPathFilter(path, 'kind:connection')).toBe(false);
    expect(matchesPathFilter(path, 'rule:youtube')).toBe(true);
    expect(matchesPathFilter(path, 'rule:main')).toBe(false);
  });
});

describe('connection view controls', () => {
  it('shows destination ports, including HTTPS and IPv6 endpoints', () => {
    expect(formatEndpoint('example.org', 443)).toBe('example.org:443');
    expect(formatEndpoint('192.0.2.1', '8443')).toBe('192.0.2.1:8443');
    expect(formatEndpoint('2001:db8::1', 443)).toBe('[2001:db8::1]:443');
    expect(formatEndpoint('example.org')).toBe('example.org');
    expect(formatEndpoint('', 443)).toBe('-');
  });

  it('sorts by the requested traffic metric', () => {
    const connection = { download: 20, upload: 5 };
    expect(trafficSortValue(connection, 'download')).toBe(20);
    expect(trafficSortValue(connection, 'upload')).toBe(5);
    expect(trafficSortValue(connection, 'total')).toBe(25);
    expect(trafficSortValue(connection, 'start')).toBeNull();
  });
});

describe('connection row actions', () => {
  it('offers details and close for active connections', () => {
    const actions = connectionActions(true);
    expect(actions.map((action) => action.kind)).toEqual(['details', 'close']);
    for (const action of actions) expect(action.label).not.toBe('');
  });

  it('never offers closing a closed connection or to a read-only session', () => {
    expect(connectionActions(false).map((action) => action.kind)).toEqual([
      'details',
    ]);
    expect(connectionActions(true, true).map((action) => action.kind)).toEqual([
      'details',
    ]);
  });
});
