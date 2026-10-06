// The connection payload and user actions render immediately. The periodic
// refresh is only needed for elapsed time on connections that are still open.
export function needsElapsedTimeRefresh(
  paused: boolean,
  visible: boolean,
  activeCount: number,
  showingActive: boolean,
  selectedConnectionActive: boolean,
): boolean {
  return (
    !paused &&
    visible &&
    activeCount > 0 &&
    (showingActive || selectedConnectionActive)
  );
}

export function advancedOptionCount(
  device: string,
  path: string,
  sort: string,
  defaultValue = 'all',
): number {
  return (
    Number(device !== defaultValue) +
    Number(path !== defaultValue) +
    Number(sort !== 'start')
  );
}

export function shouldPaintConnectionSnapshot(
  mounted: boolean,
  sameMount: boolean,
  visible: boolean,
): boolean {
  return mounted && sameMount && visible;
}
