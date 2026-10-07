#!/usr/bin/env python3
"""Mirror the latest verified Timeweb release and publish its signed APK feed."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request

try:
    import fcntl
except ModuleNotFoundError:  # Static validation can run on Windows workstations.
    fcntl = None


RELEASE_BASE_URL = os.environ.get("FORKOP_RELEASE_BASE_URL", "https://fold8.ru/forkop").rstrip("/")
MIRROR_ROOT = Path(os.environ.get("MIRROR_ROOT", "/srv/mirror/public/forkop"))
BUILD_ROOT = Path(os.environ.get("FORKOP_BUILD_ROOT", "/srv/mirror/build/releases"))
LOCK_FILE = Path(os.environ.get("FORKOP_RELEASE_LOCK_FILE", "/run/lock/forkop-release-sync.lock"))
PUBLISH_COMMAND = os.environ.get("FORKOP_PUBLISH_COMMAND", "/usr/local/sbin/publish-forkop-feed")
MAX_ASSET_SIZE = 64 * 1024 * 1024
PACKAGE_SPECS = tuple(
    (package, extension)
    for package in ("forkop", "luci-app-forkop", "luci-i18n-forkop-ru")
    for extension in ("apk", "ipk")
)
def safe_url(url):
    parsed = urllib.parse.urlsplit(url)
    base = urllib.parse.urlsplit(RELEASE_BASE_URL)
    if (
        parsed.scheme != "https"
        or parsed.netloc != base.netloc
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(base.path.rstrip("/") + "/")
    ):
        raise ValueError("Unapproved Timeweb release URL")
    return url


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return super().redirect_request(request, file_pointer, code, message, headers, safe_url(new_url))


def opener():
    return urllib.request.build_opener(Redirects())


def read_json(client, url):
    request = urllib.request.Request(
        safe_url(url),
        headers={
            "Accept": "application/json",
            "User-Agent": "Forkop-Own-Mirror/1.0",
        },
    )
    with client.open(request, timeout=30) as response:
        body = response.read(2 * 1024 * 1024)
    return json.loads(body)


def release_assets(release):
    tag = release.get("tag_name", "")
    version = tag.removeprefix("v")
    if release.get("draft") or release.get("prerelease") or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Latest Timeweb release is not a stable x.y.z version")

    assets = {asset.get("name"): asset for asset in release.get("assets", [])}
    selected = {}
    for package, extension in PACKAGE_SPECS:
        name = f"{package}_{version}.{extension}"
        asset = assets.get(name)
        if not asset:
            raise ValueError(f"Missing release asset: {name}")
        digest = str(asset.get("sha256", ""))
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"Missing SHA-256 release digest: {name}")
        url = safe_url(asset.get("browser_download_url", ""))
        parsed = urllib.parse.urlsplit(url)
        expected_path = urllib.parse.urlsplit(RELEASE_BASE_URL).path.rstrip("/") + f"/releases/{version}/{name}"
        if parsed.path != expected_path:
            raise ValueError(f"Unexpected release asset URL: {name}")
        selected[name] = (url, digest)
    return version, selected


def download(client, url, destination, expected_digest):
    if destination.is_file():
        with destination.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest == expected_digest:
            return

    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.unlink(missing_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "Forkop-Own-Mirror/1.0"})
    digest = hashlib.sha256()
    total = 0
    with client.open(request, timeout=30) as response, temporary.open("wb") as output:
        content_length = response.headers.get("Content-Length")
        if content_length is not None and int(content_length) > MAX_ASSET_SIZE:
            raise ValueError(f"Release asset exceeds size limit: {destination.name}")
        while chunk := response.read(64 * 1024):
            total += len(chunk)
            if total > MAX_ASSET_SIZE:
                raise ValueError(f"Release asset exceeds its declared size: {destination.name}")
            output.write(chunk)
            digest.update(chunk)
        output.flush()
        os.fsync(output.fileno())
    if total == 0 or digest.hexdigest() != expected_digest:
        raise ValueError(f"Release asset verification failed: {destination.name}")
    temporary.chmod(0o644)
    os.replace(temporary, destination)


def published(version):
    root = MIRROR_ROOT / "mirror" / "releases" / version
    updates = MIRROR_ROOT / "updates" / "releases" / version
    latest = MIRROR_ROOT / "MIRROR_LATEST"
    if not latest.is_file():
        return False
    try:
        catalog = json.loads((MIRROR_ROOT / "updates" / "releases.json").read_text())
        catalog_has_version = any(item.get("tag_name") == version for item in catalog["releases"])
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return (
        latest.read_text().strip() == version
        and catalog_has_version
        and (root / "packages.adb").is_file()
        and all((root / f"{package}-{version}.apk").is_file() for package, extension in PACKAGE_SPECS if extension == "apk")
        and all((updates / f"{package}_{version}.{extension}").is_file() for package, extension in PACKAGE_SPECS)
    )


def main():
    if fcntl is None:
        raise RuntimeError("Forkop release sync requires POSIX file locking")
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOCK_FILE.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Forkop release sync is already running", flush=True)
            return
        client = opener()
        release = read_json(client, RELEASE_BASE_URL + "/updates/latest.json")
        version, assets = release_assets(release)
        if published(version):
            print(f"Forkop mirror is already current at {version}", flush=True)
            return

        BUILD_ROOT.mkdir(parents=True, exist_ok=True)
        temporary_root = Path(tempfile.mkdtemp(prefix=f"release-{version}.", dir=BUILD_ROOT))
        try:
            for name, (url, digest) in assets.items():
                destination = temporary_root / name
                print(f"Downloading {name}", flush=True)
                download(client, url, destination, digest)
            environment = os.environ.copy()
            environment["MIRROR_ROOT"] = str(MIRROR_ROOT)
            subprocess.run([PUBLISH_COMMAND, str(temporary_root), version], check=True, env=environment)
        finally:
            shutil.rmtree(temporary_root, ignore_errors=True)


if __name__ == "__main__":
    main()
