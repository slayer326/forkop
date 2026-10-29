#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
UI_UC="$FORKOP_LIB/service/ui.uc"
WORK_DIR="$(mktemp -d)"
PROBE_BIN="$WORK_DIR/sing-box"
PROBE_COUNT="$WORK_DIR/probe-count"
PROBE_PIDS="$WORK_DIR/probe-pids"
CACHE_FILE="$WORK_DIR/sing-box-version-cache"

cleanup() {
  if [ -f "$PROBE_PIDS" ]; then
    while IFS= read -r pid; do
      kill -9 "$pid" 2>/dev/null || true
    done <"$PROBE_PIDS"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$PROBE_BIN" <<'SH'
#!/bin/sh
printf '%s\n' "$$" >>"$FORKOP_TEST_SING_BOX_PROBE_PIDS"
printf 'probe\n' >>"$FORKOP_TEST_SING_BOX_PROBE_COUNT"
if [ "${FORKOP_TEST_SING_BOX_PROBE_MODE:-fast}" = "slow" ]; then
  exec sleep 30
fi
printf 'sing-box version 1.13.14\n\n'
printf 'Tags: %s\n' "${FORKOP_TEST_SING_BOX_PROBE_TAGS:-with_quic,with_tailscale}"
SH
chmod 755 "$PROBE_BIN"
cat >"$WORK_DIR/apk" <<'SH'
#!/bin/sh
if [ "$1" = "list" ] && [ "$2" = "--installed" ] && [ "$3" = "--manifest" ]; then
  printf '%s\n' "${FORKOP_TEST_APK_MANIFEST:-}"
  exit 0
fi
# Tiny provides the virtual sing-box dependency. info -e cannot distinguish it.
if [ "$1" = "info" ] && [ "$2" = "-e" ]; then
  exit 0
fi
exit 1
SH
chmod 755 "$WORK_DIR/apk"
cat >"$WORK_DIR/opkg" <<'SH'
#!/bin/sh
if [ "$1" = "list-installed" ]; then
  printf '%s\n' "${FORKOP_TEST_OPKG_MANIFEST:-}"
fi
exit 0
SH
chmod 755 "$WORK_DIR/opkg"

ui_capabilities() {
  PATH="$WORK_DIR:$PATH" \
  FORKOP_CONFIG_NAME=forkop-ui-probe-test \
  FORKOP_UI_STATE_DIR="$WORK_DIR/state" \
  FORKOP_UI_COMPONENT_ACTION_DIR="$WORK_DIR/components" \
  FORKOP_UI_SING_BOX_VERSION_CACHE_FILE="$CACHE_FILE" \
  FORKOP_UI_SING_BOX_VARIANT_STATE_FILE="$WORK_DIR/missing-variant" \
  FORKOP_UI_SING_BOX_BIN_PATH="$PROBE_BIN" \
  FORKOP_UI_SING_BOX_VERSION_PROBE_TIMEOUT_SECONDS=1 \
  FORKOP_UI_SING_BOX_VERSION_PROBE_FAILURE_TTL_SECONDS=30 \
  FORKOP_TEST_SING_BOX_PROBE_COUNT="$PROBE_COUNT" \
  FORKOP_TEST_SING_BOX_PROBE_PIDS="$PROBE_PIDS" \
  ucode -L "$FORKOP_LIB" "$UI_UC" get-ui-capabilities
}

fast_first="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
fast_second="$(FORKOP_TEST_SING_BOX_PROBE_MODE=fast ui_capabilities)"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "successful sing-box capability detection must be cached by binary signature"

JSON_VALUE="$fast_first" node - <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 1) {
  console.error('cached sing-box capability flags mismatch');
  process.exit(1);
}
NODE
[ "$fast_first" = "$fast_second" ] ||
  fail "cached sing-box capabilities must match the initial detection"

: >"$PROBE_COUNT"
: >"$PROBE_PIDS"
rm -rf "$CACHE_FILE" "$CACHE_FILE.lock"

start_seconds=$SECONDS
workers=""
for index in 1 2 3 4 5; do
  FORKOP_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >"$WORK_DIR/slow-$index.json" &
  workers="$workers $!"
done
for worker in $workers; do
  wait "$worker"
done
elapsed_seconds=$((SECONDS - start_seconds))

[ "$elapsed_seconds" -le 4 ] ||
  fail "bounded sing-box probes took ${elapsed_seconds}s"
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "parallel UI requests must share one sing-box probe"

for output in "$WORK_DIR"/slow-*.json; do
  JSON_FILE="$output" node - <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.env.JSON_FILE, 'utf8'));
if (value.sing_box_extended !== 0 || value.sing_box_tiny !== 0 || value.sing_box_tailscale !== 0) {
  console.error('failed sing-box probe must produce conservative capability flags');
  process.exit(1);
}
NODE
done

FORKOP_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities >/dev/null
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] ||
  fail "failed sing-box probe must be cached during the retry cooldown"

while IFS= read -r pid; do
  if kill -0 "$pid" 2>/dev/null; then
    fail "timed-out sing-box probe process $pid is still running"
  fi
done <"$PROBE_PIDS"
: >"$PROBE_PIDS"

assert_capabilities() {
  local output="$1" package="$2" extended="$3" tiny="$4" compressed="$5" tailscale="$6"
  JSON_VALUE="$output" node - "$package" "$extended" "$tiny" "$compressed" "$tailscale" <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
const fields = ['sing_box_package', 'sing_box_extended', 'sing_box_tiny', 'sing_box_compressed', 'sing_box_tailscale'];
const expected = process.argv.slice(2).map((v, i) => i ? Number(v) : v);
for (let i = 0; i < fields.length; i++) {
  if (value[fields[i]] !== expected[i]) {
    console.error(`${fields[i]}: expected ${expected[i]}, got ${value[fields[i]]}`);
    process.exit(1);
  }
}
NODE
}

# Exact package names supersede all old variant markers. Regular packages use
# the bounded, cached probe only to inspect build capabilities, not identity.
: >"$PROBE_COUNT"
rm -f "$CACHE_FILE"
for marker in tiny extended extended-compressed; do
  printf '%s\n' "$marker" >"$WORK_DIR/missing-variant"
  regular="$(FORKOP_TEST_APK_MANIFEST='sing-box 1.13.14-r1' ui_capabilities)"
  assert_capabilities "$regular" sing-box 0 0 0 1
done
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] || fail "regular package build capabilities must be cached across stale markers"
tiny="$(FORKOP_TEST_APK_MANIFEST='sing-box-tiny 1.13.14-r1' ui_capabilities)"
assert_capabilities "$tiny" sing-box-tiny 0 1 0 0
extended="$(FORKOP_TEST_APK_MANIFEST='sing-box-extended 1.13.14-r1' ui_capabilities)"
assert_capabilities "$extended" sing-box-extended 1 0 0 1
regular_opkg="$(FORKOP_TEST_OPKG_MANIFEST='sing-box - 1.13.14-r1' ui_capabilities)"
assert_capabilities "$regular_opkg" sing-box 0 0 0 1
tiny_opkg="$(FORKOP_TEST_OPKG_MANIFEST='sing-box-tiny - 1.13.14-r1' ui_capabilities)"
assert_capabilities "$tiny_opkg" sing-box-tiny 0 1 0 0
[ "$(wc -l <"$PROBE_COUNT")" -eq 1 ] || fail "Tiny/Extended identity and cached regular capabilities must not trigger extra probes"

rm -f "$CACHE_FILE"
regular_without_tailscale="$(FORKOP_TEST_SING_BOX_PROBE_TAGS=with_quic FORKOP_TEST_APK_MANIFEST='sing-box 1.13.14-r1' ui_capabilities)"
assert_capabilities "$regular_without_tailscale" sing-box 0 0 0 0
regular_without_tailscale_cached="$(FORKOP_TEST_SING_BOX_PROBE_TAGS=with_quic FORKOP_TEST_APK_MANIFEST='sing-box 1.13.14-r1' ui_capabilities)"
[ "$regular_without_tailscale" = "$regular_without_tailscale_cached" ] || fail "regular package without Tailscale must retain cached capabilities"
[ "$(wc -l <"$PROBE_COUNT")" -eq 2 ] || fail "regular package without Tailscale must use exactly one fresh probe"

rm -f "$WORK_DIR/missing-variant"
unknown="$(FORKOP_TEST_SING_BOX_PROBE_TAGS=with_quic FORKOP_TEST_APK_MANIFEST='sing-box-tools 1.0-r1' ui_capabilities)"
assert_capabilities "$unknown" '' 0 0 0 0

# A regular package must not bypass the component-update guard; unknown
# identity also retains the existing no-probe behavior during replacement.
rm -f "$CACHE_FILE"
: >"$PROBE_COUNT"
mkdir -p "$WORK_DIR/components"
printf '%s\n' '{"running":true,"component":"sing_box"}' >"$WORK_DIR/components/update.json"
updating_regular="$(FORKOP_TEST_SING_BOX_PROBE_MODE=slow FORKOP_TEST_APK_MANIFEST='sing-box 1.13.14-r1' ui_capabilities)"
assert_capabilities "$updating_regular" sing-box 0 0 0 0
updating_unknown="$(FORKOP_TEST_SING_BOX_PROBE_MODE=slow ui_capabilities)"
assert_capabilities "$updating_unknown" '' 0 0 0 1
[ ! -s "$PROBE_COUNT" ] || fail "component replacement must not execute the changing sing-box binary"

printf 'UI sing-box probe checks passed\n'
