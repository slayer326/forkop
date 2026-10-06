import { describe, expect, it } from 'vitest';
import {
  advancedOptionCount,
  needsElapsedTimeRefresh,
  shouldPaintConnectionSnapshot,
} from '../renderPolicy';

describe('monitoring elapsed-time refresh', () => {
  it('refreshes visible active connections', () => {
    expect(needsElapsedTimeRefresh(false, true, 1, true, false)).toBe(true);
  });

  it('keeps an active detail current while the closed tab is open', () => {
    expect(needsElapsedTimeRefresh(false, true, 1, false, true)).toBe(true);
  });

  it.each([
    [true, true, 1, true, false],
    [false, false, 1, true, false],
    [false, true, 0, true, false],
    [false, true, 1, false, false],
  ])('skips a refresh when no elapsed label can change', (...args) => {
    expect(needsElapsedTimeRefresh(...args)).toBe(false);
  });
});

describe('advanced monitoring options', () => {
  it('counts only selected device, path and non-default sorting', () => {
    expect(advancedOptionCount('all', 'all', 'start')).toBe(0);
    expect(advancedOptionCount('192.0.2.1', 'all', 'start')).toBe(1);
    expect(advancedOptionCount('192.0.2.1', 'kind:direct', 'total')).toBe(3);
  });
});

describe('connection snapshot painting', () => {
  it('paints current data while monitoring is visible', () => {
    expect(shouldPaintConnectionSnapshot(true, true, true)).toBe(true);
  });

  it.each([
    [false, true, true],
    [true, false, true],
    [true, true, false],
  ])('defers data from an unmounted or hidden view', (...args) => {
    expect(shouldPaintConnectionSnapshot(...args)).toBe(false);
  });
});
