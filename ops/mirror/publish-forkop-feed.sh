#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "Usage: $0 BUILD_DIRECTORY VERSION" >&2
    exit 2
fi

BUILD_DIRECTORY="$1"
VERSION="$2"
MIRROR_ROOT="${MIRROR_ROOT:-/srv/mirror/public/forkop}"
PUBLIC_BASE_URL="${FORKOP_PUBLIC_BASE_URL:-https://mirror.infotechtg.ru/forkop}"
PRIVATE_KEY="${FORKOP_APK_PRIVATE_KEY:-/srv/mirror/keys/forkop-apk.pem}"
APK_BIN="${APK_BIN:-/root/.cache/forkop/openwrt-sdk/extracted/apk/staging_dir/host/bin/apk}"
STAGING="$MIRROR_ROOT/mirror/.${VERSION}.staging"
DESTINATION="$MIRROR_ROOT/mirror/releases/$VERSION"
UPDATES_STAGING="$MIRROR_ROOT/updates/.${VERSION}.staging"
UPDATES_DESTINATION="$MIRROR_ROOT/updates/releases/$VERSION"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid APK feed version: $VERSION" >&2
    exit 1
}
[[ "$PUBLIC_BASE_URL" == https://* ]] || {
    echo "FORKOP_PUBLIC_BASE_URL must use HTTPS" >&2
    exit 1
}
PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
[[ -x "$APK_BIN" ]] || {
    echo "OpenWrt apk host tool is unavailable: $APK_BIN" >&2
    exit 1
}

install -d -m 0700 "$(dirname "$PRIVATE_KEY")"
if [[ ! -s "$PRIVATE_KEY" ]]; then
    openssl ecparam -name prime256v1 -genkey -noout -out "$PRIVATE_KEY"
    chmod 0600 "$PRIVATE_KEY"
fi

mkdir -p "$MIRROR_ROOT/mirror/releases"
mkdir -p "$MIRROR_ROOT/updates/releases"
rm -rf "$STAGING" "$UPDATES_STAGING"
mkdir -p "$STAGING" "$UPDATES_STAGING"

openssl ec -in "$PRIVATE_KEY" -pubout \
    -out "$MIRROR_ROOT/forkop-apk.pem" 2>/dev/null
# apk resolves a relative --keys-dir against its root, so pass it absolute.
KEYS_DIR="$(cd "$MIRROR_ROOT" && pwd)"
UNSIGNED_DIGESTS="$STAGING/.unsigned-sha256"
: > "$UNSIGNED_DIGESTS"

# Re-signing produces new bytes even for an unchanged package. Reuse the
# signed APK already published for the same input, so republishing a
# version never changes the hashes routers have cached for it.
previous_signed_apk() {
    python3 - "$UPDATES_DESTINATION/forkop-manifest.json" "$DESTINATION" "$1" "$VERSION" "$2" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

manifest, destination, package, version, unsigned = sys.argv[1:]
try:
    assets = json.loads(Path(manifest).read_text())["assets"]
    asset = next(a for a in assets if a["file"] == f"{package}_{version}.apk")
    signed = Path(destination) / f"{package}-{version}.apk"
    with signed.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
except (OSError, ValueError, KeyError, TypeError, StopIteration):
    sys.exit(1)
if asset.get("signed") is not True or asset.get("unsigned_sha256") != unsigned or asset.get("sha256") != digest:
    sys.exit(1)
print(signed)
PY
}

for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
    for extension in apk ipk; do
        source_file="$BUILD_DIRECTORY/${package}_${VERSION}.${extension}"
        [[ -s "$source_file" ]] || {
            echo "Missing package artifact: $source_file" >&2
            exit 1
        }
        if [[ "$extension" != "apk" ]]; then
            cp "$source_file" "$STAGING/"
            cp "$source_file" "$UPDATES_STAGING/${package}_${VERSION}.ipk"
            continue
        fi
        staged="$STAGING/${package}-${VERSION}.apk"
        unsigned_sha256="$(sha256sum "$source_file" | awk '{print $1}')"
        printf '%s %s\n' "${package}_${VERSION}.apk" "$unsigned_sha256" >> "$UNSIGNED_DIGESTS"
        if previous="$(previous_signed_apk "$package" "$unsigned_sha256")"; then
            cp "$previous" "$staged"
        else
            cp "$source_file" "$staged"
        fi
        # A second signature is never added to an already trusted package.
        if ! "$APK_BIN" --keys-dir "$KEYS_DIR" verify "$staged" >/dev/null 2>&1; then
            "$APK_BIN" adbsign --allow-untrusted --sign-key "$PRIVATE_KEY" "$staged"
        fi
        "$APK_BIN" --keys-dir "$KEYS_DIR" verify "$staged"
        cp "$staged" "$UPDATES_STAGING/${package}_${VERSION}.apk"
    done
done

(
    cd "$STAGING"
    "$APK_BIN" mkndx \
        --allow-untrusted \
        --sign-key "$PRIVATE_KEY" \
        --description "Forkop mirror packages" \
        --output packages.adb \
        ./*.apk
    "$APK_BIN" verify --keys-dir "$KEYS_DIR" packages.adb
    sha256sum ./*.apk ./*.ipk packages.adb > SHA256SUMS
)

# The update directory describes itself: every package with its hash and,
# for APK, the hash it had before signing, plus the signer's public key.
cp "$MIRROR_ROOT/forkop-apk.pem" "$UPDATES_STAGING/forkop-apk.pem"
python3 - "$UPDATES_STAGING" "$VERSION" "$UNSIGNED_DIGESTS" "${FORKOP_SOURCE_COMMIT:-}" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

directory, version, unsigned_file, source_commit = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3]), sys.argv[4]
unsigned = dict(line.split() for line in unsigned_file.read_text().splitlines())


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


assets = []
for extension in ("apk", "ipk"):
    for package in ("forkop", "luci-app-forkop", "luci-i18n-forkop-ru"):
        name = f"{package}_{version}.{extension}"
        path = directory / name
        asset = {
            "file": name,
            "package": package,
            "format": extension,
            "version": version,
            "architecture": "noarch" if extension == "apk" else "all",
            "size": path.stat().st_size,
            "sha256": digest(path),
        }
        if extension == "apk":
            asset["signed"] = True
            asset["unsigned_sha256"] = unsigned[name]
        assets.append(asset)
manifest = {
    "format": 1,
    "version": version,
    "apk_signed": True,
    "signing_public_key_sha256": digest(directory / "forkop-apk.pem"),
    "assets": assets,
}
if re.fullmatch(r"[0-9a-f]{40}", source_commit):
    manifest["source_commit"] = source_commit
(directory / "forkop-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(directory / "SHA256SUMS").write_text("".join(f"{a['sha256']}  {a['file']}\n" for a in assets))
PY
rm -f "$UNSIGNED_DIGESTS"

rm -rf "$DESTINATION"
mv "$STAGING" "$DESTINATION"
ln -sfn "releases/$VERSION" "$MIRROR_ROOT/mirror/current"
printf '%s\n' "$VERSION" > "$MIRROR_ROOT/MIRROR_LATEST"

cat > "$UPDATES_STAGING/release.json" <<EOF
{
  "tag_name": "$VERSION",
  "html_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/",
  "assets": [
    {"name": "forkop_$VERSION.apk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/forkop_$VERSION.apk", "sha256": "$(sha256sum "$UPDATES_STAGING/forkop_$VERSION.apk" | awk '{print $1}')"},
    {"name": "luci-app-forkop_$VERSION.apk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/luci-app-forkop_$VERSION.apk", "sha256": "$(sha256sum "$UPDATES_STAGING/luci-app-forkop_$VERSION.apk" | awk '{print $1}')"},
    {"name": "luci-i18n-forkop-ru_$VERSION.apk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/luci-i18n-forkop-ru_$VERSION.apk", "sha256": "$(sha256sum "$UPDATES_STAGING/luci-i18n-forkop-ru_$VERSION.apk" | awk '{print $1}')"},
    {"name": "forkop_$VERSION.ipk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/forkop_$VERSION.ipk", "sha256": "$(sha256sum "$UPDATES_STAGING/forkop_$VERSION.ipk" | awk '{print $1}')"},
    {"name": "luci-app-forkop_$VERSION.ipk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/luci-app-forkop_$VERSION.ipk", "sha256": "$(sha256sum "$UPDATES_STAGING/luci-app-forkop_$VERSION.ipk" | awk '{print $1}')"},
    {"name": "luci-i18n-forkop-ru_$VERSION.ipk", "browser_download_url": "$PUBLIC_BASE_URL/updates/releases/$VERSION/luci-i18n-forkop-ru_$VERSION.ipk", "sha256": "$(sha256sum "$UPDATES_STAGING/luci-i18n-forkop-ru_$VERSION.ipk" | awk '{print $1}')"}
  ]
}
EOF
rm -rf "$UPDATES_DESTINATION"
mv "$UPDATES_STAGING" "$UPDATES_DESTINATION"
# Only advertise versions whose complete package sets are still present and
# match their published checksums. The index is replaced atomically so LuCI
# never sees a half-written version list while the mirror is refreshing.
python3 - "$MIRROR_ROOT" "$PUBLIC_BASE_URL" "$VERSION" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

root = Path(sys.argv[1]) / "updates"
base = sys.argv[2].rstrip("/")
releases = []
for directory in (root / "releases").iterdir():
    version = directory.name
    if directory.is_symlink() or not directory.is_dir() or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        continue
    try:
        release = json.loads((directory / "release.json").read_text())
        if release.get("tag_name") != version:
            continue
        assets = {asset["name"]: asset for asset in release["assets"]}
        for extension in ("apk", "ipk"):
            for package in ("forkop", "luci-app-forkop", "luci-i18n-forkop-ru"):
                name = f"{package}_{version}.{extension}"
                asset = assets[name]
                if asset["browser_download_url"] != f"{base}/updates/releases/{version}/{name}":
                    raise ValueError(name)
                with (directory / name).open("rb") as package_file:
                    digest = hashlib.file_digest(package_file, "sha256").hexdigest()
                if digest != asset["sha256"]:
                    raise ValueError(name)
    except (KeyError, OSError, ValueError, TypeError, json.JSONDecodeError):
        continue
    releases.append(release)

releases.sort(key=lambda release: tuple(map(int, release["tag_name"].split("."))), reverse=True)
if not releases or releases[0]["tag_name"] != sys.argv[3]:
    raise RuntimeError("New Forkop release is incomplete; catalog not updated")
catalog = {"format": 1, "releases": releases}
with tempfile.NamedTemporaryFile("w", dir=root, prefix=".releases-", suffix=".json",
                                 encoding="utf-8", delete=False) as output:
    temporary = Path(output.name)
    json.dump(catalog, output, ensure_ascii=False, indent=2)
    output.write("\n")
    output.flush()
    os.fsync(output.fileno())
os.chmod(temporary, 0o644)
os.replace(temporary, root / "releases.json")
PY
cp "$UPDATES_DESTINATION/release.json" "$MIRROR_ROOT/updates/latest.json"

echo "Published signed Forkop APK feed $VERSION"
