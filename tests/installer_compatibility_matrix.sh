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

sed \
  -e '/^main "\$@"$/d' \
  -e 's#\[ -f /etc/openwrt_release \]#\[ -f "$FORKOP_TEST_RELEASE_FILE" \]#' \
  "$ROOT_DIR/install.sh" > "$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

FORKOP_TEST_RELEASE_FILE="$WORK_DIR/openwrt_release"
touch "$FORKOP_TEST_RELEASE_FILE"

read_openwrt_release_value() {
  case "$1" in
    DISTRIB_RELEASE) printf '%s\n' "$TEST_RELEASE" ;;
    DISTRIB_TARGET) printf '%s\n' "$TEST_TARGET" ;;
    DISTRIB_ARCH) printf '%s\n' "$TEST_ARCH" ;;
  esac
}

expect_supported() {
  TEST_RELEASE="$1"
  PKG_IS_APK="$2"
  TEST_TARGET="${3:-mediatek/filogic}"
  TEST_ARCH="${4:-aarch64_cortex-a53}"
  check_system >/dev/null ||
    fail_test "expected supported platform: $TEST_RELEASE apk=$PKG_IS_APK $TEST_TARGET $TEST_ARCH"
}

expect_rejected() {
  TEST_RELEASE="$1"
  PKG_IS_APK="$2"
  TEST_TARGET="${3:-mediatek/filogic}"
  TEST_ARCH="${4:-aarch64_cortex-a53}"
  if (check_system >/dev/null 2>&1); then
    fail_test "expected rejected platform: $TEST_RELEASE apk=$PKG_IS_APK $TEST_TARGET $TEST_ARCH"
  fi
}

for release in 24.10.0 24.10.4 24.10.5 24.10.7 24.10.99; do
  expect_supported "$release" 0
done
expect_supported 25.12.5 1

expect_rejected 23.05.5 0
expect_rejected 24.09.9 0
expect_rejected 24.10.4 1
expect_rejected 25.12.5 0
expect_rejected 24.10.4 0 ramips/mt7621
expect_rejected 24.10.4 0 mediatek/filogic mipsel_24kc
expect_rejected 25.12.5 1 x86/64 x86_64

SING_BOX_INSTALL_VARIANT=""
sing_box_is_present() { return 1; }
select_sing_box_installation >/dev/null
[ "$SING_BOX_INSTALL_VARIANT" = "tiny" ] ||
  fail_test "fresh non-interactive installation must select sing-box-tiny"

SING_BOX_INSTALL_VARIANT="sentinel"
sing_box_is_present() { return 0; }
select_sing_box_installation >/dev/null
[ -z "$SING_BOX_INSTALL_VARIANT" ] ||
  fail_test "upgrade must preserve the installed sing-box variant"

FORKOP_LEGACY_DETECTED=0
SING_BOX_INSTALL_VARIANT=""
pkg_is_installed() {
  [ "$1" = "forkop" ] || [ "$1" = "luci-app-forkop" ]
}
[ "$(required_flash_space_kb)" = "6144" ] ||
  fail_test "existing Forkop package updates must require 6 MB of free flash"

SING_BOX_INSTALL_VARIANT="tiny"
[ "$(required_flash_space_kb)" = "15360" ] ||
  fail_test "new sing-box installations must retain the 15 MB free-flash requirement"

printf 'Installer compatibility matrix passed\n'
