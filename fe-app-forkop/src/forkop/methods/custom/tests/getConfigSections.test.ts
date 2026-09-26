import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getReadonlyConfigSections: vi.fn(),
}));

vi.mock('../../shell', () => ({
  ForkopShellMethods: {
    getReadonlyConfigSections: mocks.getReadonlyConfigSections,
  },
}));

import { getConfigSections } from '../getConfigSections';

describe('getConfigSections ACL fallback', () => {
  beforeEach(() => {
    mocks.getReadonlyConfigSections.mockReset();
    vi.stubGlobal('uci', {
      load: vi.fn().mockResolvedValue(undefined),
      sections: vi.fn().mockResolvedValue([
        { '.name': 'main', '.type': 'section', password: 'write-only' },
      ]),
    });
  });

  it('keeps full configuration for a user with UCI access', async () => {
    expect(await getConfigSections()).toMatchObject([
      { password: 'write-only' },
    ]);
    expect(mocks.getReadonlyConfigSections).not.toHaveBeenCalled();
  });

  it('uses sanitized sections when UCI read is denied', async () => {
    vi.mocked(uci.sections).mockRejectedValue(new Error('permission denied'));
    mocks.getReadonlyConfigSections.mockResolvedValue({
      success: true,
      data: [{ '.name': 'main', '.type': 'section', action: 'proxy' }],
    });
    expect(await getConfigSections()).toEqual([
      { '.name': 'main', '.type': 'section', action: 'proxy' },
    ]);
    expect(mocks.getReadonlyConfigSections).toHaveBeenCalledOnce();
  });
});
