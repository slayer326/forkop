#!/usr/bin/env bash
set -euo pipefail

# A fail-closed guard that a failed lifecycle transition kept (UC-019):
#   - ForkopTableDpiGuard: a reload whose DPI rollback failed keeps it
#     (service/lifecycle.uc abort_reload);
#   - the forkop_transition_guard chain in ForkopTable: a sing-box
#     transition whose rollback failed keeps it (abort_guarded_transition).
# Both are installed create-only and drop the traffic they guard until a
# stop removes them. A reload over them used to run a plan that never looks
# at them: one that restarts DPI failed at the create-only install every
# time, one that does not reported success while the guard still dropped
# DPI traffic. A duplicate start reported the running runtime as started.
#
# Now a reload and a start refuse with the explicit reason
# runtime_guard_active; the recovery is a restart, whose stop removes the
# guard before the start. A reload of an incomplete runtime is that restart
# already (restart_runtime_for_reload): it goes on and removes the guard, as
# before, instead of leaving the whole runtime down until someone restarts.
# A refused start is not retried automatically (initd.uc start_service): no
# retry can succeed before the restart, and each would log a fatal and
# record a failed start. The guard of a restore or an autotune apply
# (ForkopConfigRestoreDpiGuard) is how every such transaction reloads: the
# reload goes on under it, a cold start builds the runtime (the restore of
# a snapshot releases that guard), and only a duplicate start, which starts
# nothing, refuses to report the guarded runtime as started.
#
# The real service/lifecycle.uc runs against a library where every module
# the start, the reload and the restart call is a double that records its
# call; nft knows the tables and chains the test installs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
LIFECYCLE_UC="$LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  pkill -KILL -f "$WORK_DIR" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK_DIR/events"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  if [ -s "$EVENTS" ]; then
    sed 's/^/  event: /' "$EVENTS" >&2
  fi
  if [ -s "$WORK_DIR/syslog" ]; then
    sed 's/^/  syslog: /' "$WORK_DIR/syslog" >&2
  fi
  exit 1
}

FAKE_LIB="$WORK_DIR/lib"
STATE_DIR="$WORK_DIR/run/forkop"
TABLES="$WORK_DIR/tables"
mkdir -p "$WORK_DIR/bin" "$TABLES" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB/service"
# Copies, not links: the doubles below replace modules inside the library.
cp -R "$LIB/core" "$FAKE_LIB/core"
cp "$LIFECYCLE_UC" "$FAKE_LIB/service/lifecycle.uc"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" TEST_LIB="$LIB" EVENTS TABLES
export FORKOP_LIB="$FAKE_LIB"
export FORKOP_BIN="$WORK_DIR/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/init"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.conf"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_PENDING_RELOAD_FILE="$STATE_DIR/reload.pending"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/forkop.internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export TMP_SING_BOX_FOLDER="$WORK_DIR/tmp/sing-box"
export FORKOP_UI_ACTION_TRACKED=1

# Nothing here may reach the host's syslog, nftables or init scripts. nft
# knows only what the test installs: a table is $TABLES/<table>, a chain is
# $TABLES/<table>.<chain>; deleting a table deletes its chains.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "nft $*" >>"$EVENTS"
case "$1 $2 $3" in
  "list table inet") [ -e "$TABLES/$4" ] ;;
  "list chain inet") [ -e "$TABLES/$4.$5" ] ;;
  "delete table inet") rm -f "$TABLES/$4" "$TABLES/$4".*; exit 0 ;;
  *) exit 0 ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nprintf "%%s\\n" "init $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nprintf "%%s\\n" "forkop $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/forkop"
chmod +x "$WORK_DIR/bin/"*

# Every module records "<module> <arguments>" and succeeds, except the state
# predicates that decide the paths; runtime-dir locks go to the real
# service/state.uc. The nft double removes what the lifecycle removes: the
# DPI guard table (remove-dpi-transition-guard) and, as the real rebuild
# does, the production table with its chains (nft-rebuild-runtime-from-uci).
fake_module() {
  mkdir -p "$(dirname "$FAKE_LIB/$1")"
  cat >"$FAKE_LIB/$1" <<UC
function q(value) { return "'" + replace("" + value, /'/g, "'\\\\''") + "'"; }
let mode = "" + (ARGV[0] ?? "");
let name = "$1";
if (name == "service/state.uc" && index(mode, "runtime-dir-lock") >= 0) {
    let command = "ucode -L " + q(getenv("TEST_LIB")) + " " + q(getenv("TEST_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
system("printf '%s\\\\n' " + q(name + " " + join(" ", ARGV)) + " >> " + q(getenv("EVENTS")));
let tables = getenv("TABLES");
if (name == "nft/apply.uc" && mode == "remove-dpi-transition-guard")
    system("rm -f " + q(tables + "/" + ARGV[1] + "DpiGuard"));
if (name == "nft/apply.uc" && mode == "nft-rebuild-runtime-from-uci")
    system("rm -f " + q(tables + "/ForkopTable") + " " + q(tables) + "/ForkopTable.*");
if (name == "service/state.uc" && mode == "sing-box-process-conflict")
    exit(1);
if (name == "service/state.uc" && mode == "forkop-stably-running")
    exit((getenv("FAKE_STABLE") || "") == "1" ? 0 : 1);
if (name == "service/state.uc" && mode == "forkop-running")
    exit((getenv("FAKE_RUNNING") || "") == "1" ? 0 : 1);
if (name == "service/state.uc" && mode == "has-list-update-sources")
    exit(1);
if (name == "singbox/ruleset_cache.uc" && mode == "refresh-if-due")
    exit(1);
exit(0);
UC
}
for module in service/state.uc subscription/cache.uc config/validator.uc nft/apply.uc singbox/runtime.uc singbox/generator.uc \
  singbox/priority.uc singbox/dns_failover.uc singbox/ruleset_cache.uc components/updates.uc \
  autotune/manager.uc providers/byedpi/runtime.uc providers/zapret/runtime.uc providers/zapret2/runtime.uc \
  dns/apply.uc diagnostics/runtime.uc diagnostics/health.uc config/snapshots.uc core/packages.uc \
  service/ui.uc service/reload.uc; do
  fake_module "$module"
done

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -rf "${STATE_DIR:?}"/* "$FORKOP_RELOAD_LOCK_DIR" "${TABLES:?}"/*
  printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$WORK_DIR/forkop.conf"
  printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=1\n' \
    >"$WORK_DIR/uci.state"
  : >"$STATE_DIR/start.explicit"
  : >"$TABLES/ForkopTable"
  unset FAKE_RUNNING FAKE_STABLE
}

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }
confirmed() { grep -qx 'config/snapshots.uc confirm-working' "$EVENTS" 2>/dev/null; }
logged() { grep -q "$1" "$WORK_DIR/syslog" 2>/dev/null; }
lifecycle() {
  local status=0
  timeout -s KILL 60 ucode -L "$FAKE_LIB" "$FAKE_LIB/service/lifecycle.uc" "$@" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}
kept_dpi_guard() { : >"$TABLES/ForkopTableDpiGuard"; }
kept_transition_guard() { : >"$TABLES/ForkopTable.forkop_transition_guard"; }
restore_guard() { : >"$TABLES/ForkopConfigRestoreDpiGuard"; }

# A refused reload or start touched nothing: no plan, no DPI switch, no
# teardown or rebuild, no confirmation; it says why and what recovers.
refused_untouched() {
  local what="$1" status="$2"
  [ "$status" != 0 ] || fail "$what: succeeded while a failed transition kept its guard"
  ! has_event '^service/reload.uc plan-state-files' || fail "$what: planned a reload over the kept guard"
  ! has_event '^nft/apply.uc install-dpi-transition-guard' || fail "$what: tried the create-only DPI guard install"
  ! has_event '^nft/apply.uc remove-dpi-transition-guard' || fail "$what: removed the kept guard"
  ! has_event '^nft/apply.uc nft-rebuild-runtime-from-uci' || fail "$what: rebuilt the policy under the kept guard"
  ! has_event '^providers/.* \(stop\|start\)-runtime' || fail "$what: switched a DPI runtime"
  ! has_event '^service/state.uc stop-managed-sing-box-runtime' || fail "$what: stopped sing-box"
  ! confirmed || fail "$what: confirmed the working configuration"
  logged 'runtime_guard_active' || fail "$what: did not log the reason runtime_guard_active"
}

# 1. Controls: without a guard the reload and a duplicate start succeed.
reset_case
export FAKE_RUNNING=1
[ "$(lifecycle reload wan-up)" = 0 ] || fail "control: a clean reload failed"
has_event '^service/reload.uc plan-state-files' || fail "control: the clean reload did not reach its plan"
reset_case
export FAKE_STABLE=1
[ "$(lifecycle start)" = 0 ] || fail "control: a clean duplicate start failed"
logged 'already stably running' || fail "control: the duplicate start did not take the stable path"

# 2. The DPI guard of a failed DPI rollback is kept. A reload of the running
#    runtime is refused, a cold start and a duplicate start too; the guard
#    stays, and the refused start leaves the marker that keeps init.d from
#    retrying it.
reset_case
kept_dpi_guard
export FAKE_RUNNING=1
refused_untouched "reload under the kept DPI guard" "$(lifecycle reload wan-up)"
logged 'restart Forkop' || fail "reload under the kept DPI guard: no restart guidance in the log"
[ -e "$TABLES/ForkopTableDpiGuard" ] || fail "reload removed the kept DPI guard"
for stable in 0 1; do
  reset_case
  kept_dpi_guard
  [ "$stable" = 1 ] && export FAKE_STABLE=1
  refused_untouched "start (stable=$stable) under the kept DPI guard" "$(lifecycle start)"
  logged 'restart Forkop' || fail "start (stable=$stable) under the kept DPI guard: no restart guidance in the log"
  has_event '^diagnostics/health.uc record start failure' || fail "start (stable=$stable): the refusal was not recorded as a failed start"
  [ -e "$TABLES/ForkopTableDpiGuard" ] || fail "start (stable=$stable) removed the kept DPI guard"
  grep -qx 'reason=runtime_guard_active' "$STATE_DIR/start.failure" 2>/dev/null ||
    fail "start (stable=$stable): the refusal did not mark the start as not to be retried"
done

# 2b. A reload of an incomplete runtime under the kept DPI guard restarts
#     the runtime: its stop removes the guard, as the restart the page names
#     does, and the start builds the runtime again.
reset_case
kept_dpi_guard
[ "$(lifecycle reload wan-up)" = 0 ] || fail "a reload of an incomplete runtime under the kept DPI guard failed"
logged 'restarting Forkop runtime' || fail "the reload of an incomplete runtime did not restart it"
[ ! -e "$TABLES/ForkopTableDpiGuard" ] || fail "the restart of an incomplete runtime left the kept DPI guard"
has_event '^nft/apply.uc nft-rebuild-runtime-from-uci' || fail "the restart of an incomplete runtime did not build it again"
! has_event '^service/reload.uc plan-state-files' || fail "the reload of an incomplete runtime planned a reload over the guard"

# 2c. init.d does not retry a start refused for the kept guard: no retry is
#     scheduled, the log says why. The start the retry would run is the real
#     lifecycle start behind the real service/initd.uc start-service.
reset_case
kept_dpi_guard
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
printf '%s\n' "forkop $*" >>"$EVENTS"
exec ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/lifecycle.uc" "$@"
SH
status=0
env FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS=0 FORKOP_START_RETRY_DELAY_SECONDS=300 \
  timeout -s KILL 60 ucode -L "$LIB" "$LIB/service/initd.uc" start-service triggered "$$" >/dev/null 2>&1 || status=$?
printf '#!/bin/sh\nprintf "%%s\\n" "forkop $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/forkop"
[ "$status" != 0 ] || fail "init.d start under the kept DPI guard succeeded"
has_event '^forkop start' || fail "init.d start did not run the lifecycle start"
[ ! -e "$STATE_DIR/start.retry" ] || fail "init.d scheduled a retry of a start refused for the kept guard"
[ ! -e "$STATE_DIR/start-retry.pid" ] || fail "init.d launched a retry of a start refused for the kept guard"
logged 'retry suppressed.*runtime_guard_active' || fail "init.d did not log why the start is not retried"

# 3. The transition guard chain of a failed sing-box rollback is kept: a
#    reload and a duplicate start are refused. A cold start rebuilds the
#    production table, and with it the chain, from the configuration.
reset_case
kept_transition_guard
export FAKE_RUNNING=1
refused_untouched "reload under the kept transition guard" "$(lifecycle reload wan-up)"
reset_case
kept_transition_guard
export FAKE_STABLE=1
refused_untouched "duplicate start under the kept transition guard" "$(lifecycle start)"
logged 'failed-transition guard is still active' || fail "duplicate start under the transition guard: refusal not described"
reset_case
kept_transition_guard
[ "$(lifecycle start)" = 0 ] || fail "a cold start over a kept transition chain failed"
[ ! -e "$TABLES/ForkopTable.forkop_transition_guard" ] || fail "fixture: the cold start did not rebuild the production table"
confirmed || fail "a cold start that rebuilt the production table did not confirm"

# 4. The recovery the page names: a restart. Its stop removes the kept DPI
#    guard and the production table, the start builds the runtime again.
reset_case
kept_dpi_guard
kept_transition_guard
export FAKE_STABLE=1
[ "$(lifecycle restart)" = 0 ] || fail "the restart did not recover from the kept guards"
[ ! -e "$TABLES/ForkopTableDpiGuard" ] || fail "the restart left the kept DPI guard"
[ ! -e "$TABLES/ForkopTable.forkop_transition_guard" ] || fail "the restart left the kept transition chain"
has_event '^nft/apply.uc nft-rebuild-runtime-from-uci' || fail "the restart did not build the runtime again"

# 5. The guard of a restore that ended needs_attention: a reload goes on
#    under it (every restore reloads so) and a cold start builds the
#    runtime; neither confirms. A duplicate start starts nothing and does not
#    report the guarded runtime as started; it names the recovery.
reset_case
restore_guard
export FAKE_RUNNING=1
[ "$(lifecycle reload config-restore)" = 0 ] || fail "a reload under the restore guard was refused"
has_event '^service/reload.uc plan-state-files' || fail "the reload under the restore guard did not reach its plan"
! confirmed || fail "the reload under the restore guard confirmed the working configuration"
reset_case
restore_guard
[ "$(lifecycle start)" = 0 ] || fail "a cold start under the restore guard was refused"
! confirmed || fail "the cold start under the restore guard confirmed the working configuration"
reset_case
restore_guard
export FAKE_STABLE=1
status="$(lifecycle start)"
[ "$status" != 0 ] || fail "a duplicate start reported the runtime under the restore guard as started"
logged 'runtime_guard_active' || fail "duplicate start under the restore guard: reason not logged"
logged 'restore the last known working snapshot' || fail "duplicate start under the restore guard: no recovery named"
! confirmed || fail "duplicate start under the restore guard confirmed the working configuration"
[ -e "$TABLES/ForkopConfigRestoreDpiGuard" ] || fail "duplicate start removed the restore guard"

echo "runtime_guard_lifecycle: PASS"
