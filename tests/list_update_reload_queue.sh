#!/usr/bin/env bash
set -euo pipefail

# Reloads that arrive while a list update runs are queued and run after it
# (UC-057 follow-up).
#
# A list update reads its sources when it starts and applies them only in
# its final list-content reload. It used to hold reload.lock for its whole
# run, so init.d queued every reload that arrived meanwhile in reload.pending
# and the worker ran it when it ended. The DNS probe and the downloads now
# run without reload.lock; a reload that ran during them at once:
#
# A. A list source changed during a scheduled update: the reload started a
#    list update that the running one refused ("already running"), and the
#    running one then discarded its generation for the old sources. Nothing
#    downloaded the new sources until the next scheduled update.
# B. During an update that a list-source reload started, an unrelated reload
#    became a list-content reload (the list worker owns the final apply) and
#    failed: the generation for the new sources did not exist yet.
# C. The worker also runs the reloads it queued when it gives up waiting for
#    reload.lock after its downloads.
#
# The worker is the real components/updates.uc; reloads go through the real
# init.d script and service/initd.uc. The lifecycle reload itself is a
# stand-in with the list parts of service/lifecycle.uc reload(): a pending
# list apply turns a reload into list-content, which rebuilds the rule sets
# from the active generation (the real apply-list-cache); a changed list
# source defers the apply to a new list-update worker.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_LIB="$ROOT_DIR/forkop/files/usr/lib"
INITD="$ROOT_DIR/forkop/files/etc/init.d/forkop"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

cleanup() {
  local pid
  : >"$WORK/stop"
  if [ -s "$WORK/bg.pids" ]; then
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
    done <"$WORK/bg.pids"
  fi
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

EVENTS="$WORK/events"
RUN="$WORK/run"
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$EVENTS" ] || sed 's/^/  event: /' "$EVENTS" >&2
  [ ! -s "$WORK/worker.log" ] || sed 's/^/  worker: /' "$WORK/worker.log" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$RUN"
: >"$EVENTS"
: >"$WORK/bg.pids"

# A library with the real modules and a rule-set cache that changes nothing.
LIB="$WORK/lib"
mkdir -p "$LIB/singbox"
for entry in "$REAL_LIB"/*; do [ "${entry##*/}" = singbox ] || ln -s "$entry" "$LIB/${entry##*/}"; done
for entry in "$REAL_LIB"/singbox/*; do ln -s "$entry" "$LIB/singbox/${entry##*/}"; done
rm "$LIB/singbox/ruleset_cache.uc"
printf 'exit(1);\n' >"$LIB/singbox/ruleset_cache.uc"

export WORK EVENTS REAL_UCODE REAL_INITD="$INITD" TEST_LIB="$LIB"
export PATH="$WORK/bin:$PATH"
export FORKOP_LIB="$LIB"
export FORKOP_BIN="$WORK/bin/forkop"
export FORKOP_SERVICE_INIT="$WORK/init.d"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state"
export FORKOP_RUNTIME_STATE_DIR="$RUN"
export FORKOP_RELOAD_LOCK_DIR="$RUN/reload.lock"
export FORKOP_PENDING_RELOAD_FILE="$RUN/reload.pending"
export FORKOP_LIST_UPDATE_PID_FILE="$RUN/list.pid"
export FORKOP_INTERNAL_CONFIG_TRIGGER_GUARD="$WORK/internal-config-change"
export FORKOP_RUNTIME_LIST_GENERATION_DIR="$WORK/generation"
export FORKOP_PERSISTENT_LIST_CACHE_DIR="$WORK/cache"
export FORKOP_RULESET_CACHE_DIR="$WORK/ruleset-cache"
export TMP_RULESET_FOLDER="$WORK/rulesets"
export NFT_TABLE_NAME=forkop
MARKER="$RUN/list-update.reload"
RULESET="$WORK/rulesets/alpha-remote-domains-ruleset.json"

# UI jobs and the dnsmasq fail-safe are outside this contract. With
# $WORK/lock.timeout present, a wait for reload.lock times out at once.
cat >"$WORK/bin/ucode" <<'SH'
#!/bin/sh
case "${3:-}" in
  */service/ui.uc|*/dns/apply.uc) exit 0 ;;
  */service/state.uc)
    if [ "${4:-}" = acquire-runtime-dir-lock-wait ] && [ -e "$WORK/lock.timeout" ]; then
      exit 1
    fi ;;
  */service/lifecycle.uc)
    [ "${4:-}" = reload ] && exec "$FORKOP_BIN" reload "${5:-}"
    ;;
esac
exec "$REAL_UCODE" "$@"
SH
cat >"$WORK/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
# A download of <name> waits while $WORK/hold.<name> exists.
cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
url=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
name="${url##*/}"
printf 'download %s\n' "$name" >>"$EVENTS"
if [ -e "$WORK/hold.$name" ]; then
  : >"$WORK/in.$name"
  while [ -e "$WORK/hold.$name" ] && [ ! -e "$WORK/stop" ]; do sleep 0.05; done
fi
printf '%s.example\n' "${name%.txt}" >"$output"
SH
cat >"$WORK/bin/nft" <<'SH'
#!/bin/sh
[ "$*" = '-j list table inet forkop' ] && printf '{"nftables":[]}\n'
exit 0
SH
cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$WORK/log"
SH
# The lifecycle reload (see the header).
cat >"$WORK/bin/forkop" <<'SH'
#!/bin/sh
case "$1" in
  get_status) printf '{"running":true}\n'; exit 0 ;;
  reload) ;;
  *) exit 0 ;;
esac
reason="${2:-}"
if [ "$reason" != list-content ] && [ -e "$FORKOP_RUNTIME_STATE_DIR/list-update.reload" ]; then
  reason=list-content
fi
printf 'reload %s\n' "$reason" >>"$EVENTS"
if [ "$reason" = list-content ]; then
  if ! ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" apply-list-cache >/dev/null 2>&1; then
    printf 'list-content apply failed\n' >>"$EVENTS"
    exit 1
  fi
  rm -f "$FORKOP_RUNTIME_STATE_DIR/list-update.reload" "$WORK/sources.changed"
  printf 'list-content applied\n' >>"$EVENTS"
  exit 0
fi
if [ -e "$WORK/sources.changed" ]; then
  rm -f "$WORK/sources.changed"
  printf '1\n' >"$FORKOP_RUNTIME_STATE_DIR/list-update.reload"
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" list-update </dev/null >>"$WORK/worker.log" 2>&1 &
  printf '%s\n' "$!" >>"$WORK/bg.pids"
  printf 'list worker started\n' >>"$EVENTS"
fi
exit 0
SH
# rc.common stand-in: `<init> reload [reason]` runs the real init script's
# reload_service, as OpenWrt's rc.common does.
cat >"$WORK/init.d" <<'SH'
#!/bin/sh
action="$1"; shift
initscript="$REAL_INITD"
. "$REAL_INITD"
FORKOP_LIB="$TEST_LIB"
FORKOP_INITD_UC="$TEST_LIB/service/initd.uc"
[ "$action" = reload ] || exit 1
reload_service "$@"
SH
chmod +x "$WORK/bin/"* "$WORK/init.d"

set_source() {
  cat >"$WORK/uci.state" <<UCI
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/$1
UCI
}

reset_state() {
  : >"$EVENTS"
  : >"$WORK/worker.log"
  : >"$WORK/log"
  rm -rf "$WORK/generation" "$WORK/cache" "$WORK/ruleset-cache" "$WORK/rulesets" "${RUN:?}"/*
  rm -f "$WORK"/hold.* "$WORK"/in.* "$WORK/sources.changed" "$WORK/lock.timeout"
  mkdir -p "$WORK/cache" "$WORK/rulesets"
}

list_worker() {
  ucode -L "$LIB" "$LIB/components/updates.uc" list-update </dev/null >>"$WORK/worker.log" 2>&1
}

# The list workers are done and the new source is the applied one.
check_converged() {
  wait_until 60 test ! -e "$RUN/list.pid" || fail "a list worker did not finish"
  wait_until 30 grep -qx 'list-content applied' "$EVENTS" ||
    fail "the list change was not applied after the running update ended"
  grep -qx 'download new.txt' "$EVENTS" || fail "the new list source was never downloaded"
  grep -q 'new.example' "$RULESET" || fail "the applied rule set does not hold the new list source"
  if grep -qx 'list-content apply failed' "$EVENTS"; then
    fail "a list-content reload failed"
  fi
  [ ! -e "$MARKER" ] || fail "the list apply marker was left behind ($(cat "$MARKER"))"
  [ ! -e "$RUN/reload.pending" ] || fail "a queued reload was never run"
  [ ! -e "$RUN/reload.lock" ] || fail "reload.lock was left behind"
}

# A. A scheduled update downloads the old source; the user changes it.
reset_state
set_source old.txt
: >"$WORK/hold.old.txt"
list_worker &
worker=$!
printf '%s\n' "$worker" >>"$WORK/bg.pids"
wait_until 30 test -e "$WORK/in.old.txt" || fail "A: the scheduled update did not download"
set_source new.txt
: >"$WORK/sources.changed"
"$WORK/init.d" reload on_config_change >/dev/null || fail "A: the config-change reload failed"
if grep -q '^reload ' "$EVENTS"; then
  fail "A: a reload ran while a list update was downloading"
fi
[ -e "$RUN/reload.pending" ] || fail "A: the reload during the list update was not queued"
rm -f "$WORK/hold.old.txt"
wait_until 60 process_gone "$worker" || fail "A: the scheduled update did not finish"
check_converged

# B. A list-source change starts an update; an unrelated reload arrives while
#    it downloads.
reset_state
set_source old.txt
list_worker || fail "B: the first list update failed"
grep -q 'old.example' "$RULESET" || fail "B: the first list update was not applied"
: >"$EVENTS"
set_source new.txt
: >"$WORK/sources.changed"
: >"$WORK/hold.new.txt"
"$WORK/init.d" reload on_config_change >/dev/null || fail "B: the list-source reload failed"
grep -qx 'list worker started' "$EVENTS" || fail "B: the list-source reload did not start a list update"
wait_until 30 test -e "$WORK/in.new.txt" || fail "B: the list update did not download"
status=0
"$WORK/init.d" reload >/dev/null || status=$?
[ "$status" = 0 ] || fail "B: a reload during the list update failed with status $status"
if grep -qx 'list-content apply failed' "$EVENTS"; then
  fail "B: a reload during the list update tried to apply a generation that did not exist yet"
fi
[ -e "$RUN/reload.pending" ] || fail "B: the reload during the list update was not queued"
rm -f "$WORK/hold.new.txt"
check_converged

# C. A reload queued during the downloads is run even when the update then
#    gives up waiting for reload.lock.
reset_state
set_source old.txt
: >"$WORK/hold.old.txt"
list_worker &
worker=$!
printf '%s\n' "$worker" >>"$WORK/bg.pids"
wait_until 30 test -e "$WORK/in.old.txt" || fail "C: the scheduled update did not download"
"$WORK/init.d" reload >/dev/null || fail "C: the reload failed"
[ -e "$RUN/reload.pending" ] || fail "C: the reload during the list update was not queued"
: >"$WORK/lock.timeout"
rm -f "$WORK/hold.old.txt"
wait_until 60 process_gone "$worker" || fail "C: the list update did not finish"
grep -q 'did not release the runtime lock' "$WORK/log" || fail "C: fixture: the list update did not time out on reload.lock"
grep -qx 'reload pending' "$EVENTS" || fail "C: the reload queued during the list update was never run"
[ ! -e "$RUN/reload.pending" ] || fail "C: the queued reload was left in reload.pending"
[ ! -e "$RUN/list.pid" ] || fail "C: the list update left its PID file behind"

printf 'list update reload queue checks passed\n'
