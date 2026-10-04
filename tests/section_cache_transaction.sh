#!/usr/bin/env bash
set -euo pipefail

# A staged sing-box config and its dashboard metadata are one rollback unit.
# Publishing metadata is a directory swap: injected failures must leave the
# complete old cache visible, and restore-config-stage must restore both files.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
RUNTIME="$FORKOP_LIB/singbox/runtime.uc"
LIFECYCLE="$FORKOP_LIB/service/lifecycle.uc"
UPDATES="$FORKOP_LIB/components/updates.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

UCODE_BIN="$(command -v ucode)" || fail "ucode is required"
mkdir -p "$WORK_DIR/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK_DIR/bin/logger"
chmod 0755 "$WORK_DIR/bin/logger"

grep -Fq 'let reload_paths = private_bootstrap_paths("reload");' "$LIFECYCLE" ||
  fail "ordinary reload does not allocate one private config transaction"
if grep -Fq 'remove_file(staged_singbox_backup)' "$LIFECYCLE"; then
  fail "ordinary reload still unlinks its backup before commit"
fi
grep -Fq 'subscription_runtime_transaction_paths()' "$UPDATES" ||
  fail "subscription runtime update does not use a private config transaction"
if grep -Fq 'remove_file(backup_config_path)' "$UPDATES"; then
  fail "subscription runtime update still unlinks or discards its bare backup"
fi

runtime() {
  local case_dir="$1"
  local fail_phase="$2"
  shift 2
  PATH="$WORK_DIR/bin:$PATH" \
    FORKOP_LIB="$FORKOP_LIB" \
    FORKOP_UCI_STATE_FILE="$case_dir/uci.state" \
    FORKOP_UCI_LOG_FILE="$case_dir/uci.log" \
    FORKOP_RUNTIME_STATE_DIR="$case_dir/run" \
    FORKOP_SECTION_CACHE_DIR="$case_dir/run/section-cache" \
    FORKOP_SECTION_CACHE_FAIL_PHASE="$fail_phase" \
    "$UCODE_BIN" -L "$FORKOP_LIB" "$RUNTIME" "$@"
}

reset_case() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/private" "$case_dir/run/section-cache"
  chmod 0700 "$case_dir/private" "$case_dir/run/section-cache"
  printf 'forkop.settings=settings\n' >"$case_dir/uci.state"
  printf 'forkop.settings.config_path=%s\n' "$case_dir/live.json" >>"$case_dir/uci.state"
  printf '{"generation":"old"}\n' >"$case_dir/live.json"
  chmod 0644 "$case_dir/live.json"
  printf '{"old":"alpha","secret":"vless://old-a"}\n' >"$case_dir/run/section-cache/alpha.json"
  printf '{"old":"beta","secret":"vless://old-b"}\n' >"$case_dir/run/section-cache/beta.json"
  chmod 0600 "$case_dir/run/section-cache/"*.json
  cp -a "$case_dir/run/section-cache" "$case_dir/expected-old-cache"
  printf '{"generation":"new"}\n' >"$case_dir/private/stage.json"
  chmod 0600 "$case_dir/private/stage.json"
  mkdir "$case_dir/private/stage.json.section-cache"
  chmod 0700 "$case_dir/private/stage.json.section-cache"
  printf '{"new":"alpha","secret":"vless://new-a"}\n' >"$case_dir/private/stage.json.section-cache/alpha.json"
  printf '{"new":"gamma","secret":"vless://new-c"}\n' >"$case_dir/private/stage.json.section-cache/gamma.json"
  chmod 0600 "$case_dir/private/stage.json.section-cache/"*.json
}

assert_old_cache() {
  local case_dir="$1"
  diff -ru "$case_dir/expected-old-cache" "$case_dir/run/section-cache" >/dev/null ||
    fail "section-cache was partially published after an injected failure"
  [ "$(stat -c %a "$case_dir/run/section-cache")" = 700 ] ||
    fail "restored section-cache directory is not private"
  [ "$(stat -c %a "$case_dir/run/section-cache/alpha.json")" = 600 ] ||
    fail "restored section-cache file is not private"
}

assert_no_cache_transactions() {
  local case_dir="$1"
  if find "$case_dir/run" -maxdepth 1 -name '.section-cache-transaction.*' -print -quit | grep -q .; then
    fail "completed section-cache transaction was not cleaned"
  fi
}

for phase in candidate-copy after-live-move after-publish; do
  case_dir="$WORK_DIR/fault-$phase"
  reset_case "$case_dir"
  if runtime "$case_dir" "$phase" commit-config-stage \
    "$case_dir/private/stage.json" "$case_dir/private/backup.json"; then
    fail "commit unexpectedly succeeded at injected phase $phase"
  fi

  # Config publication precedes metadata publication.  The coherent old pair
  # is recoverable until the caller has validated and accepted the new runtime.
  grep -Fq '"generation":"new"' "$case_dir/live.json" ||
    fail "failed commit did not reach the expected config boundary at $phase"
  assert_old_cache "$case_dir"
  grep -Fq '"generation":"old"' "$case_dir/private/backup.json" ||
    fail "failed commit lost its config backup at $phase"
  diff -ru "$case_dir/expected-old-cache" "$case_dir/private/backup.json.section-cache" >/dev/null ||
    fail "failed commit lost its cache rollback snapshot at $phase"
  [ "$(stat -c %a "$case_dir/private/backup.json.section-cache")" = 700 ] ||
    fail "cache rollback snapshot directory is not private at $phase"
  [ "$(stat -c %a "$case_dir/private/backup.json.section-cache/alpha.json")" = 600 ] ||
    fail "cache rollback snapshot file is not private at $phase"

  runtime "$case_dir" "" restore-config-stage "$case_dir/private/backup.json" ||
    fail "coherent rollback failed after injected phase $phase"
  grep -Fq '"generation":"old"' "$case_dir/live.json" ||
    fail "config was not restored after injected phase $phase"
  assert_old_cache "$case_dir"
  [ ! -e "$case_dir/private/backup.json" ] ||
    fail "restore retained the consumed config backup at $phase"
  [ ! -e "$case_dir/private/backup.json.section-cache" ] ||
    fail "restore retained the consumed cache snapshot at $phase"
  runtime "$case_dir" "" discard-config-stage "$case_dir/private/stage.json"
  assert_no_cache_transactions "$case_dir"
done

case_dir="$WORK_DIR/success"
reset_case "$case_dir"
runtime "$case_dir" "" commit-config-stage \
  "$case_dir/private/stage.json" "$case_dir/private/backup.json" ||
  fail "normal config/cache commit failed"
grep -Fq '"generation":"new"' "$case_dir/live.json" ||
  fail "normal commit did not publish the new config"
grep -Fq '"new":"alpha"' "$case_dir/run/section-cache/alpha.json" ||
  fail "normal commit did not publish the complete new cache"
[ -e "$case_dir/run/section-cache/gamma.json" ] ||
  fail "normal commit lost a new cache entry"
[ ! -e "$case_dir/run/section-cache/beta.json" ] ||
  fail "normal directory swap retained a stale cache entry"
runtime "$case_dir" "" restore-config-stage "$case_dir/private/backup.json" ||
  fail "normal config/cache rollback failed"
grep -Fq '"generation":"old"' "$case_dir/live.json" ||
  fail "normal rollback did not restore the old config"
assert_old_cache "$case_dir"
assert_no_cache_transactions "$case_dir"

printf 'section-cache publication and rollback transactions passed\n'
