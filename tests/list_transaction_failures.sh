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
printf 'download\n' >>"$CASE_DIR/network.log"
[ "$FAIL_PHASE" != download ] || exit 1
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'new.example\n' >"$output"
SH
cat >"$WORK_DIR/bin/cp" <<'SH'
#!/bin/sh
if [ "$FAIL_PHASE" = ruleset ] && [ "$1" = -R ] && [ "$2" = -p ]; then
  printf 'snapshot refused\n' >>"$CASE_DIR/copy.log"
  exit 1
fi
exec /bin/cp "$@"
SH
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/nft.log"
if [ "$*" = '-j list table inet forkop' ]; then
  [ "$FAIL_PHASE" != nft ] || exit 1
  printf '{"nftables":[]}\n'
  exit 0
fi
# None of these aborted transactions is allowed to mutate nftables.
exit 1
SH
cat >"$WORK_DIR/bin/init-forkop" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$CASE_DIR/reload.log"
SH
chmod +x "$WORK_DIR/bin/"*

for phase in download ruleset nft; do
  case_dir="$WORK_DIR/$phase"
  mkdir -p "$case_dir/rulesets" "$case_dir/run" "$case_dir/cache"
  printf '{"version":3,"rules":[{"domain_suffix":["old.example"]}]}\n' >"$case_dir/rulesets/alpha-remote-domains-ruleset.json"
  cp "$case_dir/rulesets/alpha-remote-domains-ruleset.json" "$case_dir/before.json"
  printf 'previous cache\n' >"$case_dir/cache/marker"
  printf '1\n' >"$case_dir/run/list-update.reload"
  printf 'force\n' >"$case_dir/run/ruleset-refresh-after-list"
  cat >"$case_dir/uci.state" <<'UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  status=0
  env PATH="$WORK_DIR/bin:$PATH" \
    CASE_DIR="$case_dir" FAIL_PHASE="$phase" \
    FORKOP_LIB="$FORKOP_LIB" \
    FORKOP_UCI_STATE_FILE="$case_dir/uci.state" \
    TMP_RULESET_FOLDER="$case_dir/rulesets" \
    FORKOP_RUNTIME_STATE_DIR="$case_dir/run" \
    FORKOP_RELOAD_LOCK_DIR="$case_dir/run/reload.lock" \
    FORKOP_LIST_UPDATE_PID_FILE="$case_dir/run/list.pid" \
    FORKOP_PERSISTENT_LIST_CACHE_DIR="$case_dir/cache" \
    FORKOP_SERVICE_INIT="$WORK_DIR/bin/init-forkop" \
    NFT_TABLE_NAME=forkop \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/updates.uc" list-update >"$case_dir/output.log" 2>&1 || status="$?"
  [ "$status" -eq 1 ] || fail "$phase failure must abort the update"
  [ -s "$case_dir/network.log" ] || fail "$phase did not reach source download"
  cmp "$case_dir/before.json" "$case_dir/rulesets/alpha-remote-domains-ruleset.json" || fail "$phase changed active rules"
  [ "$(cat "$case_dir/cache/marker")" = 'previous cache' ] || fail "$phase replaced persistent cache"
  [ -s "$case_dir/run/list-update.reload" ] || fail "$phase lost deferred reload"
  [ -s "$case_dir/run/ruleset-refresh-after-list" ] || fail "$phase lost deferred rule-set refresh"
  [ ! -s "$case_dir/reload.log" ] || fail "$phase reloaded an incomplete generation"
  [ ! -e "$case_dir/run/list.pid" ] || fail "$phase leaked the worker PID file"
  if [ "$phase" = ruleset ]; then
    [ -s "$case_dir/copy.log" ] || fail "snapshot failure was not exercised"
  fi
  if [ "$phase" = nft ]; then
    [ "$(cat "$case_dir/nft.log")" = '-j list table inet forkop' ] || fail "failed nft snapshot must not mutate the table"
  else
    [ ! -s "$case_dir/nft.log" ] || fail "$phase failure reached nftables"
  fi
done

printf 'list transaction failure checks passed\n'
