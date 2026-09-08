#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT_DIR/ops/mirror/sync-openwrt.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK_DIR/bin/date" <<'EOF'
#!/bin/sh
printf '%s\n' '2026-09-08T00:00:00+00:00'
EOF
cat > "$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
method=GET
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -I|-*I*) method=HEAD ;;
    -o) shift; output="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
printf 'CURL %s %s\n' "$method" "$url" >> "${MIRROR_FIXTURE_LOG:?}"

if [ "$method" = HEAD ]; then
  if [ -n "${MIRROR_FAIL_TARGET:-}" ]; then
    case "$url" in
      *"/targets/$MIRROR_FAIL_TARGET/"*) exit 22 ;;
    esac
  fi
  exit 0
fi

if [ -n "$output" ]; then
  mkdir -p "$(dirname "$output")"
  printf 'fixture metadata\n' > "$output"
  exit 0
fi

case "$url" in
  */releases/)
    printf '%s\n' '<a href="24.10.6/">24.10.6/</a>' '<a href="25.12.3/">25.12.3/</a>'
    ;;
  */kmods/)
    printf '%s\n' '<a href="6.6.1-1-fixture/">6.6.1-1-fixture/</a>'
    ;;
  */kmods/6.6.1-1-fixture/)
    printf '%s\n' '<a href="Packages.gz">Packages.gz</a>' '<a href="kmod-tun.ipk">kmod-tun.ipk</a>'
    ;;
  */packages/aarch64_generic/packages/|*/packages/aarch64_cortex-a53/packages/|*/packages-*/aarch64_generic/packages/|*/packages-*/aarch64_cortex-a53/packages/)
    printf '%s\n' '<a href="Packages.gz">Packages.gz</a>' '<a href="packages.adb">packages.adb</a>' '<a href="sing-box_1.13.0_all.ipk">sing-box_1.13.0_all.ipk</a>' '<a href="sing-box-tiny-1.13.0.apk">sing-box-tiny-1.13.0.apk</a>'
    ;;
  *)
    printf '%s\n' '<a href="Packages.gz">Packages.gz</a>' '<a href="packages.adb">packages.adb</a>' '<a href="fixture.pkg">fixture.pkg</a>'
    ;;
esac
EOF
cat > "$WORK_DIR/bin/wget" <<'EOF'
#!/bin/sh
destination=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --directory-prefix=*) destination="${1#*=}" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
[ -n "$destination" ] && [ -n "$url" ] || exit 2
mkdir -p "$destination"
printf 'fixture for %s\n' "$url" > "$destination/${url##*/}"
printf 'WGET %s\n' "$url" >> "${MIRROR_FIXTURE_LOG:?}"
EOF
chmod 0755 "$WORK_DIR/bin/"*

cat > "$WORK_DIR/platforms.conf" <<'EOF'
# Existing production platform
mediatek/filogic aarch64_cortex-a53

# Two targets share a package architecture.
rockchip/armv8 aarch64_generic
qualcommax/ipq807x aarch64_generic # trailing comments are allowed
EOF

PATH="$WORK_DIR/bin:$PATH" \
MIRROR_ROOT="$WORK_DIR/mirror" \
OPENWRT_UPSTREAM="https://upstream.example" \
OPENWRT_PLATFORMS_FILE="$WORK_DIR/platforms.conf" \
OPENWRT_IPK_RELEASES="24.10.6" \
OPENWRT_LOCK_FILE="$WORK_DIR/mirror.lock" \
MIRROR_FIXTURE_LOG="$WORK_DIR/mirror.log" \
  bash "$SYNC" >/dev/null

platform_index="$WORK_DIR/mirror/forkop-platforms.tsv"
[ -s "$platform_index" ] || fail "platform index was not published"
for row in \
  $'mediatek/filogic\taarch64_cortex-a53\t24.10.6\tipk' \
  $'rockchip/armv8\taarch64_generic\t24.10.6\tipk' \
  $'qualcommax/ipq807x\taarch64_generic\t24.10.6\tipk' \
  $'mediatek/filogic\taarch64_cortex-a53\t25.12.3\tapk' \
  $'rockchip/armv8\taarch64_generic\t25.12.3\tapk' \
  $'qualcommax/ipq807x\taarch64_generic\t25.12.3\tapk'; do
  grep -Fxq "$row" "$platform_index" || fail "platform index is missing: $row"
done

for target in mediatek/filogic rockchip/armv8 qualcommax/ipq807x; do
  [ -f "$WORK_DIR/mirror/releases/25.12.3/targets/$target/packages/packages.adb" ] ||
    fail "APK target index is missing for $target"
  [ -f "$WORK_DIR/mirror/releases/25.12.3/targets/$target/kmods/6.6.1-1-fixture/kmod-tun.ipk" ] ||
    fail "kernel ABI tree is missing for $target"
done

generic_apk_base_checks="$(grep -Fc 'CURL HEAD https://upstream.example/releases/packages-25.12/aarch64_generic/base/packages.adb' "$WORK_DIR/mirror.log")"
[ "$generic_apk_base_checks" -eq 1 ] || fail "shared aarch64_generic APK feed was synchronized more than once"
generic_ipk_base_checks="$(grep -Fc 'CURL HEAD https://upstream.example/releases/24.10.6/packages/aarch64_generic/base/Packages.gz' "$WORK_DIR/mirror.log")"
[ "$generic_ipk_base_checks" -eq 1 ] || fail "shared aarch64_generic IPK feed was synchronized more than once"
grep -Fq '/24.10.6/packages/aarch64_cortex-a53/base/Packages.gz' "$WORK_DIR/mirror.log" ||
  fail "separate aarch64_cortex-a53 feed was not synchronized"
grep -Fq '/24.10.6/packages/aarch64_generic/packages/sing-box_1.13.0_all.ipk' "$WORK_DIR/mirror.log" ||
  fail "sing-box was not mirrored for the Rockchip IPK architecture"
grep -Fq '/packages-25.12/aarch64_generic/packages/sing-box-tiny-1.13.0.apk' "$WORK_DIR/mirror.log" ||
  fail "sing-box-tiny was not mirrored for the Rockchip APK architecture"

PATH="$WORK_DIR/bin:$PATH" \
MIRROR_ROOT="$WORK_DIR/mirror" \
OPENWRT_UPSTREAM="https://upstream.example" \
OPENWRT_PLATFORMS_FILE="$WORK_DIR/platforms.conf" \
OPENWRT_IPK_RELEASES="24.10.6" \
OPENWRT_FORMATS="ipk" \
OPENWRT_LOCK_FILE="$WORK_DIR/ipk-only.lock" \
MIRROR_FIXTURE_LOG="$WORK_DIR/ipk-only.log" \
  bash "$SYNC" >/dev/null
grep -Fq $'rockchip/armv8\taarch64_generic\t25.12.3\tapk' "$platform_index" ||
  fail "an IPK-only sync discarded previously verified APK platform rows"

PATH="$WORK_DIR/bin:$PATH" \
MIRROR_ROOT="$WORK_DIR/legacy-mirror" \
OPENWRT_UPSTREAM="https://upstream.example" \
OPENWRT_TARGET="x86/64" \
OPENWRT_ARCH="x86_64" \
OPENWRT_IPK_RELEASES="24.10.6" \
OPENWRT_FORMATS="ipk" \
OPENWRT_LOCK_FILE="$WORK_DIR/legacy.lock" \
MIRROR_FIXTURE_LOG="$WORK_DIR/legacy.log" \
  bash "$SYNC" >/dev/null
grep -Fq $'x86/64\tx86_64\t24.10.6\tipk' "$WORK_DIR/legacy-mirror/forkop-platforms.tsv" ||
  fail "legacy OPENWRT_TARGET/OPENWRT_ARCH mode was not preserved"

mkdir -p "$WORK_DIR/failure-mirror"
printf 'previous matrix\n' > "$WORK_DIR/failure-mirror/forkop-platforms.tsv"
if PATH="$WORK_DIR/bin:$PATH" \
  MIRROR_ROOT="$WORK_DIR/failure-mirror" \
  OPENWRT_UPSTREAM="https://upstream.example" \
  OPENWRT_PLATFORMS_FILE="$WORK_DIR/platforms.conf" \
  OPENWRT_IPK_RELEASES="24.10.6" \
  OPENWRT_FORMATS="ipk" \
  OPENWRT_LOCK_FILE="$WORK_DIR/failure.lock" \
  MIRROR_FIXTURE_LOG="$WORK_DIR/failure.log" \
  MIRROR_FAIL_TARGET="rockchip/armv8" \
    bash "$SYNC" >/dev/null 2>&1; then
  fail "partial mirror synchronization unexpectedly succeeded"
fi
grep -Fxq 'previous matrix' "$WORK_DIR/failure-mirror/forkop-platforms.tsv" ||
  fail "partial synchronization published a new platform matrix"
if find "$WORK_DIR/failure-mirror" -name '.forkop-platforms.tsv.*' -print | grep -q .; then
  fail "partial synchronization left a temporary platform matrix"
fi

printf 'Multi-platform mirror fixture tests passed\n'
