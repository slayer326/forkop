#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/run" "$WORK_DIR/lib/dns"
printf 'forkop.settings=settings\n' >"$WORK_DIR/uci.state"
printf 'exit(0);\n' >"$WORK_DIR/lib/dns/apply.uc"
cat >"$WORK_DIR/forkop" <<'SH'
#!/bin/sh
[ "$1" = start ] || exit 50
[ -s "$FORKOP_RELOAD_LOCK_DIR/pid" ] || exit 51
printf 'start\n' >>"$START_TEST_LOG"
exit "${START_TEST_STATUS:-0}"
SH
chmod +x "$WORK_DIR/forkop"

start() {
  env FORKOP_LIB="$WORK_DIR/lib" FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state" \
    FORKOP_UI_ACTION_TRACKED=1 FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
    FORKOP_RELOAD_LOCK_DIR="$WORK_DIR/run/reload.lock" \
    FORKOP_START_RUNTIME_LOCK_WAIT_SECONDS="${START_TEST_WAIT:-0}" \
    FORKOP_BIN="${START_TEST_BIN:-$WORK_DIR/forkop}" \
    START_TEST_LOG="$WORK_DIR/start.log" START_TEST_STATUS="${START_TEST_STATUS:-0}" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/initd.uc" start-service manual "$$"
}

mkdir "$WORK_DIR/run/reload.lock"
printf '%s\n' "$$" >"$WORK_DIR/run/reload.lock/pid"
if start; then fail "start ignored an active reload"; fi
[ ! -e "$WORK_DIR/start.log" ] || fail "blocked start invoked the backend"
[ -s "$WORK_DIR/run/reload.lock/pid" ] || fail "blocked start removed another owner's lock"

(
  sleep 1
  rm "$WORK_DIR/run/reload.lock/pid"
  rmdir "$WORK_DIR/run/reload.lock"
) &
release_pid=$!
START_TEST_WAIT=5 start || fail "start did not resume after reload released its lock"
wait "$release_pid"
[ "$(cat "$WORK_DIR/start.log")" = start ] || fail "backend did not start exactly once"
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "successful start leaked its lock"

# A failed backend may suppress retry; its runtime lock must still be released.
printf 'blocked\n' >"$WORK_DIR/run/start.failure"
status=0
START_TEST_STATUS=23 start || status=$?
[ "$status" = 23 ] || fail "backend failure status was lost"
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "failed start leaked its lock"

if START_TEST_BIN="$WORK_DIR/missing" start; then fail "missing backend was accepted"; fi
[ ! -d "$WORK_DIR/run/reload.lock" ] || fail "missing backend leaked its lock"
printf 'start/reload serialization checks passed\n'
