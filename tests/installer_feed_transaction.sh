#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"

cleanup_test() {
  rm -rf "$WORK_DIR"
}
trap cleanup_test EXIT

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" > "$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

TMP_DIR="$WORK_DIR/tmp"
MIRROR_BASE_URL="https://mirror.51343.ru"
mkdir -p "$TMP_DIR" "$WORK_DIR/etc/opkg"
distfeeds="$WORK_DIR/etc/opkg/distfeeds.conf"
cat > "$distfeeds" <<'EOF'
src/gz openwrt_core https://downloads.openwrt.org/releases/24.10.7/targets/mediatek/filogic/packages
src/gz openwrt_base https://archive.openwrt.org/releases/24.10.7/packages/aarch64_cortex-a53/base
EOF
cp "$distfeeds" "$WORK_DIR/original"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"
grep -Fq 'https://mirror.51343.ru/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "transaction did not rewrite OpenWrt 24 feeds"
[ -s "$distfeeds.pre-forkop-mirror" ] ||
  fail_test "transaction did not create a persistent recovery copy"

rollback_package_mirror
cmp -s "$WORK_DIR/original" "$distfeeds" ||
  fail_test "transaction rollback did not restore original feeds"

begin_package_mirror_transaction
rewrite_package_repository_file "$distfeeds"
commit_package_mirror_transaction
cleanup
grep -Fq 'https://mirror.51343.ru/openwrt/releases/24.10.7/' "$distfeeds" ||
  fail_test "committed transaction was unexpectedly rolled back"

printf 'Installer feed transaction tests passed\n'
