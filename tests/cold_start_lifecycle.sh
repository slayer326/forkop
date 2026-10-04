#!/usr/bin/env bash
set -euo pipefail

# Exercise the lifecycle around the short-lived list transport with module
# doubles. The contract is process/config ordering, cleanup and Stop winning;
# generator/runtime shape is covered separately in cold_start_list_bootstrap.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
LIFECYCLE="$LIB/service/lifecycle.uc"
REAL_UCODE="$(command -v ucode)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  [ ! -s "$WORK/events" ] || sed 's/^/  event: /' "$WORK/events" >&2
  exit 1
}

mkdir -p "$WORK/bin" "$WORK/run"
export REAL_UCODE WORK

cat >"$WORK/bin/ucode" <<'SH'
#!/bin/sh
module="${3:-}"
mode="${4:-}"
case "$module:$mode" in
  */singbox/generator.uc:startup-required-deferred|*/singbox/generator.uc:list-bootstrap-required-deferred)
    deferred="${5:-}"
    if [ "${REQUIRED_ONLY_SELECTED:-0}" = 1 ]; then
      case " $deferred " in
        *' selected '*) printf 'selected\n' ;;
        *) printf '\n' ;;
      esac
    else
      printf '%s\n' "$deferred"
    fi
    exit 0 ;;
  */singbox/runtime.uc:service-proxy-address)
    if [ "${DIRECT_LISTS:-0}" = 1 ]; then
      printf '\n'
    else
      printf '127.0.0.1:4534\n'
    fi
    exit 0 ;;
  */singbox/runtime.uc:configure-service)
    echo configure >>"$WORK/events"; exit 0 ;;
  */singbox/runtime.uc:prepare-config-stage)
    if [ "${FORKOP_LIFECYCLE_SUBSCRIPTION_BOOTSTRAP:-0}" = 1 ]; then
      [ -n "${8:-}" ] || exit 94
      printf 'prepare-subscription-stage:%s\n' "$8" >>"$WORK/events"
      printf '%s\n' "$8"
    elif [ "${FORKOP_LIFECYCLE_LIST_BOOTSTRAP:-0}" = 1 ]; then
      [ "${8:-}" = "${EXPECTED_LIST_DEFERRED:-}" ] || exit 95
      echo prepare-list-stage >>"$WORK/events"
      printf '\n'
    else
      exit 96
    fi
    printf '{"temporary":true}\n' >"${9}"
    exit 0 ;;
  */singbox/runtime.uc:validate-config-stage)
    echo validate >>"$WORK/events"
    [ "${FAIL_VALIDATE:-0}" != 1 ]
    exit $? ;;
  */singbox/runtime.uc:commit-config-stage)
    echo commit >>"$WORK/events"
    [ "${FAIL_COMMIT:-0}" != 1 ] || exit 1
    [ ! -e "$BOOTSTRAP_CONFIG" ] || cp -p "$BOOTSTRAP_CONFIG" "$6"
    printf '%s\n' "$6" >"$WORK/backup.path"
    mv -f "$5" "$BOOTSTRAP_CONFIG"
    chmod 600 "$BOOTSTRAP_CONFIG"
    [ "${FAIL_COMMIT_AFTER_PUBLISH:-0}" != 1 ] || exit 1
    [ "${STOP_AT_COMMIT:-0}" != 1 ] || : >"$FORKOP_STOP_REQUESTED_FILE"
    exit 0 ;;
  */singbox/runtime.uc:restore-config-stage)
    echo restore >>"$WORK/events"
    [ "${FAIL_RESTORE:-0}" != 1 ] || exit 1
    mv -f "$5" "$BOOTSTRAP_CONFIG"
    exit 0 ;;
  */singbox/runtime.uc:discard-config-stage)
    echo discard >>"$WORK/events"
    rm -f "$5"
    rm -rf "$5.section-cache"
    exit 0 ;;
  */service/state.uc:stop-managed-sing-box-runtime)
    count=0
    [ ! -s "$WORK/stop.count" ] || count="$(cat "$WORK/stop.count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$WORK/stop.count"
    printf 'stop:%s\n' "$count" >>"$WORK/events"
    if [ "${FAIL_CLEANUP_STOP:-0}" = 1 ] && [ "$count" -ge 2 ]; then exit 1; fi
    exit 0 ;;
  */service/state.uc:start-managed-sing-box-runtime-unless-stopped)
    echo start >>"$WORK/events"
    if [ "${STOP_AT_START:-0}" = 1 ]; then
      : >"$FORKOP_STOP_REQUESTED_FILE"
      echo guard-stop >>"$WORK/events"
      exit 1
    fi
    [ "${FAIL_START:-0}" != 1 ]
    exit $? ;;
  */service/state.uc:wait-managed-sing-box-config-listeners)
    echo wait-listener >>"$WORK/events"
    [ "${FAIL_WAIT:-0}" != 1 ]
    exit $? ;;
  */components/updates.uc:prepare-list-cache)
    echo prepare-list-cache >>"$WORK/events"
    [ "${STOP_DURING_LIST:-0}" != 1 ] || : >"$FORKOP_STOP_REQUESTED_FILE"
    [ "${FAIL_LIST:-0}" != 1 ]
    exit $? ;;
  */subscription/cache.uc:prepare-caches)
    echo prepare-subscriptions >>"$WORK/events"
    [ "${STOP_DURING_SUBSCRIPTIONS:-0}" != 1 ] || : >"$FORKOP_STOP_REQUESTED_FILE"
    [ "${FAIL_SUBSCRIPTIONS:-0}" != 1 ] || exit 1
    count=0
    [ ! -s "$WORK/subscription.count" ] || count="$(cat "$WORK/subscription.count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$WORK/subscription.count"
    if [ "${NO_SUBSCRIPTION_PROGRESS:-0}" = 1 ]; then
      printf 'selected\n'
    elif [ "${NESTED_SUBSCRIPTIONS:-0}" = 1 ] && [ "$count" = 1 ]; then
      printf 'selected\n'
    elif [ "${UNRELATED_DEFERRED:-0}" = 1 ]; then
      printf 'unrelated\n'
    else
      printf '\n'
    fi
    exit 0 ;;
esac
exec "$REAL_UCODE" "$@"
SH

cat >"$WORK/bin/logger" <<'SH'
#!/bin/sh
printf 'logger %s\n' "$*" >>"$WORK/events"
SH
chmod +x "$WORK/bin/ucode" "$WORK/bin/logger"

export PATH="$WORK/bin:$PATH"
export FORKOP_LIB="$LIB"
export FORKOP_RUNTIME_STATE_DIR="$WORK/run"
export FORKOP_STOP_REQUESTED_FILE="$WORK/run/stop.requested"
export FORKOP_UCI_STATE_FILE="$WORK/uci.state"
export BOOTSTRAP_CONFIG="$WORK/config.json"
cat >"$FORKOP_UCI_STATE_FILE" <<UCI
forkop.settings=settings
forkop.settings.config_path=$BOOTSTRAP_CONFIG
forkop.settings.download_lists_via_proxy=1
forkop.settings.download_lists_via_proxy_section=selected
UCI

reset_case() {
  rm -f "$WORK/events" "$WORK/stop.count" "$WORK/subscription.count" "$WORK/backup.path" "$FORKOP_STOP_REQUESTED_FILE"
  # Keep an extra trailing newline so restoration checks cannot accidentally
  # pass through command substitution, which strips trailing newlines.
  printf '{"old":true}\n\n' >"$WORK/expected-config"
  printf '{"temporary":true}\n' >"$WORK/expected-temporary-config"
  cp "$WORK/expected-config" "$BOOTSTRAP_CONFIG"
  chmod 640 "$BOOTSTRAP_CONFIG"
}

run_bootstrap() {
  env "$@" "$REAL_UCODE" -L "$LIB" "$LIFECYCLE" cold-start-list-bootstrap-fixture
}

run_two_stage_bootstrap() {
  env "$@" "$REAL_UCODE" -L "$LIB" "$LIFECYCLE" cold-start-list-bootstrap-fixture selected
}

run_nested_bootstrap() {
  env NESTED_SUBSCRIPTIONS=1 "$@" "$REAL_UCODE" -L "$LIB" "$LIFECYCLE" cold-start-list-bootstrap-fixture 'selected detour'
}

backup_path() {
  [ -s "$WORK/backup.path" ] || return 1
  cat "$WORK/backup.path"
}

assert_restored() {
  cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-config" || fail "$1: previous config content was not restored byte-for-byte"
  [ "$(stat -c %a "$BOOTSTRAP_CONFIG")" = 640 ] || fail "$1: previous config mode was not restored"
  local backup
  backup="$(backup_path)" || fail "$1: no recovery path was recorded"
  [ ! -e "$backup" ] || fail "$1: successful restore left a backup"
}

reset_case
run_bootstrap || fail "successful list bootstrap failed"
assert_restored success
expected=$'configure\nstop:1\nprepare-list-stage\nvalidate\ncommit\nstart\nwait-listener\nprepare-list-cache\nstop:2\nrestore\ndiscard'
[ "$(cat "$WORK/events")" = "$expected" ] || fail "successful call order changed"

# Direct downloads need no temporary sing-box runtime. The private stage
# directory is still allocated and must be removed after list preparation.
reset_case
sed -i 's/download_lists_via_proxy=1/download_lists_via_proxy=0/' "$FORKOP_UCI_STATE_FILE"
mkdir -p "$WORK/direct-tmp"
run_bootstrap DIRECT_LISTS=1 TMPDIR="$WORK/direct-tmp" || fail "direct list bootstrap failed"
cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-config" || fail "direct list bootstrap changed the live config"
expected=$'prepare-list-cache\ndiscard'
[ "$(cat "$WORK/events")" = "$expected" ] || fail "direct list bootstrap started a temporary runtime"
if find "$WORK/direct-tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "direct list bootstrap left its private stage directory"
fi
sed -i 's/download_lists_via_proxy=0/download_lists_via_proxy=1/' "$FORKOP_UCI_STATE_FILE"

# A clean install has no previous config. The temporary bootstrap file must
# disappear after its exact managed process stops, and its private directory
# must not be left behind.
reset_case
rm -f "$BOOTSTRAP_CONFIG"
run_bootstrap || fail "no-prior-config bootstrap failed"
[ ! -e "$BOOTSTRAP_CONFIG" ] || fail "no-prior-config bootstrap left its temporary config live"
backup="$(backup_path)" || fail "no-prior-config bootstrap did not record its transaction path"
[ ! -e "$(dirname "$backup")" ] || fail "no-prior-config bootstrap left its private transaction directory"

reset_case
if run_bootstrap FAIL_VALIDATE=1; then fail "invalid bootstrap candidate was accepted"; fi
cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-config" || fail "validation failure changed the live config"
if grep -q '^commit\|^start\|^prepare-list-cache$' "$WORK/events"; then
  fail "work continued after bootstrap validation failed"
fi

reset_case
if run_bootstrap FAIL_COMMIT=1; then fail "failed bootstrap commit was accepted"; fi
cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-config" || fail "early commit failure changed the live config"
if grep -q '^start\|^prepare-list-cache$' "$WORK/events"; then
  fail "work continued after bootstrap commit failed"
fi

# A commit can fail after publishing its temporary config. The recovery
# backup must still restore the old file before startup returns failure.
reset_case
if run_bootstrap FAIL_COMMIT_AFTER_PUBLISH=1; then
  fail "partially published bootstrap commit was accepted"
fi
assert_restored partial-commit-failure
if grep -q '^start\|^prepare-list-cache$' "$WORK/events"; then
  fail "work continued after partially published bootstrap commit failed"
fi

# A selected connection whose subscription itself uses another connection is
# recovered in a first private runtime. Only after that runtime is stopped and
# the previous config is restored may the list transport be built.
reset_case
run_two_stage_bootstrap || fail "successful two-stage bootstrap failed"
assert_restored two-stage-success
expected=$'configure\nstop:1\nprepare-subscription-stage:selected\nvalidate\ncommit\nstart\nwait-listener\nprepare-subscriptions\nstop:2\nrestore\ndiscard\nconfigure\nstop:3\nprepare-list-stage\nvalidate\ncommit\nstart\nwait-listener\nprepare-list-cache\nstop:4\nrestore\ndiscard'
[ "$(cat "$WORK/events")" = "$expected" ] || fail "two-stage bootstrap call order changed"

reset_case
run_nested_bootstrap || fail "nested subscription bootstrap failed"
assert_restored nested-success
expected=$'configure\nstop:1\nprepare-subscription-stage:selected detour\nvalidate\ncommit\nstart\nwait-listener\nprepare-subscriptions\nstop:2\nrestore\ndiscard\nconfigure\nstop:3\nprepare-subscription-stage:selected\nvalidate\ncommit\nstart\nwait-listener\nprepare-subscriptions\nstop:4\nrestore\ndiscard\nconfigure\nstop:5\nprepare-list-stage\nvalidate\ncommit\nstart\nwait-listener\nprepare-list-cache\nstop:6\nrestore\ndiscard'
[ "$(cat "$WORK/events")" = "$expected" ] || fail "nested bootstrap did not recover one dependency layer per stage"

reset_case
env REQUIRED_ONLY_SELECTED=1 UNRELATED_DEFERRED=1 EXPECTED_LIST_DEFERRED=unrelated \
  "$REAL_UCODE" -L "$LIB" "$LIFECYCLE" cold-start-list-bootstrap-fixture 'selected unrelated' ||
  fail "unrelated deferred subscription blocked selected list transport"
assert_restored unrelated-deferred
if [ "$(grep -c '^prepare-subscription-stage:' "$WORK/events")" -ne 1 ]; then
  fail "unrelated deferred subscription entered the list dependency bootstrap"
fi

reset_case
if run_two_stage_bootstrap FAIL_SUBSCRIPTIONS=1; then
  fail "failed deferred subscription recovery was accepted"
fi
assert_restored subscription-failure
grep -q '^stop:2$' "$WORK/events" || fail "subscription failure did not stop its temporary runtime"
if grep -q '^prepare-list-stage\|^prepare-list-cache$' "$WORK/events"; then
  fail "list stage ran after subscription recovery failed"
fi

reset_case
if run_two_stage_bootstrap NO_SUBSCRIPTION_PROGRESS=1; then
  fail "subscription bootstrap without progress was accepted"
fi
assert_restored subscription-no-progress
[ "$(grep -c '^prepare-subscription-stage:' "$WORK/events")" -eq 1 ] ||
  fail "no-progress guard ran more than one temporary subscription runtime"
if grep -q '^prepare-list-stage\|^prepare-list-cache$' "$WORK/events"; then
  fail "list stage ran after subscription bootstrap made no progress"
fi

reset_case
if run_two_stage_bootstrap STOP_DURING_SUBSCRIPTIONS=1; then
  fail "Stop during deferred subscription recovery was accepted"
fi
assert_restored stop-during-subscriptions
[ -e "$FORKOP_STOP_REQUESTED_FILE" ] || fail "Stop marker during subscription recovery was cleared"
if grep -q '^prepare-list-stage\|^prepare-list-cache$' "$WORK/events"; then
  fail "list stage ran after Stop won during subscription recovery"
fi

reset_case
if run_bootstrap FAIL_LIST=1; then fail "failed list preparation was accepted"; fi
assert_restored list-failure
grep -q '^stop:2$' "$WORK/events" || fail "failed list preparation did not stop temporary runtime"

reset_case
if run_bootstrap FAIL_WAIT=1; then fail "unready service proxy was accepted"; fi
assert_restored listener-failure
if grep -q '^prepare-list-cache$' "$WORK/events"; then fail "list download ran before listener readiness"; fi

reset_case
if run_bootstrap FAIL_START=1; then fail "partial temporary start was accepted"; fi
assert_restored partial-start
grep -q '^stop:2$' "$WORK/events" || fail "partial start did not run managed cleanup"

reset_case
if run_bootstrap STOP_AT_COMMIT=1; then fail "Stop at commit boundary lost the race"; fi
assert_restored stop-at-commit
[ -e "$FORKOP_STOP_REQUESTED_FILE" ] || fail "Stop marker at commit boundary was cleared"
if grep -q '^start$' "$WORK/events"; then fail "runtime started after Stop was recorded at commit"
fi

reset_case
if run_bootstrap STOP_AT_START=1; then fail "guarded start ignored Stop"; fi
assert_restored stop-at-start
[ -e "$FORKOP_STOP_REQUESTED_FILE" ] || fail "Stop marker during start was cleared"
if grep -q '^wait-listener\|^prepare-list-cache$' "$WORK/events"; then
  fail "work continued after guarded start lost to Stop"
fi

reset_case
if run_bootstrap STOP_DURING_LIST=1; then fail "Stop during list preparation was accepted as success"; fi
assert_restored stop-during-list
[ -e "$FORKOP_STOP_REQUESTED_FILE" ] || fail "Stop marker during list preparation was cleared"

reset_case
if run_bootstrap FAIL_RESTORE=1; then fail "restore failure was accepted"; fi
backup="$(backup_path)" || fail "restore failure did not expose its recovery backup"
[ -e "$backup" ] || fail "restore failure deleted its recovery backup"
cmp -s "$backup" "$WORK/expected-config" || fail "restore failure backup lost previous content"
cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-temporary-config" ||
  fail "restore failure did not leave the published recovery config"

reset_case
if run_bootstrap FAIL_CLEANUP_STOP=1; then fail "unsafe temporary stop was accepted"; fi
backup="$(backup_path)" || fail "unsafe stop did not expose its recovery backup"
[ -e "$backup" ] || fail "unsafe stop deleted its recovery backup"
if grep -q '^restore$' "$WORK/events"; then fail "config was restored while temporary PID was not proven stopped"; fi
cmp -s "$BOOTSTRAP_CONFIG" "$WORK/expected-temporary-config" ||
  fail "unsafe stop did not preserve the temporary config used by the unproven PID"
cmp -s "$backup" "$WORK/expected-config" ||
  fail "unsafe stop did not preserve the exact recovery backup"

printf 'cold-start lifecycle cleanup and Stop-race checks passed\n'
