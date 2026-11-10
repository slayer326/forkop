#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
# shellcheck source=tests/helpers/source_checks.sh
. "$ROOT_DIR/tests/helpers/source_checks.sh"

# Run the production restart decision against the actual cache/download module,
# with only network and live-system commands replaced by isolated fixtures.
cat >"$WORK_DIR/restart.uc" <<'UCODE'
let fs = require("fs");
const UPDATES_UC = getenv("FORKOP_LIB") + "/components/updates.uc";
function quote(s) { return "'" + replace(s, /'/g, "'\\''") + "'"; }
function module_capture_with_env(path, args, overrides) {
    let command = "ucode -L " + quote(getenv("FORKOP_LIB")) + " " + quote(path);
    for (let name, value in (overrides || {}))
        command = name + "=" + quote(value) + " " + command;
    for (let arg in args) command += " " + quote(arg);
    let pipe = fs.popen(command, "r");
    let output = pipe.read("all");
    return { status: pipe.close(), output: output };
}
function module_success(path, args) {
    return module_capture_with_env(path, args, {}).status == 0;
}
function log_message(message, level) { print(level, ": ", message, "\n"); }
UCODE
source_function "$FORKOP_LIB/service/lifecycle.uc" prepare_manual_restart_lists >>"$WORK_DIR/restart.uc"
printf '\nexit(prepare_manual_restart_lists({ FORKOP_MANUAL_RESTART_LOCK_HELD: "1" }) ? 0 : 1);\n' >>"$WORK_DIR/restart.uc"

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/bin/sh
printf '192.0.2.1\n'
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
[ "${DOWNLOAD_FAIL:-0}" = 0 ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'cached.example\n' >"$2"; exit 0; fi
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

run() {
  env PATH="$WORK_DIR/bin:$PATH" CASE_DIR="$case_dir" DOWNLOAD_FAIL="$download_fail" \
    FORKOP_LIB="$FORKOP_LIB" FORKOP_UCI_STATE_FILE="$case_dir/uci.state" \
    TMP_SING_BOX_FOLDER="$case_dir/tmp" TMP_RULESET_FOLDER="$case_dir/rulesets" \
    FORKOP_RUNTIME_STATE_DIR="$case_dir/run" FORKOP_RELOAD_LOCK_DIR="$case_dir/run/reload.lock" \
    FORKOP_LIST_UPDATE_PID_FILE="$case_dir/run/list.pid" \
    FORKOP_PERSISTENT_LIST_CACHE_DIR="$case_dir/cache" \
    FORKOP_RULESET_CACHE_DIR="$case_dir/ruleset-cache" \
    FORKOP_RUNTIME_LIST_GENERATION_DIR="$case_dir/generation" \
    FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES="$cache_space" \
    FORKOP_SERVICE_INIT="$WORK_DIR/bin/init-forkop" \
    ucode -L "$FORKOP_LIB" "$@"
}

for scenario in online ram flash missing corrupt changed incomplete; do
  case_dir="$WORK_DIR/$scenario"
  mkdir -p "$case_dir/run" "$case_dir/rulesets"
  cat >"$case_dir/uci.state" <<'UCI'
forkop.settings=settings
forkop.settings.update_interval=1d
forkop.alpha=section
forkop.alpha.enabled=1
forkop.alpha.action=connection
forkop.alpha.remote_domain_lists=https://lists.test/domains.txt
UCI
  cache_space=33554432
  [ "$scenario" != ram ] || cache_space=0
  download_fail=0
  run "$FORKOP_LIB/service/state.uc" acquire-runtime-dir-lock "$case_dir/run/reload.lock" "$$" || fail "lock failed"
  if [ "$scenario" != missing ]; then
    run "$WORK_DIR/restart.uc" >"$case_dir/prepare.log" || fail "$scenario: online preparation failed"
    grep -Fq cached.example "$case_dir/rulesets/alpha-remote-domains-ruleset.json" || fail "list not materialized"
  fi
  if [ "$scenario" = flash ]; then
    # Simulate loss of RAM data at boot: restore must reconstruct it from flash.
    [ -s "$case_dir/cache/manifest.json" ] || fail "persistent fixture not saved"
    rm -rf "$case_dir/generation" "$case_dir/rulesets"
  elif [ "$scenario" = ram ]; then
    [ ! -e "$case_dir/cache/manifest.json" ] || fail "RAM fixture unexpectedly persisted"
  elif [ "$scenario" = corrupt ]; then
    printf 'corrupt\n' >>"$case_dir/cache/source-1"
    printf 'corrupt\n' >>"$case_dir/generation/source-1"
  elif [ "$scenario" = changed ]; then
    sed -i 's@lists.test/domains.txt@lists.test/changed.txt@' "$case_dir/uci.state"
  elif [ "$scenario" = incomplete ]; then
    # Checksums and current signature alone do not prove source completeness.
    printf 'forkop.alpha.remote_subnet_lists=https://lists.test/subnets.txt\n' >>"$case_dir/uci.state"
    signature="$(run "$FORKOP_LIB/service/state.uc" list-update-signature)"
    for manifest in "$case_dir/cache/manifest.json" "$case_dir/generation/manifest.json"; do
      ucode -e 'let fs = require("fs"); let value = json(fs.readfile(ARGV[0])); value.signature = ARGV[1]; fs.writefile(ARGV[0], sprintf("%J\n", value));' "$manifest" "$signature"
    done
    run "$FORKOP_LIB/components/updates.uc" restore-list-cache || fail "incomplete fixture is not otherwise valid"
    if run "$FORKOP_LIB/components/updates.uc" list-cache-complete; then fail "incomplete fixture has all sources"; fi
  fi
  download_fail=1
  [ "$scenario" != online ] || download_fail=0
  status=0
  run "$WORK_DIR/restart.uc" >"$case_dir/restart.log" || status=$?
  case "$scenario" in
    online|ram|flash)
      [ "$status" = 0 ] || fail "$scenario: usable generation rejected"
      grep -Fq cached.example "$case_dir/rulesets/alpha-remote-domains-ruleset.json" || fail "$scenario: restored list missing"
      if [ "$scenario" = online ]; then
        if grep -Fq 'complete validated list cache' "$case_dir/restart.log"; then fail "online refresh used fallback"; fi
      else
        grep -Fq 'complete validated list cache' "$case_dir/restart.log" || fail "$scenario: fallback not reported"
      fi
      ;;
    *) [ "$status" != 0 ] || fail "$scenario: unusable cache accepted" ;;
  esac
  [ ! -s "$case_dir/nft.log" ] || fail "$scenario: preflight changed live policy"
  [ ! -s "$case_dir/reload.log" ] || fail "$scenario: preflight reloaded runtime"
  [ ! -e "$case_dir/run/list.pid" ] || fail "$scenario: worker PID leaked"
  [ "$(run "$FORKOP_LIB/service/state.uc" runtime-dir-lock-owner "$case_dir/run/reload.lock")" = "$$" ] || fail "$scenario: parent lock released"
done
printf 'manual restart list cache checks passed\n'
