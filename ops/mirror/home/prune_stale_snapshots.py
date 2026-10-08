#!/usr/bin/env python3
"""Remove completed OpenWrt mirror snapshots no longer served publicly.

Dry-run is the default. --apply shares the mirror synchronizer's lock and
retains every published or incomplete snapshot.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import time

from guard import ROOT, guard


OBJECT_NAME = re.compile(r"[0-9a-f]{64}")
INCOMPLETE_MAX_AGE = 7 * 24 * 60 * 60


def plan_cleanup(data, now=None):
    data = Path(data).resolve(strict=True)
    snapshots = data / "snapshots" / "openwrt"
    public = data / "public" / "openwrt" / "releases"
    if not snapshots.is_dir() or not public.is_dir():
        raise RuntimeError("OpenWrt snapshots or public release tree is missing")
    if snapshots.is_symlink() or public.is_symlink():
        raise RuntimeError("OpenWrt mirror roots must not be symbolic links")
    snapshots = snapshots.resolve(strict=True)
    if not snapshots.is_relative_to(data):
        raise RuntimeError("Snapshot root escapes the mirror data directory")

    published = set()
    for link in public.rglob("*"):
        if not link.is_symlink():
            continue
        try:
            target = link.resolve(strict=True)
        except (FileNotFoundError, RuntimeError) as error:
            raise RuntimeError("A public OpenWrt link is broken") from error
        if target.is_relative_to(snapshots):
            if not (target / ".complete").is_file():
                raise RuntimeError("A published snapshot is incomplete")
            published.add(target)

    completed = []
    incomplete = []
    for feed in snapshots.iterdir():
        if feed.is_symlink():
            raise RuntimeError("A snapshot feed is a symbolic link")
        if not feed.is_dir():
            continue
        for snapshot in feed.iterdir():
            if snapshot.is_symlink():
                raise RuntimeError("A snapshot is a symbolic link")
            if not snapshot.is_dir():
                continue
            snapshot = snapshot.resolve(strict=True)
            if (snapshot / ".complete").is_file():
                completed.append(snapshot)
            else:
                incomplete.append(snapshot)

    if completed and not published:
        raise RuntimeError("Refusing cleanup without published OpenWrt snapshots")
    stale = [snapshot for snapshot in completed if snapshot not in published]
    cutoff = (time.time() if now is None else now) - INCOMPLETE_MAX_AGE
    # The mirror lock excludes a running sync. A week-old unfinished directory
    # cannot be an active transfer and should not accumulate forever.
    stale_incomplete = [snapshot for snapshot in incomplete
                        if snapshot not in published and snapshot.stat().st_mtime < cutoff]
    retained_incomplete = [snapshot for snapshot in incomplete if snapshot not in stale_incomplete]
    return snapshots, published, retained_incomplete, stale, stale_incomplete


def plan_list_cleanup(data):
    """Only unreferenced timestamped list snapshots may be removed."""
    data = Path(data).resolve(strict=True)
    root = data / 'snapshots' / 'lists'
    if not root.exists():
        return []
    if root.is_symlink() or not root.is_dir() or not root.resolve().is_relative_to(data):
        raise RuntimeError('List snapshot root is unsafe')
    link = data / 'public' / 'forkop' / 'lists'
    if not link.exists() and not link.is_symlink():
        return []
    if not link.is_symlink():
        raise RuntimeError('No published list snapshot link; refusing cleanup')
    try:
        current = link.resolve(strict=True)
    except (FileNotFoundError, RuntimeError) as error:
        raise RuntimeError('Published list snapshot link is broken') from error
    root = root.resolve(strict=True)
    if current.parent != root or not current.is_dir():
        raise RuntimeError('Published lists are not a direct snapshot')
    stale = []
    for item in root.iterdir():
        if item.is_symlink():
            raise RuntimeError('List snapshot is a symbolic link')
        if item.is_dir() and item != current and re.fullmatch(r'[0-9]{10}', item.name):
            stale.append(item)
    return stale


def cleanup_lists(data, apply=False):
    stale = plan_list_cleanup(data)
    if apply:
        for snapshot in stale:
            if snapshot not in plan_list_cleanup(data):
                raise RuntimeError('List snapshot changed while applying cleanup')
            shutil.rmtree(snapshot)
    return len(stale)


def cleanup(data, apply=False):
    snapshots, published, incomplete, stale, stale_incomplete = plan_cleanup(data)
    stale_lists = cleanup_lists(data)
    result = {
        "mode": "apply" if apply else "dry-run",
        "published_preserved": len(published),
        "incomplete_preserved": len(incomplete),
        "stale_completed": len(stale),
        "stale_incomplete": len(stale_incomplete),
        "stale_lists": stale_lists,
        "objects_removed": 0,
        "reclaimed_object_bytes": 0,
    }
    if not apply:
        return result

    for snapshot in stale + stale_incomplete:
        if not snapshot.is_relative_to(snapshots) or \
                (snapshot / ".complete").is_file() != (snapshot in stale):
            raise RuntimeError("Snapshot changed while applying cleanup")
        if snapshot in stale_incomplete and snapshot.stat().st_mtime >= time.time() - INCOMPLETE_MAX_AGE:
            raise RuntimeError("Incomplete snapshot became recent during cleanup")
        shutil.rmtree(snapshot)

    cleanup_lists(data, apply=True)

    for feed in snapshots.iterdir():
        if feed.is_dir() and not feed.is_symlink() and not any(feed.iterdir()):
            feed.rmdir()

    objects = Path(data) / "objects"
    if objects.is_dir() and not objects.is_symlink():
        for item in objects.iterdir():
            if item.is_symlink() or not item.is_file() or not OBJECT_NAME.fullmatch(item.name):
                continue
            stat = item.stat()
            if stat.st_nlink == 1:
                result["reclaimed_object_bytes"] += stat.st_size
                item.unlink()
                result["objects_removed"] += 1
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="delete stale snapshots after safety checks")
    args = parser.parse_args()

    guard()
    data = ROOT / "data"
    with (data / ".sync.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SystemExit("Mirror synchronization is running; try later") from error
        result = cleanup(data, apply=args.apply)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
