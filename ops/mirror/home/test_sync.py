import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import sync


class MirrorTests(unittest.TestCase):
    def test_safe_paths(self):
        for name in ['../private', '/etc/passwd', '.secret', 'a/b', 'a?b', 'a#b', 'a\\b', '']:
            with self.assertRaises(ValueError):
                sync.safe_name(name)
        self.assertEqual(sync.safe_name('libfoo_1.2+3-r1_aarch64.ipk'), 'libfoo_1.2+3-r1_aarch64.ipk')

    def test_upstream_restrictions(self):
        for url in ['http://github.com/a', 'https://127.0.0.1/a', 'https://github.com:8443/a',
                    'https://github.com.evil.test/a', 'https://user@github.com/a', 'file:///etc/passwd']:
            with self.assertRaises(ValueError):
                sync.safe_url(url)
        self.assertEqual(sync.safe_url('https://github.com/a/b'), 'https://github.com/a/b')

    def test_listing_rejects_traversal(self):
        p = sync.Links()
        p.feed('<a href="../">parent</a><a href="%2e%2e%2fsecret">bad</a><a href="pkg.apk">ok</a><a href="6.6.1-hash/">dir</a>')
        self.assertEqual(p.files, {'pkg.apk'})
        self.assertEqual(p.directories, {'6.6.1-hash'})

    def test_ipk_hash_required(self):
        with self.assertRaises(ValueError):
            sync.ipk_manifest(b'Filename: a.ipk\nSize: 42\n')
        body = ('Filename: ./a.ipk\nSize: 42\nSHA256sum: ' + 'a' * 64 + '\n').encode()
        self.assertEqual(sync.ipk_manifest(body), {'a.ipk': ('a' * 64, 42)})

    def test_atomic_publish_and_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root):
                first = root / 'snapshots/first'
                second = root / 'snapshots/second'
                first.mkdir(parents=True)
                second.mkdir()
                target = root / 'public/feed'
                sync.publish(first, target)
                self.assertEqual(target.resolve(), first)
                sync.publish(second, target)
                self.assertEqual(target.resolve(), second)
                self.assertTrue(first.is_dir())
                with self.assertRaises(ValueError):
                    sync.publish(Path('/etc'), target)
                real = root / 'public/real'
                real.mkdir()
                with self.assertRaises(ValueError):
                    sync.publish(first, real)

    def test_bad_hash_never_published(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '3'}
        class Opener:
            def open(self, *args, **kwargs):
                return Response(b'bad')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    with self.assertRaises(ValueError):
                        m.fetch('https://downloads.openwrt.org/a', 'a' * 64, 3)
                self.assertEqual(list((root / 'objects').iterdir()), [])
                self.assertFalse((root / 'staging/download.part').exists())

    def test_bad_download_retried_and_only_verified_content_saved(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '4'}

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                return Response(b'junk' if len(self.requests) == 1 else b'good')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                expected = hashlib.sha256(b'good').hexdigest()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch('https://downloads.openwrt.org/a', expected, 4)
                self.assertEqual(result.read_bytes(), b'good')
                self.assertEqual(len(m.opener.requests), 2)
                self.assertEqual(m.opener.requests[1].get_header('Cache-control'), 'no-cache')
                self.assertFalse((root / 'staging/download.part').exists())

    def test_stale_304_retried_without_conditionals(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '4'}

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                if len(self.requests) == 1:
                    raise urllib.error.HTTPError(request.full_url, 304, 'Not Modified', {}, None)
                return Response(b'good')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                url = 'https://downloads.openwrt.org/a'
                old = hashlib.sha256(b'old!').hexdigest()
                expected = hashlib.sha256(b'good').hexdigest()
                (root / 'objects' / old).write_bytes(b'old!')
                request_path = root / 'requests' / (hashlib.sha256(url.encode()).hexdigest() + '.json')
                request_path.write_text(json.dumps({'sha256': old, 'etag': 'old-tag'}))
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch(url, expected, 4)
                self.assertEqual(result.read_bytes(), b'good')
                self.assertEqual(len(m.opener.requests), 2)
                self.assertIsNone(m.opener.requests[1].get_header('If-none-match'))
                self.assertEqual(m.opener.requests[1].get_header('Cache-control'), 'no-cache')

    def test_short_response_resumes_only_verified_remaining_bytes(self):
        class Response(io.BytesIO):
            def __init__(self, body, status, headers):
                super().__init__(body)
                self.status = status
                self.headers = headers

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                if len(self.requests) == 1:
                    return Response(b'ab', 200, {'Content-Length': '6', 'ETag': '"version-a"'})
                return Response(b'cdef', 206, {'Content-Length': '4',
                                               'Content-Range': 'bytes 2-5/6', 'ETag': '"version-a"'})

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                expected = hashlib.sha256(b'abcdef').hexdigest()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch('https://downloads.openwrt.org/a', expected, 6)
                self.assertEqual(result.read_bytes(), b'abcdef')
                self.assertEqual(m.opener.requests[1].get_header('Range'), 'bytes=2-')
                self.assertEqual(m.opener.requests[1].get_header('If-range'), '"version-a"')
                self.assertEqual(m.downloaded, 6)
                self.assertFalse((root / 'staging/download.part').exists())

    def test_ignored_range_starts_fresh_instead_of_appending(self):
        class Response(io.BytesIO):
            def __init__(self, body):
                super().__init__(body)
                self.headers = {'Content-Length': '4'}

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                return Response(b'ab' if len(self.requests) == 1 else b'good')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                expected = hashlib.sha256(b'good').hexdigest()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch('https://downloads.openwrt.org/a', expected, 4)
                self.assertEqual(result.read_bytes(), b'good')
                self.assertEqual(m.opener.requests[1].get_header('Range'), 'bytes=2-')

    def test_wrong_range_is_discarded_before_retry(self):
        class Response(io.BytesIO):
            def __init__(self, body, status, headers):
                super().__init__(body)
                self.status = status
                self.headers = headers

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                if len(self.requests) == 1:
                    return Response(b'ab', 200, {'Content-Length': '6', 'ETag': '"v1"'})
                if len(self.requests) == 2:
                    return Response(b'bcdef', 206, {'Content-Length': '5',
                                                    'Content-Range': 'bytes 1-5/6', 'ETag': '"v1"'})
                return Response(b'abcdef', 200, {'Content-Length': '6', 'ETag': '"v2"'})

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                expected = hashlib.sha256(b'abcdef').hexdigest()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch('https://downloads.openwrt.org/a', expected, 6)
                self.assertEqual(result.read_bytes(), b'abcdef')
                self.assertEqual(m.opener.requests[1].get_header('Range'), 'bytes=2-')
                self.assertIsNone(m.opener.requests[2].get_header('Range'))

    def test_unverified_index_starts_over_without_an_etag(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '4'}

        class Opener:
            def __init__(self):
                self.requests = []

            def open(self, request, **kwargs):
                self.requests.append(request)
                return Response(b'ab' if len(self.requests) == 1 else b'good')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    result = m.fetch('https://downloads.openwrt.org/a')
                self.assertEqual(result.read_bytes(), b'good')
                self.assertIsNone(m.opener.requests[1].get_header('Range'))

    def test_incomplete_transfer_never_replaces_published_object(self):
        class Response(io.BytesIO):
            headers = {'Content-Length': '4'}

        class Opener:
            def open(self, request, **kwargs):
                return Response(b'a')

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                m = sync.Mirror()
                m.opener = Opener()
                existing = root / 'objects' / hashlib.sha256(b'old').hexdigest()
                existing.write_bytes(b'old')
                with patch.object(m, 'space'), patch.object(sync.time, 'sleep'):
                    with self.assertRaises(sync.IncompleteDownload):
                        m.fetch('https://downloads.openwrt.org/a', hashlib.sha256(b'good').hexdigest(), 4)
                self.assertEqual(existing.read_bytes(), b'old')
                self.assertFalse((root / 'staging/download.part').exists())

    def test_persistent_mismatch_defers_platform(self):
        m = sync.Mirror.__new__(sync.Mirror)
        m.deferred = []
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sync, 'PUBLIC', Path(directory)), \
                    patch.object(sync, 'RELEASES', ['24.10.5']), \
                    patch.object(sync, 'PLATFORMS', [('mediatek/filogic', 'aarch64_cortex-a53')]), \
                    patch.object(m, 'feed', side_effect=sync.ContentMismatch('bad package')), \
                    patch.object(m, 'report'):
                m.openwrt()
        self.assertEqual(len(m.deferred), 1)
        self.assertIn('ContentMismatch', m.deferred[0])

    def test_space_budget(self):
        m = sync.Mirror.__new__(sync.Mirror)
        m.used = sync.MAX_DATA
        with self.assertRaises(RuntimeError):
            m.space(1)

    def test_prunes_only_unpublished_complete_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                objects = root / 'objects'
                objects.mkdir(parents=True)
                current = root / 'snapshots/openwrt/feed/current'
                stale = root / 'snapshots/openwrt/feed/stale'
                incomplete = root / 'snapshots/openwrt/feed/incomplete'
                for snapshot in [current, stale, incomplete]:
                    snapshot.mkdir(parents=True)
                (current / '.complete').write_text('ok')
                (stale / '.complete').write_text('old')

                current_object = objects / ('a' * 64)
                stale_object = objects / ('b' * 64)
                incomplete_object = objects / ('c' * 64)
                current_object.write_bytes(b'current')
                stale_object.write_bytes(b'stale')
                incomplete_object.write_bytes(b'incomplete')
                os.link(current_object, current / 'current.apk')
                os.link(stale_object, stale / 'stale.apk')
                os.link(incomplete_object, incomplete / 'partial.apk')

                public = root / 'public/openwrt/releases/1/packages'
                public.parent.mkdir(parents=True)
                public.symlink_to(os.path.relpath(current, public.parent), target_is_directory=True)

                result = sync.prune_openwrt_snapshots()
                self.assertEqual(result['snapshots'], 1)
                self.assertEqual(result['objects'], 1)
                self.assertTrue(current.is_dir())
                self.assertTrue(incomplete.is_dir())
                self.assertFalse(stale.exists())
                self.assertTrue(current_object.is_file())
                self.assertTrue(incomplete_object.is_file())
                self.assertFalse(stale_object.exists())

    def test_prune_fails_closed_without_published_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sync, 'DATA', root), patch.object(sync, 'PUBLIC', root / 'public'):
                stale = root / 'snapshots/openwrt/feed/stale'
                stale.mkdir(parents=True)
                (stale / '.complete').write_text('old')
                with self.assertRaises(RuntimeError):
                    sync.prune_openwrt_snapshots()
                self.assertTrue(stale.is_dir())


if __name__ == '__main__':
    unittest.main()
