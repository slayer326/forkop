import { Forkop } from '../../types';

// How one viewer likes a section's node grid: sorted by latency and/or
// without the nodes that have no latency. Only the browser keeps it; the
// configuration and the nodes themselves are untouched.
export interface OutboundViewOptions {
  sortByLatency: boolean;
  hideWithoutLatency: boolean;
}

const STORAGE_KEY = 'forkop.dashboard.outboundView';

type StorageLike = Pick<Storage, 'getItem' | 'setItem'>;

function readAll(storage: StorageLike): Record<string, OutboundViewOptions> {
  try {
    const value = JSON.parse(storage.getItem(STORAGE_KEY) || '{}');
    return value && typeof value === 'object' && !Array.isArray(value)
      ? value
      : {};
  } catch (_error) {
    return {};
  }
}

export function loadOutboundView(
  storage: StorageLike,
  sectionName: string,
): OutboundViewOptions {
  const stored = readAll(storage)[sectionName];

  return {
    sortByLatency: stored?.sortByLatency === true,
    hideWithoutLatency: stored?.hideWithoutLatency === true,
  };
}

export function saveOutboundView(
  storage: StorageLike,
  sectionName: string,
  options: OutboundViewOptions,
) {
  try {
    const all = readAll(storage);
    all[sectionName] = {
      sortByLatency: options.sortByLatency,
      hideWithoutLatency: options.hideWithoutLatency,
    };
    storage.setItem(STORAGE_KEY, JSON.stringify(all));
  } catch (_error) {
    /* private mode or blocked storage: the choice lasts for this page */
  }
}

// URLTest, priority and selector cards stand for groups, not servers: they
// keep their place at the top and are never hidden.
export function isGroupOutbound(outbound: Forkop.Outbound) {
  const type = outbound.type?.toLowerCase();

  return Boolean(
    outbound.urlTestInfo ||
      outbound.priorityInfo ||
      type === 'urltest' ||
      type === 'priority' ||
      type === 'selector',
  );
}

function latencyRank(outbound: Forkop.Outbound) {
  const latency = Number(outbound.latency);
  return Number.isFinite(latency) && latency > 0
    ? latency
    : Number.POSITIVE_INFINITY;
}

export function arrangeOutbounds(
  outbounds: Forkop.Outbound[],
  options: OutboundViewOptions,
) {
  const visible = options.hideWithoutLatency
    ? outbounds.filter(
        (outbound) =>
          isGroupOutbound(outbound) ||
          outbound.selected ||
          latencyRank(outbound) !== Number.POSITIVE_INFINITY,
      )
    : outbounds;

  if (!options.sortByLatency) {
    return { outbounds: visible, hidden: outbounds.length - visible.length };
  }

  const groups = visible.filter(isGroupOutbound);
  const nodes = visible
    .filter((outbound) => !isGroupOutbound(outbound))
    .map((outbound, index) => ({ outbound, index }))
    .sort(
      (left, right) =>
        latencyRank(left.outbound) - latencyRank(right.outbound) ||
        left.index - right.index,
    )
    .map(({ outbound }) => outbound);

  return {
    outbounds: [...groups, ...nodes],
    hidden: outbounds.length - visible.length,
  };
}

// The share links of the shown nodes, in the order shown, one per line.
export function getVisibleLinks(outbounds: Forkop.Outbound[]) {
  return outbounds
    .filter((outbound) => !isGroupOutbound(outbound) && outbound.link)
    .map((outbound) => outbound.link as string);
}
