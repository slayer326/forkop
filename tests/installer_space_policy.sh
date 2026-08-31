#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$WORK_DIR/install-library.sh"
# shellcheck disable=SC1090
. "$WORK_DIR/install-library.sh"

fail_test() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for mode in clean update legacy; do
  INSTALL_MODE="$mode"
  [ "$(required_flash_space_kb)" = "15360" ] ||
    fail_test "$mode mode must require 15 MB before package changes"
done

available_flash_space_kb() { printf '%s\n' 15360; }
ensure_flash_space

sing_box_recovery_owner() { printf '%s\n' "$WORK_DIR/forkop"; }
pkg_is_installed() { return 1; }
legacy_binary_managed_sing_box_present() { return 0; }
prepare_sing_box_recovery
[ "$SING_BOX_RECOVERY_RESTORE_ACTION" = "install_extended_compressed" ] ||
  fail_test "legacy binary-managed sing-box must be safely replaceable and restorable"

available_flash_space_kb() { printf '%s\n' 15359; }
prepare_sing_box_recovery() { return 1; }
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "15359 KB without a safe sing-box recovery path must be rejected"
fi

printf '0\n' >"$WORK_DIR/space-call"
: >"$WORK_DIR/forkop"
chmod +x "$WORK_DIR/forkop"
available_flash_space_kb() {
  call="$(cat "$WORK_DIR/space-call")"
  if [ "$call" -eq 0 ]; then
    printf '1\n' >"$WORK_DIR/space-call"
    printf '%s\n' 4096
  else
    printf '%s\n' 16384
  fi
}
prepare_sing_box_recovery() {
  SING_BOX_RECOVERY_OWNER="$WORK_DIR/forkop"
  SING_BOX_RECOVERY_RESTORE_ACTION="install_stable"
}
interactive_terminal_available() { return 0; }
numbered_yes_no_prompt() { return 0; }
sing_box_tiny_is_active() { return 0; }
run_sing_box_recovery_action() {
  printf '%s\n' "$2" >>"$WORK_DIR/actions"
}
SING_BOX_INSTALL_VARIANT="extended-compressed"
ensure_flash_space >/dev/null
[ "$SING_BOX_RECOVERY_PERFORMED" -eq 1 ] ||
  fail_test "successful tiny recovery must be tracked for rollback"
[ -z "$SING_BOX_INSTALL_VARIANT" ] ||
  fail_test "successful low-space tiny recovery must not reinstall the legacy extended variant later"
grep -Fxq 'install_tiny' "$WORK_DIR/actions" ||
  fail_test "low-space recovery must install sing-box-tiny"

restore_sing_box_on_failure
[ "$SING_BOX_RECOVERY_PERFORMED" -eq 0 ] ||
  fail_test "failure rollback must clear the recovery marker"
grep -Fxq 'install_stable' "$WORK_DIR/actions" ||
  fail_test "failure rollback must restore the previous stable variant"

printf '0\n' >"$WORK_DIR/space-call"
: >"$WORK_DIR/partial-actions"
SING_BOX_RECOVERY_PERFORMED=0
SING_BOX_INSTALL_VARIANT="extended-compressed"
run_sing_box_recovery_action() {
  printf '%s\n' "$2" >>"$WORK_DIR/partial-actions"
  [ "$2" != "install_tiny" ]
}
ensure_flash_space >/dev/null
[ "$SING_BOX_RECOVERY_PERFORMED" -eq 1 ] ||
  fail_test "a reported component error must be accepted when tiny is actually active"
[ -z "$SING_BOX_INSTALL_VARIANT" ] ||
  fail_test "partial-success tiny recovery must suppress later extended reinstallation"

printf '0\n' >"$WORK_DIR/space-call"
SING_BOX_RECOVERY_PERFORMED=0
ALLOW_LOW_SPACE_TINY=0
interactive_terminal_available() { return 1; }
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "non-interactive low-space replacement must require explicit authorization"
fi

printf '0\n' >"$WORK_DIR/space-call"
SING_BOX_RECOVERY_PERFORMED=0
ALLOW_LOW_SPACE_TINY=1
run_sing_box_recovery_action() { return 0; }
ensure_flash_space >/dev/null
[ "$SING_BOX_RECOVERY_PERFORMED" -eq 1 ] ||
  fail_test "--allow-low-space-tiny must authorize the scoped non-interactive replacement"

FORKOP_LEGACY_DETECTED=1
printf '0\n' >"$WORK_DIR/legacy-prompts"
interactive_terminal_available() { return 0; }
numbered_yes_no_prompt() {
  count="$(cat "$WORK_DIR/legacy-prompts")"
  printf '%s\n' "$((count + 1))" >"$WORK_DIR/legacy-prompts"
  return 0
}
prepare_legacy_config_backup() { return 0; }
confirm_legacy_migration
[ "$(cat "$WORK_DIR/legacy-prompts")" -eq 1 ] ||
  fail_test "every legacy migration must require explicit confirmation"

interactive_terminal_available() { return 1; }
CONFIRM_LEGACY_MIGRATION=0
if (confirm_legacy_migration >/dev/null 2>&1); then
  fail_test "non-interactive legacy migration must require explicit authorization"
fi

CONFIRM_LEGACY_MIGRATION=1
confirm_legacy_migration >/dev/null

available_flash_space_kb() { printf '%s\n' 4096; }
interactive_terminal_available() { return 0; }
ALLOW_LOW_SPACE_TINY=0
SING_BOX_RECOVERY_PERFORMED=0
: >"$WORK_DIR/insufficient-actions"
run_sing_box_recovery_action() {
  printf '%s\n' "$2" >>"$WORK_DIR/insufficient-actions"
  return 0
}
if (ensure_flash_space >/dev/null 2>&1); then
  fail_test "installation must stop when tiny still leaves less than 15 MB"
fi
grep -Fxq 'install_tiny' "$WORK_DIR/insufficient-actions" ||
  fail_test "insufficient-after-tiny scenario must attempt tiny first"
grep -Fxq 'install_stable' "$WORK_DIR/insufficient-actions" ||
  fail_test "insufficient-after-tiny scenario must restore the previous variant"

ALLOW_LOW_SPACE_TINY=0
CONFIRM_LEGACY_MIGRATION=0
parse_args --allow-low-space-tiny --confirm-legacy-migration
[ "$ALLOW_LOW_SPACE_TINY" -eq 1 ] ||
  fail_test "--allow-low-space-tiny must be parsed"
[ "$CONFIRM_LEGACY_MIGRATION" -eq 1 ] ||
  fail_test "--confirm-legacy-migration must be parsed"

printf 'Installer space policy passed\n'
