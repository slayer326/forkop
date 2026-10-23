#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_BIN="$ROOT_DIR/forkop/files/usr/bin/forkop"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PACKAGE_UC="$FORKOP_LIB/service/package.uc"
FORKOP_MAKEFILE="$ROOT_DIR/forkop/Makefile"
LUCI_UCI_DEFAULTS="$ROOT_DIR/luci-app-forkop/root/etc/uci-defaults/50_luci-forkop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
WORK_DIR="$(mktemp -d)"
export FORKOP_PACKAGE_UPGRADE_STATE="$WORK_DIR/package-was-running"
# prerm reads service/initd.uc runtime state (a deferred start); never the
# host's.
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
mkdir -p "$FORKOP_RUNTIME_STATE_DIR"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[ -r "$PACKAGE_UC" ] ||
  fail "service/package.uc must own package lifecycle logic"
if grep -n -E 'require\("uci"\)\.cursor|uci -q|uci", "-q"' "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "service/package.uc must use core.uci instead of direct UCI cursor or CLI access"
fi
grep -Fq 'require("core.uci")' "$PACKAGE_UC" ||
  fail "service/package.uc must import core.uci"
grep -Fq 'package_prerm: [ "service/package.uc", "prerm", 1 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch package prerm cleanup through service/package.uc"
grep -Fq 'package_postinst: [ "service/package.uc", "postinst", 0 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch package postinst recovery through service/package.uc"
grep -Fq 'luci_postinst: [ "service/package.uc", "luci-postinst", 0 ]' "$FORKOP_BIN" ||
  fail "forkop entrypoint must dispatch LuCI postinstall cleanup through service/package.uc"
grep -Fq '#!/bin/sh' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must remain a shell script because OpenWrt default_postinst runs it through shell"
grep -Fq '/usr/bin/forkop luci_postinst' "$LUCI_UCI_DEFAULTS" ||
  fail "LuCI uci-defaults must delegate cache/rpcd handling to ucode"
if grep -E 'rm -f /var/luci-indexcache|rm -f /tmp/luci-indexcache|logger -t "forkop"' "$LUCI_UCI_DEFAULTS" >/dev/null; then
  fail "LuCI uci-defaults must not own cache/logger shell logic"
fi

if grep -n -E 'grep -q "105 forkop"|sed -i "/105 forkop|forkop_dont_touch_dhcp=.*uci|cp /etc/config/forkop|rm -f /tmp/luci-indexcache|killall -HUP rpcd' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT" >/dev/null; then
  fail "package scripts must not keep backend/LuCI lifecycle business logic in shell"
fi
grep -Fq '#!/usr/bin/ucode' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile package hooks must use ucode entrypoints"
grep -Fq '/usr/bin/forkop package_prerm' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile prerm must delegate cleanup to package_prerm"
grep -Fq '/usr/bin/forkop package_postinst' "$FORKOP_MAKEFILE" ||
  fail "forkop Makefile postinst must restore a service that was running before upgrade"
grep -Fq '/usr/bin/forkop package_prerm upgrade' "$BUILD_SCRIPT" ||
  fail "manual APK pre-upgrade must record and stop the running service"
grep -Fq '/usr/bin/forkop package_postinst' "$BUILD_SCRIPT" ||
  fail "manual packages must restore a service that was running before upgrade"
grep -Fq '/usr/share/forkop/defaults/forkop' "$FORKOP_MAKEFILE" ||
  fail "forkop package must include a recovery copy of the default configuration"
grep -Fq 'usr/share/forkop/defaults/forkop' "$BUILD_SCRIPT" ||
  fail "manual packages must include a recovery copy of the default configuration"
if grep -Fq '/usr/bin/forkop luci_postinst' "$BUILD_SCRIPT"; then
  fail "manual package hooks must let default_postinst run luci_postinst exactly once through uci-defaults"
fi
if grep -n -E 'Package/forkop/preinst|copy_legacy_config|FORKOP_LEGACY_CONFIG|mode == "preinst"' \
  "$FORKOP_MAKEFILE" "$BUILD_SCRIPT" "$PACKAGE_UC" >/dev/null 2>&1; then
  fail "package hooks and runtime service must not own configuration migration"
fi

rt_tables="$WORK_DIR/rt_tables"
cat >"$rt_tables" <<'EOF'
100 main
105 forkop
200 custom
EOF
FORKOP_PACKAGE_TEST_MODE=1 FORKOP_RT_TABLES="$rt_tables" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 1) exited non-zero"
if grep -Fq '105 forkop' "$rt_tables"; then
  fail "package prerm must remove the Forkop routing table entry"
fi
grep -Fq '200 custom' "$rt_tables" ||
  fail "package prerm must preserve unrelated rt_tables entries"

cat >"$WORK_DIR/forkop-init" <<'SH'
#!/usr/bin/env bash
# Model a real init script: only "stop" tears anything down, and "status"
# reports whether the service is running so prerm can decide about a restart.
case "$1" in
  status) exit "${FORKOP_FAKE_STATUS:-0}" ;;
  stop)
    grep -Fq '105 forkop' "${FORKOP_RT_TABLES:?}" || exit 1
    printf '%s\n' 'stop-with-route-table' >>"${FORKOP_STOP_LOG:?}"
    printf 'stop-source=%s\n' "${FORKOP_STOP_SOURCE:-}" >>"${FORKOP_STOP_LOG:?}"
    ;;
esac
SH
chmod 0755 "$WORK_DIR/forkop-init"
cat >"$WORK_DIR/stop-order.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_stop_order"
: >"$WORK_DIR/stop-order.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/stop-order.state" \
FORKOP_INIT="$WORK_DIR/forkop-init" \
FORKOP_STOP_LOG="$WORK_DIR/stop-order.log" \
FORKOP_BIN="$WORK_DIR/missing-forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_stop_order" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 2) exited non-zero"
grep -Fxq 'stop-with-route-table' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must stop Forkop before removing its routing table name"
[ ! -s "$WORK_DIR/rt_tables_stop_order" ] ||
  fail "package prerm must remove the routing table name after Forkop stops"
# Its stop is Forkop's own, for the package change, not the user's
# (service/initd.uc stop_request_source; UC-056).
grep -Fxq 'stop-source=package' "$WORK_DIR/stop-order.log" ||
  fail "package prerm must record its stop as the package's, not the user's"

# The preceding case stops a running Forkop, so prerm correctly records a
# restart for postinst. The configuration-recovery cases below own no init
# double, so start from an explicit clean slate instead of inheriting it.
rm -f "$FORKOP_PACKAGE_UPGRADE_STATE"

printf '%s\n' "config settings 'settings'" >"$WORK_DIR/default-forkop"
printf '%s\n' 'forkop.settings=settings' >"$WORK_DIR/config.state"
mkdir -p "$WORK_DIR/component-update-checks"
touch "$WORK_DIR/component-update-checks/forkop.json"
touch "$WORK_DIR/component-update-check.timestamp"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop" \
FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop" \
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
FORKOP_COMPONENT_UPDATE_CHECK_CACHE_DIR="$WORK_DIR/component-update-checks" \
FORKOP_COMPONENT_UPDATE_CHECK_STATE_FILE="$WORK_DIR/component-update-check.timestamp" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 3) exited non-zero"
cmp -s "$WORK_DIR/default-forkop" "$WORK_DIR/config-forkop" ||
  fail "package postinst must restore a missing Forkop configuration from packaged defaults"
[ ! -e "$WORK_DIR/component-update-checks/forkop.json" ] ||
  fail "package postinst must remove cached component update results"
[ ! -e "$WORK_DIR/component-update-check.timestamp" ] ||
  fail "package postinst must remove the component update check timestamp"

printf '%s\n' "config settings 'custom'" >"$WORK_DIR/config-forkop"
cp "$WORK_DIR/config-forkop" "$WORK_DIR/config-forkop.expected"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop" \
FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop" \
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 4) exited non-zero"
cmp -s "$WORK_DIR/config-forkop.expected" "$WORK_DIR/config-forkop" ||
  fail "package postinst must preserve an existing user configuration"

cat >"$WORK_DIR/config-forkop" <<'EOF_CONFIG_105'
config settings 'settings'
        option config_version '1.0.5'
        option custom_remote_setting 'preserve-me'
EOF_CONFIG_105
cp "$WORK_DIR/config-forkop" "$WORK_DIR/config-forkop-1.0.5.expected"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop" \
FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop" \
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 5) exited non-zero"
cmp -s "$WORK_DIR/config-forkop-1.0.5.expected" "$WORK_DIR/config-forkop" ||
  fail "1.0.5 package upgrade must preserve the existing user configuration"
cp "$WORK_DIR/config-forkop.expected" "$WORK_DIR/config-forkop"

if FORKOP_PACKAGE_TEST_MODE=1 \
  FORKOP_CONFIG_PATH="$WORK_DIR/unrecoverable-config" \
  FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/missing-default-config" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
    ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst 2>/dev/null; then
  fail "package postinst must fail when a missing configuration cannot be restored"
fi

printf '%s\n' 'not-a-forkop-section=value' >"$WORK_DIR/invalid-config.state"
if FORKOP_PACKAGE_TEST_MODE=1 \
  FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop" \
  FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop" \
  FORKOP_UCI_STATE_FILE="$WORK_DIR/invalid-config.state" \
    ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst 2>/dev/null; then
  fail "package postinst must reject a configuration without the required settings section"
fi
cmp -s "$WORK_DIR/config-forkop.expected" "$WORK_DIR/config-forkop" ||
  fail "package postinst must preserve an invalid non-empty user configuration"

touch "$WORK_DIR/luci-indexcache.one" "$WORK_DIR/luci-indexcache.two"
FORKOP_PACKAGE_TEST_MODE=1 FORKOP_LUCI_CACHE_GLOBS="$WORK_DIR/luci-indexcache*" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" luci-postinst
if compgen -G "$WORK_DIR/luci-indexcache*" >/dev/null; then
  fail "luci-postinst must remove LuCI index cache files"
fi

cat >"$WORK_DIR/forkop-bin" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FORKOP_RESTORE_LOG:?}"
SH
chmod 0755 "$WORK_DIR/forkop-bin"

cat >"$WORK_DIR/dont-touch.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=1
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_dont_touch"
: >"$WORK_DIR/restore-dont-touch.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/dont-touch.state" \
FORKOP_RESTORE_LOG="$WORK_DIR/restore-dont-touch.log" \
FORKOP_BIN="$WORK_DIR/forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_dont_touch" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 8) exited non-zero"
[ ! -s "$WORK_DIR/restore-dont-touch.log" ] ||
  fail "package prerm must skip dnsmasq restore when dont_touch_dhcp is enabled"

cat >"$WORK_DIR/restore.state" <<'EOF_UCI'
forkop.settings=settings
forkop.settings.dont_touch_dhcp=0
EOF_UCI
printf '105 forkop\n' >"$WORK_DIR/rt_tables_restore"
: >"$WORK_DIR/restore.log"
FORKOP_UCI_STATE_FILE="$WORK_DIR/restore.state" \
FORKOP_RESTORE_LOG="$WORK_DIR/restore.log" \
FORKOP_BIN="$WORK_DIR/forkop-bin" \
FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
FORKOP_SING_BOX_INIT="$WORK_DIR/missing-sing-box-init" \
FORKOP_SING_BOX_BIN="$WORK_DIR/missing-sing-box-bin" \
FORKOP_SING_BOX_CRONET="$WORK_DIR/missing-cronet" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_restore" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 9) exited non-zero"
grep -Fxq 'restore_dnsmasq' "$WORK_DIR/restore.log" ||
  fail "package prerm must restore dnsmasq when dont_touch_dhcp is disabled"

# init.d under procd accepts the start at once; its detached worker reports
# the outcome to the waiting postinst (service/initd.uc start-and-wait).
cat >"$WORK_DIR/upgrade-init" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) exit "${FORKOP_FAKE_STATUS:-0}" ;;
  start)
    printf '%s\n' start >>"${FORKOP_START_LOG:?}"
    [ -z "${FORKOP_START_REQUEST:-}" ] ||
      printf 'status=0\n' >"$FORKOP_RUNTIME_STATE_DIR/start-result.$FORKOP_START_REQUEST"
    ;;
esac
SH
cat >"$WORK_DIR/upgrade-forkop" <<'SH'
#!/bin/sh
[ "$1" != get_status ] || printf '{"running":1}\n'
SH
chmod 0755 "$WORK_DIR/upgrade-init" "$WORK_DIR/upgrade-forkop"
mkdir -p "$WORK_DIR/upgrade-run"
: >"$WORK_DIR/upgrade-start.log"
: >"$WORK_DIR/rt_tables_upgrade"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm upgrade ||
    fail "package prerm upgrade (case 10) exited non-zero"
[ -f "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must remember a running service"
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_LIB="$FORKOP_LIB" \
FORKOP_BIN="$WORK_DIR/upgrade-forkop" \
FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/upgrade-run" \
FORKOP_START_WAIT_TIMEOUT_SECONDS=5 \
FORKOP_START_LOG="$WORK_DIR/upgrade-start.log" \
FORKOP_CONFIG_PATH="$WORK_DIR/config-forkop" \
FORKOP_DEFAULT_CONFIG_PATH="$WORK_DIR/default-forkop" \
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" postinst ||
    fail "package postinst (case 11) exited non-zero"
grep -Fxq start "$WORK_DIR/upgrade-start.log" ||
  fail "package postinst must restart a service that was running before upgrade"
# That restart is an explicit start, also when init.d records none (an older
# init.d, a start that never comes): reloads may repair the runtime after it
# (service/initd.uc EXPLICIT_START_FILE; D-15(a)).
[ -e "$WORK_DIR/upgrade-run/start.explicit" ] ||
  fail "package postinst must record the restart after an upgrade as an explicit start"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package postinst must clear the consumed upgrade state"

FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_FAKE_STATUS=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm upgrade ||
    fail "package prerm upgrade (case 12) exited non-zero"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not mark an already stopped service"

# opkg calls prerm without an action argument on some OpenWrt 24 builds, an
# ordinary upgrade included. The running service must still be restored.
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 13) exited non-zero"
[ -f "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "prerm without an action must remember a running service"

FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_FAKE_STATUS=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm ||
    fail "package prerm (case 14) exited non-zero"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "prerm without an action must not mark an already stopped service"

# A start deferred for reload.lock (service/initd.uc) was requested but does
# not run yet: the package's own stop cancels it, so postinst starts Forkop
# in its place. A stop requested after that start has won over it (D-15), and
# the retry of a failed start is no requested start.
mkdir -p "$WORK_DIR/deferred-run"
prerm_with_stopped_runtime() {
  local lib="$FORKOP_LIB"
  FORKOP_PACKAGE_TEST_MODE=1 \
  FORKOP_FAKE_STATUS=1 \
  FORKOP_INIT="$WORK_DIR/upgrade-init" \
  FORKOP_LIB="$lib" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/deferred-run" \
  FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
    ucode -L "$lib" "$PACKAGE_UC" prerm upgrade ||
      fail "package prerm upgrade ($1) exited non-zero"
}
printf 'reason=start_deferred\nupdated_at=1\nstop_request=\n' >"$WORK_DIR/deferred-run/start.retry"
prerm_with_stopped_runtime "deferred start"
[ -f "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must restart a start deferred for the runtime lock"
rm -f "$FORKOP_PACKAGE_UPGRADE_STATE"
printf 'later\nby=user\n' >"$WORK_DIR/deferred-run/stop.requested"
prerm_with_stopped_runtime "deferred start, later stop"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not restart a deferred start that a later stop cancelled"
rm -f "$WORK_DIR/deferred-run/stop.requested"
printf 'reason=start_failed\nupdated_at=1\n' >"$WORK_DIR/deferred-run/start.retry"
prerm_with_stopped_runtime "failed start retry"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package pre-upgrade must not take the retry of a failed start for a requested start"
rm -f "$WORK_DIR/deferred-run/start.retry"

# An explicit removal stays unambiguous: nothing is restored afterwards.
FORKOP_PACKAGE_TEST_MODE=1 \
FORKOP_INIT="$WORK_DIR/upgrade-init" \
FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm remove ||
    fail "package prerm remove (case 15) exited non-zero"
[ ! -e "$FORKOP_PACKAGE_UPGRADE_STATE" ] ||
  fail "package removal must not schedule a restart"

# A binary sing-box variant belongs to Forkop's component manager, not to
# the backend APK. Upgrading the backend must not erase the only working core;
# explicitly removing Forkop must still clean it up.
printf '#!/bin/sh\n# Forkop managed sing-box service for binary variants\nexit 0\n' >"$WORK_DIR/managed-sing-box-init"
chmod 0755 "$WORK_DIR/managed-sing-box-init"
printf 'working core\n' >"$WORK_DIR/managed-sing-box-bin"
printf 'working library\n' >"$WORK_DIR/managed-cronet"
managed_prerm() {
  FORKOP_UCI_STATE_FILE="$WORK_DIR/stop-order.state" \
  FORKOP_INIT="$WORK_DIR/upgrade-init" \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_BIN="$WORK_DIR/missing-forkop-bin" \
  FORKOP_DNS_APPLY_UC="$WORK_DIR/missing-dns-apply.uc" \
  FORKOP_SING_BOX_INIT="$WORK_DIR/managed-sing-box-init" \
  FORKOP_SING_BOX_BIN="$WORK_DIR/managed-sing-box-bin" \
  FORKOP_SING_BOX_CRONET="$WORK_DIR/managed-cronet" \
  FORKOP_RT_TABLES="$WORK_DIR/rt_tables_upgrade" \
  FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/upgrade-run" \
    ucode -L "$FORKOP_LIB" "$PACKAGE_UC" prerm "$1"
}
managed_prerm upgrade || fail "managed sing-box upgrade prerm exited non-zero"
[ -e "$WORK_DIR/managed-sing-box-init" ] &&
[ -e "$WORK_DIR/managed-sing-box-bin" ] &&
[ -e "$WORK_DIR/managed-cronet" ] ||
  fail "backend upgrade removed a managed sing-box binary variant"
managed_prerm remove || fail "managed sing-box removal prerm exited non-zero"
[ ! -e "$WORK_DIR/managed-sing-box-init" ] &&
[ ! -e "$WORK_DIR/managed-sing-box-bin" ] &&
[ ! -e "$WORK_DIR/managed-cronet" ] ||
  fail "backend removal left managed sing-box files behind"

printf 'package lifecycle checks passed\n'
