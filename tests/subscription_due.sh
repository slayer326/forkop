#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_status() {
  local expected="$1" label="$2" status=0
  shift 2
  "$@" >/dev/null 2>&1 || status="$?"
  [ "$status" = "$expected" ] || {
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$status" >&2
    exit 1
  }
}

cache_due() {
  ucode -L "$LIB" "$LIB/subscription/cache.uc" update-due-status-fixture "$@"
}

updates_due() {
  ucode -L "$LIB" "$LIB/components/updates.uc" "$@"
}

# A check up to one minute early must not postpone an hourly subscription
# until the next cron run. Short intervals and backwards time remain exact.
assert_status 0 'hourly within allowance' cache_due 103540 100000 3600
assert_status 0 'hourly one second early' cache_due 103599 100000 3600
assert_status 1 'hourly outside allowance' cache_due 103539 100000 3600
assert_status 0 'four-hour within allowance' cache_due 114399 100000 14400
assert_status 1 'four-hour outside allowance' cache_due 114339 100000 14400
assert_status 1 'short interval remains exact' cache_due 100059 100000 60
assert_status 0 'short interval reaches boundary' cache_due 100060 100000 60
assert_status 1 'backwards clock remains waiting' cache_due 99999 100000 3600
assert_status 0 'never updated is due' cache_due 100000 0 14400
assert_status 2 'invalid interval is rejected' cache_due 100000 100000 invalid

printf '100000\n' > "$WORK/timestamp"
cat > "$WORK/fixture.json" <<'JSON'
{"sections":[{".name":"VPN","enabled":"1","action":"connection","subscription_urls":["https://example.invalid/sub"],"subscription_update_enabled":"1"}],"settings":{"update_interval":"4h"}}
JSON

assert_status 0 'subscription entry point agrees with cache' updates_due \
  subscription-update-section-due-status-fixture "$WORK/fixture.json" VPN "$WORK/timestamp" 114399
assert_status 1 'list timing remains exact' updates_due \
  list-update-due-status-fixture "$WORK/fixture.json" "$WORK/timestamp" 114399

printf 'PASS: subscription due boundaries and separate list timing\n'
