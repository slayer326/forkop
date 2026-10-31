#!/bin/sh
# Runs inside an OpenWrt rootfs container that uses opkg (24.10 and older),
# after compat_check.sh installed Forkop. A sing-box variant switch first
# dry-runs the target package to install its dependencies while the current
# variant is still installed (components/action.uc). On the Xiaomi AX3000T
# (24.10) podkop-engine-full declares a conflict with sing-box-tiny and that
# dry run stopped the switch. The unit test checks the parsing against output
# copied from that router; this runs the real dependency check against the
# real opkg of the release, with stand-in packages that conflict the same way.
#
# usage: opkg_variant_switch.sh SOURCE_DIR
set -eu

SOURCE_DIR="${1:?source directory}"
ACTION="$SOURCE_DIR/forkop/files/usr/lib/components/action.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM
# shellcheck source=tests/helpers/source_checks.sh
. "$SOURCE_DIR/tests/helpers/source_checks.sh"

fail() {
    printf 'opkg_variant_switch: FAIL: %s\n' "$1" >&2
    exit 1
}

# A feed package this image does not have installed, for a dependency the
# dry run has to find.
DEPENDENCY=jq
opkg list-installed "$DEPENDENCY" | grep -q . && fail "$DEPENDENCY is already installed in this image"
opkg info "$DEPENDENCY" | grep -q '^Package:' || fail "$DEPENDENCY is not in this release's feeds"

# make_ipk NAME DEPENDS CONFLICTS builds $WORK_DIR/NAME.ipk the way
# ipkg-build does: a gzip tar of debian-binary, control and data archives.
make_ipk() {
    dir="$WORK_DIR/build-$1"
    mkdir -p "$dir/control" "$dir/data/usr/share/forkop-compat"
    printf '%s\n' "$1" >"$dir/data/usr/share/forkop-compat/$1"
    {
        printf 'Package: %s\n' "$1"
        printf 'Version: 1.0.0-r1\n'
        printf 'Architecture: all\n'
        [ -z "$2" ] || printf 'Depends: %s\n' "$2"
        [ -z "$3" ] || printf 'Conflicts: %s\n' "$3"
        printf 'Description: Forkop compatibility test stand-in\n'
    } >"$dir/control/control"
    printf '2.0\n' >"$dir/debian-binary"
    (cd "$dir/control" && tar -czf ../control.tar.gz ./control)
    (cd "$dir/data" && tar -czf ../data.tar.gz ./usr)
    (cd "$dir" && tar -czf "$WORK_DIR/$1.ipk" ./debian-binary ./control.tar.gz ./data.tar.gz)
}

make_ipk sing-box-tiny "" ""
make_ipk forkop-compat-other "" ""
opkg install "$WORK_DIR/sing-box-tiny.ipk" "$WORK_DIR/forkop-compat-other.ipk" >"$WORK_DIR/install.log" 2>&1 ||
    { cat "$WORK_DIR/install.log"; fail "the stand-in installed variant could not be installed"; }

mkdir -p "$WORK_DIR/full" "$WORK_DIR/missing" "$WORK_DIR/foreign" "$WORK_DIR/plain"
make_ipk podkop-engine-full "$DEPENDENCY" "sing-box-tiny"
mv "$WORK_DIR/podkop-engine-full.ipk" "$WORK_DIR/full/podkop-engine-full.ipk"
make_ipk podkop-engine-full "forkop-compat-missing" "sing-box-tiny"
mv "$WORK_DIR/podkop-engine-full.ipk" "$WORK_DIR/missing/podkop-engine-full.ipk"
make_ipk podkop-engine-full "$DEPENDENCY" "sing-box-tiny, forkop-compat-other"
mv "$WORK_DIR/podkop-engine-full.ipk" "$WORK_DIR/foreign/podkop-engine-full.ipk"
make_ipk podkop-engine "$DEPENDENCY" ""
mv "$WORK_DIR/podkop-engine.ipk" "$WORK_DIR/plain/podkop-engine.ipk"

{
    cat <<'UCODE'
let last_logged_output = "";
let switch_notes = [];
function as_string(value) { return value == null ? "" : "" + value; }
function is_apk() { return false; }
function shell_quote(value) { return "'" + replace(as_string(value), /'/g, "'\\''") + "'"; }
function command_from_args(args) {
    let parts = [];
    for (let arg in args) push(parts, shell_quote(arg));
    return join(" ", parts);
}
function readfile(path) {
    let fs = require("fs");
    return fs.readfile(path);
}
function updates_log(message, level) { push(switch_notes, as_string(message)); }
// What components/action.uc run_logged does, without its busy-lock retry.
function run_logged(description, command) {
    let output_file = ARGV[2];
    let status = system(as_string(command) + " >" + shell_quote(output_file) + " 2>&1");
    last_logged_output = as_string(readfile(output_file));
    return status == 0;
}
UCODE
    source_between "$ACTION" '^function array_has\(' '^// The packages that own /usr/bin/sing-box' ||
        fail "array_has was not found"
    source_between "$ACTION" '^const SING_BOX_VARIANT_PACKAGE_NAMES = ' '^// opkg refuses a package whose dependencies' ||
        fail "the dry-run parsing functions were not found"
    source_function "$ACTION" opkg_sing_box_dependencies_to_install ||
        fail "opkg_sing_box_dependencies_to_install was not found"
    cat <<'UCODE'
let result = opkg_sing_box_dependencies_to_install(ARGV[0], ARGV[1]);
print(result == null ? "null" : join(",", result), "\n");
print(join("\n", switch_notes), "\n");
UCODE
} >"$WORK_DIR/harness.uc"

# run_case DIR PACKAGE prints the dependencies to install, or null, then
# the log lines of the check.
run_case() {
    ucode "$WORK_DIR/harness.uc" "$WORK_DIR/$1/$2.ipk" "$2" "$WORK_DIR/opkg-$1.log" 2>&1
}

output="$(run_case full podkop-engine-full)" || fail "the harness failed: $output"
[ "$(printf '%s\n' "$output" | head -n 1)" = "$DEPENDENCY" ] ||
    fail "a target conflicting only with sing-box-tiny did not resolve to its dependency: $output"
printf '%s\n' "$output" | grep -q 'conflicts with podkop-engine-full, which replaces it' ||
    fail "the real opkg did not report the variant conflict the switch has to step over: $output"

output="$(run_case missing podkop-engine-full)" || fail "the harness failed: $output"
[ "$(printf '%s\n' "$output" | head -n 1)" = null ] ||
    fail "a dependency no feed has was accepted: $output"

output="$(run_case foreign podkop-engine-full)" || fail "the harness failed: $output"
[ "$(printf '%s\n' "$output" | head -n 1)" = null ] ||
    fail "a conflict with a package that is not a sing-box variant was stepped over: $output"

output="$(run_case plain podkop-engine)" || fail "the harness failed: $output"
[ "$(printf '%s\n' "$output" | head -n 1)" = "$DEPENDENCY" ] ||
    fail "a target without conflicts did not resolve to its dependency: $output"

opkg list-installed "$DEPENDENCY" | grep -q . && fail "a dry run installed $DEPENDENCY"
opkg remove sing-box-tiny forkop-compat-other >/dev/null 2>&1 || true
printf 'opkg_variant_switch: ok\n'
