#!/usr/bin/env python3
import hashlib
import os
import pathlib
import tempfile
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("ZAPRET_CACHE_LISTEN", "127.0.0.1")
PORT = int(os.environ.get("ZAPRET_CACHE_PORT", "9081"))
CACHE_ROOT = pathlib.Path(os.environ.get("ZAPRET_CACHE_ROOT", "/srv/mirror/cache/zapret-manager"))
TTL = int(os.environ.get("ZAPRET_CACHE_TTL", "3600"))
ALLOWED_HOSTS = {
    "github.com", "api.github.com", "raw.githubusercontent.com",
    "release-assets.githubusercontent.com", "objects.githubusercontent.com",
    "github-releases.githubusercontent.com", "packages.routerich.ru",
    "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "api.cdnjs.com",
}


class CacheHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, send_body):
        prefix = "/zapret-manager/proxy/"
        if not self.path.startswith(prefix):
            self.send_error(404)
            return
        host, separator, path = self.path[len(prefix):].partition("/")
        if not separator or host not in ALLOWED_HOSTS:
            self.send_error(403, "upstream host is not allowed")
            return

        url = f"https://{host}/{path}"
        digest = hashlib.sha256(url.encode()).hexdigest()
        body_path = CACHE_ROOT / digest[:2] / digest
        meta_path = body_path.with_suffix(".meta")
        body_path.parent.mkdir(parents=True, exist_ok=True)
        fresh = body_path.is_file() and time.time() - body_path.stat().st_mtime < TTL

        if not fresh:
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "Forkop-Zapret-Mirror/1.0"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    content_type = response.headers.get("Content-Type", "application/octet-stream")
                    with tempfile.NamedTemporaryFile(dir=body_path.parent, delete=False) as output:
                        while True:
                            chunk = response.read(1024 * 1024)
                            if not chunk:
                                break
                            output.write(chunk)
                        temporary = pathlib.Path(output.name)
                    temporary.replace(body_path)
                    meta_path.write_text(content_type, encoding="utf-8")
            except (OSError, urllib.error.URLError) as error:
                if not body_path.is_file():
                    self.send_error(502, str(error))
                    return

        content_type = "application/octet-stream"
        if meta_path.is_file():
            content_type = meta_path.read_text(encoding="utf-8").strip() or content_type
        size = body_path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", f"public, max-age={TTL}")
        self.end_headers()
        if send_body:
            with body_path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    self.wfile.write(chunk)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    ThreadingHTTPServer((LISTEN, PORT), CacheHandler).serve_forever()
