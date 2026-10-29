#!/usr/bin/env bash
set -euo pipefail

# A stop that overtakes a reload in progress holds for the rest of that
# reload (D-15(a), UC-056).
#
# The reload holds reload.lock; init.d stop_service records the stop request,
# waits for the lock only for a bounded time and then stops without it. The
# reload checked for a stop only when it began: once past that check it
# started the new sing-box, Priority, DNS failover, the new nft table and the
# dnsmasq change after the stop had torn the runtime down,
# and a transition that failed because of the teardown was "rolled back" by
# starting the previous sing-box again. Forkop then showed "Stopped by user"
# with a lone sing-box behind it.
#
# Now every start, commit and rollback step of the reload gives way to a
# recorded stop request: the reload is abandoned, leaves sing-box stopped and
# the teardown to the stop, and reports no failure (the next explicit start
# applies the whole configuration).
#
# The reload is the real service/lifecycle.uc under reload.lock; the stop is
# the real init.d stop_service and service/initd.uc, with a backend that
# stands in for `forkop stop` (tears the modelled runtime down). Locks and
# the stop marker go through the real service/state.uc; sing-box, nft and
# the modules the reload calls are modelled.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
REAL_INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
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

FAKE_LIB="$WORK_DIR/fake-lib"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/run/forkop" "$WORK_DIR/tmp" "$WORK_DIR/singbox-tmp/rulesets" \
  "$FAKE_LIB/service" "$FAKE_LIB/subscription" "$FAKE_LIB/config" "$FAKE_LIB/singbox" "$FAKE_LIB/nft" \
  "$FAKE_LIB/dns" "$FAKE_LIB/components" "$FAKE_LIB/diagnostics"
cat >"$WORK_DIR/uci.state" <<'EOF'
forkop.settings=settings
forkop.settings.yacd_secret_key=0123456789abcdef
forkop.settings.dont_touch_dhcp=0
EOF
: >"$WORK_DIR/forkop.config"
printf 'config dnsmasq\n' >"$WORK_DIR/dhcp"

export TMPDIR="$WORK_DIR/tmp"
export PATH="$WORK_DIR/bin:$PATH"
export EVENTS REAL_LIB REAL_INITD FAKE_LIB
export RELOAD_LOCK="$WORK_DIR/run/forkop.reload.lock"
export SING_BOX_STATE="$WORK_DIR/singbox.state"
export NFT_TABLE_FILE="$WORK_DIR/nft.table"
export STOP_MARKER="$WORK_DIR/run/forkop/stop.requested"
export GATE="$WORK_DIR/gate"
export FORKOP_RELOAD_LOCK_DIR="$RELOAD_LOCK"
export FORKOP_SUBSCRIPTION_UPDATE_LOCK_DIR="$WORK_DIR/run/forkop/subscription-update.lock"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run/forkop"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/forkop/reload.pending"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_DNSMASQ_CONFIG_FILE="$WORK_DIR/dhcp"
export DNSMASQ_INIT="$WORK_DIR/bin/no-init"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK_DIR/run/internal-config-change"
export FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="$WORK_DIR/run/managed-upgrade-sing-box"
export FORKOP_UI_ACTION_TRACKED=1
export TMP_SING_BOX_FOLDER="$WORK_DIR/singbox-tmp"
export TMP_RULESET_FOLDER="$WORK_DIR/singbox-tmp/rulesets"
export FORKOP_SING_BOX_RELOAD_PID_TIMEOUT=2

# Nothing here may reach the host's syslog, firewall or init scripts.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\n' "$WORK_DIR/syslog" >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/ip"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
[ "$1" != -t ] || shift
# Only the production table is modelled: no DPI guard of a failed transition
# or of a restore (ForkopTableDpiGuard, ForkopConfigRestoreDpiGuard).
if [ "$1 $2 $3" = "list table inet" ] && [ "$4" != ForkopTable ]; then
  exit 1
fi
if [ "$1 $2 $3" = "list table inet" ]; then
  [ -e "$NFT_TABLE_FILE" ]
  exit $?
fi
if [ "$1 $2 $3" = "delete table inet" ]; then
  rm -f "$NFT_TABLE_FILE"
fi
[ "$1 $2" != "list chain" ]
SH

# `forkop stop` behind initd.uc: tears the modelled runtime down.
cat >"$WORK_DIR/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  stop)
    printf 'stopped\n' >"$SING_BOX_STATE"
    rm -f "$NFT_TABLE_FILE"
    printf 'stop end\n' >>"$EVENTS"
    ;;
  get_status) printf '{"running":false}\n' ;;
esac
exit 0
SH

# rc.common stand-in: sources the real init script and runs its handler.
cat >"$WORK_DIR/rc" <<'SH'
#!/bin/sh
action="$1"
shift
initscript="$REAL_INITD"
# shellcheck disable=SC1090
. "$REAL_INITD"
FORKOP_LIB="$REAL_LIB"
FORKOP_INITD_UC="$REAL_LIB/service/initd.uc"
case "$action" in
  stop) stop_service "$@" ;;
  *) exit 64 ;;
esac
SH

# init.d holds reload.lock around `forkop reload`; what init.d then finds
# (service/initd.uc reload_service) is recorded before the lock is released.
cat >"$WORK_DIR/reload" <<'SH'
#!/bin/sh
state() { ucode -L "$REAL_LIB" "$REAL_LIB/service/state.uc" "$@"; }
state acquire-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$" || exit 99
env FORKOP_LIB="$FAKE_LIB" ucode -L "$REAL_LIB" "$REAL_LIB/service/lifecycle.uc" reload "$1"
status=$?
printf 'reload returned, sing-box %s\n' "$(cat "$SING_BOX_STATE")" >>"$EVENTS"
state release-runtime-dir-lock "$FORKOP_RELOAD_LOCK_DIR" "$$"
exit "$status"
SH

fake_header='let fs = require("fs");
function q(value) { return "'"'"'" + replace("" + value, /'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'"; }
function ev(line) { system("printf '"'"'%s\\n'"'"' " + q(line) + " >> " + q(getenv("EVENTS"))); }
// The step armed by the test (HOLD_AT) waits for the gate once.
function hold(step) {
    if (getenv("HOLD_AT") != step || fs.stat(getenv("GATE") + ".armed") == null)
        return;
    fs.unlink(getenv("GATE") + ".armed");
    ev("held at " + step);
    for (let n = 0; fs.stat(getenv("GATE")) == null && n < 1200; n++)
        system("sleep 0.05");
}
function running() {
    return trim(fs.readfile(getenv("SING_BOX_STATE")) ?? "") == "running" && fs.stat(getenv("NFT_TABLE_FILE")) != null;
}
let mode = "" + (ARGV[0] ?? "");
'

cat >"$FAKE_LIB/service/state.uc" <<UC
$fake_header
if (index(mode, "runtime-dir-lock") >= 0 || mode == "runtime-apply-allowed" || mode == "stop-requested") {
    let command = "ucode -L " + q(getenv("REAL_LIB")) + " " + q(getenv("REAL_LIB") + "/service/state.uc");
    for (let arg in ARGV)
        command += " " + q(arg);
    exit(system(command));
}
if (mode == "forkop-running" || mode == "forkop-stably-running")
    exit(running() ? 0 : 1);
if (mode == "sing-box-process-conflict")
    exit(1);
if (mode == "stop-managed-sing-box-runtime") {
    ev("stop-managed");
    fs.writefile(getenv("SING_BOX_STATE"), "stopped\n");
    exit(0);
}
if (mode == "start-managed-sing-box-runtime") {
    ev("start-managed");
    fs.writefile(getenv("SING_BOX_STATE"), "running\n");
    exit(0);
}
if (mode == "wait-forkop-stable-start") {
    hold("wait-stable");
    ev("wait-stable " + (running() ? "ok" : "failed"));
    exit(running() ? 0 : 1);
}
if (mode == "sing-box-service-runtime-pid") {
    print("4242\n");
    exit(0);
}
if (mode == "has-list-update-sources" || mode == "has-nft-list-update-sources")
    exit(1);
exit(0);
UC

# The reload plan comes from the test (PLAN: "key=value ...").
cat >"$FAKE_LIB/service/reload.uc" <<UC
$fake_header
if (mode != "plan-state-files")
    exit(0);
for (let item in split(trim(getenv("PLAN") ?? ""), " "))
    if (item != "")
        print(replace(item, "=", "\t"), "\n");
exit(0);
UC

cat >"$FAKE_LIB/service/ui.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/config/validator.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/config/snapshots.uc" <<UC
$fake_header
exit(0);
UC

cat >"$FAKE_LIB/diagnostics/health.uc" <<UC
$fake_header
ev("health " + join(" ", ARGV));
exit(0);
UC

cat >"$FAKE_LIB/subscription/cache.uc" <<UC
$fake_header
exit(mode == "runtime-cache-needs-rebuild" ? 1 : 0);
UC

cat >"$FAKE_LIB/singbox/runtime.uc" <<UC
$fake_header
if (mode == "commit-config-stage") {
    hold("commit-config-stage");
    if (("" + (ARGV[2] ?? "")) != "")
        fs.writefile(ARGV[2], "backup\n");
}
ev("singbox " + mode);
exit(0);
UC

cat >"$FAKE_LIB/nft/apply.uc" <<UC
$fake_header
if (mode == "nft-rebuild-runtime-from-uci")
    hold("nft-rebuild");
if (mode == "remove-dpi-transition-guard")
    hold("dpi-guard-removal");
if (mode == "nft-apply-candidate-batch" || mode == "nft-commit-candidate-batch")
    fs.writefile(getenv("NFT_TABLE_FILE"), "ForkopTable\n");
ev("nft " + mode);
exit(0);
UC

cat >"$FAKE_LIB/dns/apply.uc" <<UC
$fake_header
ev("dns " + mode);
exit(0);
UC

for module in singbox/priority singbox/dns_failover components/updates; do
  name="${module#*/}"
  cat >"$FAKE_LIB/$module.uc" <<UC
$fake_header
if (mode == "snapshot-runtime")
    hold("$name snapshot-runtime");
ev("$name " + mode);
exit(0);
UC
done
chmod +x "$WORK_DIR/bin/"* "$WORK_DIR/rc" "$WORK_DIR/reload"

has_event() { grep -q "$1" "$EVENTS" 2>/dev/null; }

# Whether an event matching $1 follows the event $2.
event_after() {
  awk -v pattern="$1" -v anchor="$2" '
    $0 == anchor { seen = 1; next }
    seen && $0 ~ pattern { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$EVENTS"
}

start_actor() {
  setsid timeout -s KILL 90 "$@" &
  LAST_ACTOR=$!
  actors+=("$LAST_ACTOR")
}

finish() {
  local label="$1" pid="$2" out="$3" status=0
  wait_until 60 process_gone "$pid" || fail "$label did not finish"
  wait "$pid" || status=$?
  [ "$status" = 0 ] || fail "$label failed with status $status: $(cat "$out")"
}

reset_case() {
  : >"$EVENTS"
  : >"$WORK_DIR/syslog"
  rm -f "$GATE" "$GATE.armed" "$STOP_MARKER" "$FORKOP_PENDING_RELOAD_FILE"
  [ ! -e "$RELOAD_LOCK" ] || fail "reload.lock leaked from the previous case"
  printf 'running\n' >"$SING_BOX_STATE"
  printf 'ForkopTable\n' >"$NFT_TABLE_FILE"
}

# The reload runs until it is held at HOLD_AT; a stop that gives up waiting
# for reload.lock after STOP_WAIT seconds tears the runtime down; then the
# reload goes on.
reload_overtaken_by_stop() {
  local plan="$1" hold_at="$2"
  : >"$GATE.armed"
  start_actor env PLAN="$plan" HOLD_AT="$hold_at" "$WORK_DIR/reload" "" >"$WORK_DIR/reload.out" 2>&1
  RELOAD_PID="$LAST_ACTOR"
  wait_until 30 has_event "^held at $hold_at\$" || fail "the reload did not reach $hold_at"
  start_actor env FORKOP_BIN="$WORK_DIR/bin/forkop" FORKOP_LIB="$REAL_LIB" \
    FORKOP_STOP_RUNTIME_LOCK_WAIT_SECONDS="${STOP_WAIT:-1}" sh "$WORK_DIR/rc" stop >"$WORK_DIR/stop.out" 2>&1
  STOP_PID="$LAST_ACTOR"
  if [ "${STOP_WAIT:-1}" -le 1 ]; then
    finish "the stop" "$STOP_PID" "$WORK_DIR/stop.out"
  else
    wait_until 10 test -e "$STOP_MARKER" || fail "the stop did not record its request"
  fi
  : >"$GATE"
  finish "the reload overtaken by the stop" "$RELOAD_PID" "$WORK_DIR/reload.out"
  finish "the stop" "$STOP_PID" "$WORK_DIR/stop.out"
}

assert_nothing_started_after_stop() {
  local label="$1" anchor="${2:-stop end}"
  ! event_after '^start-managed$' "$anchor" || fail "$label: sing-box was started after the stop"
  ! event_after '^(priority|dns_failover) (start-runtime|restore-runtime)$' "$anchor" ||
    fail "$label: an auxiliary runtime was started after the stop"
  ! event_after '^nft nft-(apply|commit)-candidate-batch$' "$anchor" || fail "$label: the nft table was rebuilt after the stop"
  ! event_after '^dns (configure|restore)' "$anchor" || fail "$label: dnsmasq was changed after the stop"
  [ "$(cat "$SING_BOX_STATE")" = stopped ] || fail "$label: sing-box runs after the stop"
  [ ! -e "$NFT_TABLE_FILE" ] || fail "$label: the nft table is back after the stop"
  ! has_event '^health record reload' || fail "$label: the abandoned reload was recorded as a success or a failure"
  grep -q 'reload abandoned' "$WORK_DIR/syslog" || fail "$label: the abandoned reload was not logged"
  [ -e "$STOP_MARKER" ] || fail "$label: the explicit stop is not recorded"
  [ ! -e "$RELOAD_LOCK" ] || fail "$label: reload.lock was left behind"
}

SINGBOX_PLAN="has_work=1 needs_sing_box_reload=1 changed_sing_box=1"
NFT_DNS_PLAN="has_work=1 needs_nft_rebuild=1 needs_dnsmasq_configure=1"

# 0. Controls: without a stop each reload applies its plan.
reset_case
: >"$GATE"
env PLAN="$SINGBOX_PLAN" "$WORK_DIR/reload" "" >"$WORK_DIR/reload.out" 2>&1 || fail "the sing-box reload failed: $(cat "$WORK_DIR/reload.out")"
has_event '^start-managed$' || fail "the sing-box reload did not start the new sing-box"
has_event '^priority start-runtime$' || fail "the sing-box reload did not restart Priority"
reset_case
: >"$GATE"
env PLAN="$NFT_DNS_PLAN" "$WORK_DIR/reload" "" >"$WORK_DIR/reload.out" 2>&1 || fail "the nft reload failed: $(cat "$WORK_DIR/reload.out")"
has_event '^nft nft-apply-candidate-batch$' || fail "the nft reload did not apply the new table"
has_event '^dns configure' || fail "the nft reload did not configure dnsmasq"

# 1. The stop gives up waiting while the reload publishes the new sing-box
#    configuration (sing-box is down): the reload does not start it.
reset_case
reload_overtaken_by_stop "$SINGBOX_PLAN" commit-config-stage
assert_nothing_started_after_stop "stop during the sing-box switch"

# 2. The stop tears the runtime down while the reload verifies the new
#    sing-box: the failed verification is not "rolled back" by starting the
#    previous sing-box again.
reset_case
reload_overtaken_by_stop "$SINGBOX_PLAN" wait-stable
has_event '^wait-stable failed$' || fail "the verification did not see the teardown"
assert_nothing_started_after_stop "stop during the sing-box verification"

# 3. The stop gives up waiting while the reload builds its nft candidate: the
#    candidate is not committed and dnsmasq is not pointed at a stopped
#    sing-box.
reset_case
reload_overtaken_by_stop "$NFT_DNS_PLAN" nft-rebuild
assert_nothing_started_after_stop "stop during the nft rebuild"

# 4. A stop that is still waiting for reload.lock when the reload reaches the
#    sing-box start: the reload does not start it either, and the stop then
#    runs under the lock. The reload leaves sing-box stopped behind, so that
#    init.d tells a snapshot restore "stopped" rather than a reload that ran,
#    before the stop has even begun its teardown.
reset_case
STOP_WAIT=20 reload_overtaken_by_stop "$SINGBOX_PLAN" commit-config-stage
assert_nothing_started_after_stop "stop waiting during the sing-box switch" "held at commit-config-stage"
grep -q 'did not get the runtime lock' "$WORK_DIR/syslog" && fail "the waiting stop did not get reload.lock"
has_event '^reload returned, sing-box stopped$' || fail "the abandoned reload left sing-box running for init.d to report"

printf 'reload overtaken by stop checks passed\n'
