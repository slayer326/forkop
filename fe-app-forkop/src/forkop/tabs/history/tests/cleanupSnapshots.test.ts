import { describe, expect, it, vi } from 'vitest';
import type { Forkop } from '../../../types';
import { cleanupOldSnapshots } from '../cleanupSnapshots';

const snapshot = (id: string, isLkg = false): Forkop.SnapshotMetadata => ({
  id,
  created_at: 1,
  kind: 'automatic',
  reason: 'before-reload',
  forkop_version: '1.0.0',
  is_lkg: isLkg,
});

describe('bulk snapshot cleanup', () => {
  const expected = [
    snapshot('old-1'),
    snapshot('working', true),
    snapshot('old-2'),
  ];

  it('deletes only old snapshots after confirming the current recovery point', async () => {
    const remove = vi.fn(async (_id: string) => 'deleted' as const);
    expect(
      await cleanupOldSnapshots(expected, async () => expected, remove),
    ).toEqual({ status: 'deleted', deleted: 2 });
    expect(remove.mock.calls.map(([id]) => id)).toEqual(['old-1', 'old-2']);
  });

  it('keeps the autotune rollback snapshot even during bulk cleanup', async () => {
    const protectedList = [
      snapshot('old-1'),
      snapshot('working', true),
      { ...snapshot('rollback'), is_protected: true },
    ];
    const remove = vi.fn(async (_id: string) => 'deleted' as const);
    expect(
      await cleanupOldSnapshots(
        protectedList,
        async () => protectedList,
        remove,
      ),
    ).toEqual({ status: 'deleted', deleted: 1 });
    expect(remove.mock.calls.map(([id]) => id)).toEqual(['old-1']);
  });

  it('does not delete anything if the working snapshot changed or disappeared', async () => {
    const remove = vi.fn(async () => 'deleted' as const);
    expect(
      await cleanupOldSnapshots(
        expected,
        async () => [
          snapshot('old-1', true),
          snapshot('working'),
          snapshot('old-2'),
        ],
        remove,
      ),
    ).toEqual({ status: 'changed', deleted: 0 });
    expect(
      await cleanupOldSnapshots(
        expected,
        async () => [snapshot('old-1'), snapshot('old-2')],
        remove,
      ),
    ).toEqual({ status: 'changed', deleted: 0 });
    expect(remove).not.toHaveBeenCalled();
  });

  it('does not delete a stale list or one it cannot reload', async () => {
    const remove = vi.fn(async () => 'deleted' as const);
    expect(
      await cleanupOldSnapshots(
        expected,
        async () => [snapshot('working', true), snapshot('old-1')],
        remove,
      ),
    ).toEqual({ status: 'changed', deleted: 0 });
    expect(
      await cleanupOldSnapshots(expected, async () => null, remove),
    ).toEqual({ status: 'load-failed', deleted: 0 });
    expect(remove).not.toHaveBeenCalled();
  });

  it('stops at the first backend refusal and reports partial cleanup', async () => {
    const remove = vi
      .fn()
      .mockResolvedValueOnce('deleted')
      .mockResolvedValueOnce('busy');
    expect(
      await cleanupOldSnapshots(expected, async () => expected, remove),
    ).toEqual({ status: 'busy', deleted: 1 });
    expect(remove).toHaveBeenCalledTimes(2);
  });
});
