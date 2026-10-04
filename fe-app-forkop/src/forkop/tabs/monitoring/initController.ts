import {
  canUseDirectClashApi,
  getClashWsStreamUrl,
  onMount,
} from '../../../helpers';
import { prettyBytes } from '../../../helpers/prettyBytes';
import { showToast } from '../../../helpers/showToast';
import { confirmAction } from '../../ui/confirmAction';
import { renderStartServiceAction } from '../shared/startService';
import { isReadonlyMode } from '../../services/accessMode.service';
import {
  forkopPageUrl,
  openForkopPage,
  readPageParams,
} from '../../helpers/navigation';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import {
  renderInfoIcon24,
  renderPauseIcon24,
  renderPlayIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { CustomForkopMethods, ForkopShellMethods } from '../../methods';
import { getOutboundTagBySection } from '../../runtimeTags';
import { getClashApiSecret } from '../../methods/custom/getClashApiSecret';
import { logger, socket, store, StoreType } from '../../services';
import { Forkop } from '../../types';
import {
  connectionActions,
  connectionPath,
  formatEndpoint,
  matchesPathFilter,
  pathKindLabel,
  pathSummary,
  trafficSortValue,
  type ConnectionPath,
  type PathKind,
  type RouteRule,
} from './connectionView';
import { formatRouteReason } from './routeReason';
import {
  expandRouteConditions,
  type RuntimeRouteRule,
} from './routeConditions';
import { renderProvenance } from '../../ui/status';
import { readMonitoringView, showMonitoringView } from './views';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import {
  getServiceAvailability,
  type ServiceAvailability,
} from '../../helpers/serviceAvailability';

type MonitoringTabId = 'active' | 'closed';

type LocalDeviceChoices = Record<string, string>;

interface MonitoringControllerDependencies {
  loadLocalDeviceChoices?: () => Promise<LocalDeviceChoices>;
}

interface ClashConnectionMetadata {
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  sniffHost?: string;
  network?: string;
  processPath?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
}

interface ClashConnection {
  chains?: string[];
  download?: number;
  id?: string;
  metadata?: ClashConnectionMetadata;
  rule?: string;
  rulePayload?: string;
  start?: string;
  upload?: number;
}

interface ClashConnectionsPayload {
  connections?: ClashConnection[];
}

interface MonitoredConnection extends ClashConnection {
  id: string;
  closedAt?: number;
  lastSeenAt: number;
}

function normalizeConnectionsPayload(value: unknown): ClashConnectionsPayload {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return {};
  }

  return value as ClashConnectionsPayload;
}

let runtimeRouteRules: RuntimeRouteRule[] = [];
const expandedRouteConditions = new Map<string, string>();

function getFullRouteRule(connection: MonitoredConnection): string {
  const rule = connection.rule || '';
  if (!expandedRouteConditions.has(rule))
    expandedRouteConditions.set(
      rule,
      expandRouteConditions(rule, runtimeRouteRules),
    );
  return expandedRouteConditions.get(rule) || rule;
}

async function loadRuntimeRouteRules(mountId: number) {
  try {
    const config = JSON.parse(await fs.read('/etc/sing-box/config.json'));
    if (!monitoringMounted || mountId !== monitoringMountId) return;
    runtimeRouteRules = Array.isArray(config.route?.rules)
      ? config.route.rules
      : [];
    expandedRouteConditions.clear();
    renderConnections();
  } catch (error) {
    // The original Clash rule remains usable when the runtime config is not
    // readable (for example, before the first successful service start).
    logger.warn('[MONITORING]', 'loadRuntimeRouteRules: failed', error);
  }
}

const RENDER_INTERVAL_MS = 500;
const CONNECTIONS_RPC_POLL_INTERVAL_MS = 1500;
const CLOSED_CONNECTION_LIMIT = 300;
const ALL_FILTER_VALUE = 'all';

let dependencies: MonitoringControllerDependencies = {};
let monitoringMounted = false;
let monitoringMountId = 0;
let monitoringLifecycleRegistered = false;
let monitoringControllerInitialized = false;
let serviceStateUnsubscribe: (() => void) | null = null;
let renderTimer: ReturnType<typeof setInterval> | null = null;
let connectionsPollTimer: ReturnType<typeof setInterval> | null = null;
let connectionsSocketUrl = '';
let connectionsUpdatesId = 0;
let renderSkippedForSelection = false;
let pendingConnectionsPayload: ClashConnectionsPayload | null = null;
let pollingConnections = false;

let activeTab: MonitoringTabId = 'active';
let selectedDeviceFilter = ALL_FILTER_VALUE;
let searchQuery = '';
let pathFilter = ALL_FILTER_VALUE;
// Follow mode: only connections first seen after it was switched on (ids,
// not timestamps, so a router clock offset does not matter).
let followBaseline: Set<string> | null = null;
let selectedConnectionId: string | null = null;
let sortMode = 'start';
const MONITORING_PREFS_KEY = 'forkop.monitoring.preferences';
let localDeviceChoices: LocalDeviceChoices = {};
let routeDisplayNames: Record<string, string> = {};
let routeSections: Array<{ sectionName: string; displayName: string }> = [];
let routeRulesByTag: Record<string, RouteRule> = {};
// Node tag -> the name shown in Nodes and groups (e.g. main-2-out -> NL-2).
let nodeDisplayNames: Record<string, string> = {};
let routeRules: RouteRule[] = [];
let lastDeviceFilterSignature = '';
let loading = true;
let failed = false;
let closingAll = false;
let monitoringPaused = false;
let monitoringPausedAt: number | null = null;
let serviceAvailability: ServiceAvailability = 'loading';

const activeConnections = new Map<string, MonitoredConnection>();
const closedConnections = new Map<string, MonitoredConnection>();
const closingConnectionIds = new Set<string>();

function normalizeString(value?: string | number | null): string {
  return value == null ? '' : String(value).trim();
}

function getListValues(value?: string[] | string) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value.map((item) => normalizeString(item)).filter(Boolean);
  }

  return normalizeString(value)
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function getUrlTestIds(section: Forkop.ConfigSection) {
  const values = getListValues(section.urltests);
  return values.length
    ? values
    : section.urltest_enabled === '1'
      ? ['urltest']
      : [];
}

function getUrlTestTag(sectionName: string, id: string) {
  return getOutboundTagBySection(
    id === 'urltest'
      ? `${sectionName}-urltest`
      : `${sectionName}-urltest-${id}`,
  );
}

function getDisplayName(section: Forkop.ConfigSection) {
  return normalizeString(section.label) || section['.name'];
}

function buildRouteDisplayNames(sections: Forkop.ConfigSection[]) {
  const map: Record<string, string> = {
    'bypass-out': _('Bypass'),
    'direct-out': _('direct'),
  };
  const routeSectionItems: Array<{ sectionName: string; displayName: string }> =
    [];
  const rulesByTag: Record<string, RouteRule> = {};
  const rules: RouteRule[] = [];
  const urltestsBySection = new Map<string, string[]>();

  sections
    .filter((section) => section['.type'] === 'urltest')
    .forEach((section) => {
      const owner = normalizeString(section.section);
      const id = normalizeString(section.id) || section['.name'];
      if (!owner || !id) {
        return;
      }

      urltestsBySection.set(owner, [
        ...(urltestsBySection.get(owner) || []),
        id,
      ]);
    });

  sections
    .filter((section) => section['.type'] === 'section')
    .filter((section) => section.enabled !== '0')
    .forEach((section) => {
      const sectionName = section['.name'];
      const displayName = getDisplayName(section);

      if (!sectionName || !displayName) {
        return;
      }

      const rule: RouteRule = {
        name: sectionName,
        label: displayName,
        action: normalizeString(section.action),
        dpiProvider: section.dpi_provider,
        dpiStrategy: section.dpi_strategy,
        dpiCustom: section.dpi_strategy_custom,
      };
      rules.push(rule);
      routeSectionItems.push({ sectionName, displayName });
      map[getOutboundTagBySection(sectionName)] = displayName;
      rulesByTag[getOutboundTagBySection(sectionName)] = rule;
      const urltestIds =
        urltestsBySection.get(sectionName) || getUrlTestIds(section);
      urltestIds.forEach((id) => {
        map[getUrlTestTag(sectionName, id)] = displayName;
        rulesByTag[getUrlTestTag(sectionName, id)] = rule;
      });
    });

  routeDisplayNames = map;
  routeRulesByTag = rulesByTag;
  routeRules = rules;
  routeSections = routeSectionItems.sort(
    (a, b) => b.sectionName.length - a.sectionName.length,
  );
}

function getRouteDisplayNameByTag(tag: string): string {
  if (!tag) {
    return '';
  }

  if (routeDisplayNames[tag]) {
    return routeDisplayNames[tag];
  }

  const manualSection = routeSections.find(({ sectionName }) => {
    if (!tag.startsWith(`${sectionName}-`) || !tag.endsWith('-out')) {
      return false;
    }

    const middle = tag.slice(sectionName.length + 1, -4);
    return /^\d+(?:-\d+)?$/.test(middle);
  });

  return manualSection?.displayName || '';
}

function getRuleByTag(tag: string): RouteRule | null {
  if (routeRulesByTag[tag]) return routeRulesByTag[tag];
  // Manually numbered outbounds (<section>-<n>-out) belong to their section.
  const name = getRouteDisplayNameByTag(tag)
    ? routeSections.find(({ sectionName }) => tag.startsWith(`${sectionName}-`))
        ?.sectionName
    : '';
  return routeRules.find((rule) => rule.name === name) || null;
}

function parseStartedAt(connection: MonitoredConnection): number {
  const startedAt = Date.parse(connection.start || '');
  return Number.isFinite(startedAt) ? startedAt : connection.lastSeenAt;
}

function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const pad = (value: number) => String(value).padStart(2, '0');

  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }

  return `${minutes}:${pad(seconds)}`;
}

function formatConnectionDuration(connection: MonitoredConnection): string {
  const startedAt = parseStartedAt(connection);
  const finishedAt = connection.closedAt || monitoringPausedAt || Date.now();

  return formatDuration(finishedAt - startedAt);
}

function formatBytes(value?: number): string {
  return prettyBytes(Number.isFinite(value) ? Number(value) : 0);
}

function getConnectionSourceIp(connection: ClashConnection): string {
  return normalizeString(connection.metadata?.sourceIP);
}

function getDeviceName(ip: string): string {
  return normalizeString(localDeviceChoices[ip]);
}

function getDeviceFilterLabel(ip: string): string {
  const deviceName = getDeviceName(ip);
  return deviceName || ip;
}

function getSourceCellParts(connection: MonitoredConnection) {
  const ip = getConnectionSourceIp(connection);
  const deviceName = getDeviceName(ip);

  if (deviceName) {
    return {
      primary: deviceName,
      ip,
      copyValue: ip ? `${deviceName} (${ip})` : deviceName,
      searchValue: `${deviceName} ${ip}`,
    };
  }

  return {
    primary: ip || '-',
    ip: '',
    copyValue: ip || '-',
    searchValue: ip,
  };
}

function getTargetCellParts(connection: MonitoredConnection): {
  primary: string;
  searchValue: string;
} {
  const metadata = connection.metadata || {};
  const host = normalizeString(metadata.host);
  const destinationIp = normalizeString(metadata.destinationIP);
  const port = metadata.destinationPort;
  const primaryTarget = host || destinationIp;
  const primary = primaryTarget ? formatEndpoint(primaryTarget, port) : '-';

  return {
    primary,
    searchValue: [primary, host, destinationIp].filter(Boolean).join(' '),
  };
}

function getPath(connection: MonitoredConnection): ConnectionPath {
  const path = connectionPath(connection.chains, connection.rule, getRuleByTag);
  return path.node
    ? { ...path, node: nodeDisplayNames[path.node] || path.node }
    : path;
}

function getNetwork(connection: MonitoredConnection): string {
  return normalizeString(connection.metadata?.network).toLowerCase() || '-';
}

function getRouteReason(connection: MonitoredConnection): string {
  const labels: Record<string, string> = {
    'Not available': _('Not available'),
    'Default route': _('Default route'),
    'Built-in subnets': _('Built-in subnets'),
    'One of': _('One of'),
    'Exact match unavailable': _('Exact match unavailable'),
  };
  return formatRouteReason(
    getFullRouteRule(connection),
    connection.rulePayload,
    (value) => labels[value] || value,
    connection.metadata,
  );
}

function sortConnections(
  connections: MonitoredConnection[],
  tab: MonitoringTabId,
): MonitoredConnection[] {
  return [...connections].sort((a, b) => {
    const aTraffic = trafficSortValue(a, sortMode);
    const bTraffic = trafficSortValue(b, sortMode);
    if (aTraffic != null && bTraffic != null) return bTraffic - aTraffic;
    if (sortMode === 'duration') return parseStartedAt(a) - parseStartedAt(b);
    if (tab === 'closed') {
      return (b.closedAt || 0) - (a.closedAt || 0);
    }

    return parseStartedAt(b) - parseStartedAt(a);
  });
}

function getConnectionsForActiveTab(): MonitoredConnection[] {
  if (followBaseline) {
    const baseline = followBaseline;
    return [...activeConnections.values(), ...closedConnections.values()]
      .filter((connection) => !baseline.has(connection.id))
      .sort((a, b) => parseStartedAt(b) - parseStartedAt(a));
  }

  const source =
    activeTab === 'active'
      ? Array.from(activeConnections.values())
      : Array.from(closedConnections.values());

  return sortConnections(source, activeTab);
}

function normalizeSearchValue(value: string): string {
  return value.toLowerCase().replace(/\s+/g, ' ').trim();
}

function getSearchValues(connection: MonitoredConnection): string[] {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(connection);
  const path = pathSummary(getPath(connection));
  const routeReason = getRouteReason(connection);

  return [
    connection.id,
    target.searchValue,
    getNetwork(connection),
    path.kindLabel,
    path.primary,
    path.secondary,
    routeReason,
    normalizeString(connection.rule),
    ...(connection.chains || []),
    source.searchValue,
  ].filter(Boolean);
}

function getVisibleConnections(): MonitoredConnection[] {
  const normalizedSearch = normalizeSearchValue(searchQuery);

  return getConnectionsForActiveTab().filter((connection) => {
    const sourceIp = getConnectionSourceIp(connection);
    if (
      selectedDeviceFilter !== ALL_FILTER_VALUE &&
      sourceIp !== selectedDeviceFilter
    ) {
      return false;
    }

    if (!matchesPathFilter(getPath(connection), pathFilter)) return false;

    if (!normalizedSearch) {
      return true;
    }

    return getSearchValues(connection).some((value) =>
      normalizeSearchValue(value).includes(normalizedSearch),
    );
  });
}

function filtersActive() {
  return (
    selectedDeviceFilter !== ALL_FILTER_VALUE ||
    pathFilter !== ALL_FILTER_VALUE ||
    normalizeSearchValue(searchQuery) !== ''
  );
}

function resetFilters() {
  selectedDeviceFilter = ALL_FILTER_VALUE;
  pathFilter = ALL_FILTER_VALUE;
  searchQuery = '';
  const search = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (search) search.value = '';
  saveMonitoringPreferences();
  renderControls();
  renderConnections({ force: true });
}

function moveConnectionToClosed(connection: MonitoredConnection, now: number) {
  closedConnections.set(connection.id, {
    ...connection,
    closedAt: now,
    lastSeenAt: now,
  });
}

function trimClosedConnections() {
  const sorted = sortConnections(
    Array.from(closedConnections.values()),
    'closed',
  );

  sorted.slice(CLOSED_CONNECTION_LIMIT).forEach((connection) => {
    closedConnections.delete(connection.id);
  });
}

function applyConnectionsPayload(payload: ClashConnectionsPayload) {
  if (monitoringPaused) {
    pendingConnectionsPayload = payload;
    return;
  }

  const mountId = monitoringMountId;
  const now = Date.now();
  const incomingIds = new Set<string>();
  const rawConnections = Array.isArray(payload.connections)
    ? payload.connections
    : [];

  rawConnections.forEach((rawConnection) => {
    const id = normalizeString(rawConnection.id);
    if (!id) {
      return;
    }

    incomingIds.add(id);
    closedConnections.delete(id);
    activeConnections.set(id, {
      ...rawConnection,
      id,
      lastSeenAt: now,
    });
  });

  Array.from(activeConnections.entries()).forEach(([id, connection]) => {
    if (!incomingIds.has(id)) {
      activeConnections.delete(id);
      moveConnectionToClosed(connection, now);
    }
  });

  trimClosedConnections();
  loading = false;
  failed = false;

  if (monitoringMounted && mountId === monitoringMountId) {
    renderControls();
    renderConnections();
  }
}

function setTab(tab: MonitoringTabId) {
  if (activeTab === tab) {
    return;
  }

  activeTab = tab;
  renderControls();
  renderConnections();
}

function getKnownSourceIps(): string[] {
  const ips = new Set<string>();

  activeConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  closedConnections.forEach((connection) => {
    const ip = getConnectionSourceIp(connection);
    if (ip) {
      ips.add(ip);
    }
  });

  return Array.from(ips).sort((a, b) => {
    const byLabel = getDeviceFilterLabel(a).localeCompare(
      getDeviceFilterLabel(b),
    );
    return byLabel || a.localeCompare(b);
  });
}

function renderDeviceFilterOptions() {
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;

  if (!select) {
    return;
  }

  const sourceIps = getKnownSourceIps();
  if (
    selectedDeviceFilter !== ALL_FILTER_VALUE &&
    !sourceIps.includes(selectedDeviceFilter)
  ) {
    selectedDeviceFilter = ALL_FILTER_VALUE;
  }

  const signature = [
    selectedDeviceFilter,
    ...sourceIps.map((ip) => `${ip}:${getDeviceFilterLabel(ip)}`),
  ].join('|');
  if (signature === lastDeviceFilterSignature) {
    select.value = selectedDeviceFilter;
    return;
  }

  lastDeviceFilterSignature = signature;

  const options = [
    E('option', { value: ALL_FILTER_VALUE }, _('All devices')),
    ...sourceIps.map((ip) =>
      E('option', { value: ip }, getDeviceFilterLabel(ip)),
    ),
  ];

  select.replaceChildren(...options);
  select.value = selectedDeviceFilter;
}

const PATH_KINDS: PathKind[] = [
  'dpi',
  'connection',
  'bypass',
  'direct',
  'block',
];
let lastPathFilterSignature = '';

function renderPathFilterOptions() {
  const select = document.getElementById(
    'monitoring-path-filter',
  ) as HTMLSelectElement | null;
  if (!select) return;

  const rules = [...routeRules].sort((a, b) => a.label.localeCompare(b.label));
  const known = [
    ALL_FILTER_VALUE,
    ...PATH_KINDS.map((kind) => `kind:${kind}`),
    ...rules.map((rule) => `rule:${rule.name}`),
  ];
  if (!known.includes(pathFilter)) pathFilter = ALL_FILTER_VALUE;

  const signature = rules.map((rule) => `${rule.name}:${rule.label}`).join('|');
  if (signature !== lastPathFilterSignature || !select.options.length) {
    lastPathFilterSignature = signature;
    select.replaceChildren(
      E('option', { value: ALL_FILTER_VALUE }, _('All paths')),
      E(
        'optgroup',
        { label: _('Path type') },
        PATH_KINDS.map((kind) =>
          E('option', { value: `kind:${kind}` }, pathKindLabel(kind)),
        ),
      ),
      ...(rules.length
        ? [
            E(
              'optgroup',
              { label: _('Rule') },
              rules.map((rule) =>
                E('option', { value: `rule:${rule.name}` }, rule.label),
              ),
            ),
          ]
        : []),
    );
  }
  select.value = pathFilter;
}

function renderFilterBar() {
  const bar = document.getElementById('monitoring-filter-bar');
  if (!bar) return;
  const active = filtersActive();
  const following = followBaseline !== null;
  if (!active && !following) {
    bar.replaceChildren();
    bar.hidden = true;
    return;
  }

  const total = getConnectionsForActiveTab().length;
  const shown = active ? getVisibleConnections().length : total;
  bar.hidden = false;
  bar.replaceChildren(
    E(
      'span',
      {},
      [
        following ? _('Following new connections') : '',
        active
          ? _('Shown %d of %d')
              .replace('%d', String(shown))
              .replace('%d', String(total))
          : '',
      ]
        .filter(Boolean)
        .join(' · '),
    ),
    ...(active
      ? [
          E(
            'button',
            {
              type: 'button',
              class: 'btn cbi-button fkp_monitoring-page__reset',
              click: () => resetFilters(),
            },
            _('Reset filters'),
          ),
        ]
      : []),
  );
}

function setButtonActive(button: HTMLElement | null, active: boolean) {
  if (!button) {
    return;
  }

  button.classList.toggle('fkp_monitoring-page__tab--active', active);
}

function renderTabButtonContent(label: string, count: number) {
  return [
    E('span', { class: 'fkp_monitoring-page__tab-label' }, label),
    E('span', { class: 'fkp_monitoring-page__tab-badge' }, String(count)),
  ];
}

function renderControls() {
  const activeButton = document.getElementById(
    'monitoring-tab-active',
  ) as HTMLButtonElement | null;
  const closedButton = document.getElementById(
    'monitoring-tab-closed',
  ) as HTMLButtonElement | null;
  const closeAllButton = document.getElementById(
    'monitoring-close-all',
  ) as HTMLButtonElement | null;
  const pauseToggleButton = document.getElementById(
    'monitoring-pause-toggle',
  ) as HTMLButtonElement | null;

  const following = followBaseline !== null;
  // Follow mode lists active and closed connections together.
  if (activeButton) {
    activeButton.replaceChildren(
      ...renderTabButtonContent(_('Active'), activeConnections.size),
    );
    activeButton.disabled = serviceAvailability === 'stopped' || following;
  }

  if (closedButton) {
    closedButton.replaceChildren(
      ...renderTabButtonContent(_('Closed'), closedConnections.size),
    );
    closedButton.disabled = serviceAvailability === 'stopped' || following;
  }

  setButtonActive(activeButton, !following && activeTab === 'active');
  setButtonActive(closedButton, !following && activeTab === 'closed');

  const followButton = document.getElementById(
    'monitoring-follow-toggle',
  ) as HTMLButtonElement | null;
  if (followButton) {
    followButton.disabled = serviceAvailability === 'stopped';
    followButton.setAttribute('aria-pressed', following ? 'true' : 'false');
    followButton.classList.toggle(
      'fkp_monitoring-page__tab--active',
      following,
    );
  }

  if (closeAllButton) {
    closeAllButton.replaceChildren(renderXIcon24());
    closeAllButton.disabled =
      serviceAvailability === 'stopped' ||
      activeConnections.size === 0 ||
      closingAll;
  }

  if (pauseToggleButton) {
    const title = monitoringPaused ? _('Resume updates') : _('Pause updates');
    pauseToggleButton.replaceChildren(
      monitoringPaused ? renderPlayIcon24() : renderPauseIcon24(),
    );
    pauseToggleButton.title = title;
    pauseToggleButton.setAttribute('aria-label', title);
    pauseToggleButton.disabled = serviceAvailability === 'stopped';
    pauseToggleButton.classList.toggle(
      'fkp_monitoring-page__icon-button--active',
      monitoringPaused,
    );
  }

  const searchIcon = document.querySelector(
    '.fkp_monitoring-page__search-icon',
  );
  if (searchIcon && searchIcon.childNodes.length === 0) {
    searchIcon.replaceChildren(renderSearchIcon24());
  }

  renderDeviceFilterOptions();
  renderPathFilterOptions();
  renderFilterBar();

  const pathSelect = document.getElementById(
    'monitoring-path-filter',
  ) as HTMLSelectElement | null;
  if (pathSelect) pathSelect.disabled = serviceAvailability === 'stopped';

  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;

  if (select) {
    select.disabled = serviceAvailability === 'stopped';
  }

  if (searchInput) {
    searchInput.disabled = serviceAvailability === 'stopped';
  }
}

function renderValue(value: string, className = '') {
  const text = value || '-';
  const element = E(
    'span',
    {
      class: ['fkp_monitoring-page__value', className]
        .filter(Boolean)
        .join(' '),
      title: text,
    },
    text,
  );

  element.setAttribute('data-copy-value', text);

  return element;
}

function renderSourceValue(source: ReturnType<typeof getSourceCellParts>) {
  const fullText = source.copyValue || source.primary || '-';

  if (!source.ip) {
    const element = E(
      'span',
      {
        class:
          'fkp_monitoring-page__value fkp_monitoring-page__source-value fkp_monitoring-page__source-value--ip-only',
        title: fullText,
      },
      source.primary || '-',
    );

    element.setAttribute('data-copy-value', fullText);

    return element;
  }

  const element = E(
    'span',
    {
      class: 'fkp_monitoring-page__value fkp_monitoring-page__source-value',
      title: fullText,
    },
    [
      E('span', { class: 'fkp_monitoring-page__source-name' }, source.primary),
      E('span', { class: 'fkp_monitoring-page__source-ip' }, source.ip),
    ],
  );

  element.setAttribute('data-copy-value', fullText);

  return element;
}

function renderTableCell(label: string, children: (Node | string)[]) {
  // One wrapper keeps multi-line cells in one grid column on narrow screens.
  const cell = E('td', {}, [
    E('div', { class: 'fkp_monitoring-page__cell' }, children),
  ]);
  cell.setAttribute('data-label', label);
  return cell;
}

function renderSecondary(text: string, className = '') {
  return E(
    'span',
    {
      class: ['fkp_monitoring-page__secondary', className]
        .filter(Boolean)
        .join(' '),
      title: text,
    },
    text,
  );
}

function renderPathCell(path: ConnectionPath, reason: string) {
  const summary = pathSummary(path);
  return [
    E(
      'span',
      {
        class: `fkp_monitoring-page__path-kind fkp_monitoring-page__path-kind--${summary.kind}`,
      },
      summary.kindLabel,
    ),
    ...(summary.primary
      ? [renderValue(summary.primary, 'fkp_monitoring-page__route')]
      : []),
    ...(summary.secondary ? [renderSecondary(summary.secondary)] : []),
    ...(reason ? [renderSecondary(reason, 'fkp_monitoring-page__reason')] : []),
  ];
}

function renderConnectionRow(connection: MonitoredConnection) {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(connection);
  const isActive = activeConnections.has(connection.id);
  const isClosing = closingConnectionIds.has(connection.id);
  const icons = { details: renderInfoIcon24, close: renderXIcon24 };
  const actions = E(
    'div',
    { class: 'fkp_monitoring-page__actions' },
    connectionActions(isActive, isReadonlyMode()).map((action) =>
      E(
        'button',
        {
          class: `btn cbi-button fkp_monitoring-page__icon-action ${action.className}`,
          title: action.label,
          'aria-label': action.label,
          type: 'button',
          value: connection.id,
          ...(action.kind === 'close' && isClosing ? { disabled: true } : {}),
        },
        [icons[action.kind]()],
      ),
    ),
  );
  const destinationMeta = [
    getNetwork(connection).toUpperCase(),
    formatConnectionDuration(connection),
    ...(isActive ? [] : [_('closed')]),
  ].join(' · ');

  return E(
    'tr',
    {
      class: [
        isClosing ? 'fkp_monitoring-page__row--closing' : '',
        !isActive ? 'fkp_monitoring-page__row--closed' : '',
        selectedConnectionId === connection.id
          ? 'fkp_monitoring-page__row--selected'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    [
      renderTableCell(_('Device'), [renderSourceValue(source)]),
      renderTableCell(_('Destination'), [
        renderValue(target.primary),
        renderSecondary(destinationMeta),
      ]),
      renderTableCell(
        _('Path'),
        renderPathCell(getPath(connection), getRouteReason(connection)),
      ),
      renderTableCell(_('Traffic'), [
        renderValue(`\u2193 ${formatBytes(connection.download)}`),
        renderSecondary(`\u2191 ${formatBytes(connection.upload)}`),
      ]),
      renderTableCell(_('Actions'), [actions]),
    ],
  );
}

function safeText(value: unknown) {
  return normalizeString(value == null ? '' : String(value))
    .replace(/\b(?:https?:\/\/)?[^\s@]+@/g, '***@')
    .replace(
      /(?:token|secret|password|uuid|authorization)=([^&\s]+)/gi,
      '$1=***',
    );
}

function connectionTechnicalDetails(connection: MonitoredConnection) {
  const metadata = connection.metadata || {};
  return [
    [_('Source'), formatEndpoint(metadata.sourceIP, metadata.sourcePort)],
    [
      _('Destination'),
      formatEndpoint(metadata.destinationIP, metadata.destinationPort),
    ],
    [_('Host'), safeText(metadata.host)],
    [_('Protocol'), getNetwork(connection)],
    [_('Rule'), safeText(connection.rule)],
    [_('Rule payload'), safeText(connection.rulePayload)],
    [_('Outbound chain'), safeText((connection.chains || []).join(' → '))],
    [_('Started'), formatStarted(connection.start)],
    [_('Connection ID'), connection.id],
  ];
}

// The Clash API gives an ISO time; shown in the browser's locale.
function formatStarted(start: string | undefined) {
  const time = Date.parse(start || '');
  return Number.isFinite(time)
    ? new Date(time).toLocaleString()
    : safeText(start);
}

function connectionDetails(connection: MonitoredConnection) {
  const target = getTargetCellParts(connection);
  const source = getSourceCellParts(connection);
  const path = pathSummary(getPath(connection));
  return [
    [_('Device'), source.copyValue],
    [_('Destination'), target.primary],
    [
      _('Path'),
      [path.kindLabel, path.primary, path.secondary]
        .filter(Boolean)
        .join(' · '),
    ],
    [_('Route reason'), getRouteReason(connection)],
    [_('Duration'), formatConnectionDuration(connection)],
    [_('Download'), formatBytes(connection.download)],
    [_('Upload'), formatBytes(connection.upload)],
    ...connectionTechnicalDetails(connection),
  ];
}

function detailRow(label: string, value: Node | string) {
  return E('div', { class: 'fkp_monitoring-page__detail-row' }, [
    E('dt', {}, label),
    E('dd', {}, value),
  ]);
}

function closeConnectionDetails() {
  selectedConnectionId = null;
  document.getElementById('monitoring-connection-details')?.replaceChildren();
  renderConnections({ force: true });
}

function renderConnectionDetailsPanel() {
  const container = document.getElementById('monitoring-connection-details');
  if (!container) return;
  const connection = selectedConnectionId
    ? activeConnections.get(selectedConnectionId) ||
      closedConnections.get(selectedConnectionId)
    : undefined;
  if (!connection) {
    container.replaceChildren();
    return;
  }
  // Live refreshes keep the technical details expanded if they were.
  const technicalOpen = Boolean(
    container.querySelector<HTMLDetailsElement>('details')?.open,
  );

  const isActive = activeConnections.has(connection.id);
  const target = getTargetCellParts(connection);
  const host =
    normalizeString(connection.metadata?.host) ||
    normalizeString(connection.metadata?.destinationIP);
  const rawPath = getPath(connection);
  const path = pathSummary(rawPath);
  const source = getSourceCellParts(connection);

  container.replaceChildren(
    E('div', { class: 'fkp_monitoring-page__details' }, [
      E('div', { class: 'fkp_monitoring-page__details-head' }, [
        E('h3', {}, target.primary),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button fkp_monitoring-page__details-close',
            'aria-label': _('Close details'),
            title: _('Close details'),
            click: () => closeConnectionDetails(),
          },
          '×',
        ),
      ]),
      E('dl', { class: 'fkp_monitoring-page__detail-list' }, [
        detailRow(_('Device'), source.copyValue),
        detailRow(
          _('Status'),
          isActive
            ? `${_('Active')} · ${formatConnectionDuration(connection)}`
            : `${_('Closed')} · ${formatConnectionDuration(connection)}`,
        ),
        detailRow(
          _('Route'),
          E('span', {}, [
            [path.kindLabel, path.primary, rawPath.node]
              .filter(Boolean)
              .join(' · '),
            ' ',
            renderProvenance('observed'),
          ]),
        ),
        detailRow(
          _('Route reason'),
          E('span', {}, [
            getRouteReason(connection),
            ' ',
            renderProvenance('observed'),
          ]),
        ),
        ...(rawPath.kind === 'dpi' && path.secondary
          ? [
              detailRow(
                _('DPI strategy'),
                E('span', {}, [
                  path.secondary,
                  ' ',
                  renderProvenance('configured'),
                ]),
              ),
            ]
          : []),
        detailRow(
          _('Traffic'),
          `\u2193 ${formatBytes(connection.download)} · \u2191 ${formatBytes(connection.upload)}`,
        ),
      ]),
      E('div', { class: 'fkp_monitoring-page__details-actions' }, [
        ...(host
          ? [
              E(
                'a',
                {
                  class: 'btn cbi-button',
                  href: forkopPageUrl('diagnostics', { host }),
                  click: (event: Event) => {
                    event.preventDefault();
                    openForkopPage('diagnostics', { host });
                  },
                },
                _('Check address in Diagnostics'),
              ),
            ]
          : []),
        E(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button',
            click: () =>
              // navigator.clipboard needs a secure context; LuCI is usually plain HTTP.
              copyToClipboard(
                connectionDetails(connection)
                  .map(([key, value]) => `${key}: ${value}`)
                  .join('\n'),
              ),
          },
          _('Copy details'),
        ),
        ...(isActive && !isReadonlyMode()
          ? [
              E(
                'button',
                {
                  type: 'button',
                  class: 'btn cbi-button cbi-button-negative',
                  disabled: closingConnectionIds.has(connection.id)
                    ? true
                    : undefined,
                  click: () => void closeConnection(connection.id),
                },
                _('Close connection'),
              ),
            ]
          : []),
      ]),
      E(
        'details',
        {
          class: 'fkp_monitoring-page__technical',
          ...(technicalOpen ? { open: true } : {}),
        },
        [
          E('summary', {}, _('Technical details')),
          E(
            'dl',
            { class: 'fkp_monitoring-page__detail-list' },
            connectionTechnicalDetails(connection).map(([label, value]) =>
              detailRow(label, value || '—'),
            ),
          ),
        ],
      ),
    ]),
  );
}

function showConnectionDetails(connection: MonitoredConnection) {
  selectedConnectionId = connection.id;
  renderConnectionDetailsPanel();
  renderConnections({ force: true });
  document
    .getElementById('monitoring-connection-details')
    ?.scrollIntoView?.({ block: 'nearest' });
}

function saveMonitoringPreferences() {
  localStorage.setItem(
    MONITORING_PREFS_KEY,
    JSON.stringify({
      selectedDeviceFilter,
      pathFilter,
      sortMode,
    }),
  );
}

function loadMonitoringPreferences() {
  try {
    const value = JSON.parse(
      localStorage.getItem(MONITORING_PREFS_KEY) || '{}',
    );
    if (typeof value.selectedDeviceFilter === 'string')
      selectedDeviceFilter = value.selectedDeviceFilter;
    if (
      ['start', 'duration', 'download', 'upload', 'total'].includes(
        value.sortMode,
      )
    )
      sortMode = value.sortMode;
    if (typeof value.pathFilter === 'string')
      pathFilter = value.pathFilter.slice(0, 100);
  } catch (_error) {
    /* ignore invalid browser state */
  }
}

function renderStateRow(
  text: string,
  className = '',
  actions: HTMLElement[] = [],
) {
  return E('tr', { class: 'fkp_monitoring-page__state-row' }, [
    E(
      'td',
      {
        class: 'fkp_monitoring-page__state-cell',
        colSpan: 5,
      },
      [
        E(
          'div',
          {
            class: ['fkp_monitoring-page__state', className]
              .filter(Boolean)
              .join(' '),
          },
          actions.length ? [E('span', {}, text), ...actions] : text,
        ),
      ],
    ),
  ]);
}

function renderConnectionsTable(
  connections: MonitoredConnection[],
  state?: { text: string; className?: string; actions?: HTMLElement[] },
) {
  const rows = state
    ? [renderStateRow(state.text, state.className, state.actions)]
    : connections.map(renderConnectionRow);

  return E('div', { class: 'fkp_monitoring-page__table-wrap' }, [
    E(
      'table',
      { class: 'table cbi-section-table fkp_monitoring-page__table' },
      [
        E('thead', {}, [
          E('tr', {}, [
            E('th', {}, _('Device')),
            E('th', {}, _('Destination')),
            E('th', {}, _('Path')),
            E('th', {}, _('Traffic')),
            E('th', { class: 'fkp_monitoring-page__actions-head' }, [
              E('span', { class: 'fkp-visually-hidden' }, _('Actions')),
            ]),
          ]),
        ]),
        E('tbody', {}, rows),
      ],
    ),
  ]);
}

function isNodeInsideMonitoring(node: Node | null): boolean {
  const root = document.getElementById('monitoring-status');
  return Boolean(root && node && root.contains(node));
}

function isTextSelectionInsideMonitoring(): boolean {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return false;
  }

  return (
    isNodeInsideMonitoring(selection.anchorNode) ||
    isNodeInsideMonitoring(selection.focusNode)
  );
}

function renderConnections(options: { force?: boolean } = {}) {
  const container = document.getElementById('monitoring-connections');
  if (!container) {
    return;
  }

  if (!options.force && isTextSelectionInsideMonitoring()) {
    renderSkippedForSelection = true;
    return;
  }

  renderSkippedForSelection = false;
  const previousScrollLeft = container.scrollLeft;

  if (serviceAvailability === 'stopped') {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _(
          'Forkop service is stopped. Start the service to display connections.',
        ),
        actions: renderStartServiceAction(),
      }),
    );
    return;
  }

  if (loading) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Loading connections'),
        className: 'fkp_monitoring-page__state--loading',
      }),
    );
    return;
  }

  if (failed) {
    container.replaceChildren(
      renderConnectionsTable([], {
        text: _('Connections are unavailable'),
        className: 'fkp_monitoring-page__state--error',
      }),
    );
    return;
  }

  const visibleConnections = getVisibleConnections();
  renderFilterBar();
  renderConnectionDetailsPanel();

  if (visibleConnections.length === 0) {
    const anyConnections = getConnectionsForActiveTab().length > 0;
    container.replaceChildren(
      renderConnectionsTable(
        [],
        anyConnections && filtersActive()
          ? {
              text: _('No connections match the filters'),
              actions: [
                E(
                  'button',
                  {
                    type: 'button',
                    class: 'btn cbi-button',
                    click: () => resetFilters(),
                  },
                  _('Reset filters'),
                ),
              ],
            }
          : {
              text: followBaseline
                ? _(
                    'No new connections yet. Open the site or app you want to check.',
                  )
                : activeTab === 'active'
                  ? _('No active connections')
                  : _('No closed connections'),
            },
      ),
    );
    return;
  }

  container.replaceChildren(renderConnectionsTable(visibleConnections));
  container.scrollLeft = previousScrollLeft;
}

function flushRenderAfterSelection() {
  if (!renderSkippedForSelection || isTextSelectionInsideMonitoring()) {
    return;
  }

  renderConnections({ force: true });
}

function setMonitoringPaused(paused: boolean) {
  if (monitoringPaused === paused) {
    return;
  }

  monitoringPaused = paused;
  monitoringPausedAt = paused ? Date.now() : null;
  renderSkippedForSelection = false;
  renderControls();

  if (!paused) {
    const payload = pendingConnectionsPayload;
    pendingConnectionsPayload = null;

    if (payload) {
      applyConnectionsPayload(payload);
      return;
    }

    if (connectionsPollTimer) {
      void pollConnectionsSnapshot();
      return;
    }
  }

  renderConnections();
}

function isElementOverflowing(element: HTMLElement): boolean {
  return element.scrollWidth > element.clientWidth + 1;
}

function getMonitoringValueOverflowElements(
  element: HTMLElement,
): HTMLElement[] {
  return [
    element,
    ...Array.from(element.querySelectorAll<HTMLElement>('*')),
  ].filter(isElementOverflowing);
}

function getElementCopyText(element: HTMLElement, fallback: string): string {
  return (
    element.getAttribute('data-copy-value') || element.textContent || fallback
  );
}

function compactMonitoringText(value: string): string {
  return value
    .replace(/\u2026/g, '')
    .trim()
    .replace(/\s+/g, '');
}

function getMonitoringValueTextElements(element: HTMLElement): HTMLElement[] {
  const children = Array.from(element.children).filter(
    (child): child is HTMLElement => child instanceof HTMLElement,
  );

  if (children.length === 0) {
    return [element];
  }

  const textElements = children
    .flatMap(getMonitoringValueTextElements)
    .filter((child) => compactMonitoringText(getElementCopyText(child, '')));

  return textElements.length > 0 ? textElements : [element];
}

function estimateVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const text = compactMonitoringText(getElementCopyText(element, fallbackText));

  if (!text) {
    return 0;
  }

  if (!isElementOverflowing(element)) {
    return text.length;
  }

  return Math.floor(
    (element.clientWidth / Math.max(element.scrollWidth, 1)) * text.length,
  );
}

function getEstimatedVisibleMonitoringTextLength(
  element: HTMLElement,
  fallbackText: string,
): number {
  const textElements = getMonitoringValueTextElements(element);

  if (textElements.length === 1 && textElements[0] === element) {
    return estimateVisibleMonitoringTextLength(element, fallbackText);
  }

  return textElements.reduce(
    (total, textElement) =>
      total + estimateVisibleMonitoringTextLength(textElement, fallbackText),
    0,
  );
}

function isCompactTextSubsequence(needle: string, haystack: string): boolean {
  let haystackIndex = 0;

  for (let needleIndex = 0; needleIndex < needle.length; needleIndex += 1) {
    haystackIndex = haystack.indexOf(needle[needleIndex], haystackIndex);

    if (haystackIndex === -1) {
      return false;
    }

    haystackIndex += 1;
  }

  return true;
}

function getSelectionValueElements(selection: Selection): HTMLElement[] {
  const root = document.getElementById('monitoring-status');
  if (!root) {
    return [];
  }

  return Array.from(
    root.querySelectorAll<HTMLElement>(
      '.fkp_monitoring-page__value[data-copy-value]',
    ),
  ).filter((element) => {
    for (let index = 0; index < selection.rangeCount; index += 1) {
      try {
        if (selection.getRangeAt(index).intersectsNode(element)) {
          return true;
        }
      } catch (_error) {
        return false;
      }
    }

    return false;
  });
}

function shouldCopyFullMonitoringValue(
  element: HTMLElement,
  selectedText: string,
  fullText: string,
): boolean {
  const normalizedSelectedText = selectedText.replace(/\u2026/g, '').trim();
  const normalizedFullText = fullText.trim();
  const compactSelectedText = compactMonitoringText(selectedText);
  const compactFullText = compactMonitoringText(fullText);
  const overflowElements = getMonitoringValueOverflowElements(element);
  const hasCompositeText = getMonitoringValueTextElements(element).length > 1;

  if (!normalizedSelectedText || !normalizedFullText) {
    return false;
  }

  if (normalizedSelectedText === normalizedFullText) {
    return true;
  }

  if (overflowElements.length === 0) {
    return false;
  }

  if (hasCompositeText) {
    const selectedPrefix = compactSelectedText.slice(
      0,
      Math.min(4, compactSelectedText.length),
    );

    if (
      !compactFullText.startsWith(selectedPrefix) ||
      !isCompactTextSubsequence(compactSelectedText, compactFullText)
    ) {
      return false;
    }
  } else if (!compactFullText.startsWith(compactSelectedText)) {
    return false;
  }

  const estimatedVisibleChars = getEstimatedVisibleMonitoringTextLength(
    element,
    normalizedFullText,
  );

  return compactSelectedText.length >= Math.max(4, estimatedVisibleChars - 2);
}

function handleMonitoringValueCopy(event: ClipboardEvent) {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) {
    return;
  }

  const valueElements = getSelectionValueElements(selection);
  if (valueElements.length !== 1) {
    return;
  }

  const valueElement = valueElements[0];
  const fullText =
    valueElement.getAttribute('data-copy-value') ||
    valueElement.textContent ||
    '';
  const selectedText = selection.toString();

  if (!shouldCopyFullMonitoringValue(valueElement, selectedText, fullText)) {
    return;
  }

  event.clipboardData?.setData('text/plain', fullText);
  event.preventDefault();
}

async function closeConnection(connectionId: string) {
  if (!connectionId || closingConnectionIds.has(connectionId)) {
    return;
  }

  closingConnectionIds.add(connectionId);
  renderConnections();

  try {
    const response =
      await ForkopShellMethods.closeClashApiConnection(connectionId);

    if (!response.success) {
      showToast(_('Failed to close connection'), 'error');
      return;
    }

    const now = Date.now();
    const connection = activeConnections.get(connectionId);
    if (connection) {
      activeConnections.delete(connectionId);
      moveConnectionToClosed(connection, now);
      trimClosedConnections();
      pendingConnectionsPayload = null;
      renderControls();
    }
  } catch (error) {
    logger.error('[MONITORING]', 'closeConnection: failed', error);
    showToast(_('Failed to close connection'), 'error');
  } finally {
    closingConnectionIds.delete(connectionId);
    renderConnections();
  }
}

async function closeAllConnections() {
  if (activeConnections.size === 0 || closingAll) {
    return;
  }

  const confirmed = await confirmAction({
    title: _('Close all connections?'),
    message: _('Active connections of all devices are interrupted.'),
    consequences: [
      _('Apps reconnect on their own; downloads and calls may drop'),
    ],
    confirmLabel: _('Close all'),
    danger: true,
  });
  if (!confirmed || closingAll) {
    return;
  }

  closingAll = true;
  renderControls();

  try {
    const response = await ForkopShellMethods.closeAllClashApiConnections();

    if (!response.success) {
      showToast(_('Failed to close connections'), 'error');
      return;
    }

    const now = Date.now();
    activeConnections.forEach((connection) => {
      moveConnectionToClosed(connection, now);
    });
    activeConnections.clear();
    pendingConnectionsPayload = null;
    trimClosedConnections();
  } catch (error) {
    logger.error('[MONITORING]', 'closeAllConnections: failed', error);
    showToast(_('Failed to close connections'), 'error');
  } finally {
    closingAll = false;
    renderControls();
    renderConnections();
  }
}

function bindControls() {
  const activeButton = document.getElementById('monitoring-tab-active');
  const closedButton = document.getElementById('monitoring-tab-closed');
  const select = document.getElementById(
    'monitoring-device-filter',
  ) as HTMLSelectElement | null;
  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  const closeAllButton = document.getElementById('monitoring-close-all');
  const pauseToggleButton = document.getElementById('monitoring-pause-toggle');
  const connectionsContainer = document.getElementById(
    'monitoring-connections',
  );

  if (activeButton) {
    activeButton.onclick = () => setTab('active');
  }

  if (closedButton) {
    closedButton.onclick = () => setTab('closed');
  }

  if (closeAllButton) {
    closeAllButton.onclick = () => {
      void closeAllConnections();
    };
  }

  if (pauseToggleButton) {
    pauseToggleButton.onclick = () => {
      setMonitoringPaused(!monitoringPaused);
      pauseToggleButton.blur();
    };
  }

  if (select) {
    select.onchange = () => {
      selectedDeviceFilter = select.value || ALL_FILTER_VALUE;
      saveMonitoringPreferences();
      renderConnections();
    };
  }

  const pathSelect = document.getElementById(
    'monitoring-path-filter',
  ) as HTMLSelectElement | null;
  if (pathSelect) {
    pathSelect.onchange = () => {
      pathFilter = pathSelect.value || ALL_FILTER_VALUE;
      saveMonitoringPreferences();
      renderConnections({ force: true });
    };
  }

  const followButton = document.getElementById('monitoring-follow-toggle');
  if (followButton) {
    followButton.onclick = () => {
      followBaseline = followBaseline
        ? null
        : new Set([...activeConnections.keys(), ...closedConnections.keys()]);
      renderControls();
      renderConnections({ force: true });
    };
  }
  const sort = document.getElementById(
    'monitoring-sort',
  ) as HTMLSelectElement | null;
  if (sort) {
    sort.value = sortMode;
    sort.onchange = () => {
      sortMode = sort.value;
      saveMonitoringPreferences();
      renderConnections();
    };
  }

  if (searchInput) {
    searchInput.oninput = () => {
      searchQuery = searchInput.value;
      renderConnections();
    };
  }

  if (connectionsContainer) {
    connectionsContainer.onclick = (event) => {
      const target = event.target as HTMLElement | null;
      const action = target?.closest<HTMLButtonElement>(
        '.fkp-monitoring-details',
      );
      if (action?.value) {
        const connection =
          activeConnections.get(action.value) ||
          closedConnections.get(action.value);
        if (connection) showConnectionDetails(connection);
        return;
      }
      const button = target?.closest(
        '.fkp_monitoring-page__row-action',
      ) as HTMLButtonElement | null;

      if (button?.value) {
        void closeConnection(button.value);
      }
    };
  }
}

async function loadNodeDisplayNames() {
  try {
    const response = await CustomForkopMethods.getDashboardSections();
    const names: Record<string, string> = {};
    for (const group of response.success ? response.data : [])
      for (const outbound of group.outbounds)
        if (outbound.displayName && outbound.displayName !== outbound.code)
          names[outbound.code] = outbound.displayName;
    nodeDisplayNames = names;
  } catch (error) {
    logger.warn('[MONITORING]', 'loadNodeDisplayNames: failed', error);
  } finally {
    renderConnections();
  }
}

async function loadLocalDevices() {
  try {
    localDeviceChoices = (await dependencies.loadLocalDeviceChoices?.()) || {};
  } catch (error) {
    logger.warn('[MONITORING]', 'loadLocalDevices: failed', error);
    localDeviceChoices = {};
  } finally {
    renderControls();
    renderConnections();
  }
}

// Both roles read the same derived section view: rule labels plus the DPI
// provider and strategy name, never the raw strategy options.
async function loadRouteDisplayNames() {
  try {
    const response = await ForkopShellMethods.getReadonlyConfigSections();
    buildRouteDisplayNames(response.success ? response.data : []);
  } catch (error) {
    logger.warn('[MONITORING]', 'loadRouteDisplayNames: failed', error);
    buildRouteDisplayNames([]);
  } finally {
    renderControls();
    renderConnections();
  }
}

async function pollConnectionsSnapshot() {
  if (
    pollingConnections ||
    !monitoringMounted ||
    monitoringPaused ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  const mountId = monitoringMountId;
  pollingConnections = true;

  try {
    const response = await ForkopShellMethods.getClashApiConnections();

    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    if (!response.success) {
      failed = true;
      loading = false;
      renderConnections();
      return;
    }

    applyConnectionsPayload(normalizeConnectionsPayload(response.data));
  } catch (error) {
    if (
      !monitoringMounted ||
      mountId !== monitoringMountId ||
      serviceAvailability !== 'running'
    ) {
      return;
    }

    logger.error('[MONITORING]', 'connections polling failed', error);
    failed = true;
    loading = false;
    renderConnections();
  } finally {
    pollingConnections = false;
  }
}

function startConnectionsPolling() {
  if (connectionsPollTimer) {
    return;
  }

  void pollConnectionsSnapshot();
  connectionsPollTimer = setInterval(() => {
    void pollConnectionsSnapshot();
  }, CONNECTIONS_RPC_POLL_INTERVAL_MS);
}

async function connectToConnectionsSocket(updatesId: number) {
  const mountId = monitoringMountId;
  const clashApiSecret = await getClashApiSecret();

  if (
    !monitoringMounted ||
    mountId !== monitoringMountId ||
    updatesId !== connectionsUpdatesId ||
    serviceAvailability !== 'running'
  ) {
    return;
  }

  if (!canUseDirectClashApi(clashApiSecret)) {
    startConnectionsPolling();
    return;
  }

  connectionsSocketUrl = getClashWsStreamUrl('/connections', clashApiSecret);

  socket.subscribe(
    connectionsSocketUrl,
    (msg) => {
      if (
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      try {
        applyConnectionsPayload(JSON.parse(msg) as ClashConnectionsPayload);
      } catch (error) {
        logger.error('[MONITORING]', 'connections socket parse failed', error);
      }
    },
    (_err) => {
      if (
        !monitoringMounted ||
        mountId !== monitoringMountId ||
        updatesId !== connectionsUpdatesId ||
        serviceAvailability !== 'running'
      ) {
        return;
      }

      // The controller socket failed or dropped: keep watching through
      // rpcd instead of showing the connections as unavailable for good.
      logger.warn('[MONITORING]', 'connections socket unavailable, polling');
      if (connectionsSocketUrl) {
        socket.disconnect(connectionsSocketUrl);
        connectionsSocketUrl = '';
      }
      startConnectionsPolling();
    },
  );
}

function startConnectionsUpdates() {
  if (serviceAvailability !== 'running') {
    return;
  }

  // Direct sockets need the secret; without it (read-only, HTTPS) the
  // connections are polled through rpcd.
  const updatesId = ++connectionsUpdatesId;
  void connectToConnectionsSocket(updatesId);
}

function stopConnectionsUpdates() {
  connectionsUpdatesId += 1;

  if (connectionsPollTimer) {
    clearInterval(connectionsPollTimer);
    connectionsPollTimer = null;
  }

  if (connectionsSocketUrl) {
    socket.disconnect(connectionsSocketUrl);
    connectionsSocketUrl = '';
  }
}

function setServiceAvailability(next: ServiceAvailability) {
  if (serviceAvailability === next) {
    return;
  }

  serviceAvailability = next;

  if (next === 'running') {
    loading = true;
    failed = false;
    void loadRuntimeRouteRules(monitoringMountId);
    startConnectionsUpdates();
  } else {
    stopConnectionsUpdates();
    pendingConnectionsPayload = null;

    if (next === 'stopped') {
      loading = false;
      failed = false;
      activeConnections.clear();
      closedConnections.clear();
      closingConnectionIds.clear();
    } else if (next === 'unavailable') {
      loading = false;
      failed = true;
    }
  }

  renderControls();
  renderConnections();
}

function watchServiceState() {
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (!monitoringMounted) {
      return;
    }

    setServiceAvailability(
      getServiceAvailability({
        loading: false,
        failed: false,
        running: uiState.service.forkop.running,
      }),
    );
  });
}

function resetMonitoringState() {
  activeTab = 'active';
  selectedDeviceFilter = ALL_FILTER_VALUE;
  // A deep link (monitoring#search=example.com) opens pre-filtered.
  searchQuery = readPageParams().search || '';
  pathFilter = ALL_FILTER_VALUE;
  followBaseline = null;
  selectedConnectionId = null;
  lastPathFilterSignature = '';
  lastDeviceFilterSignature = '';
  loading = true;
  failed = false;
  closingAll = false;
  monitoringPaused = false;
  monitoringPausedAt = null;
  serviceAvailability = 'loading';
  pendingConnectionsPayload = null;
  activeConnections.clear();
  closedConnections.clear();
  closingConnectionIds.clear();

  const searchInput = document.getElementById(
    'monitoring-search',
  ) as HTMLInputElement | null;
  if (searchInput) {
    searchInput.value = searchQuery;
  }
}

async function onPageMount() {
  onPageUnmount();

  monitoringMounted = true;
  monitoringMountId += 1;
  const mountId = monitoringMountId;

  runtimeRouteRules = [];
  expandedRouteConditions.clear();
  void loadRuntimeRouteRules(mountId);
  resetMonitoringState();
  loadMonitoringPreferences();
  bindControls();
  renderControls();
  renderConnections();
  watchServiceState();

  void loadLocalDevices();
  void loadRouteDisplayNames();
  void loadNodeDisplayNames();

  if (getCachedRuntimeUiState()) {
    void refreshRuntimeUiState({ force: true });
  } else {
    const uiState = await refreshRuntimeUiState({ force: true });

    if (!monitoringMounted || mountId !== monitoringMountId) {
      return;
    }

    if (!uiState && serviceAvailability === 'loading') {
      setServiceAvailability('unavailable');
    }
  }

  document.addEventListener('selectionchange', flushRenderAfterSelection);
  document.addEventListener('copy', handleMonitoringValueCopy);

  renderTimer = setInterval(() => {
    if (monitoringPaused) {
      return;
    }

    renderConnections();
  }, RENDER_INTERVAL_MS);
}

function onPageUnmount() {
  monitoringMounted = false;
  monitoringMountId += 1;

  if (renderTimer) {
    clearInterval(renderTimer);
    renderTimer = null;
  }

  stopConnectionsUpdates();
  serviceStateUnsubscribe?.();
  serviceStateUnsubscribe = null;

  document.removeEventListener('selectionchange', flushRenderAfterSelection);
  document.removeEventListener('copy', handleMonitoringValueCopy);
}

function registerLifecycleListeners() {
  if (monitoringLifecycleRegistered) {
    return;
  }

  monitoringLifecycleRegistered = true;

  store.subscribe(
    (next: StoreType, prev: StoreType, diff: Partial<StoreType>) => {
      if (
        diff.tabService &&
        next.tabService.current !== prev.tabService.current
      ) {
        const isMonitoringVisible = next.tabService.current === 'monitoring';

        if (isMonitoringVisible) {
          return onPageMount();
        }

        if (!isMonitoringVisible) {
          return onPageUnmount();
        }
      }
    },
  );
}

export async function initController(
  controllerDependencies: MonitoringControllerDependencies = {},
): Promise<void> {
  dependencies = {
    ...dependencies,
    ...controllerDependencies,
  };

  if (monitoringControllerInitialized) {
    return;
  }

  monitoringControllerInitialized = true;

  onMount('monitoring-status').then(() => {
    registerLifecycleListeners();

    // #view=nodes opens on node selection, which the dashboard controller
    // runs: showMonitoringView hands the Monitoring tab over to it. A link
    // into this tab changes only the hash - the tabs of one view are not
    // reloaded - so the view follows the hash instead of being read once.
    const followRequestedView = () =>
      showMonitoringView(readMonitoringView(), false);

    followRequestedView();
    window.addEventListener('hashchange', followRequestedView);

    if (
      store.get().tabService.current === 'monitoring' ||
      isActiveLuciTab('monitoring')
    ) {
      onPageMount();
    }
  });
}
