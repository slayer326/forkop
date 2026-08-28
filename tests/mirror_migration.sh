#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="$ROOT_DIR/forkop/files/usr/lib/service/mirror-migration.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/root/etc/apk/repositories.d" "$WORK_DIR/bin"
cat >"$WORK_DIR/root/etc/apk/repositories" <<'EOF'
https://archive.openwrt.org/releases/25.12.4/targets/mediatek/filogic/packages/packages.adb
EOF
cat >"$WORK_DIR/root/etc/apk/repositories.d/distfeeds.list" <<'EOF'
https://ftp.snt.utwente.nl/pub/software/openwrt/releases/25.12.4/packages/aarch64_cortex-a53/base/packages.adb
https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_cortex-a53/luci/packages.adb
EOF

cat >"$WORK_DIR/bin/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$WORK_DIR/bin/curl" <<'EOF'
#!/bin/sh
eval "output=\${$#}"
cat >"$output" <<'KEY'
-----BEGIN PUBLIC KEY-----
test-key
-----END PUBLIC KEY-----
KEY
EOF
cat >"$WORK_DIR/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MIGRATION_UCI_LOG:?}"
case "$*" in
  *' get '*'applied_migrations') printf '%s\n' 'interface_sections enable_component_checks' ;;
esac
EOF
chmod 0755 "$WORK_DIR/bin/"*

PATH="$WORK_DIR/bin:$PATH" \
FORKOP_MIGRATION_ROOT="$WORK_DIR/root" \
FORKOP_MIGRATION_APK_BIN="$WORK_DIR/bin/apk" \
FORKOP_MIGRATION_CURL_BIN="$WORK_DIR/bin/curl" \
FORKOP_MIGRATION_UCI_BIN="$WORK_DIR/bin/uci" \
MIGRATION_UCI_LOG="$WORK_DIR/uci.log" \
  "$MIGRATION"

if grep -Eq 'archive\.openwrt\.org|ftp\.snt\.utwente\.nl|downloads\.openwrt\.org' \
  "$WORK_DIR/root/etc/apk/repositories" \
  "$WORK_DIR/root/etc/apk/repositories.d/distfeeds.list"; then
  fail "official OpenWrt feeds were not fully redirected"
fi
grep -Fq 'https://mirror.51343.ru/openwrt/releases/25.12.4/' \
  "$WORK_DIR/root/etc/apk/repositories.d/distfeeds.list" ||
  fail "mirror release URL is missing"
grep -Fxq 'https://mirror.51343.ru/forkop/mirror/current/packages.adb' \
  "$WORK_DIR/root/etc/apk/repositories.d/forkop.list" ||
  fail "Forkop current feed is missing"
grep -Fq 'BEGIN PUBLIC KEY' "$WORK_DIR/root/etc/apk/keys/forkop-mirror.pem" ||
  fail "Forkop mirror key is missing"
grep -Fq 'add_list forkop.settings.applied_migrations=mirror_51343_ru_v1' "$WORK_DIR/uci.log" ||
  fail "migration marker was not recorded"
grep -Fq 'set forkop.settings.mirror_base_url=https://mirror.51343.ru' "$WORK_DIR/uci.log" ||
  fail "mirror base URL was not configured"

printf 'PASS: full APK mirror migration\n'
