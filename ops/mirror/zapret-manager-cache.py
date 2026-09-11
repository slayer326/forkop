#!/usr/bin/env python3
"""Repository-allowlisted cache with pinned public-IP connections and hard limits."""
import concurrent.futures
from contextlib import closing
import hashlib
import http.client
import ipaddress
import os
from pathlib import Path
import re
import socket
import ssl
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urljoin, urlsplit

PREFIX = '/zapret-manager/proxy/'
CACHE_ROOT = Path(os.environ.get('ZAPRET_CACHE_ROOT', '/srv/mirror/cache/zapret-manager'))
MIRROR = os.environ.get('ZAPRET_MANAGER_MIRROR', 'https://mirror.infotechtg.ru').rstrip('/')
TTL, MAX_AGE = 3600, 7 * 86400
MAX_FILE, MAX_CACHE, MAX_ENTRIES = 128 * 1024 * 1024, 2 * 1024 * 1024 * 1024, 512
REPOS = {
    'screamshow/zapret-manager', 'stressozz/zapret-manager', 'stressozz/test',
    '2grey/awg-openwrt', 'flowseal/zapret-discord-youtube', 'internet-helper/geohidedns',
    'hyperion-cs/dpi-checkers', 'indeecfox/zapret4rocket', 'bol-van/zapret',
    'remittor/zapret-openwrt', 'xyzmean/splify', 'dpitrickster/byedpi-openwrt',
    'yandexru45/netshift', 'd0mhate/-tg-ws-proxy-manager-go',
    'valnesfjord/tg-ws-proxy-rs', 'spatiumstas/tg-ws-proxy-go',
    'magitrickle/magitrickle', 'zephyruso/zashboard', 'metacubex/metacubexd',
    'blackmatrix7/ios_rule_script',
}
REDIRECT_HOSTS = {'release-assets.githubusercontent.com', 'objects.githubusercontent.com',
                  'github-releases.githubusercontent.com', 'codeload.github.com'}
LOCK = threading.Lock()
TLS = ssl.create_default_context()


def validate_url(url, redirected=False):
    if len(url) > 8192 or any(ord(c) < 32 or ord(c) == 127 for c in url):
        raise ValueError('invalid URL')
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.fragment):
        raise ValueError('HTTPS only')
    host, path = parsed.hostname, parsed.path
    if '%' in path or chr(92) in path or any(p in ('.', '..') for p in path.split('/')):
        raise ValueError('invalid path')
    if redirected and host in REDIRECT_HOSTS:
        return parsed
    if parsed.query:
        raise ValueError('query not allowed')
    parts = path.strip('/').split('/')
    if host in ('raw.githubusercontent.com', 'github.com'):
        if '/'.join(parts[:2]).lower() not in REPOS or len(parts) < 3:
            raise ValueError('repository not allowed')
        if host == 'github.com' and parts[2] not in ('releases', 'archive', 'raw'):
            raise ValueError('resource not allowed')
    elif host == 'api.github.com':
        if path in ('/', '/rate_limit'):
            return parsed
        if (len(parts) != 5 or parts[0] != 'repos' or parts[3:] != ['releases', 'latest']
                or '/'.join(parts[1:3]).lower() not in REPOS):
            raise ValueError('API resource not allowed')
    elif host == 'packages.routerich.ru':
        if not re.fullmatch(r'/(24\.10|25\.12)/mediatek/filogic/routerich/[^/]*', path):
            raise ValueError('feed not allowed')
    else:
        raise ValueError('host not allowed')
    return parsed


def public_address(host):
    addresses = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
    if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global for a in addresses):
        raise ValueError('non-public destination')
    return addresses[0][4][0]


class PinnedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        # No second DNS lookup: connect to validated IP, retain hostname for TLS/SNI.
        raw = socket.create_connection((public_address(self.host), 443), self.timeout)
        try:
            self.sock = TLS.wrap_socket(raw, server_hostname=self.host)
        except Exception:
            raw.close()
            raise


def manager_content(data):
    text = data.decode('utf-8')
    old = '${ZAPRET_MANAGER_MIRROR:-https://mirror.51343.ru}'
    if old not in text or 'ZAPRET_MANAGER_VERSION=' not in text:
        raise ValueError('unrecognized manager format')
    # Persists even when the manager rewrites its own launchers.
    return text.replace(old, '${ZAPRET_MANAGER_MIRROR:-' + MIRROR + '}').encode('utf-8')


def download(url, target):
    original = urlsplit(url)
    deadline = time.monotonic() + 120
    temporary = None
    try:
        for hop in range(6):
            parsed = validate_url(url, redirected=hop > 0)
            with closing(PinnedHTTPS(parsed.hostname, timeout=15)) as conn:
                conn.request('GET', parsed.path + ('?' + parsed.query if parsed.query else ''),
                             headers={'User-Agent': 'Forkop-Mirror/1.0', 'Accept-Encoding': 'identity'})
                response = conn.getresponse()
                if response.status in (301, 302, 303, 307, 308):
                    url = urljoin(url, response.getheader('Location', ''))
                    continue
                if response.status != 200:
                    raise OSError('upstream status ' + str(response.status))
                if int(response.getheader('Content-Length', '0')) > MAX_FILE:
                    raise ValueError('file too large')
                size = 0
                with tempfile.NamedTemporaryFile(dir=CACHE_ROOT, prefix='.part-', delete=False) as output:
                    temporary = Path(output.name)
                    while chunk := response.read(65536):
                        size += len(chunk)
                        if size > MAX_FILE or time.monotonic() > deadline:
                            raise ValueError('download limit exceeded')
                        output.write(chunk)
                if (original.hostname == 'raw.githubusercontent.com'
                        and original.path.lower().startswith('/screamshow/zapret-manager/')
                        and original.path.endswith('/Zapret-Manager.sh')):
                    if size > 2 * 1024 * 1024:
                        raise ValueError('manager too large')
                    temporary.write_bytes(manager_content(temporary.read_bytes()))
                temporary.replace(target)
                return
        raise ValueError('too many redirects')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def prune(reserve=MAX_FILE):
    files = sorted((p for p in CACHE_ROOT.iterdir() if p.is_file()), key=lambda p: p.stat().st_mtime)
    size, remaining = sum(p.stat().st_size for p in files), len(files)
    for path in files:
        if (size + reserve <= MAX_CACHE and remaining < MAX_ENTRIES
                and time.time() - path.stat().st_mtime < MAX_AGE):
            continue
        size -= path.stat().st_size
        remaining -= 1
        path.unlink()


class CacheHandler(BaseHTTPRequestHandler):
    timeout = 15

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        if self.path == '/healthz':
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        try:
            if not self.path.startswith(PREFIX):
                self.send_error(404)
                return
            url = 'https://' + self.path[len(PREFIX):]
            validate_url(url)
        except ValueError:
            self.send_error(403, 'Resource is not allowed')
            return
        digest = hashlib.sha256(url.encode()).hexdigest()
        target = CACHE_ROOT / digest
        with LOCK:
            stale = False
            if not target.is_file() or time.time() - target.stat().st_mtime >= TTL:
                try:
                    prune()
                    download(url, target)
                except (OSError, ValueError, http.client.HTTPException):
                    if not target.is_file() or time.time() - target.stat().st_mtime > MAX_AGE:
                        self.send_error(502, 'Upstream download unavailable')
                        return
                    stale = True
            source = target.open('rb')
            size = os.fstat(source.fileno()).st_size
        with source:
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(size))
            self.send_header('Cache-Control', 'public, max-age=' + ('60' if stale else str(TTL)))
            self.send_header('X-Forkop-Cache', 'stale' if stale else 'fresh')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            if body:
                while chunk := source.read(65536):
                    self.wfile.write(chunk)

    def log_message(self, fmt, *args):
        # Never log tokens, paths or redirect signatures.
        pass


class BoundedServer(HTTPServer):
    request_queue_size = 16

    def __init__(self, *args):
        super().__init__(*args)
        self.slots = threading.BoundedSemaphore(8)
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=8)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        self.pool.submit(self.worker, request, address)

    def worker(self, request, address):
        try:
            self.finish_request(request, address)
        except (OSError, ValueError):
            pass
        finally:
            self.shutdown_request(request)
            self.slots.release()


if __name__ == '__main__':
    parsed = urlsplit(MIRROR)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.query or parsed.fragment or re.search(r'[^a-zA-Z0-9:/._-]', MIRROR)):
        raise SystemExit('Invalid mirror base URL')
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    BoundedServer((os.environ.get('ZAPRET_CACHE_LISTEN', '127.0.0.1'),
                   int(os.environ.get('ZAPRET_CACHE_PORT', '9081'))), CacheHandler).serve_forever()
