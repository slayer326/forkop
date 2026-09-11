"""No-network regression tests for the public download cache."""
import importlib.util
import os
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import MagicMock

path = Path(__file__).resolve().parents[2] / 'ops/mirror/zapret-manager-cache.py'
spec = importlib.util.spec_from_file_location('cache', path)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
MANAGER = 'https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh'


class CacheTests(unittest.TestCase):
    def test_atomic_download_and_size_limit(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(cache, 'CACHE_ROOT', Path(folder)), \
                patch.object(cache, 'PinnedHTTPS') as factory:
            target = Path(folder) / 'cached'
            target.write_bytes(b'old')
            conn = factory.return_value
            response = MagicMock(status=200)
            conn.getresponse.return_value = response
            response.getheader.return_value = '3'
            response.read.side_effect = [b'new', b'']
            cache.download('https://raw.githubusercontent.com/bol-van/zapret/master/file', target)
            self.assertEqual(target.read_bytes(), b'new')
            conn.close.assert_called()
            response.getheader.return_value = str(cache.MAX_FILE + 1)
            with self.assertRaises(ValueError):
                cache.download('https://raw.githubusercontent.com/bol-van/zapret/master/file', target)
            self.assertEqual(target.read_bytes(), b'new')
            self.assertEqual(list(Path(folder).iterdir()), [target])

    def test_redirect_cannot_reach_internal_service(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(cache, 'CACHE_ROOT', Path(folder)), \
                patch.object(cache, 'PinnedHTTPS') as factory:
            response = MagicMock(status=302)
            response.getheader.return_value = 'https://127.0.0.1/private'
            factory.return_value.getresponse.return_value = response
            with self.assertRaises(ValueError):
                cache.download(MANAGER, Path(folder) / 'cached')
            self.assertEqual(factory.call_count, 1)

    def test_allowlist(self):
        for url in [MANAGER, 'https://api.github.com/repos/remittor/zapret-openwrt/releases/latest',
                    'https://github.com/remittor/zapret-openwrt/releases/download/v1/a.zip',
                    'https://packages.routerich.ru/24.10/mediatek/filogic/routerich/']:
            cache.validate_url(url)

    def test_reject_unapproved_resources(self):
        for url in ['http://github.com/remittor/zapret-openwrt/releases/latest',
                    'https://127.0.0.1/', 'https://169.254.169.254/latest/meta-data',
                    'https://raw.githubusercontent.com/other/repo/main/file',
                    MANAGER + '?token=x', MANAGER + '#fragment',
                    MANAGER.replace('/main/', '/%2e%2e/'),
                    MANAGER.replace('/main/', '/../'),
                    MANAGER.replace('https://', 'https://user:pass@'),
                    'https://api.github.com/repos/remittor/zapret-openwrt/issues',
                    'https://github.com/remittor/zapret-openwrt/issues',
                    'https://release-assets.githubusercontent.com/file']:
            with self.subTest(url=url), self.assertRaises(ValueError):
                cache.validate_url(url)

    def test_redirects(self):
        cache.validate_url('https://release-assets.githubusercontent.com/file?sig=x', True)
        for url in ['https://localhost/file', 'http://release-assets.githubusercontent.com/file',
                    'https://github.com.attacker.test/file']:
            with self.assertRaises(ValueError):
                cache.validate_url(url, True)

    def test_dns_rebinding_and_private_ips(self):
        for ip in ['127.0.0.1', '192.168.10.144', '169.254.169.254', '::1', 'fc00::1']:
            with patch.object(socket, 'getaddrinfo', return_value=[(2, 1, 6, '', (ip, 443))]):
                with self.assertRaises(ValueError):
                    cache.public_address('github.com')
        with patch.object(socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('140.82.114.3', 443))]):
            self.assertEqual(cache.public_address('github.com'), '140.82.114.3')

    def test_manager_own_default(self):
        source = b'ZAPRET_MANAGER_VERSION="1"\nMIRROR="${ZAPRET_MANAGER_MIRROR:-https://mirror.51343.ru}"'
        result = cache.manager_content(source)
        self.assertNotIn(b'mirror.51343.ru', result)
        self.assertIn(b'https://mirror.infotechtg.ru', result)
        with self.assertRaises(ValueError):
            cache.manager_content(b'<html>not a script</html>')

    def test_eviction_is_bounded(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(cache, 'CACHE_ROOT', Path(folder)), \
                patch.object(cache, 'MAX_CACHE', 100), patch.object(cache, 'MAX_ENTRIES', 3):
            for i in range(4):
                file = Path(folder) / str(i)
                file.write_bytes(b'x' * 30)
                os.utime(file, (cache.time.time() - 10 + i,) * 2)
            cache.prune(reserve=40)
            self.assertLessEqual(sum(p.stat().st_size for p in Path(folder).iterdir()), 60)
            self.assertLess(len(list(Path(folder).iterdir())), 3)


if __name__ == '__main__':
    unittest.main()
