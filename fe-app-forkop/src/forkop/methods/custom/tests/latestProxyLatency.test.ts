import { describe, expect, it } from 'vitest';
import type { ClashAPI } from '../../../types';
import { latestProxyLatency } from '../latestProxyLatency';

const proxy = (history: ClashAPI.ProxyBase['history']) =>
  ({ history }) as ClashAPI.ProxyBase;
describe('latest proxy measurement', () => {
  const old = { time: '2026-11-10T10:00:00Z', delay: 0 };
  const recent = { time: '2026-11-10T10:01:00Z', delay: 84 };
  it('shows a recovered tunnel in either controller history order', () => {
    expect(latestProxyLatency(proxy([old, recent]))).toBe(84);
    expect(latestProxyLatency(proxy([recent, old]))).toBe(84);
  });
  it('does not reuse a historical success after a failed recent check', () => {
    expect(
      latestProxyLatency(
        proxy([recent, { time: '2026-11-10T10:02:00Z', delay: 0 }]),
      ),
    ).toBe(0);
  });
  it('handles missing history and controllers without usable timestamps', () => {
    expect(latestProxyLatency()).toBe(0);
    expect(latestProxyLatency(proxy([]))).toBe(0);
    expect(
      latestProxyLatency(
        proxy([
          { time: '', delay: 12 },
          { time: '', delay: 55 },
        ]),
      ),
    ).toBe(55);
  });
});
