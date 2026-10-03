import { describe, expect, it } from 'vitest';

import { styles as dashboardStyles } from '../styles';
import { styles as diagnosticStyles } from '../../diagnostic/styles';
import { styles as historyStyles } from '../../history/styles';

describe('wide tab layouts', () => {
  it.each([
    ['dashboard', dashboardStyles],
    ['diagnostic', diagnosticStyles],
    ['history', historyStyles],
  ])('lets the %s mount field use the full LuCI section width', (_, styles) => {
    expect(styles).toMatch(/> \.cbi-value-title \{\s*display: none;/);
    expect(styles).toMatch(
      /> \.cbi-value-field \{[\s\S]*?margin-inline-start: 0;[\s\S]*?width: 100%;[\s\S]*?max-width: none;/,
    );
  });

  it('uses the available width without stretching every card', () => {
    expect(dashboardStyles).toContain(
      'repeat(auto-fit, minmax(min(100%, 320px), 1fr))',
    );
    expect(diagnosticStyles).toContain(
      'grid-template-columns: minmax(0, 1.15fr) minmax(320px, 0.85fr)',
    );
    expect(historyStyles).toContain(
      'grid-template-columns: minmax(280px, 0.8fr) minmax(0, 2fr)',
    );
  });
});
