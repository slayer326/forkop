import type { ClashAPI } from '../../types';

// Controllers may return history in either order. Display the newest sample,
// including a failed (zero-delay) sample, instead of a stale first entry.
export function latestProxyLatency(proxy?: ClashAPI.ProxyBase): number {
  const history = Array.isArray(proxy?.history) ? proxy.history : [];
  let latest = history[history.length - 1];
  let timestamp = Number.NEGATIVE_INFINITY;
  for (const entry of history) {
    if (!entry) continue;
    const time =
      typeof entry.time === 'string' ? Date.parse(entry.time) : Number.NaN;
    if (Number.isFinite(time) && time >= timestamp) {
      timestamp = time;
      latest = entry;
    }
  }
  return typeof latest?.delay === 'number' &&
    Number.isFinite(latest.delay) &&
    latest.delay > 0
    ? latest.delay
    : 0;
}
