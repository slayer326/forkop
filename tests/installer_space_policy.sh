#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"
TMP_DIR="$WORK_DIR"

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

dd if=/dev/zero of="$WORK_DIR/forkop.ipk" bs=1024 count=1 status=none
dd if=/dev/zero of="$WORK_DIR/app.ipk" bs=1024 count=2 status=none
dd if=/dev/zero of="$WORK_DIR/i18n.ipk" bs=1024 count=1 status=none
FORKOP_BACKEND_FILE="$WORK_DIR/forkop.ipk"
FORKOP_APP_FILE="$WORK_DIR/app.ipk"
FORKOP_I18N_FILE="$WORK_DIR/i18n.ipk"

pkg_is_installed() { return 0; }

APK_WORLD_FILE="$WORK_DIR/apk-world"
: >"$APK_WORLD_FILE"
expected_required=$((4 * PACKAGE_ARCHIVE_SPACE_FACTOR + PACKAGE_INSTALL_OVERHEAD_KB + FLASH_RESERVE_KB))
[ "$(forkop_install_required_space_kb)" -eq "$expected_required" ] ||
  fail_test "Forkop space plan must be derived from the downloaded package sizes"
[ "$expected_required" -lt 15360 ] ||
  fail_test "calculated Forkop space plan must replace the old fixed 15 MB threshold"

pkg_is_installed() { return 1; }
missing_dependency_required="$(forkop_install_required_space_kb)"
[ "$missing_dependency_required" -eq "$((expected_required + 15 * MISSING_DEPENDENCY_ALLOWANCE_KB))" ] ||
  fail_test "space plan must include an allowance only for missing direct dependencies"
pkg_is_installed() { return 0; }

available_flash_space_kb() { printf '%s\n' "$expected_required"; }
ensure_flash_space >/dev/null

(
  printf '%s\n' sing-box-tiny >"$APK_WORLD_FILE"
  PKG_IS_APK=1
  pkg_is_installed() { [ "$1" = sing-box ]; }
  package_file_list() { printf '%s\n' /usr/bin/sing-box /etc/init.d/sing-box; }
  sing_box_tiny_is_active() { return 1; }
  download_sing_box_tiny_package() { SING_BOX_TINY_FILE="$WORK_DIR/tiny-world.apk"; }
  dd if=/dev/zero of="$WORK_DIR/tiny-world.apk" bs=1024 count=2 status=none
  package_reclaimable_space_kb() { printf '%s\n' 10000; }
  interactive_terminal_available() { return 0; }
  numbered_yes_no_prompt() { return 0; }
  switch_sing_box_to_downloaded_tiny() {
    printf '%s\n' "$1" >"$WORK_DIR/world-switch"
    SING_BOX_TINY_SWITCHED=1
  }
  available_flash_space_kb() { printf '%s\n' 10000; }
  ensure_flash_space >/dev/null
)
[ "$(cat "$WORK_DIR/world-switch")" = sing-box ] ||
  fail_test "a stale sing-box-tiny APK world entry must force conversion before the Forkop transaction"
: >"$APK_WORLD_FILE"
pkg_is_installed() { return 0; }

pkg_is_installed() { [ "$1" = sing-box ]; }
package_file_list() { printf '%s\n' /usr/bin/sing-box /etc/init.d/sing-box; }
[ "$(installed_sing_box_package)" = sing-box ] ||
  fail_test "ordinary package-owned sing-box must be a supported low-space source"
pkg_is_installed() { [ "$1" = sing-box ] || [ "$1" = sing-box-extended ]; }
if installed_sing_box_package >/dev/null 2>&1; then
  fail_test "ambiguous sing-box package ownership must be rejected"
fi
pkg_is_installed() { return 0; }

mkdir -p "$WORK_DIR/fake-bin"
cat >"$WORK_DIR/fake-bin/opkg" <<'SH'
#!/bin/sh
case "$1" in
  info)
    printf '%s\n' 'Package: sing-box' 'Size: 10240'
    ;;
  remove)
    printf '%s\n' "$*" >>"$FORKOP_TEST_PACKAGE_LOG"
    ;;
esac
SH
cat >"$WORK_DIR/fake-bin/apk" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FORKOP_TEST_PACKAGE_LOG"
SH
chmod 0755 "$WORK_DIR/fake-bin/opkg"
chmod 0755 "$WORK_DIR/fake-bin/apk"
FORKOP_TEST_PACKAGE_LOG="$WORK_DIR/package-manager.log"
export FORKOP_TEST_PACKAGE_LOG
original_path="$PATH"
PATH="$WORK_DIR/fake-bin:$PATH"
PKG_IS_APK=0
[ "$(package_reclaimable_space_kb sing-box)" -eq 9 ] ||
  fail_test "OPKG reclaim calculation must use 90 percent of the feed archive size"
pkg_remove_name sing-box
grep -Fxq 'remove --force-depends sing-box' "$FORKOP_TEST_PACKAGE_LOG" ||
  fail_test "OPKG sing-box replacement must permit its dependency to be restored by tiny"
PKG_IS_APK=1
pkg_remove_name sing-box
grep -Fxq 'del --force-broken-world sing-box' "$FORKOP_TEST_PACKAGE_LOG" ||
  fail_test "APK sing-box replacement must permit its world dependency to be restored by tiny"
PKG_IS_APK=0
PATH="$original_path"

available_flash_space_kb() { printf '%s\n' 512; }
installed_sing_box_package() { return 1; }
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "low-space installation without an unambiguous package-owned sing-box must stop before changes"
fi

dd if=/dev/zero of="$WORK_DIR/tiny.ipk" bs=1024 count=2 status=none
(
  SING_BOX_TINY_FILE="$WORK_DIR/tiny.ipk"
  : >"$WORK_DIR/direct-switch"
  pkg_remove_name() { printf 'remove:%s\n' "$1" >>"$WORK_DIR/direct-switch"; }
  pkg_install_files() { printf 'install:%s\n' "$1" >>"$WORK_DIR/direct-switch"; }
  validate_sing_box_tiny_install() { return 0; }
  switch_sing_box_to_downloaded_tiny sing-box
  [ "$SING_BOX_TINY_SWITCHED" -eq 1 ] || fail_test "direct tiny switch must be marked only after validation"
  [ "$SING_BOX_CHANGE_STARTED" -eq 1 ] || fail_test "successful package removal must mark the permanent sing-box change"
  grep -Fxq 'remove:sing-box' "$WORK_DIR/direct-switch" || fail_test "direct switch must remove the detected owner"
  grep -Fxq "install:$WORK_DIR/tiny.ipk" "$WORK_DIR/direct-switch" || fail_test "direct switch must install the downloaded local tiny package"
)
(
  SING_BOX_TINY_FILE="$WORK_DIR/tiny.ipk"
  pkg_remove_name() { return 1; }
  pkg_install_files() { fail_test "tiny install must not run after package removal failed"; }
  if switch_sing_box_to_downloaded_tiny sing-box; then
    fail_test "direct switch must report package removal failure"
  fi
  [ "$SING_BOX_CHANGE_STARTED" -eq 0 ] || fail_test "failed package removal must not mark a sing-box change"
)
(
  SING_BOX_TINY_FILE="$WORK_DIR/tiny.ipk"
  pkg_remove_name() { return 0; }
  pkg_install_files() { return 0; }
  validate_sing_box_tiny_install() { return 1; }
  if switch_sing_box_to_downloaded_tiny sing-box; then
    fail_test "direct switch must reject an installed tiny package that fails final invariants"
  fi
  [ "$SING_BOX_TINY_SWITCHED" -eq 0 ] || fail_test "failed tiny validation must not be marked successful"
  [ "$SING_BOX_CHANGE_STARTED" -eq 1 ] || fail_test "post-removal failure must preserve the sing-box change marker"
)
(
  SING_BOX_TINY_FILE="$WORK_DIR/tiny.ipk"
  : >"$WORK_DIR/partial-tiny-switch"
  pkg_remove_name() { printf 'remove:%s\n' "$1" >>"$WORK_DIR/partial-tiny-switch"; }
  pkg_install_files() { printf 'install:%s\n' "$1" >>"$WORK_DIR/partial-tiny-switch"; }
  validate_sing_box_tiny_install() { return 0; }
  switch_sing_box_to_downloaded_tiny sing-box-tiny
  grep -Fxq 'remove:sing-box-tiny' "$WORK_DIR/partial-tiny-switch" ||
    fail_test "a partially installed sing-box-tiny package must be removed before repair"
  grep -Fxq "install:$WORK_DIR/tiny.ipk" "$WORK_DIR/partial-tiny-switch" ||
    fail_test "a partially installed sing-box-tiny package must be reinstalled from the downloaded archive"
)

installed_sing_box_package() { printf '%s\n' sing-box; }
download_sing_box_tiny_package() { SING_BOX_TINY_FILE="$WORK_DIR/tiny.ipk"; }
package_reclaimable_space_kb() { printf '%s\n' 10000; }
interactive_terminal_available() { return 0; }
numbered_yes_no_prompt() { return 0; }

: >"$WORK_DIR/switches"
switch_sing_box_to_downloaded_tiny() {
  printf '%s\n' "$1" >>"$WORK_DIR/switches"
  SING_BOX_TINY_SWITCHED=1
}
printf '0\n' >"$WORK_DIR/space-call"
available_flash_space_kb() {
  if [ "$(cat "$WORK_DIR/space-call")" -eq 0 ]; then
    printf '1\n' >"$WORK_DIR/space-call"
    printf '%s\n' 512
  else
    printf '%s\n' "$expected_required"
  fi
}
SING_BOX_INSTALL_VARIANT="stable"
ensure_flash_space >/dev/null
[ "$SING_BOX_TINY_SWITCHED" -eq 1 ] || fail_test "successful low-space conversion must be recorded"
[ -z "$SING_BOX_INSTALL_VARIANT" ] || fail_test "successful tiny conversion must suppress a later sing-box reinstall"
grep -Fxq sing-box "$WORK_DIR/switches" || fail_test "the detected ordinary sing-box package must be replaced"

: >"$WORK_DIR/switches"
printf '0\n' >"$WORK_DIR/space-call"
package_reclaimable_space_kb() { printf '%s\n' 100; }
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "conversion must be rejected when the conservative plan does not fit after removing sing-box"
fi
[ ! -s "$WORK_DIR/switches" ] || fail_test "an insufficient plan must not change sing-box"

package_reclaimable_space_kb() { printf '%s\n' 10000; }
printf '0\n' >"$WORK_DIR/space-call"
ALLOW_LOW_SPACE_TINY=0
interactive_terminal_available() { return 1; }
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "non-interactive low-space conversion must require explicit authorization"
fi
[ ! -s "$WORK_DIR/switches" ] || fail_test "missing authorization must stop before changing sing-box"

printf '0\n' >"$WORK_DIR/space-call"
ALLOW_LOW_SPACE_TINY=1
ensure_flash_space >/dev/null
[ -s "$WORK_DIR/switches" ] || fail_test "--allow-low-space-tiny must authorize the calculated conversion"

: >"$WORK_DIR/switches"
printf '0\n' >"$WORK_DIR/space-call"
available_flash_space_kb() {
  if [ "$(cat "$WORK_DIR/space-call")" -eq 0 ]; then
    printf '1\n' >"$WORK_DIR/space-call"
    printf '%s\n' 512
  else
    printf '%s\n' 513
  fi
}
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "installer must stop when real post-tiny free space contradicts preflight"
fi
[ -s "$WORK_DIR/switches" ] || fail_test "post-conversion remeasurement must follow an authorized switch"

FORKOP_LEGACY_DETECTED=1
interactive_terminal_available() { return 0; }
numbered_yes_no_prompt() { return 0; }
: >"$WORK_DIR/backups"
prepare_legacy_config_backup() { printf '%s\n' backup >>"$WORK_DIR/backups"; }
confirm_legacy_migration >/dev/null
[ "$(wc -l <"$WORK_DIR/backups")" -eq 1 ] || fail_test "legacy confirmation must create its config backup"

LEGACY_CONFIG_BACKUP="$WORK_DIR/persistent-legacy-backup"
printf '%s\n' legacy >"$LEGACY_CONFIG_BACKUP"
LEGACY_CLEANUP_STARTED=0
SING_BOX_CHANGE_STARTED=1
rollback_legacy_config_on_failure >/dev/null
[ -f "$LEGACY_CONFIG_BACKUP" ] ||
  fail_test "legacy backup must remain after any permanent sing-box package change"

interactive_terminal_available() { return 1; }
CONFIRM_LEGACY_MIGRATION=0
if (confirm_legacy_migration >/dev/null 2>&1); then
  fail_test "non-interactive legacy migration must require explicit authorization"
fi
CONFIRM_LEGACY_MIGRATION=1
confirm_legacy_migration >/dev/null

ALLOW_LOW_SPACE_TINY=0
CONFIRM_LEGACY_MIGRATION=0
parse_args --allow-low-space-tiny --confirm-legacy-migration
[ "$ALLOW_LOW_SPACE_TINY" -eq 1 ] || fail_test "--allow-low-space-tiny must be parsed"
[ "$CONFIRM_LEGACY_MIGRATION" -eq 1 ] || fail_test "--confirm-legacy-migration must be parsed"

if sed -n '/^ensure_flash_space()/,/^installer_is_ru()/p' "$ROOT_DIR/install.sh" |
  grep -Fq 'component_action'; then
  fail_test "low-space migration must not delegate replacement to an old component manager"
fi
confirm_line="$(grep -n '^[[:space:]]*confirm_legacy_migration$' "$ROOT_DIR/install.sh" | tail -n 1 | cut -d: -f1)"
space_line="$(grep -n '^[[:space:]]*ensure_flash_space$' "$ROOT_DIR/install.sh" | tail -n 1 | cut -d: -f1)"
[ "$confirm_line" -lt "$space_line" ] || fail_test "legacy backup must happen before a low-space sing-box change"

printf 'Installer space policy passed\n'
