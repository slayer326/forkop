#!/bin/sh
# The extended sing-box release resolution lives in updater.uc helper modes.
# Commit 03e333a35 once dropped str_endswith from that script while four call
# sites still used it, which made every extended install fail with
# "Failed to resolve sing-box-extended package release". These checks feed a
# mirror-shaped latest.json through the helpers so the regression cannot
# return unnoticed.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPDATER="$ROOT/forkop/files/usr/lib/components/updater.uc"

FIXTURE="$(mktemp)"
trap 'rm -f "$FIXTURE"' EXIT
cat > "$FIXTURE" <<'JSON'
{
  "tag_name": "v1.14.3-extended-2.7.3",
  "html_url": "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/",
  "assets": [
    { "name": "sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.apk",
      "browser_download_url": "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.apk" },
    { "name": "sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.ipk",
      "browser_download_url": "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.ipk" },
    { "name": "sing-box-extended_1.14.3-extended-2.7.3_openwrt_mipsel_24kc.ipk",
      "browser_download_url": "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended_1.14.3-extended-2.7.3_openwrt_mipsel_24kc.ipk" },
    { "name": "sing-box-extended-linux-arm64-compressed.tar.gz",
      "browser_download_url": "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended-linux-arm64-compressed.tar.gz" }
  ]
}
JSON

url="$(ucode "$UPDATER" sing-box-extended-package-asset-url aarch64_cortex-a53 ipk < "$FIXTURE")"
[ "$url" = "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.ipk" ] ||
  { echo "unexpected ipk asset url: $url" >&2; exit 1; }

url="$(ucode "$UPDATER" sing-box-extended-package-asset-url aarch64_cortex-a53 apk < "$FIXTURE")"
case "$url" in
  *_openwrt_aarch64_cortex-a53.apk) ;;
  *) echo "unexpected apk asset url: $url" >&2; exit 1 ;;
esac

url="$(ucode "$UPDATER" sing-box-extended-package-asset-url mipsel_24kc ipk < "$FIXTURE")"
case "$url" in
  *_openwrt_mipsel_24kc.ipk) ;;
  *) echo "unexpected mipsel asset url: $url" >&2; exit 1 ;;
esac

# An arch the release does not serve must fail loudly instead of resolving.
if ucode "$UPDATER" sing-box-extended-package-asset-url arm_cortex-a7 ipk < "$FIXTURE" >/dev/null 2>&1; then
  echo "package asset url must fail for an unserved arch" >&2
  exit 1
fi

# The compressed binary path matches linux-<suffix>-compressed.tar.gz assets.
url="$(ucode "$UPDATER" sing-box-extended-asset-url arm64 0 1 < "$FIXTURE")"
[ "$url" = "/forkop/sing-box-extended/releases/v1.14.3-extended-2.7.3/sing-box-extended-linux-arm64-compressed.tar.gz" ] ||
  { echo "unexpected compressed asset url: $url" >&2; exit 1; }

if ucode "$UPDATER" sing-box-extended-asset-url mipsle-softfloat 0 1 < "$FIXTURE" >/dev/null 2>&1; then
  echo "compressed asset url must fail for an unserved arch" >&2
  exit 1
fi

# release-asset-url-by-suffix shares the same str_endswith helper.
name="$(ucode "$UPDATER" release-asset-name-by-suffix _openwrt_mipsel_24kc.ipk < "$FIXTURE")"
[ "$name" = "sing-box-extended_1.14.3-extended-2.7.3_openwrt_mipsel_24kc.ipk" ] ||
  { echo "unexpected asset name by suffix: $name" >&2; exit 1; }

printf 'sing_box_extended_release: PASS\n'
