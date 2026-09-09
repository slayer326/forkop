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
TMP_DIR="$WORK_DIR/tmp"
mkdir -p "$TMP_DIR"

cat > "$WORK_DIR/forkop-platforms.tsv" <<'EOF'
# target architecture release format
mediatek/filogic aarch64_cortex-a53 24.10.0 ipk
mediatek/filogic aarch64_cortex-a53 24.10.1 ipk
mediatek/filogic aarch64_cortex-a53 24.10.4 ipk
mediatek/filogic aarch64_cortex-a53 24.10.5 ipk
mediatek/filogic aarch64_cortex-a53 24.10.7 ipk
mediatek/filogic aarch64_cortex-a53 24.10.99 ipk
mediatek/filogic aarch64_cortex-a53 25.12.5 apk
rockchip/armv8 aarch64_generic 24.10.4 ipk
rockchip/armv8 aarch64_generic 24.10.0 ipk
rockchip/armv8 aarch64_generic 24.10.1 ipk
rockchip/armv8 aarch64_generic 25.12.5 apk
x86/64 x86_64 24.10.4 ipk
x86/64 x86_64 25.12.5 apk
ramips/mt7621 mipsel_24kc 24.10.4 ipk
ramips/mt7621 mipsel_24kc 25.12.5 apk
EOF

PLATFORM_INDEX_UNAVAILABLE=0
download_file_once() {
  [ "$PLATFORM_INDEX_UNAVAILABLE" -eq 0 ] || return 1
  cp "$WORK_DIR/forkop-platforms.tsv" "$2"
}

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

for release in 24.10.0 24.10.1 24.10.4 24.10.5 24.10.7 24.10.99; do
  expect_supported "$release" 0
done
expect_supported 25.12.5 1
expect_supported 24.10.4 0 rockchip/armv8 aarch64_generic
expect_supported 24.10.0 0 rockchip/armv8 aarch64_generic
expect_supported 24.10.1 0 rockchip/armv8 aarch64_generic
expect_supported 25.12.5 1 rockchip/armv8 aarch64_generic
expect_supported 24.10.4 0 x86/64 x86_64
expect_supported 25.12.5 1 x86/64 x86_64
expect_supported 24.10.4 0 ramips/mt7621 mipsel_24kc
expect_supported 25.12.5 1 ramips/mt7621 mipsel_24kc

expect_rejected 23.05.5 0
expect_rejected 24.09.9 0
expect_rejected 24.10.4 1
expect_rejected 25.12.5 0
expect_rejected 24.10.4 0 ramips/mt7621
expect_rejected 24.10.4 0 mediatek/filogic mipsel_24kc
expect_rejected 25.12.5 1 rockchip/armv8 aarch64_cortex-a53
expect_rejected 24.10.1 1
expect_rejected 24.10.1 0 rockchip/armv8 aarch64_cortex-a53
expect_rejected 24.10.2 0

PLATFORM_INDEX_UNAVAILABLE=1
expect_rejected 25.12.5 1 rockchip/armv8 aarch64_generic
MIRROR_BASE_URL="https://custom-legacy-mirror.example"
expect_supported 25.12.5 1 rockchip/armv8 aarch64_generic
MIRROR_BASE_URL="https://mirror.infotechtg.ru"
PLATFORM_INDEX_UNAVAILABLE=0

interactive_terminal_available() { return 1; }
SING_BOX_INSTALL_VARIANT=""
sing_box_is_present() { return 1; }
select_sing_box_installation >/dev/null
[ "$SING_BOX_INSTALL_VARIANT" = "tiny" ] ||
  fail_test "fresh non-interactive installation must select sing-box-tiny"

interactive_terminal_available() { return 0; }
SING_BOX_INSTALL_VARIANT=""
SING_BOX_INSTALL_VARIANT_EXPLICIT=1
parse_args --sing-box extended
[ "$SING_BOX_INSTALL_VARIANT" = "extended" ] ||
  fail_test "explicit sing-box selection must be parsed"

INSTALLER_LANG="en"
INSTALLER_LANG_EXPLICIT=0
parse_args --lang ru
[ "$INSTALLER_LANG" = "ru" ] ||
  fail_test "explicit installer language must be parsed"

interactive_terminal_available() { return 1; }
SING_BOX_INSTALL_VARIANT=""
SING_BOX_INSTALL_VARIANT_EXPLICIT=0
select_sing_box_installation >/dev/null
[ "$SING_BOX_INSTALL_VARIANT" = "tiny" ] ||
  fail_test "fresh non-interactive installation must default to sing-box-tiny"

SING_BOX_INSTALL_VARIANT="sentinel"
sing_box_is_present() { return 0; }
select_sing_box_installation >/dev/null
[ -z "$SING_BOX_INSTALL_VARIANT" ] ||
  fail_test "upgrade must preserve the installed sing-box variant"

# A clean interactive install defaults to Russian, but the menu can select
# English and each sing-box option remains selectable.
INSTALL_MODE="clean"
INSTALLER_LANG="ru"
INSTALLER_LANG_EXPLICIT=0
INSTALLER_LANG_DETECTED=0
pkg_is_installed() { return 1; }
get_luci_main_lang() { printf '%s\n' en; }
detect_installer_language
[ "$INSTALLER_LANG" = "ru" ] ||
  fail_test "clean installation must default to Russian when LuCI is English"

interactive_terminal_available() { return 1; }
select_installer_language >/dev/null
[ "$INSTALLER_LANG" = "ru" ] ||
  fail_test "non-interactive clean installation must default to Russian"

interactive_terminal_available() { return 0; }
read_installer_answer() { answer="2"; return 0; }
select_installer_language >/dev/null
[ "$INSTALLER_LANG" = "en" ] ||
  fail_test "interactive language menu must allow selecting English"

SING_BOX_INSTALL_VARIANT=""
SING_BOX_INSTALL_VARIANT_EXPLICIT=0
sing_box_is_present() { return 1; }
read_installer_answer() { answer="$TEST_SING_BOX_ANSWER"; return 0; }
for TEST_SING_BOX_ANSWER in 1 2 3; do
  SING_BOX_INSTALL_VARIANT=""
  select_sing_box_installation >/dev/null
  case "$TEST_SING_BOX_ANSWER:$SING_BOX_INSTALL_VARIANT" in
    1:tiny|2:stable|3:extended) ;;
    *) fail_test "interactive sing-box menu selected an unexpected variant: $TEST_SING_BOX_ANSWER/$SING_BOX_INSTALL_VARIANT" ;;
  esac
done

INSTALLER_LANG="ru"
INSTALLER_LANG_EXPLICIT=0
INSTALLER_LANG_DETECTED=0
read_installer_answer() { answer=""; return 0; }
select_installer_language >/dev/null
[ "$INSTALLER_LANG" = "ru" ] ||
  fail_test "clean interactive language menu must default to Russian"

INSTALL_MODE="update"
INSTALLER_LANG="ru"
INSTALLER_LANG_EXPLICIT=0
INSTALLER_LANG_DETECTED=0
get_luci_main_lang() { printf '%s\n' en; }
detect_installer_language
[ "$INSTALLER_LANG" = "en" ] && [ "$INSTALLER_LANG_DETECTED" -eq 1 ] ||
  fail_test "update must preserve the detected English installer language"
interactive_terminal_available() { return 0; }
read_installer_answer() { fail_test "update must not prompt for an already detected language"; }
select_installer_language >/dev/null

# The explicit options make pipe-based installation deterministic without
# consuming stdin, while interactive sessions use the menus above.
INSTALLER_LANG="en"
INSTALLER_LANG_EXPLICIT=0
SING_BOX_INSTALL_VARIANT=""
SING_BOX_INSTALL_VARIANT_EXPLICIT=0
parse_args --language=ru --sing-box stable
[ "$INSTALLER_LANG" = "ru" ] && [ "$INSTALLER_LANG_EXPLICIT" -eq 1 ] ||
  fail_test "explicit Russian language selection must be retained"
[ "$SING_BOX_INSTALL_VARIANT" = "stable" ] && [ "$SING_BOX_INSTALL_VARIANT_EXPLICIT" -eq 1 ] ||
  fail_test "explicit stable sing-box selection must be retained"

INSTALL_MODE="clean"
FORKOP_I18N_REQUESTED=0
INSTALLER_LANG="en"
INSTALLER_LANG_EXPLICIT=0
INSTALLER_LANG_DETECTED=0
pkg_is_installed() { return 1; }
get_luci_main_lang() { printf '%s\n' ru; }
parse_args --lang ru
decide_i18n_installation >/dev/null
[ "$INSTALLER_LANG" = "ru" ] && [ "$FORKOP_I18N_REQUESTED" -eq 1 ] ||
  fail_test "Russian selection must request the Russian LuCI package"

FORKOP_I18N_REQUESTED=0
parse_args --lang en
decide_i18n_installation >/dev/null
[ "$INSTALLER_LANG" = "en" ] && [ "$FORKOP_I18N_REQUESTED" -eq 0 ] ||
  fail_test "explicit English selection must override the detected LuCI language"

printf x >"$WORK_DIR/backend.ipk"
printf xx >"$WORK_DIR/app.ipk"
FORKOP_BACKEND_FILE="$WORK_DIR/backend.ipk"
FORKOP_APP_FILE="$WORK_DIR/app.ipk"
FORKOP_I18N_FILE=""
pkg_is_installed() { return 0; }
calculated_space="$(forkop_install_required_space_kb)"
[ "$calculated_space" -eq "$((2 * PACKAGE_ARCHIVE_SPACE_FACTOR + PACKAGE_INSTALL_OVERHEAD_KB + FLASH_RESERVE_KB))" ] ||
  fail_test "installer must calculate flash requirements from the selected downloaded packages"
[ "$calculated_space" -lt 15360 ] ||
  fail_test "installer must not retain the fixed 15 MB threshold"

printf 'Installer compatibility matrix passed\n'
