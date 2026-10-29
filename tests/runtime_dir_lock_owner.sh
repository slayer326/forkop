#!/usr/bin/env bash
set -euo pipefail

# A runtime directory lock (reload.lock, subscription-update.lock, the latency
# test locks) has exactly one owner (UC-011). The owner record is published
# together with the lock directory, so a lock that is still being set up is
# never taken for a stale one; the record names the owner by pid and start
# ticks, so a dead owner or a reused pid is stale; only the owner releases.
# A lock left by the previous package version (mkdir, then <lock>/pid) keeps
# its meaning across an upgrade: a live owner holds it, a dead one does not.
#
# service/state.uc, service/initd.uc, config/snapshots.uc and service/ui.uc
# are the real code.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
# shellcheck source=tests/helpers/wait.sh
. "$ROOT_DIR/tests/helpers/wait.sh"

actors=()
cleanup() {
  local pid
  for pid in "${actors[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/run" "$WORK_DIR/bin" "$WORK_DIR/snapshots"
LOCK="$WORK_DIR/run/forkop.reload.lock"
export FORKOP_RELOAD_LOCK_DIR="$LOCK"
export FORKOP_PENDING_RELOAD_FILE="$WORK_DIR/run/reload.pending"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run"
export FORKOP_UI_ACTION_TRACKED=1
export FORKOP_CONFIG_FILE="$WORK_DIR/forkop.config"
export FORKOP_SNAPSHOT_DIR="$WORK_DIR/snapshots"
export FORKOP_SNAPSHOT_HASH_DIR="$WORK_DIR/hash"
export FORKOP_SNAPSHOT_LOCK_DIR="$WORK_DIR/run/config-snapshot.lock"
export FORKOP_HISTORY_FILE="$WORK_DIR/history.jsonl"
export FORKOP_RELOAD_COMMAND="$WORK_DIR/bin/no-init"
export FORKOP_SERVICE_INIT="$WORK_DIR/bin/no-init"
export FORKOP_UCI_SAVEDIR="$WORK_DIR/uci-save"
export FORKOP_LATENCY_TEST_LOCK_DIR="$LOCK"
export FORKOP_LIB="$LIB"
export PATH="$WORK_DIR/bin:$PATH"
# Nothing here may reach the host's syslog, nftables or init scripts.
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/no-init"
printf '#!/bin/sh\nexit 1\n' >"$WORK_DIR/bin/nft"
chmod +x "$WORK_DIR/bin/logger" "$WORK_DIR/bin/no-init" "$WORK_DIR/bin/nft"

state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }
initd() { ucode -L "$LIB" "$LIB/service/initd.uc" "$@"; }
# The live owner, read through the shared helper; empty when there is none.
owner_of() { state runtime-dir-lock-owner "$LOCK" 2>/dev/null || true; }
acquire() { state acquire-runtime-dir-lock "$LOCK" "$1" >/dev/null 2>&1; }
refused() { ! acquire "$1" || fail "$2"; }
start_ticks() {
  local stat
  IFS= read -r stat <"/proc/$1/stat" || return 1
  stat="${stat##*) }"
  # shellcheck disable=SC2086
  set -- $stat
  shift 19
  printf '%s\n' "$1"
}
reset_lock() { rm -rf "$LOCK" "$LOCK".new.*; }

# Owners are long-lived children of this shell; DEAD is a reaped process, so
# no process runs under its pid.
sleep 300 >/dev/null 2>&1 &
A=$!
actors+=("$A")
sleep 300 >/dev/null 2>&1 &
B=$!
actors+=("$B")
sleep 300 >/dev/null 2>&1 &
C=$!
actors+=("$C")
sleep 0 &
DEAD=$!
wait "$DEAD" || true
for pid in "$A" "$B" "$C"; do
  wait_until 10 process_exec_is "$pid" sleep || fail "owner process $pid did not start"
done
process_gone "$DEAD" || fail "the dead owner still runs"

# race ROUND SETUP CONTENDER...: the contenders start together on a busy-wait
# barrier against the lock SETUP left; exactly one of them may get it.
# CONTENDER is "state:<owner>" (service/state.uc) or "initd:<owner>" (the
# in-process lock of service/initd.uc, as init.d reload takes it).
race() {
  local round="$1" setup="$2" gate="$WORK_DIR/gate" contender kind owner pids=() winners=0 winner=""
  shift 2
  reset_lock
  rm -f "$gate" "$WORK_DIR"/rc.* "$FORKOP_PENDING_RELOAD_FILE"
  case "$setup" in
    free) ;;
    dead) mkdir "$LOCK" && : >"$LOCK/owner.$DEAD.$(start_ticks "$$")" ;;
    legacy-dead) mkdir "$LOCK" && printf '%s\n' "$DEAD" >"$LOCK/pid" ;;
  esac
  for contender in "$@"; do
    kind="${contender%%:*}"
    owner="${contender#*:}"
    (
      status=0
      while [ ! -e "$gate" ]; do :; done
      if [ "$kind" = initd ]; then
        initd reload-begin-fixture badwan_interface_up "$owner" 1 1 "" >/dev/null 2>&1 || status=$?
      else
        state acquire-runtime-dir-lock "$LOCK" "$owner" >/dev/null 2>&1 || status=$?
      fi
      printf '%s\n' "$status" >"$WORK_DIR/rc.$owner"
    ) &
    pids+=("$!")
  done
  sleep 0.05
  : >"$gate"
  wait "${pids[@]}"
  for contender in "$@"; do
    owner="${contender#*:}"
    if [ "$(cat "$WORK_DIR/rc.$owner")" = 0 ]; then
      winners=$((winners + 1))
      winner="$owner"
    fi
  done
  [ "$winners" = 1 ] || fail "round $round ($setup, $*): $winners contenders own the lock"
  [ "$(owner_of)" = "$winner" ] || fail "round $round ($setup): the lock names '$(owner_of)', not the winner $winner"
  state release-runtime-dir-lock "$LOCK" "$winner"
  [ ! -e "$LOCK" ] || fail "round $round ($setup): the winner's release left the lock behind"
  ! compgen -G "$LOCK.new.*" >/dev/null || fail "round $round ($setup): a contender left its pending lock behind"
}

# 1. Two processes acquiring within milliseconds: exactly one owner, 100 times
#    on a free lock, and when both break the same stale lock.
for round in $(seq 1 100); do
  race "$round" free "state:$A" "state:$B"
done
for round in $(seq 1 25); do
  race "$round" dead "state:$A" "state:$B"
  race "$round" legacy-dead "state:$A" "state:$B"
done
# init.d reload takes reload.lock in-process: the same protocol, also against
# the service/state.uc helper.
for round in $(seq 1 25); do
  race "$round" free "initd:$A" "initd:$B"
done
for round in $(seq 1 10); do
  race "$round" free "state:$A" "initd:$B"
done

# 2. Only the owner releases. Neither another owner nor an unrelated caller
#    of the helper without an owner drops the lock.
reset_lock
acquire "$A" || fail "a free lock was refused"
refused "$B" "a second owner took a held lock"
state release-runtime-dir-lock "$LOCK" "$B"
[ "$(owner_of)" = "$A" ] || fail "another owner released the lock"
state release-runtime-dir-lock "$LOCK"
[ "$(owner_of)" = "$A" ] || fail "a caller that is not the owner released the lock"
refused "$B" "the lock was free after a refused release"
state release-runtime-dir-lock "$LOCK" "$A"
[ ! -e "$LOCK" ] || fail "the owner's release left the lock behind"
# A holder whose lock was taken over releases nothing of its successor.
acquire "$A" || fail "a released lock was refused"
reset_lock
acquire "$C" || fail "the takeover owner was refused"
state release-runtime-dir-lock "$LOCK" "$A"
[ "$(owner_of)" = "$C" ] || fail "a former owner released its successor's lock"
state release-runtime-dir-lock "$LOCK" "$C"
[ ! -e "$LOCK" ] || fail "the successor's release left the lock behind"
# The helper releases for the owner that runs it, as callers of the previous
# package version run `release-runtime-dir-lock <lock>` without an owner.
bash -c 'while [ ! -e "$1" ]; do sleep 0.05; done
  ucode -L "$2" "$2/service/state.uc" release-runtime-dir-lock "$3"' _ "$WORK_DIR/release.gate" "$LIB" "$LOCK" &
releaser=$!
acquire "$releaser" || fail "the lock was refused to the releasing owner"
: >"$WORK_DIR/release.gate"
wait "$releaser" || fail "the owner's own helper call failed"
[ ! -e "$LOCK" ] || fail "the owner's helper call without an owner did not release its lock"

# 3. A lock without an owner record is being set up (the previous package
#    version creates the directory, then writes <lock>/pid): it is not taken
#    while fresh, and it does not stay busy once abandoned.
reset_lock
mkdir "$LOCK"
refused "$A" "a lock without its owner record yet was taken"
if [ ! -d "$LOCK" ] || [ -n "$(ls -A "$LOCK")" ]; then fail "a refused contender changed a lock being set up"; fi
touch -d '1 minute ago' "$LOCK"
acquire "$A" || fail "an abandoned lock without an owner record stays busy"
[ "$(owner_of)" = "$A" ] || fail "the abandoned lock was not taken by its new owner"
reset_lock
mkdir "$LOCK"
: >"$LOCK/pid"
refused "$A" "a lock whose previous-version owner is writing its pid was taken"
touch -d '1 minute ago' "$LOCK"
acquire "$A" || fail "an abandoned previous-version lock with an empty pid stays busy"
[ ! -e "$LOCK/pid" ] || fail "the empty previous-version pid survived the takeover"

# 4. Stale owners are reclaimed; live ones are not. The record names the
#    owner by pid and start ticks, in either format.
stale_case() {
  local label="$1"
  acquire "$A" || fail "$label: the stale lock was not reclaimed"
  [ "$(owner_of)" = "$A" ] || fail "$label: the reclaimed lock does not name its new owner"
  [ "$(ls -A "$LOCK")" = "owner.$A.$(start_ticks "$A")" ] ||
    fail "$label: the reclaimed lock kept the stale records: $(ls -A "$LOCK" | tr '\n' ' ')"
  state release-runtime-dir-lock "$LOCK" "$A"
}
busy_case() {
  local label="$1" expected="$2"
  refused "$A" "$label: a live owner lost the lock"
  [ "$(owner_of)" = "$expected" ] || fail "$label: the lock names '$(owner_of)', not $expected"
}
b_ticks="$(start_ticks "$B")"
reset_lock; mkdir "$LOCK"; : >"$LOCK/owner.$DEAD.$b_ticks"
stale_case "dead owner"
reset_lock; mkdir "$LOCK"; : >"$LOCK/owner.$B.$((b_ticks + 1))"
stale_case "reused pid"
reset_lock; mkdir "$LOCK"; : >"$LOCK/owner.$B.$b_ticks"
busy_case "live owner" "$B"
reset_lock; mkdir "$LOCK"; printf '%s\n' "$DEAD" >"$LOCK/pid"
stale_case "previous-version dead owner"
reset_lock; mkdir "$LOCK"; printf '%s\n' "$B" >"$LOCK/pid"
busy_case "previous-version live owner" "$B"
reset_lock; mkdir "$LOCK"; printf '%s\n%s\n' "$B" "$b_ticks" >"$LOCK/pid"
busy_case "previous-version live owner with start ticks" "$B"
reset_lock; mkdir "$LOCK"; printf '%s\n%s\n' "$B" "$((b_ticks + 1))" >"$LOCK/pid"
stale_case "previous-version reused pid"
reset_lock; mkdir "$LOCK"; : >"$LOCK/stray"; touch -d '1 minute ago' "$LOCK"
stale_case "abandoned stray entry"
reset_lock; : >"$LOCK"
acquire "$A" || fail "a file in place of the lock blocks it"
if [ ! -d "$LOCK" ] || [ "$(owner_of)" != "$A" ]; then fail "the lock replacing a file does not name its owner"; fi
reset_lock

# 4b. Breaking a stale lock never removes a record that appeared after the
#     lock was inspected. The races above hit that gap only now and then, so
#     here it is forced: a stand-in core/process_identity runs HOOK the first
#     time the contender asks whether the dead owner runs, i.e. after it read
#     the stale lock and before it cleans it up.
mkdir -p "$WORK_DIR/hook/core"
cat >"$WORK_DIR/hook/core/process_identity.uc" <<'UC'
let real = loadfile(getenv("FORKOP_LIB") + "/core/process_identity.uc")();
let fired = false;
let hooked = {};
for (let name in real)
    hooked[name] = real[name];
hooked.start_ticks = function(pid) {
    let ticks = real.start_ticks(pid);
    if (!fired && "" + pid == getenv("HOOK_PID")) {
        fired = true;
        system(getenv("HOOK"));
    }
    return ticks;
};
return hooked;
UC
printf 'let lock = require("core.runtime_lock");\nexit(lock.acquire(ARGV[0], ARGV[1]) ? 0 : 1);\n' \
  >"$WORK_DIR/hook/acquire.uc"
hooked_acquire() {
  HOOK_PID="$DEAD" HOOK="$1" ucode -L "$WORK_DIR/hook" -L "$LIB" "$WORK_DIR/hook/acquire.uc" "$LOCK" "$A"
}
# Another contender breaks the same stale lock first and publishes its own.
reset_lock; mkdir "$LOCK"; : >"$LOCK/owner.$DEAD.$b_ticks"
! hooked_acquire "ucode -L '$LIB' '$LIB/service/state.uc' acquire-runtime-dir-lock '$LOCK' '$B'" ||
  fail "a contender took the lock its rival had just published over the stale one"
[ "$(owner_of)" = "$B" ] || fail "breaking a stale lock removed its successor's record"
[ "$(ls -A "$LOCK")" = "owner.$B.$b_ticks" ] || fail "the successor's lock was changed: $(ls -A "$LOCK" | tr '\n' ' ')"
# A previous-version contender (still running during an upgrade) breaks it
# its own way: rm pid, rmdir, mkdir, then writes its pid under the same name.
reset_lock; mkdir "$LOCK"; printf '%s\n' "$DEAD" >"$LOCK/pid"
! hooked_acquire "rm -f '$LOCK/pid'; rmdir '$LOCK'; mkdir '$LOCK'; printf '%s\n' '$B' >'$LOCK/pid'" ||
  fail "a contender took the lock a previous-version owner had just rewritten"
[ "$(owner_of)" = "$B" ] || fail "breaking a stale lock removed the previous-version owner's new pid"
reset_lock

# 5. Readers see the owner through the same helper: a snapshot restore waits
#    for a live lifecycle action, including one still setting up its lock,
#    and a stale lock is none. The UI refuses a second latency test.
printf 'config settings\n' >"$FORKOP_CONFIG_FILE"
snapshot_restore() {
  local id
  id="$(ls "$FORKOP_SNAPSHOT_DIR" | sed -n 's/\.json$//p' | head -n 1)"
  ucode -L "$LIB" "$LIB/config/snapshots.uc" restore "$id" || true
}
# busy: the reader found a service action; free: it found none, and the
# restore stops at its next step (the snapshot store is full of manual
# snapshots, so no pre-restore snapshot fits). A queued reload without a live
# owner is no service action.
busy_answer='{ "status": "busy", "reason": "service_action_in_progress" }'
free_answer='{ "status": "failed", "reason": "pre_restore_snapshot_failed" }'
reader_case() {
  local label="$1" answer
  answer="$(snapshot_restore)"
  if [ "$2" = busy ]; then [ "$answer" = "$busy_answer" ]; else [ "$answer" = "$free_answer" ]; fi ||
    fail "$label: snapshot restore answered $answer"
}
for _ in $(seq 1 10); do ucode -L "$LIB" "$LIB/config/snapshots.uc" create manual >/dev/null; done
: >"$FORKOP_PENDING_RELOAD_FILE"
acquire "$B" || fail "the reader lock was refused"
reader_case "live owner" busy
answer="$(ucode -L "$LIB" "$LIB/service/ui.uc" latency-test-async proxy main test 5000 || true)"
printf '%s\n' "$answer" | grep -Fq 'Another latency test is already running' ||
  fail "the UI started a latency test next to a live owner: $answer"
reset_lock; mkdir "$LOCK"
reader_case "lock being set up" busy
reset_lock; mkdir "$LOCK"; : >"$LOCK/owner.$B.$((b_ticks + 1))"
reader_case "reused pid" free
reset_lock; mkdir "$LOCK"; printf '%s\n' "$B" >"$LOCK/pid"
reader_case "previous-version live owner" busy
reset_lock; mkdir "$LOCK"; printf '%s\n' "$DEAD" >"$LOCK/pid"
reader_case "previous-version dead owner" free
reset_lock
rm -f "$FORKOP_PENDING_RELOAD_FILE"

printf 'runtime dir lock owner checks passed\n'
