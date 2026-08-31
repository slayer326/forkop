#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${1:-}"
ARTIFACT_DIR="${2:-$ROOT_DIR/filtered-bin/release}"
OUTPUT_DIR="${3:-$ROOT_DIR/filtered-bin/hosting}"
RELEASE_BASE_URL="${FORKOP_RELEASE_BASE_URL:-https://fold8.ru/forkop}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "release version must use x.y.z format"
[[ "$RELEASE_BASE_URL" == http://* || "$RELEASE_BASE_URL" == https://* ]] ||
  fail "FORKOP_RELEASE_BASE_URL must use http:// or https://"

RELEASE_BASE_URL="${RELEASE_BASE_URL%/}"
PUBLISH_ROOT="$OUTPUT_DIR/forkop"
RELEASE_DIR="$PUBLISH_ROOT/releases/$VERSION"
METADATA_DIR="$PUBLISH_ROOT/updates"
ARCHIVE_PATH="$OUTPUT_DIR/forkop-timeweb-$VERSION.tar.gz"

packages=(
  "forkop_${VERSION}.ipk"
  "luci-app-forkop_${VERSION}.ipk"
  "luci-i18n-forkop-ru_${VERSION}.ipk"
  "forkop_${VERSION}.apk"
  "luci-app-forkop_${VERSION}.apk"
  "luci-i18n-forkop-ru_${VERSION}.apk"
)

for package in "${packages[@]}"; do
  [[ -s "$ARTIFACT_DIR/$package" ]] || fail "missing build artifact: $package"
done
[[ -s "$ROOT_DIR/install.sh" ]] || fail "install.sh is missing"

mkdir -p "$RELEASE_DIR" "$METADATA_DIR"
cp "$ROOT_DIR/install.sh" "$PUBLISH_ROOT/install.sh"
printf '%s\n' "$VERSION" >"$PUBLISH_ROOT/LATEST"

for package in "${packages[@]}"; do
  cp "$ARTIFACT_DIR/$package" "$RELEASE_DIR/$package"
done

(
  cd "$RELEASE_DIR"
  sha256sum "${packages[@]}" >SHA256SUMS
)

FORKOP_RELEASE_VERSION="$VERSION" \
FORKOP_RELEASE_PUBLIC_URL="$RELEASE_BASE_URL" \
FORKOP_RELEASE_PACKAGES="$(printf '%s\n' "${packages[@]}")" \
"$PYTHON_BIN" - "$METADATA_DIR/latest.json" <<'PY'
import json
import os
import sys

version = os.environ["FORKOP_RELEASE_VERSION"]
base_url = os.environ["FORKOP_RELEASE_PUBLIC_URL"].rstrip("/")
packages = os.environ["FORKOP_RELEASE_PACKAGES"].splitlines()
document = {
    "tag_name": version,
    "name": version,
    "html_url": f"{base_url}/releases/{version}/",
    "draft": False,
    "prerelease": False,
    "assets": [
        {
            "name": name,
            "browser_download_url": f"{base_url}/releases/{version}/{name}",
        }
        for name in packages
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(document, output, ensure_ascii=False, indent=2)
    output.write("\n")
PY

tar -C "$OUTPUT_DIR" -czf "$ARCHIVE_PATH" forkop

printf 'Timeweb bundle: %s\n' "$ARCHIVE_PATH"
printf 'Upload and extract it in the document root for: %s\n' "$RELEASE_BASE_URL"
