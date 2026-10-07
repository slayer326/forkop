#!/usr/bin/env python3
"""Build the release catalog the LuCI version picker reads.

The Timeweb document root is updated by extracting one bundle per release, so
earlier versions stay on the host and can be reinstalled. Nothing on that host
can generate an index, and its directory listing is closed, so the catalog is
written here, at build time, and shipped inside the bundle.

The release being built is always listed: its packages travel in the same
bundle. Earlier releases are discovered from the existing Timeweb catalog and
nearby version directories. Their SHA256SUMS and all six packages must be
present; GitHub metadata is not involved in what routers can install.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

VERSION = re.compile(r"^\d+\.\d+\.\d+$")
PACKAGES = ("forkop", "luci-app-forkop", "luci-i18n-forkop-ru")
EXTENSIONS = ("ipk", "apk")
TIMEOUT = 20


def package_names(version):
    return [f"{package}_{version}.{extension}"
            for extension in EXTENSIONS for package in PACKAGES]


def release_entry(version, base_url, digests):
    assets = []
    for name in package_names(version):
        digest = digests.get(name, "")
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError(f"missing or malformed sha256 for {name}")
        assets.append({
            "name": name,
            "sha256": digest,
            "browser_download_url": f"{base_url}/releases/{version}/{name}",
        })
    return {
        "tag_name": version,
        "channel": "stable",
        "html_url": f"{base_url}/releases/{version}/",
        "assets": assets,
    }


def current_digests(release_dir, version):
    return {name: hashlib.sha256((release_dir / name).read_bytes()).hexdigest()
            for name in package_names(version)}


def published_digests(base_url, version):
    """Read package digests from the previously uploaded Timeweb bundle."""
    request = urllib.request.Request(
        f"{base_url}/releases/{version}/SHA256SUMS",
        headers={"User-Agent": "forkop-release-catalog"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        lines = response.read(8192).decode("ascii").splitlines()
    digests = {}
    for line in lines:
        match = re.fullmatch(r"([a-f0-9]{64})\s+\*?([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in digests:
            raise ValueError("invalid or duplicate checksum entry")
        digests[match[2]] = match[1]
    return digests


def mirror_has_every_package(base_url, version):
    for name in package_names(version):
        request = urllib.request.Request(
            f"{base_url}/releases/{version}/{name}", method="HEAD",
            headers={"User-Agent": "forkop-release-catalog"})
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                if response.status != 200:
                    return False
        except (urllib.error.URLError, OSError):
            return False
    return True


def previous_releases(base_url, current, limit):
    candidates = set()
    try:
        request = urllib.request.Request(
            f"{base_url}/updates/releases.json",
            headers={"User-Agent": "forkop-release-catalog"})
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            catalog = json.load(response)
        if catalog.get("format") == 1:
            candidates.update(str(item.get("tag_name", ""))
                              for item in catalog.get("releases", []))
    except (urllib.error.URLError, OSError, ValueError, TypeError) as error:
        print(f"Existing release catalog unavailable: {error}", file=sys.stderr)

    major, minor, patch = map(int, current.split("."))
    candidates.update(f"{major}.{minor}.{number}"
                      for number in range(max(0, patch - limit), patch))

    entries = []
    for version in sorted(candidates, key=lambda value: tuple(map(int, value.split(".")))
                          if VERSION.fullmatch(value) else (-1,), reverse=True):
        if version == current or not VERSION.fullmatch(version):
            continue
        try:
            entry = release_entry(version, base_url, published_digests(base_url, version))
        except (ValueError, urllib.error.URLError, OSError, UnicodeError) as error:
            print(f"Skipping {version}: {error}", file=sys.stderr)
            continue
        if not mirror_has_every_package(base_url, version):
            print(f"Skipping {version}: not published on the mirror yet", file=sys.stderr)
            continue
        entries.append(entry)
        if len(entries) >= limit:
            break
    return entries


def version_key(entry):
    return tuple(int(part) for part in entry["tag_name"].split("."))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("release_dir", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--limit", type=int, default=10)
    arguments = parser.parse_args()

    if not VERSION.fullmatch(arguments.version):
        parser.error("release version must use x.y.z format")
    base_url = arguments.base_url.rstrip("/")

    releases = [release_entry(arguments.version, base_url,
                              current_digests(arguments.release_dir, arguments.version))]
    releases.extend(previous_releases(base_url,
                                      arguments.version, arguments.limit))
    releases.sort(key=version_key, reverse=True)

    catalog = {"format": 1, "releases": releases}
    handle, temporary = tempfile.mkstemp(prefix=".releases-", suffix=".json",
                                         dir=arguments.output.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            json.dump(catalog, output, ensure_ascii=False, indent=2)
            output.write("\n")
        os.chmod(temporary, 0o644)
        os.replace(temporary, arguments.output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Release catalog: {len(releases)} version(s)")


if __name__ == "__main__":
    main()
