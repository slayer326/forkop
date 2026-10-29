#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB_DIR="$ROOT_DIR/forkop/files/usr/lib"
CLI="$ROOT_DIR/tests/fixtures/process_identity_cli.uc"
STATE_DIR="$(mktemp -d)"
sleep 300 &
foreign_pid=$!
cleanup() {
    kill "$foreign_pid" 2>/dev/null || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT HUP INT TERM

export FORKOP_LIB="$LIB_DIR"
export FORKOP_RUNTIME_STATE_DIR="$STATE_DIR"
export FORKOP_DNS_FAILOVER_PID_FILE="$STATE_DIR/dns.pid"
export FORKOP_PRIORITY_PID_FILE="$STATE_DIR/priority.pid"

for file in "$FORKOP_DNS_FAILOVER_PID_FILE" "$FORKOP_PRIORITY_PID_FILE"; do
    ucode -L "$LIB_DIR" "$CLI" record "$file" "$foreign_pid"
done

ucode -L "$LIB_DIR" "$LIB_DIR/singbox/dns_failover.uc" stop-runtime
kill -0 "$foreign_pid"
ucode -L "$LIB_DIR" "$LIB_DIR/singbox/priority.uc" stop-runtime
kill -0 "$foreign_pid"

printf 'foreign_pid_stop: PASS\n'
