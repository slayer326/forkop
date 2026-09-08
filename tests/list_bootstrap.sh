#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
cat >"$WORK_DIR/bin/wget" <<'SH'
#!/bin/sh
[ "${BOOTSTRAP_FAIL:-0}" = 0 ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -O ]; then
    printf 'bootstrap.example\n' >"$2"
    exit 0
  fi
  shift
done
exit 1
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/nft.log"
exit 1
SH
cat >"$WORK_DIR/bin/init-forkop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/reload.log"
SH
chmod +x "$WORK_DIR/bin/"*

bootstrap_cmd() {
  env PATH="$WORK_DIR/bin:$PATH" CASE_DIR="$case_dir" BOOTSTRAP_FAIL="$bootstrap_fail" \
    FORKOP_LIB="$FORKOP_LIB" FORKOP_UCI_STATE_FILE="$case_dir/uci.state" \
    TMP_SING_BOX_FOLDER="$case_dir/tmp" TMP_RULESET_FOLDER="$case_dir/rulesets" \
    FORKOP_RUNTIME_STATE_DIR="$case_dir/run" FORKOP_RELOAD_LOCK_DIR="$case_dir/run/reload.lock" \
    FORKOP_LIST_UPDATE_PID_FILE="$case_dir/run/list.pid" \
    FORKOP_PERSISTENT_LIST_CACHE_DIR="$case_dir/cache" \
    FORKOP_RULESET_CACHE_DIR="$case_dir/ruleset-cache" \
    FORKOP_RUNTIME_LIST_GENERATION_DIR="$case_dir/generation" \
    FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES=0 \
    FORKOP_SERVICE_INIT="$WORK_DIR/bin/init-forkop" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" "$@"
}

for bootstrap_fail in 0 1; do
  case_dir="$WORK_DIR/case-$bootstrap_fail"
  mkdir -p "$case_dir/rulesets" "$case_dir/run/reload.lock" "$case_dir/cache"
  # Startup already owns this lock; preparation must not wait for its parent.
  printf '%s\n' "$$" >"$case_dir/run/reload.lock/pid"
  printf 'previous flash data\n' >"$case_dir/cache/marker"
  cat >"$case_dir/uci.state" <<'UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  status=0
  bootstrap_cmd prepare-list-cache || status=$?
  if [ "$bootstrap_fail" = 0 ]; then
    [ "$status" = 0 ] || fail "first generation preparation failed"
    bootstrap_cmd restore-list-cache || fail "new RAM-only generation is not usable at startup"
    grep -Fq bootstrap.example "$case_dir/rulesets/alpha-remote-domains-ruleset.json" || fail "initial list data missing"
  else
    [ "$status" != 0 ] || fail "failed initial download was accepted"
    if bootstrap_cmd runtime-list-cache-active; then fail "failed bootstrap published incomplete data"; fi
  fi
  [ ! -s "$case_dir/nft.log" ] || fail "bootstrap touched live nft policy"
  [ ! -s "$case_dir/reload.log" ] || fail "bootstrap recursively requested reload"
  [ ! -e "$case_dir/run/list.pid" ] || fail "bootstrap leaked worker PID"
  [ -e "$case_dir/run/reload.lock/pid" ] || fail "bootstrap released the parent's lock"
  grep -Fxq 'previous flash data' "$case_dir/cache/marker" || fail "bootstrap damaged flash cache"
done
printf 'initial list generation checks passed\n'
