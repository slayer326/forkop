#!/usr/bin/env bash
set -euo pipefail

# `forkop main` is a compatibility alias of the protected start (UC-015).
#
# The command once ran start_main() directly: it rebuilt the working nftables
# table, rewrote the sing-box configuration and cron, and started sing-box
# without the gates of start_inner() (managed-upgrade provenance, ambiguous
# sing-box ownership, the retained failed-transition guard), without cleanup
# on failure and without a health record. The command name and its arity stay,
# but it has to be the very same path as `forkop start`.
#
# The real /usr/bin/forkop and service/lifecycle.uc run against a library
# where every module the start calls is a double that records its call.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
FORKOP_CLI="$ROOT_DIR/forkop/files/usr/bin/forkop"
LIFECYCLE_UC="$LIB/service/lifecycle.uc"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

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

# 1. Static: the dispatcher routes `main` to the lifecycle start, and
#    start_main() has exactly one caller, start_impl(), which only
#    start_inner() reaches after its gates.
source_require "$FORKOP_CLI" "$LIFECYCLE_UC"
grep -Eq '^[[:space:]]*main: \[ "service/lifecycle\.uc", "start", 0 \],$' "$FORKOP_CLI" ||
  fail "forkop main must dispatch to the lifecycle start with no arguments"
callers="$(awk '
  BEGIN { name = "<top level>" }
  /^function [A-Za-z0-9_]+\(/ { name = $2; sub(/\(.*/, "", name); next }
  /^}/ { name = "<top level>"; next }
  /start_main\(\)/ && !/^[[:space:]]*\/\// { print name }
' "$LIFECYCLE_UC")"
[ "$callers" = "start_impl" ] ||
  fail "start_main() must only be called from start_impl(), found callers: $(printf '%s' "$callers" | tr '\n' ' ')"

# 2. Behaviour.
FAKE_LIB="$WORK_DIR/lib"
STATE_DIR="$WORK_DIR/run/forkop"
mkdir -p "$WORK_DIR/bin" "$STATE_DIR" "$WORK_DIR/tmp" "$FAKE_LIB/service"
# Copies, not links: the doubles below replace modules inside the library.
cp -R "$LIB/core" "$FAKE_LIB/core"
cp "$LIFECYCLE_UC" "$FAKE_LIB/service/lifecycle.uc"
: >"$WORK_DIR/forkop.conf"

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

# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$TEST_WORK/syslog"\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nprintf "%%s\\n" "nft $*" >>"$EVENTS"\nexit 1\n' >"$WORK_DIR/bin/nft"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
printf '#!/bin/sh\nprintf "%%s\\n" "init $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/init"
printf '#!/bin/sh\nprintf "%%s\\n" "forkop $*" >>"$EVENTS"\nexit 0\n' >"$WORK_DIR/bin/forkop"
chmod +x "$WORK_DIR/bin/"*

# Every module the start calls records "<module> <mode>" and succeeds, except
# the state predicates that decide the gates; runtime-dir locks go to the real
# service/state.uc.
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
if (name == "diagnostics/health.uc")
    mode = join(" ", ARGV);
system("printf '%s\\\\n' " + q(name + " " + mode) + " >> " + q(getenv("EVENTS")));
if (name == "service/state.uc" && mode == "sing-box-process-conflict")
    exit((getenv("FAKE_CONFLICT") || "") == "1" ? 0 : 1);
if (name == "service/state.uc" && mode == "forkop-stably-running")
    exit((getenv("FAKE_STABLE") || "") == "1" ? 0 : 1);
if (name == "service/state.uc" && (mode == "has-list-update-sources" || mode == "forkop-running"))
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
  rm -rf "${STATE_DIR:?}"/* "$FORKOP_RELOAD_LOCK_DIR"
  printf 'forkop.settings=settings\nforkop.settings.yacd_secret_key=0123456789abcdef\nforkop.settings.dont_touch_dhcp=1\n' \
    >"$WORK_DIR/uci.state"
}

has_event() { grep -qx "$1" "$EVENTS" 2>/dev/null; }
no_event() { ! grep -q "$1" "$EVENTS" 2>/dev/null; }

# run_cli COMMAND [CONFLICT [STABLE]]: runs the real CLI with an ambiguous
# sing-box (CONFLICT=1) and/or a stably running runtime (STABLE=1); prints
# its exit status.
run_cli() {
  local status=0
  FAKE_CONFLICT="${2:-0}" FAKE_STABLE="${3:-0}" timeout -s KILL 60 ucode "$FORKOP_CLI" "$1" >/dev/null 2>&1 ||
    status=$?
  printf '%s\n' "$status"
}

# 2a. An ambiguous sing-box: `forkop main` refuses like `forkop start`,
#     before any mutation, and records the failed start.
reset_case
status="$(run_cli main 1)"
[ "$status" != 0 ] || fail "forkop main succeeded while sing-box ownership is ambiguous"
has_event "service/state.uc sing-box-process-conflict" || fail "forkop main skipped the sing-box ownership gate"
no_event '^nft/apply.uc' || fail "forkop main touched the nftables policy while sing-box ownership is ambiguous"
no_event '^nft ' || fail "forkop main ran nft while sing-box ownership is ambiguous"
no_event '^singbox/runtime.uc' || fail "forkop main rewrote the sing-box configuration while ownership is ambiguous"
no_event '^components/updates.uc' || fail "forkop main refreshed cron while sing-box ownership is ambiguous"
no_event '^providers/byedpi/runtime.uc' || fail "forkop main started ByeDPI while sing-box ownership is ambiguous"
no_event '^service/state.uc start-managed-sing-box-runtime' || fail "forkop main started sing-box while ownership is ambiguous"
grep -q 'Refusing Forkop start: sing-box process ownership is ambiguous' "$WORK_DIR/syslog" ||
  fail "forkop main did not log the ownership refusal"
has_event "diagnostics/health.uc record start failure" || fail "the refused forkop main was not recorded as a failed start"
[ ! -e "$STATE_DIR/start.in-progress" ] || fail "the refused forkop main left its start marker"
main_refused="$(cat "$EVENTS")"
reset_case
start_status="$(run_cli start 1)"
[ "$start_status" = "$status" ] || fail "forkop main exited $status where forkop start exited $start_status"
[ "$(cat "$EVENTS")" = "$main_refused" ] || fail "forkop main did not take the same path as forkop start"

# 2b. The failed-transition guard of a coordinated rollback is still in
#     place: a stably running runtime is not rebuilt under it.
reset_case
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "nft $*" >>"$EVENTS"
[ "$*" = "list chain inet ForkopTable forkop_transition_guard" ]
SH
status="$(run_cli main 0 1)"
[ "$status" != 0 ] || fail "forkop main succeeded under the failed-transition guard"
has_event "nft list chain inet ForkopTable forkop_transition_guard" || fail "forkop main did not look for the failed-transition guard"
no_event '^nft/apply.uc' || fail "forkop main rebuilt the nftables policy under the failed-transition guard"
grep -q 'failed-transition guard is still active' "$WORK_DIR/syslog" ||
  fail "forkop main did not log the failed-transition guard refusal"
printf '#!/bin/sh\nprintf "%%s\\n" "nft $*" >>"$EVENTS"\nexit 1\n' >"$WORK_DIR/bin/nft"

# 2c. Control: a clean runtime starts through the full start, with its health
#     record and the working-config confirmation.
reset_case
status="$(run_cli main 0)"
[ "$status" = 0 ] || fail "forkop main failed on a clean runtime (status $status)"
has_event "service/state.uc sing-box-process-conflict" || fail "forkop main did not check sing-box ownership"
has_event "nft/apply.uc nft-rebuild-runtime-from-uci" || fail "forkop main did not build the nftables policy"
has_event "service/state.uc start-managed-sing-box-runtime" || fail "forkop main did not start sing-box"
has_event "diagnostics/health.uc record start success" || fail "forkop main was not recorded as a successful start"
has_event "config/snapshots.uc confirm-working" || fail "forkop main did not confirm the working configuration"

# 3. The loader treats the alias like start: a missing lifecycle module
#    restores the dnsmasq fail-safe.
MISSING_LIB="$WORK_DIR/missing-lib"
mkdir -p "$MISSING_LIB/dns"
cat >"$MISSING_LIB/dns/apply.uc" <<'UC'
let marker = getenv("FORKOP_TEST_DNS_RESTORE_MARKER");
if (marker != null && marker != "")
    require("fs").writefile(marker, ARGV[0] || "");
UC
status=0
FORKOP_TEST_DNS_RESTORE_MARKER="$WORK_DIR/dns-restore.marker" FORKOP_LIB="$MISSING_LIB" \
  ucode "$FORKOP_CLI" main >/dev/null 2>&1 || status=$?
[ "$status" != 0 ] || fail "forkop main without the lifecycle module succeeded"
[ "$(cat "$WORK_DIR/dns-restore.marker" 2>/dev/null)" = failsafe-restore ] ||
  fail "forkop main without the lifecycle module did not restore the dnsmasq fail-safe"

printf 'forkop main alias checks passed\n'
