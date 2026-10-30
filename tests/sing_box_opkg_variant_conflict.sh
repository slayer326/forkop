#!/bin/sh
set -eu

# A sing-box variant switch on opkg checks the target's dependencies with a
# dry run while the current variant is still installed. podkop-engine-full
# conflicts with sing-box-tiny, and opkg checks conflicts before dependencies,
# so that dry run failed and the switch stopped with "Failed to install
# required sing-box dependencies" although the switch removes sing-box-tiny
# itself. A conflict with another sing-box variant only must now lead to a
# second dry run without the conflict check; any other conflict, or a
# dependency opkg cannot satisfy, must still fail.
#
# The real parsing functions run against opkg's own output.

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="$ROOT_DIR/forkop/files/usr/lib/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

fail() {
  printf 'sing_box_opkg_variant_conflict: FAIL: %s\n' "$1" >&2
  exit 1
}

{
  printf '%s\n' 'function as_string(value) { return value == null ? "" : "" + value; }'
  source_between "$ACTION" '^function array_has\(' '^// The packages that own /usr/bin/sing-box' ||
    fail "array_has was not found"
  source_between "$ACTION" '^const SING_BOX_VARIANT_PACKAGE_NAMES = ' '^// opkg refuses a package whose dependencies' ||
    fail "the dry-run parsing functions were not found"
} >"$WORK_DIR/harness.uc"

cat >>"$WORK_DIR/harness.uc" <<'UCODE'
function check(condition, message) { if (!condition) die(message + "\n"); }

// As the AX3000T printed it on OpenWrt 24.10.5.
let tiny = " * check_conflicts_for: The following packages conflict with podkop-engine-full:\n" +
    " * check_conflicts_for: \tsing-box-tiny *\n" +
    " * opkg_install_cmd: Cannot install package podkop-engine-full.\n";
check(join(",", opkg_dry_run_conflicts(tiny)) == "sing-box-tiny", "the sing-box-tiny conflict was not read");
check(opkg_dry_run_blocked_by_variant(tiny), "a conflict with sing-box-tiny alone still blocked the switch");

let two = " * check_conflicts_for: The following packages conflict with podkop-engine-full:\n" +
    " * check_conflicts_for: \tsing-box-tiny * check_conflicts_for: \tpodkop-engine *\n" +
    " * opkg_install_cmd: Cannot install package podkop-engine-full.\n";
check(join(",", opkg_dry_run_conflicts(two)) == "sing-box-tiny,podkop-engine", "two conflicts on one line were not both read");
check(opkg_dry_run_blocked_by_variant(two), "conflicts with two variants still blocked the switch");

let foreign = " * check_conflicts_for: The following packages conflict with podkop-engine-full:\n" +
    " * check_conflicts_for: \tsing-box-tiny * check_conflicts_for: \txray-core *\n";
check(!opkg_dry_run_blocked_by_variant(foreign), "a conflict with a package that is not a sing-box variant was ignored");

let missing = " * satisfy_dependencies_for: Cannot satisfy the following dependencies for podkop-engine-full:\n" +
    " * \tkmod-nft-tproxy\n";
check(!opkg_dry_run_blocked_by_variant(missing), "an unsatisfied dependency was taken for a variant conflict");
check(!opkg_dry_run_blocked_by_variant(""), "an empty failure was taken for a variant conflict");
check(!opkg_dry_run_blocked_by_variant(" * opkg_install_cmd: Cannot install package podkop-engine-full.\n"),
    "a failure without a conflict was taken for a variant conflict");

let installed = "Installing podkop-engine-full (1.14.4-r20) to root...\n" +
    "Installing ca-bundle (20250419-r1) to root...\n" +
    "Installing kmod-nft-tproxy (6.6.119-r1) to root...\n" +
    "Installing ca-bundle (20250419-r1) to root...\n";
check(join(",", opkg_dry_run_dependencies(installed, "podkop-engine-full")) == "ca-bundle,kmod-nft-tproxy",
    "the dependencies of a passing dry run were not read");
print("ok\n");
UCODE

result="$(ucode "$WORK_DIR/harness.uc" 2>&1)" || fail "$result"
[ "$result" = "ok" ] || fail "unexpected harness output: $result"

# The second dry run must keep reporting a dependency it cannot satisfy.
region="$(source_function "$ACTION" opkg_sing_box_dependencies_to_install)" || exit 1
printf '%s\n' "$region" | grep -q -- '"--force-depends"' ||
  fail "the dry run after a variant conflict does not skip the conflict check"
printf '%s\n' "$region" | grep -q 'Cannot satisfy the following dependencies' ||
  fail "the dry run after a variant conflict does not fail on an unsatisfied dependency"

printf 'sing_box_opkg_variant_conflict: ok\n'
