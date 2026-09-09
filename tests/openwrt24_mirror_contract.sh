#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT_DIR/ops/mirror/sync-openwrt.sh"
PUBLISH="$ROOT_DIR/ops/mirror/publish-forkop-feed.sh"
PLATFORMS="$ROOT_DIR/ops/mirror/openwrt-platforms.conf.example"
SERVICE="$ROOT_DIR/ops/mirror/openwrt-mirror.service"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

bash -n "$SYNC"
bash -n "$PUBLISH"

grep -Fq 'discover_ipk_releases' "$SYNC" ||
  fail "mirror does not discover all OpenWrt 24.10 patch releases"
grep -Fq '24\.10\.[0-9][0-9]*' "$SYNC" ||
  fail "OpenWrt 24 discovery is not constrained to the 24.10 series"
grep -Fq 'OPENWRT_FORMATS:-ipk apk' "$SYNC" ||
  fail "mirror cannot run an isolated initial IPK synchronization"
grep -Fq 'package_index="Packages.gz"' "$SYNC" ||
  fail "mirror does not recognize IPK target indexes"
grep -Fq 'sync_package_root "$release/packages" "Packages.gz"' "$SYNC" ||
  fail "mirror does not synchronize exact-release OpenWrt 24 package feeds"
grep -Fq 'OPENWRT_DOWNLOAD_JOBS:-8' "$SYNC" ||
  fail "OpenWrt package downloads are not parallelized"
grep -Fq 'xargs -r -P "$DOWNLOAD_JOBS"' "$SYNC" ||
  fail "OpenWrt package download workers are not used"
grep -Fq 'sync_package_root "packages-$series" "packages.adb"' "$SYNC" ||
  fail "OpenWrt 25 APK synchronization was not preserved"
grep -Fq 'forkop-platforms.tsv' "$SYNC" ||
  fail "mirror does not publish its platform matrix"
grep -Fq 'rockchip/armv8 aarch64_generic' "$PLATFORMS" ||
  fail "tracked platform example is missing rockchip/armv8"
grep -Fq 'EnvironmentFile=-/etc/default/forkop-openwrt-mirror' "$SERVICE" ||
  fail "OpenWrt mirror service does not load its optional environment file"

for package in forkop luci-app-forkop luci-i18n-forkop-ru; do
  grep -Fq "${package}_\$VERSION.ipk" "$PUBLISH" ||
    fail "release metadata does not publish $package IPK"
done

printf 'OpenWrt 24 mirror contract tests passed\n'
