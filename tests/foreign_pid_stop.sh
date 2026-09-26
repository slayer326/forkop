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
export BYEDPI_STATE_DIR="$STATE_DIR/byedpi"
export BYEDPI_PID_DIR="$BYEDPI_STATE_DIR/pid"
export BYEDPI_CHILD_PID_DIR="$BYEDPI_STATE_DIR/child-pid"
export BYEDPI_LOG_DIR="$BYEDPI_STATE_DIR/log"
export ZAPRET2_STATE_DIR="$STATE_DIR/zapret2"
export ZAPRET2_PID_DIR="$ZAPRET2_STATE_DIR/pid"
export ZAPRET2_CHILD_PID_DIR="$ZAPRET2_STATE_DIR/child-pid"
export ZAPRET2_LOG_DIR="$ZAPRET2_STATE_DIR/log"
mkdir -p "$BYEDPI_PID_DIR" "$BYEDPI_CHILD_PID_DIR" "$BYEDPI_LOG_DIR" "$ZAPRET2_PID_DIR" "$ZAPRET2_CHILD_PID_DIR" "$ZAPRET2_LOG_DIR"

for file in "$FORKOP_DNS_FAILOVER_PID_FILE" "$FORKOP_PRIORITY_PID_FILE" "$BYEDPI_PID_DIR/example.pid" "$BYEDPI_CHILD_PID_DIR/example.pid" "$ZAPRET2_PID_DIR/example.pid" "$ZAPRET2_CHILD_PID_DIR/example.pid"; do
    ucode -L "$LIB_DIR" "$CLI" record "$file" "$foreign_pid"
done

ucode -L "$LIB_DIR" "$LIB_DIR/singbox/dns_failover.uc" stop-runtime
kill -0 "$foreign_pid"
ucode -L "$LIB_DIR" "$LIB_DIR/singbox/priority.uc" stop-runtime
kill -0 "$foreign_pid"
ucode -L "$LIB_DIR" "$LIB_DIR/providers/byedpi/runtime.uc" stop-runtime
kill -0 "$foreign_pid"
ucode -L "$LIB_DIR" "$LIB_DIR/providers/zapret2/runtime.uc" stop-runtime
kill -0 "$foreign_pid"

printf 'foreign_pid_stop: PASS\n'
