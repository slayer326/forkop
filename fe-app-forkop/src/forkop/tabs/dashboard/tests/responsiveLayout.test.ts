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
      'grid-template-columns: minmax(480px, 0.95fr) minmax(0, 1.5fr)',
    );
    expect(historyStyles).toContain('@media (min-width: 1100px)');
  });

  it('keeps recovery statuses in an aligned column without splitting words', () => {
    expect(historyStyles).toContain(
      'grid-template-columns: minmax(0, 1fr) 190px',
    );
    expect(historyStyles).toMatch(
      /\.fkp-history__facts \.fkp-status \{[^}]*width: 100%;[^}]*overflow-wrap: normal;[^}]*word-break: normal;/,
    );
  });
});
