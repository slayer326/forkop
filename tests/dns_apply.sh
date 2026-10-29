#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ROOT_DIR/forkop/files/usr/lib/dns/apply.uc"
UCODE_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
STATE="$WORK_DIR/uci.state"
LOG="$WORK_DIR/uci.log"
DNSMASQ_LOG="$WORK_DIR/dnsmasq.log"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  printf 'UCI state:\n' >&2
  cat "$STATE" >&2 2>/dev/null || true
  printf 'UCI log:\n' >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
}

# The fixture state is read back through core.uci itself, so the test and
# production share one implementation of the state file format (UC-155).
cat >"$WORK_DIR/uci-get.uc" <<'UCODE'
let uci = require("core.uci");
if (!uci.exists(ARGV[0]))
    exit(1);
print(uci.get(ARGV[0]), "\n");
UCODE

cat >"$WORK_DIR/dnsmasq-init" <<'DNSMASQ'
#!/usr/bin/env bash
set -eo pipefail
printf '%s\n' "$*" >> "${DNSMASQ_LOG:?}"
DNSMASQ
chmod 0755 "$WORK_DIR/dnsmasq-init"

export FORKOP_UCI_STATE_FILE="$STATE"
export FORKOP_UCI_LOG_FILE="$LOG"
export DNSMASQ_LOG
export DNSMASQ_INIT="$WORK_DIR/dnsmasq-init"
export FORKOP_CONFIG_NAME="forkop"
export SB_DNS_INBOUND_ADDRESS="127.0.0.42"

if grep -E 'uci -q|command -v uci' "$APPLY" >/dev/null; then
  fail "dns/apply.uc must use ucode UCI access instead of shelling out to uci"
fi

run_restore() {
  : > "$LOG"
  ucode -L "$UCODE_LIB" "$APPLY" failsafe-restore
}

uci_get() {
  ucode -L "$UCODE_LIB" "$WORK_DIR/uci-get.uc" "$1"
}

assert_value() {
  local path="$1"
  local expected="$2"
  local actual

  actual="$(uci_get "$path" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail "$path: expected '$expected', got '$actual'"
}

assert_absent() {
  local path="$1"

  if uci_get "$path" >/dev/null 2>&1; then
    fail "$path: expected option to be absent"
  fi
}

assert_log_contains() {
  local expected="$1"

  grep -Fxq "$expected" "$LOG" || fail "expected log entry '$expected'"
}

assert_log_empty() {
  [ ! -s "$LOG" ] || fail "expected empty log"
}

assert_dnsmasq_restarted() {
  grep -Fxq 'restart' "$DNSMASQ_LOG" || fail "expected dnsmasq restart"
}

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].noresolv=0
dhcp.@dnsmasq[0].cachesize=150
forkop.settings.shutdown_correctly=1
EOF_STATE

: > "$DNSMASQ_LOG"
: > "$LOG"
ucode -L "$UCODE_LIB" "$APPLY" configure force
assert_value 'dhcp.@dnsmasq[0].server' '127.0.0.42'
assert_value 'dhcp.@dnsmasq[0].forkop_server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].forkop_noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_value 'dhcp.@dnsmasq[0].forkop_cachesize' '150'
assert_log_contains 'commit dhcp'
assert_dnsmasq_restarted

: > "$DNSMASQ_LOG"
: > "$LOG"
ucode -L "$UCODE_LIB" "$APPLY" restore force
assert_value 'dhcp.@dnsmasq[0].server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].noresolv' '0'
assert_value 'dhcp.@dnsmasq[0].cachesize' '150'
assert_absent 'dhcp.@dnsmasq[0].forkop_server'
assert_absent 'dhcp.@dnsmasq[0].forkop_noresolv'
assert_absent 'dhcp.@dnsmasq[0].forkop_cachesize'
assert_log_contains 'commit dhcp'
assert_dnsmasq_restarted

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].notinterface=br-lan guest
dhcp.@dnsmasq[0].forkop_server=1.1.1.1 8.8.8.8
dhcp.@dnsmasq[0].forkop_notinterface=wan docker
dhcp.@dnsmasq[0].forkop_noresolv=1
dhcp.@dnsmasq[0].forkop_cachesize=0
dhcp.forkop.interface=br-lan guest
forkop.settings.dont_touch_dhcp=1
EOF_STATE

run_restore
assert_value 'dhcp.@dnsmasq[0].server' '1.1.1.1 8.8.8.8'
assert_value 'dhcp.@dnsmasq[0].notinterface' 'wan docker'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_absent 'dhcp.@dnsmasq[0].forkop_server'
assert_absent 'dhcp.@dnsmasq[0].forkop_notinterface'
assert_absent 'dhcp.@dnsmasq[0].forkop_noresolv'
assert_absent 'dhcp.@dnsmasq[0].forkop_cachesize'
assert_absent 'dhcp.forkop.interface'
assert_log_contains 'commit dhcp'

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=9.9.9.9
forkop.settings.dont_touch_dhcp=1
EOF_STATE

run_restore
assert_value 'dhcp.@dnsmasq[0].server' '9.9.9.9'
assert_log_empty

cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=127.0.0.42
dhcp.@dnsmasq[0].forkop_noresolv=1
dhcp.@dnsmasq[0].forkop_cachesize=0
forkop.settings.dont_touch_dhcp=0
EOF_STATE

run_restore
assert_absent 'dhcp.@dnsmasq[0].server'
assert_value 'dhcp.@dnsmasq[0].noresolv' '1'
assert_value 'dhcp.@dnsmasq[0].cachesize' '0'
assert_absent 'dhcp.@dnsmasq[0].forkop_noresolv'
assert_absent 'dhcp.@dnsmasq[0].forkop_cachesize'
assert_log_contains 'commit dhcp'

# Nothing of Forkop is left: the failsafe neither commits nor restarts
# dnsmasq a second time after the regular restore.
cat >"$STATE" <<'EOF_STATE'
dhcp.@dnsmasq[0].server=9.9.9.9
dhcp.@dnsmasq[0].noresolv=0
forkop.settings.dont_touch_dhcp=0
EOF_STATE

: > "$DNSMASQ_LOG"
run_restore
assert_value 'dhcp.@dnsmasq[0].server' '9.9.9.9'
assert_log_empty
[ ! -s "$DNSMASQ_LOG" ] || fail "dnsmasq was restarted with nothing to roll back"

printf 'DNS apply checks passed\n'
