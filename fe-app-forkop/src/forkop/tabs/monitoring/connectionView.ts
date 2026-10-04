export function trafficSortValue(
  connection: { download?: number; upload?: number },
  mode: string,
) {
  if (mode === 'download') return connection.download || 0;
  if (mode === 'upload') return connection.upload || 0;
  if (mode === 'total')
    return (connection.download || 0) + (connection.upload || 0);
  return null;
}

// Where a connection went. The route itself is observed (sing-box reports
// the outbound chain); a DPI strategy name comes from the configuration.
export type PathKind =
  | 'dpi'
  | 'connection'
  | 'bypass'
  | 'direct'
  | 'block'
  | 'unknown';

export interface RouteRule {
  name: string;
  label: string;
  action: string;
  dpiProvider?: string;
  dpiStrategy?: string;
  dpiCustom?: boolean;
}

export interface ConnectionPath {
  kind: PathKind;
  rule: RouteRule | null;
  // The node chosen inside the rule's group; '' when the rule is the outbound.
  node: string;
  // Raw outbound tag when no rule owns the connection.
  tag: string;
}

const BYPASS_TAG = 'bypass-out';
const DIRECT_TAG = 'direct-out';

export function formatEndpoint(
  address?: string,
  port?: string | number,
): string {
  const normalizedAddress = address == null ? '' : String(address).trim();
  const normalizedPort = port == null ? '' : String(port).trim();

  if (!normalizedAddress) return '-';
  if (!normalizedPort) return normalizedAddress;
  if (normalizedAddress.includes(':') && !normalizedAddress.startsWith('['))
    return `[${normalizedAddress}]:${normalizedPort}`;
  return `${normalizedAddress}:${normalizedPort}`;
}

export function routeTagFromRule(rule?: string): string {
  const match = String(rule || '').match(/=>\s*route\(([^)]+)\)/);
  return String(match?.[1] || '')
    .trim()
    .replace(/^['"]|['"]$/g, '');
}

function kindForAction(action: string): PathKind {
  switch (action) {
    case 'zapret':
    case 'zapret2':
    case 'byedpi':
      return 'dpi';
    case 'connection':
    case 'proxy':
    case 'outbound':
    case 'vpn':
      return 'connection';
    case 'bypass':
      return 'bypass';
    case 'block':
      return 'block';
    default:
      return 'unknown';
  }
}

// sing-box lists the chain from the final outbound back to the first one the
// route picked, so the rule's own outbound sits at the end.
export function connectionPath(
  chains: string[] | undefined,
  rule: string | undefined,
  ruleByTag: (tag: string) => RouteRule | null,
): ConnectionPath {
  const list = (Array.isArray(chains) ? chains : []).filter(Boolean);
  const routeTag = routeTagFromRule(rule);

  for (let index = list.length - 1; index >= 0; index--) {
    const owner = ruleByTag(list[index]);
    if (owner)
      return {
        kind: kindForAction(owner.action),
        rule: owner,
        node: index > 0 ? list[0] : '',
        tag: '',
      };
  }
  const owner = routeTag ? ruleByTag(routeTag) : null;
  if (owner)
    return {
      kind: kindForAction(owner.action),
      rule: owner,
      node: list[0] && list[0] !== routeTag ? list[0] : '',
      tag: '',
    };

  const tag = list[list.length - 1] || routeTag;
  if (list.includes(BYPASS_TAG) || routeTag === BYPASS_TAG)
    return { kind: 'bypass', rule: null, node: '', tag: '' };
  if (/\breject\b/.test(String(rule || '')))
    return { kind: 'block', rule: null, node: '', tag: '' };
  if (!tag || tag === DIRECT_TAG)
    return { kind: 'direct', rule: null, node: '', tag: '' };
  return { kind: 'unknown', rule: null, node: '', tag };
}

export function pathKindLabel(kind: PathKind) {
  switch (kind) {
    case 'dpi':
      return _('DPI');
    case 'connection':
      return _('Connection');
    case 'bypass':
      return _('Bypass');
    case 'direct':
      return _('Direct');
    case 'block':
      return _('Block');
    default:
      return _('Other');
  }
}

export function dpiProviderLabel(provider?: string) {
  switch (provider) {
    case 'zapret':
      return 'Zapret';
    case 'zapret2':
      return 'Zapret2';
    case 'byedpi':
      return 'ByeDPI';
    default:
      return _('DPI');
  }
}

// '' when the configuration did not say (e.g. an older backend).
export function dpiStrategyLabel(rule: RouteRule) {
  if (rule.dpiCustom) return _('custom strategy');
  if (rule.dpiStrategy === 'default') return _('default strategy');
  return rule.dpiStrategy || '';
}

export interface PathSummary {
  kind: PathKind;
  kindLabel: string;
  primary: string;
  secondary: string;
}

export function pathSummary(path: ConnectionPath): PathSummary {
  const base = { kind: path.kind, kindLabel: pathKindLabel(path.kind) };
  if (path.rule && path.kind === 'dpi') {
    const strategy = dpiStrategyLabel(path.rule);
    return {
      ...base,
      primary: path.rule.label,
      secondary: [dpiProviderLabel(path.rule.dpiProvider), strategy]
        .filter(Boolean)
        .join(' · '),
    };
  }
  if (path.rule)
    return { ...base, primary: path.rule.label, secondary: path.node };
  if (path.kind === 'direct')
    return { ...base, primary: '', secondary: _('No rule matched') };
  return { ...base, primary: path.tag, secondary: '' };
}

// Path filter values: 'all', 'kind:<PathKind>' or 'rule:<section name>'.
export function matchesPathFilter(path: ConnectionPath, filter: string) {
  if (!filter || filter === 'all') return true;
  if (filter.startsWith('kind:')) return path.kind === filter.slice(5);
  if (filter.startsWith('rule:')) return path.rule?.name === filter.slice(5);
  return true;
}

export type ConnectionActionKind = 'details' | 'close';

export interface ConnectionAction {
  kind: ConnectionActionKind;
  label: string;
  className: string;
}

// Details open a panel with the rarer actions (check in Diagnostics, copy,
// close). Closing stays one click for admins; read-only sessions and closed
// connections cannot close anything.
export function connectionActions(
  active: boolean,
  readonly = false,
): ConnectionAction[] {
  const actions: ConnectionAction[] = [
    {
      kind: 'details',
      label: _('Details'),
      className: 'fkp-monitoring-details',
    },
  ];
  if (active && !readonly)
    actions.push({
      kind: 'close',
      label: _('Close connection'),
      className: 'fkp_monitoring-page__row-action',
    });
  return actions;
}
