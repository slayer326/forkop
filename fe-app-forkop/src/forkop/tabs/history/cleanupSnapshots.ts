import type { Forkop } from '../../types';
import { snapshotCleanupIds } from './model';

type DeleteStatus = 'deleted' | 'busy' | 'failed';
export type CleanupStatus =
  | 'deleted'
  | 'changed'
  | 'load-failed'
  | 'busy'
  | 'failed';

export async function cleanupOldSnapshots(
  expected: Forkop.SnapshotMetadata[],
  list: () => Promise<Forkop.SnapshotMetadata[] | null>,
  remove: (id: string) => Promise<DeleteStatus>,
): Promise<{ status: CleanupStatus; deleted: number }> {
  const workingId = expected.find((snapshot) => snapshot.is_lkg)?.id;
  const ids = snapshotCleanupIds(expected);
  if (!workingId || ids.length === 0) return { status: 'changed', deleted: 0 };

  let current: Forkop.SnapshotMetadata[] | null;
  try {
    current = await list();
  } catch (_error) {
    return { status: 'load-failed', deleted: 0 };
  }
  if (!current) return { status: 'load-failed', deleted: 0 };

  const currentIds = snapshotCleanupIds(current);
  if (
    current.find((snapshot) => snapshot.is_lkg)?.id !== workingId ||
    currentIds.length !== ids.length ||
    currentIds.some((id) => !ids.includes(id))
  ) {
    return { status: 'changed', deleted: 0 };
  }

  let deleted = 0;
  for (const id of ids) {
    let status: DeleteStatus;
    try {
      status = await remove(id);
    } catch (_error) {
      return { status: 'failed', deleted };
    }
    if (status !== 'deleted') return { status, deleted };
    deleted += 1;
  }
  return { status: 'deleted', deleted };
}
