#!/usr/bin/env python3
"""Bounded, single-worker mirror. Never execute downloaded code or modify the host.

Feeds are built privately using content-addressed objects, then exposed by an
atomic symlink. Original package indexes/signatures are kept unchanged.
"""
import argparse
import datetime
import errno
import fcntl
import gzip
import hashlib
import html.parser
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from guard import ROOT, guard
from fast_https import FastHTTPSHandler
from archive_sing_box import collect as collect_sing_box_archive
from prune_stale_snapshots import INCOMPLETE_MAX_AGE, cleanup_lists

DATA = ROOT / 'data'
PUBLIC = DATA / 'public'
RATE = 1024 * 1024  # Aggregate incoming payload, one worker: 1 MiB/s.
MAX_DATA = 100 * 1024**3
MIN_FREE = 10 * 1024**3
MAX_FILE = 512 * 1024**2
PLATFORMS = [('mediatek/filogic', 'aarch64_cortex-a53'), ('rockchip/armv8', 'aarch64_generic')]
# Start with the user's existing firmware, then the latest stable APK firmware.
# Additional releases are deliberately not advertised until their feeds are complete.
RELEASES = ['24.10.5', '24.10.0', '24.10.1', '25.12.5']
HOSTS = {'downloads.openwrt.org', 'github.com', 'api.github.com', 'raw.githubusercontent.com',
         'codeload.github.com', 'release-assets.githubusercontent.com',
         'objects.githubusercontent.com', 'github-releases.githubusercontent.com'}


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def safe_name(name):
    if not re.fullmatch(r'[A-Za-z0-9_+.,~=@-]+', name) or name.startswith('.'):
        raise ValueError('Unsafe upstream filename')
    return name


def safe_url(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or p.hostname not in HOSTS or p.port not in (None, 443) or p.username or p.password:
        raise ValueError('Unapproved upstream URL')
    return url


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, safe_url(newurl))


def atomic_bytes(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name('.' + path.name + '.tmp')
    with temporary.open('wb') as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.chmod(0o644)
    os.replace(temporary, path)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode())


def publish(snapshot, destination):
    snapshot = snapshot.resolve()
    if not snapshot.is_relative_to((DATA / 'snapshots').resolve()):
        raise ValueError('Snapshot escapes private data directory')
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and not destination.is_symlink():
        raise ValueError('Refusing to replace an existing real directory')
    temporary = destination.with_name('.' + destination.name + '.next')
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(os.path.relpath(snapshot, destination.parent), target_is_directory=True)
    os.replace(temporary, destination)


def prune_openwrt_snapshots():
    """Keep published snapshots and recent partials; prune orphaned old data.

    This runs under the synchronizer lock before downloads. An incomplete
    snapshot older than a week no longer provides reliable restart progress.
    """
    snapshot_root = DATA / 'snapshots' / 'openwrt'
    if not snapshot_root.exists():
        return {'snapshots': 0, 'incomplete': 0, 'objects': 0, 'bytes': 0}
    snapshot_root = snapshot_root.resolve()

    published = set()
    releases = PUBLIC / 'openwrt' / 'releases'
    if releases.exists():
        for link in releases.rglob('*'):
            if not link.is_symlink():
                continue
            try:
                target = link.resolve(strict=True)
            except FileNotFoundError as error:
                raise RuntimeError('Refusing mirror cleanup while a public OpenWrt link is broken') from error
            if target.is_relative_to(snapshot_root):
                if not (target / '.complete').is_file():
                    raise RuntimeError('Refusing mirror cleanup while a published snapshot is incomplete')
                published.add(target)

    completed = []
    incomplete = []
    for feed in snapshot_root.iterdir():
        if feed.is_symlink():
            raise RuntimeError('Refusing mirror cleanup because a feed is a symbolic link')
        if not feed.is_dir():
            continue
        for snapshot in feed.iterdir():
            if snapshot.is_symlink():
                raise RuntimeError('Refusing mirror cleanup because a snapshot is a symbolic link')
            if not snapshot.is_dir():
                continue
            if (snapshot / '.complete').is_file():
                completed.append(snapshot.resolve())
            else:
                incomplete.append(snapshot.resolve())
    if completed and not published:
        raise RuntimeError('Refusing mirror cleanup without published OpenWrt snapshots')

    stale = [snapshot for snapshot in completed if snapshot not in published]
    old_partials = [snapshot for snapshot in incomplete
                    if snapshot.stat().st_mtime < time.time() - INCOMPLETE_MAX_AGE]
    for snapshot in stale + old_partials:
        if not snapshot.is_relative_to(snapshot_root) or \
                (snapshot / '.complete').is_file() != (snapshot in stale):
            raise RuntimeError('Snapshot changed while pruning')
        if snapshot in old_partials and snapshot.stat().st_mtime >= time.time() - INCOMPLETE_MAX_AGE:
            raise RuntimeError('Incomplete snapshot became recent while pruning')
        shutil.rmtree(snapshot)
    for feed in snapshot_root.iterdir():
        if feed.is_dir() and not feed.is_symlink() and not any(feed.iterdir()):
            feed.rmdir()

    objects = 0
    reclaimed = 0
    object_root = DATA / 'objects'
    if object_root.exists():
        for item in object_root.iterdir():
            if item.is_symlink() or not item.is_file() or not re.fullmatch(r'[0-9a-f]{64}', item.name):
                continue
            details = item.stat()
            if details.st_nlink == 1:
                reclaimed += details.st_size
                item.unlink()
                objects += 1
    return {'snapshots': len(stale), 'incomplete': len(old_partials),
            'objects': objects, 'bytes': reclaimed}


class Links(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.files, self.directories = set(), set()

    def handle_starttag(self, tag, attributes):
        if tag != 'a':
            return
        href = dict(attributes).get('href', '')
        is_directory = href.endswith('/')
        name = urllib.parse.unquote(href[:-1] if is_directory else href)
        try:
            safe_name(name)
        except ValueError:
            return
        (self.directories if is_directory else self.files).add(name)


def ipk_manifest(body):
    result = {}
    for block in body.decode().split('\n\n'):
        fields = dict(line.split(': ', 1) for line in block.splitlines() if ': ' in line and not line.startswith(' '))
        if 'Filename' not in fields:
            continue
        name = fields['Filename'].removeprefix('./')
        safe_name(name)
        digest = fields.get('SHA256sum', '')
        if not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Package index has no valid SHA256sum')
        result[name] = (digest, int(fields['Size']))
    if not result:
        raise ValueError('Empty package index')
    return result


class FeedRotated(RuntimeError):
    """Upstream replaced the feed while it was being mirrored."""


class ContentMismatch(ValueError):
    """A completed upstream response does not match its package index."""


class IncompleteDownload(OSError):
    """The upstream connection ended before its advertised payload did."""


# downloads.openwrt.org never answers a static GET with these; they come
# from something on the path, so they are worth another attempt.
RETRY_STATUSES = [408, 425, 429, 500, 501, 502, 503, 504, 507, 509]


class Mirror:
    def __init__(self):
        self.opener = urllib.request.build_opener(Redirects(), FastHTTPSHandler())
        for name in ['objects', 'requests', 'snapshots', 'staging', 'public']:
            (DATA / name).mkdir(exist_ok=True)
        pruned = prune_openwrt_snapshots()
        if pruned['snapshots'] or pruned['incomplete'] or pruned['objects']:
            print(stamp(), 'pruned stale OpenWrt snapshots=' + str(pruned['snapshots']),
                  'incomplete=' + str(pruned['incomplete']),
                  'objects=' + str(pruned['objects']), 'bytes=' + str(pruned['bytes']), flush=True)
        lists_pruned = cleanup_lists(DATA, apply=True)
        if lists_pruned:
            print(stamp(), 'pruned unreferenced list snapshots=' + str(lists_pruned), flush=True)
        # du counts hard links only once, including links shared across feeds.
        import subprocess
        # The Zapret-Manager cache is a separate service with its own size cap
        # and its own UID, so this account cannot read it and du would exit 1.
        # Exclude it explicitly: the mirror budget covers mirror data only, and
        # any other unreadable subtree must still fail loudly rather than
        # silently understate the budget.
        measured = subprocess.run(
            ['du', '-sb', '--exclude=' + str(DATA / 'cache' / 'zapret-manager'), str(DATA)],
            capture_output=True, text=True, check=True)
        self.used = int(measured.stdout.split()[0])
        self.downloaded = 0
        self.deferred = []
        self.next_check = 0
        self.last_report = 0
        self.status = {'started_at': stamp(), 'sync_complete': False, 'state': 'syncing', 'phase': 'starting',
                       'components': ['openwrt', 'routing_lists', 'sing_box_extended'],
                       'release_versions': RELEASES}

    def report(self, phase):
        self.status.update(phase=phase, updated_at=stamp(), downloaded_bytes=self.downloaded)
        atomic_json(PUBLIC / 'status.json', self.status)
        print(stamp(), phase, 'downloaded_bytes=' + str(self.downloaded), flush=True)
        self.last_report = time.monotonic()

    def space(self, size):
        if self.used + size > MAX_DATA:
            raise RuntimeError('Mirror reached its 100 GiB safety budget; existing files preserved')
        if time.monotonic() >= self.next_check:
            guard()
            if shutil.disk_usage(DATA).free < MIN_FREE + size:
                raise RuntimeError('Insufficient free space; existing files preserved')
            self.next_check = time.monotonic() + 30

    def fetch(self, url, expected=None, size=None):
        safe_url(url)
        if expected:
            if not re.fullmatch('[0-9a-f]{64}', expected):
                raise ValueError('Invalid content digest')
            cached = DATA / 'objects' / expected
            if cached.is_file() and (size is None or cached.stat().st_size == size):
                return cached
        request_path = DATA / 'requests' / (hashlib.sha256(url.encode()).hexdigest() + '.json')
        metadata = json.loads(request_path.read_text()) if request_path.exists() else {}
        headers = {'User-Agent': 'Forkop-Own-Mirror/1.0', 'Accept-Encoding': 'identity'}
        if metadata.get('etag'):
            headers['If-None-Match'] = metadata['etag']
        if metadata.get('modified'):
            headers['If-Modified-Since'] = metadata['modified']
        previous = DATA / 'objects' / metadata.get('sha256', 'missing')
        if not previous.is_file():
            headers.pop('If-None-Match', None)
            headers.pop('If-Modified-Since', None)
        temporary = DATA / 'staging' / 'download.part'
        # An orphan from an interrupted process has no trusted validator.
        temporary.unlink(missing_ok=True)
        partial = 0
        full_length = None
        validator = None
        try:
            for attempt in range(6):
                resume = partial > 0 and (expected is not None or validator is not None)
                request_headers = headers.copy()
                if resume:
                    request_headers.pop('If-None-Match', None)
                    request_headers.pop('If-Modified-Since', None)
                    request_headers['Range'] = f'bytes={partial}-'
                    if validator:
                        request_headers['If-Range'] = validator
                try:
                    req = urllib.request.Request(url, headers=request_headers)
                    with self.opener.open(req, timeout=30) as response:
                        status = getattr(response, 'status', 200)
                        content_length = response.headers.get('Content-Length')
                        length = int(content_length) if content_length is not None else None
                        if length is not None and (length < 0 or length > MAX_FILE):
                            raise ValueError('Upstream file exceeds size cap')
                        if status == 206 and resume:
                            value = response.headers.get('Content-Range', '')
                            match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', value.strip())
                            if not match:
                                raise ContentMismatch('Malformed HTTP Content-Range')
                            start, end, total_length = map(int, match.groups())
                            if start != partial or end < start or total_length <= end or \
                                    (length is not None and length != end - start + 1) or \
                                    (full_length is not None and total_length != full_length) or \
                                    (validator and not expected and response.headers.get('ETag') != validator):
                                raise ContentMismatch('HTTP range response does not match the partial file')
                            full_length = total_length
                        elif status == 200:
                            # A server may ignore Range or return a changed resource.
                            partial = 0
                            full_length = length
                            etag = response.headers.get('ETag', '')
                            validator = etag if etag and not etag.startswith('W/') else None
                        else:
                            raise ContentMismatch('Unexpected HTTP response to a download request')
                        if full_length is not None and full_length > MAX_FILE:
                            raise ValueError('Upstream file exceeds size cap')
                        if full_length is not None and size is not None and size != full_length:
                            raise ContentMismatch(f'index size={size}, response size={full_length}')
                        self.space(full_length or size or MAX_FILE)
                        digest = hashlib.sha256()
                        if partial:
                            with temporary.open('rb') as existing:
                                while chunk := existing.read(64 * 1024):
                                    digest.update(chunk)
                        received = 0
                        total = partial
                        started = time.monotonic()
                        with temporary.open('ab' if partial else 'wb') as output:
                            while chunk := response.read(64 * 1024):
                                received += len(chunk)
                                total += len(chunk)
                                if total > MAX_FILE or (full_length is not None and total > full_length):
                                    raise ValueError('Upstream file exceeded size cap')
                                self.space(total)
                                output.write(chunk)
                                digest.update(chunk)
                                self.downloaded += len(chunk)
                                delay = received / RATE - (time.monotonic() - started)
                                if delay > 0:
                                    time.sleep(delay)
                            output.flush()
                            os.fsync(output.fileno())
                        if length is not None and received != length:
                            raise IncompleteDownload(f'received {received} of {length} response bytes')
                        if full_length is not None and total != full_length:
                            raise IncompleteDownload(f'received {total} of {full_length} file bytes')
                        if size is not None and total < size:
                            raise IncompleteDownload(f'received {total} of {size} indexed bytes')
                        checksum = digest.hexdigest()
                        if (expected and checksum != expected) or (size is not None and size != total):
                            raise ContentMismatch(f'index sha256={expected or "unspecified"}, received sha256={checksum}, '
                                                  f'index size={size}, received size={total}')
                        destination = DATA / 'objects' / checksum
                        if destination.exists():
                            temporary.unlink()
                        else:
                            temporary.chmod(0o644)
                            os.replace(temporary, destination)
                            self.used += total
                        atomic_json(request_path, {'sha256': checksum, 'size': total,
                                                   'etag': response.headers.get('ETag') or validator,
                                                   'modified': response.headers.get('Last-Modified')})
                        return destination
                except urllib.error.HTTPError as error:
                    error.close()
                    if error.code == 304 and previous.is_file():
                        if (expected and previous.name != expected) or (size is not None and previous.stat().st_size != size):
                            if attempt == 5:
                                raise ContentMismatch(f'cached sha256={previous.name}, index sha256={expected}, '
                                                      f'cached size={previous.stat().st_size}, index size={size}') from error
                        else:
                            return previous
                    elif error.code == 416 and resume:
                        partial = 0
                        full_length = None
                        validator = None
                        temporary.unlink(missing_ok=True)
                    elif error.code not in RETRY_STATUSES or attempt == 5:
                        raise
                except IncompleteDownload as error:
                    partial = temporary.stat().st_size if temporary.exists() else 0
                    if not expected and not validator:
                        partial = 0
                        temporary.unlink(missing_ok=True)
                    if attempt == 5:
                        raise
                    print(stamp(), 'upstream transfer retry=' + str(attempt + 1), str(error), flush=True)
                except ContentMismatch as error:
                    partial = 0
                    full_length = None
                    validator = None
                    temporary.unlink(missing_ok=True)
                    if attempt == 5:
                        raise
                    print(stamp(), 'upstream verification retry=' + str(attempt + 1), str(error), flush=True)
                except (TimeoutError, OSError, urllib.error.URLError, http.client.IncompleteRead) as error:
                    if isinstance(error, OSError) and error.errno in (errno.ENOSPC, errno.EIO,
                                                                       errno.EACCES, errno.EPERM, errno.EROFS):
                        raise
                    partial = temporary.stat().st_size if temporary.exists() else 0
                    if not expected and not validator:
                        partial = 0
                        temporary.unlink(missing_ok=True)
                    if attempt == 5:
                        raise
                headers.pop('If-None-Match', None)
                headers.pop('If-Modified-Since', None)
                headers['Cache-Control'] = 'no-cache'
                headers['Pragma'] = 'no-cache'
                time.sleep(5 * (attempt + 1))
        finally:
            temporary.unlink(missing_ok=True)
        raise RuntimeError('Download did not complete')

    def links(self, url):
        parser = Links()
        parser.feed(self.fetch(url).read_text())
        return parser

    def link(self, source, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            if os.path.samefile(source, destination):
                return
            raise ValueError('Conflicting file in immutable snapshot')
        os.link(source, destination)

    def feed_file(self, url, index, initial, name, expected=None, size=None):
        try:
            return self.fetch(url + urllib.parse.quote(name), expected, size)
        except IncompleteDownload as error:
            raise IncompleteDownload(f'{name}: {error}') from error
        except ContentMismatch as error:
            if self.fetch(url + index).name != initial.name:
                raise FeedRotated('Package index changed during sync; previous feed remains active') from error
            raise ContentMismatch(f'{name}: {error}') from error
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            # A rolling feed can be rebuilt between listing and download.
            # Confirm that is what happened rather than hiding a real gap:
            # either the index moved, or the file left the directory.
            if self.fetch(url + index).name != initial.name:
                raise FeedRotated('Package index changed during sync; previous feed remains active') from error
            if name not in self.links(url).files:
                raise FeedRotated('Feed contents changed during sync; previous feed remains active') from error
            raise

    def feed(self, relative, index):
        url = 'https://downloads.openwrt.org/releases/' + relative.rstrip('/') + '/'
        self.report('feed: ' + relative)
        initial = self.fetch(url + index)
        key = hashlib.sha256(relative.encode()).hexdigest()[:24]
        snapshot = DATA / 'snapshots' / 'openwrt' / key / initial.name
        destination = PUBLIC / 'openwrt/releases' / relative
        if (snapshot / '.complete').exists():
            publish(snapshot, destination)
            return
        snapshot.mkdir(parents=True, exist_ok=True)
        listing = self.links(url)
        packages = ipk_manifest(gzip.decompress(initial.read_bytes())) if index == 'Packages.gz' else None
        filenames = set(packages) if packages is not None else {n for n in listing.files if n.endswith('.apk')}
        if not filenames:
            raise RuntimeError('No packages found in required feed')
        for number, name in enumerate(sorted(filenames), 1):
            expected, size = packages[name] if packages is not None else (None, None)
            self.link(self.feed_file(url, index, initial, name, expected, size), snapshot / name)
            if number % 100 == 0 or time.monotonic() - self.last_report >= 30:
                self.report('feed: ' + relative + ' ' + str(number) + '/' + str(len(filenames)))
        for name in sorted(listing.files - filenames):
            if name != index and not name.endswith(('.ipk', '.apk')):
                self.link(self.feed_file(url, index, initial, name), snapshot / name)
        if self.fetch(url + index).name != initial.name:
            raise FeedRotated('Package index changed during sync; previous feed remains active')
        self.link(initial, snapshot / index)
        atomic_bytes(snapshot / '.complete', (stamp() + '\n').encode())
        publish(snapshot, destination)

    def openwrt(self):
        complete = set()
        matrix = PUBLIC / 'openwrt/forkop-platforms.tsv'
        if matrix.exists():
            complete = {line for line in matrix.read_text().splitlines() if line and not line.startswith('#')}
        synced = set()
        for release in RELEASES:
            is_ipk = release.startswith('24.')
            index = 'Packages.gz' if is_ipk else 'packages.adb'
            package_root = release + '/packages' if is_ipk else 'packages-' + release.rsplit('.', 1)[0]
            for target, arch in PLATFORMS:
                try:
                    target_root = release + '/targets/' + target
                    self.feed(target_root + '/packages', index)
                    kmods = self.links('https://downloads.openwrt.org/releases/' + target_root + '/kmods/')
                    if not kmods.directories:
                        raise RuntimeError('Required kernel module directories missing')
                    for kernel in sorted(kmods.directories):
                        self.feed(target_root + '/kmods/' + kernel, index)
                    if (package_root, arch) not in synced:
                        for name in ['base', 'luci', 'packages', 'routing', 'telephony', 'video']:
                            try:
                                self.feed(package_root + '/' + arch + '/' + name, index)
                            except urllib.error.HTTPError as error:
                                if error.code != 404 or name not in ['telephony', 'video']:
                                    raise
                        synced.add((package_root, arch))
                    if not is_ipk:
                        alias = PUBLIC / 'openwrt/releases' / release / 'packages'
                        if not alias.is_symlink():
                            alias.parent.mkdir(parents=True, exist_ok=True)
                            alias.symlink_to('../' + package_root, target_is_directory=True)
                except (FeedRotated, ContentMismatch, urllib.error.HTTPError, urllib.error.URLError,
                        TimeoutError, OSError) as error:
                    # One platform must not discard the rest of the run. A row
                    # already in the index keeps its previous, complete files;
                    # a row that never completed simply stays out of it.
                    label = target + ' ' + arch + ' ' + release
                    self.deferred.append(label + ': ' + type(error).__name__)
                    print(stamp(), 'platform failure detail:', label, str(error), flush=True)
                    self.report('platform deferred: ' + label +
                                ' (' + type(error).__name__ + ')')
                    continue
                complete.add('\t'.join([target, arch, release, 'ipk' if is_ipk else 'apk']))
                atomic_bytes(matrix, ('# target\tarchitecture\trelease\tformat\n' + '\n'.join(sorted(complete)) + '\n').encode())

    def lists(self):
        self.report('routing lists')
        snapshot = DATA / 'snapshots' / 'lists' / str(int(time.time()))
        snapshot.mkdir(parents=True)
        for repo, destination in [('itdoginfo/allow-domains', 'allow-domains'), ('Greeg0ry/b4geoip-forkop', 'b4geoip-forkop')]:
            archive = self.fetch('https://codeload.github.com/' + repo + '/tar.gz/refs/heads/main')
            with tarfile.open(archive, 'r:gz') as source:
                for member in source:
                    # Only regular files, never links/devices or executable hooks.
                    if not member.isfile():
                        continue
                    parts = Path(member.name).parts[1:]
                    if not parts or any(part in ('.', '..') or part.startswith('.') for part in parts):
                        continue
                    if member.size > 32 * 1024**2:
                        raise ValueError('List archive member exceeds cap')
                    self.space(member.size)
                    target = snapshot / destination / Path(*parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(member) as input_file, target.open('wb') as output:
                        shutil.copyfileobj(input_file, output)
                    target.chmod(0o644)
                    self.used += member.size
        release = json.loads(self.fetch('https://api.github.com/repos/itdoginfo/allow-domains/releases/latest').read_text())
        sources = [('rulesets/community/' + safe_name(a['name']), a['browser_download_url'], a.get('digest'))
                   for a in release['assets'] if a['name'].endswith('.srs')]
        if not sources:
            raise ValueError('Community rulesets missing')
        sources += [
            ('rulesets/adlist.srs', 'https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs', None),
            ('rulesets/supercell.srs', 'https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs', None),
            ('rulesets/github.srs', 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/github.srs', None)]
        for name, url, digest in sources:
            expected = digest.removeprefix('sha256:') if digest and digest.startswith('sha256:') else None
            source = self.fetch(url, expected)
            with source.open('rb') as stream:
                if stream.read(3) != b'SRS':
                    raise ValueError('Invalid binary ruleset')
            self.link(source, snapshot / name)
        publish(snapshot, PUBLIC / 'forkop/lists')
        lists_pruned = cleanup_lists(DATA, apply=True)
        if lists_pruned:
            print(stamp(), 'pruned unreferenced list snapshots=' + str(lists_pruned), flush=True)

    def singbox(self):
        self.report('sing-box-extended')
        release = json.loads(self.fetch('https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest').read_text())
        tag = safe_name(release['tag_name'])
        if release.get('draft') or release.get('prerelease'):
            raise ValueError('Stable sing-box release required')
        pattern = r'^sing-box-extended_.*_openwrt_(aarch64_cortex-a53|aarch64_generic)\.(apk|ipk)$'
        assets = [a for a in release['assets'] if re.fullmatch(pattern, a['name'])]
        if len(assets) != 4:
            raise ValueError('Expected APK/IPK sing-box assets for both mirrored architectures')
        snapshot = DATA / 'snapshots' / 'sing-box' / tag
        snapshot.mkdir(parents=True, exist_ok=True)
        output_assets = []
        for asset in assets:
            name = safe_name(asset['name'])
            digest = asset.get('digest', '') or ''
            expected = digest.removeprefix('sha256:') if digest.startswith('sha256:') else None
            source = self.fetch(asset['browser_download_url'], expected, asset['size'])
            self.link(source, snapshot / name)
            output_assets.append({**asset, 'sha256': source.name,
                                  'browser_download_url': '/forkop/sing-box-extended/releases/' + tag + '/' + name})
        metadata = {**release, 'assets': output_assets, 'html_url': '/forkop/sing-box-extended/releases/' + tag + '/'}
        atomic_json(snapshot / 'release.json', metadata)
        publish(snapshot, PUBLIC / 'forkop/sing-box-extended/releases' / tag)
        atomic_json(PUBLIC / 'forkop/sing-box-extended/latest.json', metadata)
        atomic_bytes(PUBLIC / 'forkop/sing-box-extended/LATEST', (tag + '\n').encode())

    def run(self, mode):
        try:
            if mode in ['assets', 'all']:
                self.singbox()
                self.lists()
            if mode in ['openwrt', 'all']:
                self.openwrt()
                try:
                    retained = collect_sing_box_archive(
                        PUBLIC, DATA / 'snapshots' / 'openwrt',
                        PUBLIC / 'forkop' / 'sing-box-archive')
                    self.report('sing-box package archive: ' + str(retained) + ' retained')
                except (OSError, ValueError, KeyError, TypeError) as error:
                    # Do not let an optional archive invalidate complete feeds.
                    self.deferred.append('sing-box archive: ' + type(error).__name__)
                    print(stamp(), 'archive failure detail:', str(error), flush=True)
            if self.deferred:
                # Everything published is complete; some platforms simply did
                # not finish this run and stay due for the next one.
                self.status.update(state='incomplete', sync_complete=False,
                                   deferred=self.deferred, completed_at=stamp())
                self.report('finished with deferred platforms: ' + '; '.join(self.deferred))
            else:
                self.status.update(state='complete', sync_complete=(mode == 'all'),
                                   deferred=[], completed_at=stamp())
                self.report('finished: ' + mode)
        except Exception as error:
            self.status.update(state='failed', error=type(error).__name__)
            self.report('sync stopped; existing published files preserved')
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['all', 'assets', 'openwrt'], default='all', nargs='?')
    args = parser.parse_args()
    guard()
    DATA.mkdir(exist_ok=True)
    with (DATA / '.sync.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('A mirror synchronization is already running')
        Mirror().run(args.mode)
