#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
VERSION="1.0.2"
BASE_URL="https://downloads.example/forkop"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

packages=(
  "forkop_${VERSION}.ipk"
  "luci-app-forkop_${VERSION}.ipk"
  "luci-i18n-forkop-ru_${VERSION}.ipk"
  "forkop_${VERSION}.apk"
  "luci-app-forkop_${VERSION}.apk"
  "luci-i18n-forkop-ru_${VERSION}.apk"
)

mkdir -p "$WORK_DIR/artifacts"
for package in "${packages[@]}"; do
  printf 'test package: %s\n' "$package" >"$WORK_DIR/artifacts/$package"
done

FORKOP_RELEASE_BASE_URL="$BASE_URL" \
  "$ROOT_DIR/ops/hosting/prepare-release.sh" \
  "$VERSION" "$WORK_DIR/artifacts" "$WORK_DIR/output"

[[ "$(cat "$WORK_DIR/output/forkop/LATEST")" == "$VERSION" ]] ||
  fail "LATEST does not contain the release version"
[[ -s "$WORK_DIR/output/forkop/install.sh" ]] || fail "install.sh was not included"
[[ -s "$WORK_DIR/output/forkop/releases/$VERSION/SHA256SUMS" ]] ||
  fail "SHA256SUMS was not generated"
[[ -s "$WORK_DIR/output/forkop-timeweb-$VERSION.tar.gz" ]] ||
  fail "Timeweb archive was not generated"

for package in "${packages[@]}"; do
  [[ -s "$WORK_DIR/output/forkop/releases/$VERSION/$package" ]] ||
    fail "$package was not copied"
done

"$PYTHON_BIN" - "$WORK_DIR/output/forkop/updates/latest.json" "$VERSION" "$BASE_URL" <<'PY'
import json
import hashlib
import sys
from pathlib import Path

path, version, base_url = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    document = json.load(source)
assert document["tag_name"] == version
assert document["draft"] is False
assert document["prerelease"] is False
assert len(document["assets"]) == 6
for asset in document["assets"]:
    package_path = Path(path).parent.parent / "releases" / version / asset["name"]
    digest = hashlib.sha256(package_path.read_bytes()).hexdigest()
    assert asset["browser_download_url"] == (
        f"{base_url}/releases/{version}/{asset['name']}"
    )
    assert asset["sha256"] == digest
    assert asset["digest"] == f"sha256:{digest}"
PY

tar -tzf "$WORK_DIR/output/forkop-timeweb-$VERSION.tar.gz" |
  grep -Fxq 'forkop/updates/latest.json' || fail "archive does not contain latest.json"

printf 'hosting release bundle checks passed\n'
