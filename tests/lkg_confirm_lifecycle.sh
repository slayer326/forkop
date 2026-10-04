#!/usr/bin/env bash
set -euo pipefail

# A successful start or reload confirms the working configuration as
# last-known-working (config/snapshots.uc confirm-working) only for what that
# start or reload proved (UC-019, UC-020):
#   - the configuration file is still the one it began with (an edit made
#     meanwhile queued a reload of its own and was never run);
#   - no DPI transition guard is installed: neither the one of a restore or
#     an autotune apply (ForkopConfigRestoreDpiGuard) nor the one of a failed
#     lifecycle transition (ForkopTableDpiGuard) protects a runtime that no
#     reload has proved yet.
# confirm-working itself then refuses while an unresolved autotune apply
# names the configuration as its candidate (tests/autotune_apply.sh).
#
# The real service/lifecycle.uc runs against a library where every module
# the start and the reload call is a double that records its call.

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
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/tables" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB/service"
# Copies, not links: the doubles below replace modules inside the library.
cp -R "$LIB/core" "$FAKE_LIB/core"
cp "$LIFECYCLE_UC" "$FAKE_LIB/service/lifecycle.uc"
printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$WORK_DIR/forkop.conf"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export TEST_WORK="$WORK_DIR" TEST_LIB="$LIB" EVENTS
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
# knows only the tables the test installs ($WORK_DIR/tables/<name>).
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "nft $*" >>"$EVENTS"
[ "$1 $2 $3" = "list table inet" ] && [ -e "$TEST_WORK/tables/$4" ]
SH
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nprintf "%%s\\n" "init $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nprintf "%%s\\n" "forkop $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/forkop"
chmod +x "$WORK_DIR/bin/"*

# Every module records "<module> <arguments>" and succeeds, except the state
# predicates that decide the paths; runtime-dir locks go to the real
# service/state.uc. EDIT_DURING=<module mode> edits the configuration when
# that step runs, as a user saving in LuCI meanwhile would.
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
if ((getenv("EDIT_DURING") || "") == name + " " + mode)
    system("printf '%s\\\\n' \"\toption dns_rewrite_ttl '30'\" >> " + q(getenv("FORKOP_CONFIG_FILE")));
if (name == "service/state.uc" && mode == "sing-box-process-conflict")
    exit(1);
if (name == "service/state.uc" && mode == "forkop-stably-running")
    exit(1);
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
  rm -rf "${STATE_DIR:?}"/* "$FORKOP_RELOAD_LOCK_DIR" "$WORK_DIR/tables"/*
  printf "config settings 'settings'\n\toption dns_server '1.1.1.1'\n" >"$WORK_DIR/forkop.conf"
  printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=1\n' \
    >"$WORK_DIR/uci.state"
  unset EDIT_DURING FAKE_RUNNING
}

confirmed() { grep -qx 'config/snapshots.uc confirm-working' "$EVENTS" 2>/dev/null; }
lifecycle() {
  local status=0
  timeout -s KILL 60 ucode -L "$FAKE_LIB" "$FAKE_LIB/service/lifecycle.uc" "$@" >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}
# A reload of a running runtime whose plan has no work: the path the WAN-up
# and other reloads of an unchanged configuration take.
reload_ok() {
  : >"$STATE_DIR/start.explicit"
  export FAKE_RUNNING=1
  [ "$(lifecycle reload wan-up)" = 0 ] || fail "$1: the reload failed"
  grep -q '^service/reload.uc plan-state-files' "$EVENTS" || fail "$1: the reload did not reach its plan"
}

# 1. Controls: a clean start and a clean reload confirm the working
#    configuration, with no argument that would skip the autotune check.
reset_case
[ "$(lifecycle start)" = 0 ] || fail "a clean start failed"
confirmed || fail "a clean start did not confirm the working configuration"
reset_case
reload_ok "clean reload"
confirmed || fail "a clean reload did not confirm the working configuration"

# 2. A DPI transition guard is installed: the start or reload proves nothing
#    for last-known-working. The guard of a restore or autotune apply
#    (ForkopConfigRestoreDpiGuard) is how every such transaction reloads, and
#    the transaction moves last-known-working itself: that is routine and not
#    logged. A leftover guard of a failed lifecycle transition
#    (ForkopTableDpiGuard) refuses the start and the reload altogether
#    (runtime_guard_active; tests/runtime_guard_lifecycle.sh).
not_confirmed_logged() { grep -q 'not confirmed as last known working' "$WORK_DIR/syslog" 2>/dev/null; }
for guard in ForkopTableDpiGuard ForkopConfigRestoreDpiGuard; do
  for action in start reload; do
    reset_case
    : >"$WORK_DIR/tables/$guard"
    if [ "$guard" = ForkopTableDpiGuard ]; then
      : >"$STATE_DIR/start.explicit"
      export FAKE_RUNNING=1
      [ "$(lifecycle "$action" wan-up)" != 0 ] || fail "$guard: the $action succeeded over the kept guard"
      grep -q 'runtime_guard_active' "$WORK_DIR/syslog" || fail "$guard: the $action did not say why it was refused"
    elif [ "$action" = start ]; then
      [ "$(lifecycle start)" = 0 ] || fail "$guard: the start failed"
    else
      reload_ok "$guard"
    fi
    ! confirmed || fail "$guard: the $action confirmed the working configuration under the guard"
    if [ "$guard" = ForkopConfigRestoreDpiGuard ]; then
      ! not_confirmed_logged || fail "$guard: the $action logged the routine transaction guard as a refusal"
    fi
  done
done

# 3. The configuration was edited while the start ran: the start ran the
#    configuration it began with, the edit waits for its queued reload.
reset_case
export EDIT_DURING="nft/apply.uc nft-rebuild-runtime-from-uci"
[ "$(lifecycle start)" = 0 ] || fail "the start with an edit during it failed"
grep -q '^nft/apply.uc nft-rebuild-runtime-from-uci' "$EVENTS" || fail "fixture: the edit step did not run"
! confirmed || fail "the start confirmed a configuration edited while it ran"

echo "lkg_confirm_lifecycle: PASS"
