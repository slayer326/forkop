#!/bin/sh
set -eu

# Run only on a healthy OpenWrt test installation. This creates and removes
# only its own short-lived BusyBox process; it never changes Forkop or nftables.
lib="${FORKOP_LIB:-/usr/lib/forkop}"
work="$(mktemp -d)"
child=""
cleanup() {
    if [ -n "$child" ]; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
state() { ucode -L "$lib" "$lib/service/state.uc" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

state sing-box-single-owned-service-runtime || fail 'baseline is not owned'
expected="$(state sing-box-service-runtime-pid)"
cp /bin/busybox "$work/sing-box"
ln -s sing-box "$work/busybox"

"$work/busybox" sh -c 'sleep 2' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'transient process was not observed'
state sing-box-process-conflict && fail 'transient process blocked ownership'
wait "$child"
child=""

"$work/busybox" sh -c 'sleep 2' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'UI transient was not observed'
ucode -L "$lib" "$lib/service/ui.uc" get-ui-state >"$work/ui.json"
wait "$child"
child=""
[ "$(jsonfilter -i "$work/ui.json" -e '@.service.forkop.restart_blocked')" = 0 ] ||
    fail 'UI retained a transient restart block'
[ "$(jsonfilter -i "$work/ui.json" -e '@.service.forkop.running')" = 1 ] ||
    fail 'UI returned a stale stopped state'

"$work/busybox" sh -c 'sleep 30' &
child=$!
[ "$(state sing-box-process-count)" = 2 ] || fail 'persistent process was not observed'
state sing-box-process-conflict || fail 'persistent process was accepted'
kill "$child"
wait "$child" 2>/dev/null || true
child=""
[ "$(state sing-box-service-runtime-pid)" = "$expected" ] || fail 'service PID changed'
state sing-box-single-owned-service-runtime || fail 'baseline did not recover'
echo 'transient and persistent sing-box ownership checks passed'
