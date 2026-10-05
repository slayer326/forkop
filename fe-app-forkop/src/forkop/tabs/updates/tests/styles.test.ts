import { describe, expect, it } from 'vitest';
import { styles } from '../styles';

describe('component card action layout', () => {
  it('wraps action rows and keeps buttons inside the card', () => {
    expect(styles).toMatch(
      /\.fkp_updates-page__component__actions-main\s*\{[^}]*flex-wrap:\s*wrap;/s,
    );
    expect(styles).toMatch(
      /\.fkp_updates-page__component__variants-buttons\s*\{[^}]*flex-wrap:\s*wrap;/s,
    );
    expect(styles).toMatch(
      /\.fkp_updates-page__component__actions-main > \.fkp-partial-button,[^}]*max-width:\s*100%;/s,
    );
  });
});
