#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
OVERRIDE_UC="$FORKOP_LIB/config/urltest_override.uc"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

: >"$WORK_DIR/config.state"
FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group \
    https://example.com/generate_204 70s 175 30m 1

grep -Fq 'forkop.cfg000001=urltest_override' "$WORK_DIR/config.state" ||
  fail "save must create a URLTest override section"
grep -Fq 'forkop.cfg000001.testing_url=https://example.com/generate_204' "$WORK_DIR/config.state" ||
  fail "save must persist the testing URL"

cat >"$WORK_DIR/apply.uc" <<'EOF'
let override = require("config.urltest_override");
let outbound = { type: "urltest", url: "source", interval: "3m", tolerance: 50, idle_timeout: "30m", interrupt_exist_connections: false };
override.apply(outbound, "main", "group");
print(outbound.url, "|", outbound.interval, "|", outbound.tolerance, "|", outbound.idle_timeout, "|", outbound.interrupt_exist_connections, "\n");
EOF
applied="$(FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" ucode -L "$FORKOP_LIB" "$WORK_DIR/apply.uc")"
[ "$applied" = 'https://example.com/generate_204|70s|175|30m|true' ] ||
  fail "apply must overlay all URLTest runtime fields"

if FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" save main group bad-url 0s '' nope 2; then
  fail "save must reject invalid values"
fi

FORKOP_UCI_STATE_FILE="$WORK_DIR/config.state" \
  ucode -L "$FORKOP_LIB" "$OVERRIDE_UC" reset main group
if grep -Fq 'urltest_override' "$WORK_DIR/config.state"; then
  fail "reset must remove the URLTest override section"
fi

printf 'URLTest override checks passed\n'
