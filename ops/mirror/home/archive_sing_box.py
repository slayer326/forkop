"""Keep verified sing-box packages after rolling OpenWrt feeds change.

Only packages from complete, published feed snapshots are archived. The
catalog and blobs are immutable from a router's perspective; a changed
upstream package becomes a new SHA-256-addressed entry.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re

from guard import ROOT, guard

NAMES = ('sing-box', 'sing-box-tiny')
VERSION = r'[0-9][A-Za-z0-9.+~_-]*'
ARCH = r'[A-Za-z0-9_-]+'


def package_identity(filename, arch):
    for name in NAMES:
        ipk = re.fullmatch(rf'{name}_({VERSION})_{re.escape(arch)}\.ipk', filename)
        if ipk:
            return dict(package=name, version=ipk[1], arch=arch, format='ipk')
        apk = re.fullmatch(rf'{name}-({VERSION})\.apk', filename)
        if apk:
            return dict(package=name, version=apk[1], arch=arch, format='apk')
    return None


def published_feeds(public, snapshots):
    releases = public / 'openwrt' / 'releases'
    if not releases.exists():
        return
    for link in releases.rglob('*'):
        if not link.is_symlink():
            continue
        target = link.resolve(strict=True)
        if not target.is_relative_to(snapshots) or not (target / '.complete').is_file():
            continue
        relative = link.relative_to(public / 'openwrt')
        parts = relative.parts
        if len(parts) < 4 or parts[0] != 'releases':
            continue
        if parts[2] == 'packages' and len(parts) >= 5:
            arch = parts[3]
        elif parts[1].startswith('packages-') and len(parts) >= 4:
            arch = parts[2]
        else:
            continue
        if not re.fullmatch(ARCH, arch):
            continue
        yield relative, arch, target


def collect(public, snapshots, destination):
    """Publish an archive catalog; never replace a mismatched existing blob."""
    if destination.exists() and destination.is_symlink():
        raise ValueError('Archive destination must not be a symlink')
    destination.mkdir(parents=True, exist_ok=True)
    catalog_path = destination / 'packages.json'
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {'schema': 1, 'packages': []}
    if catalog.get('schema') != 1 or not isinstance(catalog.get('packages'), list):
        raise ValueError('Invalid sing-box archive catalog')
    entries = {}
    for row in catalog['packages']:
        if any(not isinstance(row.get(key), str) for key in
               ('package', 'version', 'arch', 'format', 'sha256', 'filename', 'url')):
            raise ValueError('Invalid sing-box archive entry')
        identity = package_identity(row['filename'], row['arch'])
        if not identity or any(row[key] != identity[key] for key in identity) or \
                not re.fullmatch(r'[a-f0-9]{64}', row['sha256']) or \
                row['url'] != f"/forkop/sing-box-archive/blobs/{row['sha256']}/{row['filename']}":
            raise ValueError('Invalid sing-box archive entry')
        blob = destination / 'blobs' / row['sha256'] / row['filename']
        if not blob.is_file() or hashlib.sha256(blob.read_bytes()).hexdigest() != row['sha256']:
            raise ValueError('Corrupt sing-box archive blob')
        key = tuple(row[k] for k in ('package', 'version', 'arch', 'format', 'sha256'))
        entries[key] = row

    for relative, arch, feed in published_feeds(public, snapshots):
        for path in feed.iterdir():
            if path.is_symlink() or not path.is_file():
                continue
            identity = package_identity(path.name, arch)
            if not identity:
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            key = tuple(identity[k] for k in ('package', 'version', 'arch', 'format')) + (digest,)
            if key in entries:
                continue
            blob = destination / 'blobs' / digest / path.name
            blob.parent.mkdir(parents=True, exist_ok=True)
            if blob.exists():
                if hashlib.sha256(blob.read_bytes()).hexdigest() != digest:
                    raise ValueError('Archive blob has changed')
            else:
                temporary = blob.with_name('.' + blob.name + '.next')
                temporary.unlink(missing_ok=True)
                os.link(path, temporary)
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                    temporary.unlink()
                    raise ValueError('Package changed while archiving')
                os.replace(temporary, blob)
            entries[key] = {**identity, 'sha256': digest, 'filename': path.name,
                            'url': f'/forkop/sing-box-archive/blobs/{digest}/{path.name}',
                            'source': '/openwrt/' + relative.as_posix() + '/' + path.name}

    result = {'schema': 1, 'packages': [entries[k] for k in sorted(entries)]}
    temporary = catalog_path.with_name('.packages.json.next')
    with temporary.open('w') as output:
        json.dump(result, output, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    temporary.chmod(0o644)
    os.replace(temporary, catalog_path)
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wait', action='store_true',
                        help='wait until mirror synchronization releases its lock')
    args = parser.parse_args()

    guard()
    data = ROOT / 'data'
    with (data / '.sync.lock').open('a') as lock:
        if args.wait:
            fcntl.flock(lock, fcntl.LOCK_EX)
        else:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SystemExit('Mirror synchronization is running; try later') from error
        guard()
        retained = collect(data / 'public', data / 'snapshots' / 'openwrt',
                           data / 'public' / 'forkop' / 'sing-box-archive')
    print(json.dumps({'archived_packages': retained}))


if __name__ == '__main__':
    main()
