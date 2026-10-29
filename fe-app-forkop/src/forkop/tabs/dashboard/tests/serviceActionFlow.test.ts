import { describe, expect, it, vi } from 'vitest';

import { runOverviewServiceAction } from '../serviceActionFlow';

describe('overview service action flow', () => {
  const steps = () => {
    const calls: string[] = [];
    const run = vi.fn(async () => {
      calls.push('run');
    });
    const refreshHealth = vi.fn(async () => {
      calls.push('health');
    });
    return {
      calls,
      run,
      refreshHealth,
      value: {
        run,
        onError: () => {
          calls.push('error');
        },
        refreshRuntime: async () => {
          calls.push('runtime');
        },
        refreshHealth,
        setBusy: (busy: boolean) => {
          calls.push(busy ? 'busy' : 'idle');
        },
      },
    };
  };

  it('reads the health again before the buttons are enabled', async () => {
    // After the restart that removes a kept safety guard (UC-019) the Recovery
    // card must not offer that restart again until the next poll.
    const { calls, value } = steps();
    await runOverviewServiceAction(value);
    expect(calls).toEqual(['busy', 'run', 'runtime', 'health', 'idle']);
  });

  it('reports a failed action and still refreshes', async () => {
    const { calls, run, value } = steps();
    run.mockImplementationOnce(async () => {
      calls.push('run');
      throw new Error('boom');
    });
    await runOverviewServiceAction(value);
    expect(calls).toEqual([
      'busy',
      'run',
      'error',
      'runtime',
      'health',
      'idle',
    ]);
  });

  it('enables the buttons again when a refresh fails', async () => {
    const { calls, refreshHealth, value } = steps();
    refreshHealth.mockImplementationOnce(async () => {
      throw new Error('rpc');
    });
    await expect(runOverviewServiceAction(value)).rejects.toThrow('rpc');
    expect(calls[calls.length - 1]).toBe('idle');
  });
});
