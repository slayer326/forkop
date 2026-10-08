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

  it('keeps the four overview cards balanced and stacks them on narrow screens', () => {
    expect(dashboardStyles).toContain(
      'grid-template-columns: repeat(2, minmax(0, 1fr))',
    );
    expect(dashboardStyles).toMatch(
      /@media \(max-width: 900px\) \{[\s\S]*?\.fkp-overview__grid \{\s*grid-template-columns: minmax\(0, 1fr\);/,
    );
    expect(diagnosticStyles).toContain(
      'grid-template-columns: minmax(0, 1.7fr) minmax(280px, 0.85fr)',
    );
    expect(historyStyles).toContain(
      'grid-template-columns: minmax(480px, 0.95fr) minmax(0, 1.5fr)',
    );
    expect(historyStyles).toContain('@media (min-width: 1100px)');
  });

  it('keeps recovery statuses aligned but sized to their content', () => {
    expect(historyStyles).toContain(
      'grid-template-columns: minmax(0, 1fr) 190px',
    );
    expect(historyStyles).toMatch(
      /\.fkp-history__facts \.fkp-status \{[^}]*display: inline-block;[^}]*width: auto;[^}]*max-width: 100%;[^}]*border-radius: 999px;/,
    );
  });
});
