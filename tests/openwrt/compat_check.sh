#!/bin/sh
# Runs inside an official OpenWrt rootfs container (openwrt/rootfs) of one
# release: installs the built Forkop packages with that release's own package
# manager, then checks what differs from one release to the next and that the
# backend tests on the build host cannot see: the ucode that compiles and runs
# the library, the busybox applets and tools it calls, the package database it
# reads, and the package scripts that migrate the configuration.
#
# usage: compat_check.sh PACKAGE_DIR SOURCE_DIR
set -u

PACKAGE_DIR="${1:?package directory}"
SOURCE_DIR="${2:?source directory}"
FORKOP_LIB=/usr/lib/forkop
failures=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

note() {
    printf '== %s\n' "$1"
}

# The rootfs image ships without the volatile directories procd creates.
mkdir -p /var/lock /var/run /tmp/run /tmp/lock

. /etc/openwrt_release
note "OpenWrt $DISTRIB_RELEASE ($DISTRIB_TARGET)"

if command -v apk >/dev/null 2>&1; then
    PM=apk
    note "$(apk --version)"
else
    PM=opkg
fi

note "Installing the Forkop packages with $PM"
if [ "$PM" = apk ]; then
    apk update >/tmp/pm-update.log 2>&1 || { cat /tmp/pm-update.log; fail "apk update failed"; }
    set -- "$PACKAGE_DIR"/forkop_*.apk "$PACKAGE_DIR"/luci-app-forkop_*.apk "$PACKAGE_DIR"/luci-i18n-forkop-ru_*.apk
    apk add --allow-untrusted "$@" >/tmp/pm-install.log 2>&1
    status=$?
else
    opkg update >/tmp/pm-update.log 2>&1 || { cat /tmp/pm-update.log; fail "opkg update failed"; }
    set -- "$PACKAGE_DIR"/forkop_*.ipk "$PACKAGE_DIR"/luci-app-forkop_*.ipk "$PACKAGE_DIR"/luci-i18n-forkop-ru_*.ipk
    opkg install "$@" >/tmp/pm-install.log 2>&1
    status=$?
fi
cat /tmp/pm-install.log
[ "$status" -eq 0 ] || fail "$PM could not install the Forkop packages (exit $status)"
# opkg reports a failed postinst only in its output.
grep -Eq 'postinst script returned status [1-9]|ERROR: .*forkop|ERROR: .*Forkop' /tmp/pm-install.log &&
    fail "a Forkop package script failed during installation"
[ -f "$FORKOP_LIB/service/lifecycle.uc" ] || { fail "the backend was not installed"; exit 1; }

UCODE_VERSION=""
if [ "$PM" = apk ]; then
    UCODE_VERSION="$(apk list -I ucode 2>/dev/null | awk '{ print $1 }')"
else
    UCODE_VERSION="$(opkg list-installed ucode 2>/dev/null)"
fi
note "ucode: ${UCODE_VERSION:-unknown}"

note "Compiling the library with this release's ucode"
compiled=0
for file in $(find "$FORKOP_LIB" -name '*.uc') /usr/bin/forkop; do
    compiled=$((compiled + 1))
    if ! output="$(ucode -c -o /dev/null "$file" 2>&1)"; then
        fail "$file does not compile: $output"
    fi
done
[ "$compiled" -gt 50 ] || fail "only $compiled ucode files were found under $FORKOP_LIB"
printf 'compiled %s files\n' "$compiled"

# Every module is a script dispatching on its first argument. An unknown
# operation must end in the module's usage message, not in an exception from
# a missing builtin, module or a load-time error.
note "Loading every module"
for file in $(find "$FORKOP_LIB" -name '*.uc'); do
    output="$(cd /tmp && ucode -L "$FORKOP_LIB" "$file" __forkop_compat_probe__ 2>&1 </dev/null)"
    case "$output" in
        *"Syntax error"*|*"Runtime error"*|*"Reference error"*|*"Type error"*|*"Unable to"*|*"left-hand side is not a function"*)
            fail "${file#$FORKOP_LIB/} fails to load: $(printf '%s' "$output" | head -n 5)" ;;
    esac
done

# The commands the backend runs by name. Optional components (sing-box,
# mwan3, TorrServer) are checked by the code itself before use.
note "Checking the commands Forkop calls"
for command_name in cat chmod cp crontab curl date df dig dirname du env find grep gzip ip kill killall \
    logger logread md5sum mkdir mktemp modprobe mv netstat nft nslookup pgrep readlink rm rmdir sh \
    sha256sum sleep sync sysctl tar ubus ucode uname wget "$PM"; do
    command -v "$command_name" >/dev/null 2>&1 || fail "command not available: $command_name"
done

note "Reading the package database"
for package_name in forkop luci-app-forkop; do
    state="$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/packages.uc" installed-version "$package_name" 2>&1)"
    case "$state" in
        "found "*) printf '%s: %s\n' "$package_name" "$state" ;;
        *) fail "the installed version of $package_name was not read: $state" ;;
    esac
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/packages.uc" installed "$package_name" ||
        fail "$package_name is not reported as installed"
done
state="$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/core/packages.uc" installed-version forkop-compat-absent 2>&1)"
[ "$state" = missing ] || fail "a package that is not installed was not reported missing: $state"

note "Checking the installed configuration"
uci -q get forkop.settings >/dev/null || fail "the forkop UCI configuration has no settings section"

if [ "$PM" = opkg ]; then
    note "Checking the sing-box variant switch against the real opkg"
    sh "$SOURCE_DIR/tests/openwrt/opkg_variant_switch.sh" "$SOURCE_DIR" ||
        fail "the opkg variant switch check failed"
fi

if [ "$failures" -ne 0 ]; then
    printf '%s compatibility check(s) failed on OpenWrt %s\n' "$failures" "$DISTRIB_RELEASE" >&2
    exit 1
fi
printf 'OpenWrt %s compatibility checks passed\n' "$DISTRIB_RELEASE"
