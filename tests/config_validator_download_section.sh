#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$ROOT_DIR/forkop/files/usr/lib/config/validator.uc"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

rows() {
  printf '%s\t%s\t%s\t%s\n' "$@"
}

assert_accepts() {
  local target="$1"
  shift

  rows "$@" | ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-download-section "$target"
}

assert_rejects() {
  local label="$1"
  local expected="$2"
  local target="$3"
  shift 3
  local output

  if output="$(rows "$@" | ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-download-section "$target" 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

assert_accepts proxy proxy 1 proxy 1
assert_accepts outbound outbound 1 outbound 1
assert_accepts vpn vpn 1 vpn 1

assert_rejects "empty target" "no download section is selected" "" proxy 1 proxy 1
assert_rejects "missing target" "references missing rule 'missing'" missing proxy 1 proxy 1
assert_rejects "disabled target" "references disabled rule 'proxy'" proxy proxy 0 proxy 1
assert_rejects "retired zapret rule" "cannot provide an outbound" zap zap 1 zapret 0
assert_rejects "retired byedpi rule" "cannot provide an outbound" bye bye 1 byedpi 0
assert_rejects "unsupported action" "cannot provide an outbound" bypass bypass 1 bypass 0
assert_rejects "empty connection" "has no proxy source" proxy proxy 1 proxy 0

printf 'config validator download section checks passed\n'
