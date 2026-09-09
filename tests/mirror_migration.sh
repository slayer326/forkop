#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/forkop/files/usr/share/forkop/mirror-migration.sh"
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
cat > "$WORK_DIR/platforms.tsv" <<'EOF'
# target architecture release format
rockchip/armv8 aarch64_generic 25.12.4 apk
mediatek/filogic aarch64_cortex-a53 24.10.5 ipk
EOF

cat > "$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; output="$1" ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */openwrt/forkop-platforms.tsv)
    [ "${MIGRATION_PLATFORM_UNAVAILABLE:-0}" -eq 0 ] || exit 22
    cp "${MIGRATION_PLATFORM_INDEX:?}" "$output"
    ;;
  */forkop/forkop-apk.pem)
    cat > "$output" <<'KEY'
-----BEGIN PUBLIC KEY-----
test-key
-----END PUBLIC KEY-----
KEY
    ;;
  *) exit 22 ;;
esac
EOF
cat > "$WORK_DIR/bin/apk" <<'EOF'
#!/bin/sh
printf 'apk %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
if [ "${MIGRATION_PACKAGE_UPDATE_FAIL:-0}" -eq 1 ] && [ "${1:-}" = "update" ]; then
  exit 1
fi
EOF
cat > "$WORK_DIR/bin/opkg" <<'EOF'
#!/bin/sh
printf 'opkg %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
if [ "${MIGRATION_PACKAGE_UPDATE_FAIL:-0}" -eq 1 ] && [ "${1:-}" = "update" ]; then
  exit 1
fi
EOF
cat > "$WORK_DIR/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
  *' get '*'mirror_base_url') printf '%s' "${MIGRATION_CONFIGURED_MIRROR:-}"; exit 0 ;;
esac
printf 'uci %s\n' "$*" >> "${MIGRATION_EVENT_LOG:?}"
case "$*" in
  *' get '*'applied_migrations') printf '%s\n' 'interface_sections enable_component_checks' ;;
esac
EOF
chmod 0755 "$WORK_DIR/bin/"*

mkdir -p "$WORK_DIR/apk-root/etc/apk/repositories.d"
cat > "$WORK_DIR/apk-root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='25.12.4'
DISTRIB_TARGET='rockchip/armv8'
DISTRIB_ARCH='aarch64_generic'
EOF
cat > "$WORK_DIR/apk-root/etc/apk/repositories" <<'EOF'
https://archive.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
EOF
cat > "$WORK_DIR/apk-root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://ftp.snt.utwente.nl/pub/software/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/luci/packages.adb
https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb
EOF

PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/apk-root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
MIGRATION_EVENT_LOG="$WORK_DIR/apk-events.log" \
  sh "$MIGRATION"

if grep -Eq 'archive\.openwrt\.org|ftp\.snt\.utwente\.nl|downloads\.openwrt\.org' \
  "$WORK_DIR/apk-root/etc/apk/repositories" \
  "$WORK_DIR/apk-root/etc/apk/repositories.d/distfeeds.list"; then
  fail "official OpenWrt feeds were not fully redirected"
fi
grep -Fxq 'https://mirror.infotechtg.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$WORK_DIR/apk-root/etc/apk/repositories" ||
  fail "Rockchip APK target feed was not preserved"
grep -Fxq 'https://mirror.infotechtg.ru/openwrt/releases/25.12.4/packages/aarch64_generic/base/packages.adb' \
  "$WORK_DIR/apk-root/etc/apk/repositories.d/distfeeds.list" ||
  fail "aarch64_generic APK package feed was not preserved"
grep -Fxq 'https://vendor.example/openwrt/releases/25.12.4/packages/aarch64_generic/vendor/packages.adb' \
  "$WORK_DIR/apk-root/etc/apk/repositories.d/distfeeds.list" ||
  fail "vendor APK feed was changed"
grep -Fxq 'https://mirror.infotechtg.ru/forkop/mirror/current/packages.adb' \
  "$WORK_DIR/apk-root/etc/apk/repositories.d/forkop.list" ||
  fail "Forkop current feed is missing"
grep -Fq 'BEGIN PUBLIC KEY' "$WORK_DIR/apk-root/etc/apk/keys/forkop-mirror.pem" ||
  fail "Forkop mirror key is missing"
grep -Fxq 'apk update' "$WORK_DIR/apk-events.log" ||
  fail "APK index was not checked before committing the migration"
grep -Fq 'uci -q add_list forkop.settings.applied_migrations=mirror_infotechtg_ru_v1' "$WORK_DIR/apk-events.log" ||
  fail "migration marker was not recorded"
apk_update_line="$(grep -nFx 'apk update' "$WORK_DIR/apk-events.log" | cut -d: -f1)"
apk_marker_line="$(grep -nF 'applied_migrations=mirror_infotechtg_ru_v1' "$WORK_DIR/apk-events.log" | cut -d: -f1)"
[ "$apk_update_line" -lt "$apk_marker_line" ] ||
  fail "migration marker was recorded before APK index validation"

printf 'PASS: transactional APK mirror migration\n'

# A second migration with already-correct APK repositories must not force an
# unnecessary package-index refresh.
: > "$WORK_DIR/apk-idempotent-events.log"
PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/apk-root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
MIGRATION_EVENT_LOG="$WORK_DIR/apk-idempotent-events.log" \
  sh "$MIGRATION"
if grep -Fxq 'apk update' "$WORK_DIR/apk-idempotent-events.log"; then
  fail "idempotent APK mirror migration performed an unnecessary package index update"
fi
printf 'PASS: idempotent APK mirror migration\n'

# Package post-install/upgrade runs while apk owns its database lock. The
# mirror migration may still rewrite feeds, rotate the key and commit UCI, but
# it must never invoke apk recursively in that context.
mkdir -p "$WORK_DIR/apk-postinst-root/etc/apk/repositories.d"
cat > "$WORK_DIR/apk-postinst-root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='25.12.4'
DISTRIB_TARGET='rockchip/armv8'
DISTRIB_ARCH='aarch64_generic'
EOF
cat > "$WORK_DIR/apk-postinst-root/etc/apk/repositories" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
EOF
cat > "$WORK_DIR/apk-postinst-root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/base/packages.adb
EOF
: > "$WORK_DIR/apk-postinst-events.log"
PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/apk-postinst-root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
FORKOP_PACKAGE_POSTINST=1 \
MIGRATION_PACKAGE_UPDATE_FAIL=1 \
MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
MIGRATION_EVENT_LOG="$WORK_DIR/apk-postinst-events.log" \
  sh "$MIGRATION"
if grep -Fxq 'apk update' "$WORK_DIR/apk-postinst-events.log"; then
  fail "package postinst recursively invoked apk update while apk owns the database lock"
fi
grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  "$WORK_DIR/apk-postinst-root/etc/apk/repositories" ||
  fail "package postinst did not migrate the APK target feed"
grep -Fxq 'https://mirror.infotechtg.ru/forkop/mirror/current/packages.adb' \
  "$WORK_DIR/apk-postinst-root/etc/apk/repositories.d/forkop.list" ||
  fail "package postinst did not configure the Forkop APK feed"
grep -Fq 'BEGIN PUBLIC KEY' "$WORK_DIR/apk-postinst-root/etc/apk/keys/forkop-mirror.pem" ||
  fail "package postinst did not install the Forkop mirror key"
grep -Fq 'uci -q commit forkop' "$WORK_DIR/apk-postinst-events.log" ||
  fail "package postinst did not commit Forkop mirror settings"
printf 'PASS: APK package postinst avoids nested package-manager lock\n'

mkdir -p "$WORK_DIR/opkg-root/etc/opkg"
cat > "$WORK_DIR/opkg-root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='24.10.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
cat > "$WORK_DIR/opkg-root/etc/opkg/distfeeds.conf" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base
src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base
EOF

PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/opkg-root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/missing-apk" \
FORKOP_MIGRATION_OPKG_BIN="$WORK_DIR/bin/opkg" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
MIGRATION_EVENT_LOG="$WORK_DIR/opkg-events.log" \
  sh "$MIGRATION"

grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/24.10.5/targets/mediatek/filogic/packages' \
  "$WORK_DIR/opkg-root/etc/opkg/distfeeds.conf" ||
  fail "mirrored OpenWrt 24 target feed is missing"
grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/24.10.5/packages/aarch64_cortex-a53/base' \
  "$WORK_DIR/opkg-root/etc/opkg/distfeeds.conf" ||
  fail "mirrored OpenWrt 24 architecture feed is missing"
grep -Fxq 'src/gz vendor_custom https://packages.vendor.example/24.10/mediatek/filogic/base' \
  "$WORK_DIR/opkg-root/etc/opkg/distfeeds.conf" ||
  fail "vendor OPKG feed was changed"
grep -Fxq 'opkg update' "$WORK_DIR/opkg-events.log" ||
  fail "OPKG index was not checked before committing the migration"
opkg_update_line="$(grep -nFx 'opkg update' "$WORK_DIR/opkg-events.log" | cut -d: -f1)"
opkg_marker_line="$(grep -nF 'applied_migrations=mirror_infotechtg_ru_v1' "$WORK_DIR/opkg-events.log" | cut -d: -f1)"
[ "$opkg_update_line" -lt "$opkg_marker_line" ] ||
  fail "migration marker was recorded before OPKG index validation"

printf 'PASS: transactional OPKG mirror migration\n'

# The same package-lifecycle rule applies to OpenWrt 24.x: opkg must not be
# invoked recursively from the installed package's postinst script.
mkdir -p "$WORK_DIR/opkg-postinst-root/etc/opkg"
cat > "$WORK_DIR/opkg-postinst-root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='24.10.5'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
cat > "$WORK_DIR/opkg-postinst-root/etc/opkg/distfeeds.conf" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.5/targets/mediatek/filogic/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/24.10.5/packages/aarch64_cortex-a53/base
EOF
: > "$WORK_DIR/opkg-postinst-events.log"
PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/opkg-postinst-root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/missing-apk" \
FORKOP_MIGRATION_OPKG_BIN="$WORK_DIR/bin/opkg" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
FORKOP_PACKAGE_POSTINST=1 \
MIGRATION_PACKAGE_UPDATE_FAIL=1 \
MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
MIGRATION_EVENT_LOG="$WORK_DIR/opkg-postinst-events.log" \
  sh "$MIGRATION"
if grep -Fxq 'opkg update' "$WORK_DIR/opkg-postinst-events.log"; then
  fail "package postinst recursively invoked opkg update while opkg owns the database lock"
fi
grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/24.10.5/targets/mediatek/filogic/packages' \
  "$WORK_DIR/opkg-postinst-root/etc/opkg/distfeeds.conf" ||
  fail "package postinst did not migrate the OPKG target feed"
grep -Fq 'uci -q commit forkop' "$WORK_DIR/opkg-postinst-events.log" ||
  fail "OPKG package postinst did not commit Forkop mirror settings"
printf 'PASS: OPKG package postinst avoids nested package-manager lock\n'

mkdir -p "$WORK_DIR/failure-root/etc/apk/repositories.d"
cat > "$WORK_DIR/failure-root/etc/openwrt_release" <<'EOF'
DISTRIB_RELEASE='25.12.4'
DISTRIB_TARGET='rockchip/armv8'
DISTRIB_ARCH='aarch64_generic'
EOF
cat > "$WORK_DIR/failure-root/etc/apk/repositories" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb
EOF
cat > "$WORK_DIR/failure-root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_generic/base/packages.adb
EOF
cp "$WORK_DIR/failure-root/etc/apk/repositories" "$WORK_DIR/failure-repositories.original"
cp "$WORK_DIR/failure-root/etc/apk/repositories.d/distfeeds.list" "$WORK_DIR/failure-distfeeds.original"

if PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_MIGRATION_ROOT="$WORK_DIR/failure-root" \
  FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
  FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
  FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
  MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
  MIGRATION_EVENT_LOG="$WORK_DIR/failure-events.log" \
  MIGRATION_PACKAGE_UPDATE_FAIL=1 \
    sh "$MIGRATION" >/dev/null 2>&1; then
  fail "migration unexpectedly succeeded after an APK index failure"
fi

cmp -s "$WORK_DIR/failure-repositories.original" "$WORK_DIR/failure-root/etc/apk/repositories" ||
  fail "APK repository file was not rolled back"
cmp -s "$WORK_DIR/failure-distfeeds.original" "$WORK_DIR/failure-root/etc/apk/repositories.d/distfeeds.list" ||
  fail "APK distfeeds were not rolled back"
[ ! -e "$WORK_DIR/failure-root/etc/apk/keys/forkop-mirror.pem" ] ||
  fail "new APK key was not removed during rollback"
[ ! -e "$WORK_DIR/failure-root/etc/apk/repositories.d/forkop.list" ] ||
  fail "new Forkop APK feed was not removed during rollback"
if grep -Fq 'applied_migrations' "$WORK_DIR/failure-events.log"; then
  fail "migration marker was written before APK index validation"
fi

printf 'PASS: mirror migration rollback\n'

mkdir -p "$WORK_DIR/unsupported-root/etc/apk/repositories.d"
cp "$WORK_DIR/failure-root/etc/openwrt_release" "$WORK_DIR/unsupported-root/etc/openwrt_release"
cp "$WORK_DIR/failure-repositories.original" "$WORK_DIR/unsupported-root/etc/apk/repositories"
cp "$WORK_DIR/failure-distfeeds.original" "$WORK_DIR/unsupported-root/etc/apk/repositories.d/distfeeds.list"
cat > "$WORK_DIR/unsupported-platforms.tsv" <<'EOF'
# target architecture release format
mediatek/filogic aarch64_cortex-a53 25.12.4 apk
EOF

if PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_MIGRATION_ROOT="$WORK_DIR/unsupported-root" \
  FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
  FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
  FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
  MIGRATION_PLATFORM_INDEX="$WORK_DIR/unsupported-platforms.tsv" \
  MIGRATION_EVENT_LOG="$WORK_DIR/unsupported-events.log" \
    sh "$MIGRATION" >/dev/null 2>&1; then
  fail "migration accepted a platform absent from the mirror index"
fi
cmp -s "$WORK_DIR/failure-repositories.original" "$WORK_DIR/unsupported-root/etc/apk/repositories" ||
  fail "unsupported platform check changed APK repositories"
cmp -s "$WORK_DIR/failure-distfeeds.original" "$WORK_DIR/unsupported-root/etc/apk/repositories.d/distfeeds.list" ||
  fail "unsupported platform check changed APK distfeeds"
[ ! -e "$WORK_DIR/unsupported-root/etc/apk/keys/forkop-mirror.pem" ] ||
  fail "unsupported platform check installed an APK key"
[ ! -e "$WORK_DIR/unsupported-events.log" ] ||
  fail "unsupported platform check invoked the package manager or UCI"

printf 'PASS: unsupported mirror platform rejection\n'

# Existing keys must rotate when switching away from the legacy mirror.
mkdir -p "$WORK_DIR/apk-root/etc/apk/keys"
printf '%s\n' '-----BEGIN PUBLIC KEY-----' 'old-key' '-----END PUBLIC KEY-----' \
  > "$WORK_DIR/apk-root/etc/apk/keys/forkop-mirror.pem"
printf '%s\n' 'https://mirror.51343.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/packages/packages.adb' \
  > "$WORK_DIR/apk-root/etc/apk/repositories"
cp "$WORK_DIR/apk-root/etc/apk/keys/forkop-mirror.pem" "$WORK_DIR/old-key"
cp "$WORK_DIR/apk-root/etc/apk/repositories" "$WORK_DIR/old-mirror-feed"
for should_fail in 1 0; do
  status=0
  PATH="$WORK_DIR/bin:$PATH" \
    FORKOP_MIGRATION_ROOT="$WORK_DIR/apk-root" \
    FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
    FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
    FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
    MIGRATION_CONFIGURED_MIRROR=https://mirror.51343.ru \
    MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
    MIGRATION_EVENT_LOG="$WORK_DIR/rotation-events.log" \
    MIGRATION_PACKAGE_UPDATE_FAIL="$should_fail" \
      sh "$MIGRATION" >/dev/null 2>&1 || status=$?
  if [ "$should_fail" -eq 1 ]; then
    [ "$status" -ne 0 ] || fail "failed key rotation unexpectedly succeeded"
    cmp -s "$WORK_DIR/old-key" "$WORK_DIR/apk-root/etc/apk/keys/forkop-mirror.pem" ||
      fail "old APK key was not restored"
    cmp -s "$WORK_DIR/old-mirror-feed" "$WORK_DIR/apk-root/etc/apk/repositories" ||
      fail "old mirror feed was not restored"
  else
    [ "$status" -eq 0 ] || fail "key rotation failed"
    grep -Fxq test-key "$WORK_DIR/apk-root/etc/apk/keys/forkop-mirror.pem" ||
      fail "legacy APK key was not replaced"
    grep -Fq 'https://mirror.infotechtg.ru/openwrt/releases/25.12.4/targets/rockchip/armv8/' \
      "$WORK_DIR/apk-root/etc/apk/repositories" || fail "legacy mirror was not replaced"
  fi
done

# A missing readiness index on the new mirror must not trigger the old fallback.
if PATH="$WORK_DIR/bin:$PATH" \
  FORKOP_MIGRATION_ROOT="$WORK_DIR/unsupported-root" \
  FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
  FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
  FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
  MIGRATION_PLATFORM_UNAVAILABLE=1 \
  MIGRATION_PLATFORM_INDEX="$WORK_DIR/platforms.tsv" \
  MIGRATION_EVENT_LOG="$WORK_DIR/unavailable-events.log" \
    sh "$MIGRATION" >/dev/null 2>&1; then
  fail "new mirror migration accepted an unavailable readiness index"
fi
[ ! -e "$WORK_DIR/unavailable-events.log" ] || fail "unready mirror changed package state"

printf 'PASS: legacy mirror key rotation and readiness gate\n'
