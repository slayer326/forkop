import { describe, expect, it } from 'vitest';

import { styles } from '../styles';

describe('monitoring layout', () => {
  it('keeps the LuCI output wrapper at the full section width', () => {
    expect(styles).toMatch(
      /> output \{[^}]*flex: 1 1 100%;[^}]*width: 100%;[^}]*min-width: 0;/,
    );
  });

  it('does not let mobile flex bases stretch the search and filters vertically', () => {
    expect(styles).toMatch(
      /@media \(max-width: 520px\) \{[\s\S]*?\.fkp_monitoring-page__filters > select \{\s*flex: none;/,
    );
    expect(styles).toMatch(
      /@media \(max-width: 520px\) \{[\s\S]*?\.fkp_monitoring-page__search \{\s*flex: none;/,
    );
    expect(styles).toMatch(
      /@media \(max-width: 520px\) \{[\s\S]*?#monitoring-follow-toggle \{\s*grid-column: 1 \/ -1;/,
    );
  });
});
