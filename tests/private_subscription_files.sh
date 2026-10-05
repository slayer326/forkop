#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mode_is() { [ "$(stat -c %a "$1")" = "$2" ] || fail "$1 must be mode $2"; }

mkdir -p "$WORK_DIR/run/section-cache" "$WORK_DIR/persistent" "$WORK_DIR/subscriptions"
printf '12\n' > "$WORK_DIR/run/cache-format"
printf '9\n' > "$WORK_DIR/persistent/cache-format"
printf '{}\n' > "$WORK_DIR/run/section-cache/old.json"
printf '{}\n' > "$WORK_DIR/persistent/old.json"
chmod 0755 "$WORK_DIR/run/section-cache" "$WORK_DIR/persistent" "$WORK_DIR/subscriptions"
chmod 0644 "$WORK_DIR/run/section-cache/old.json" "$WORK_DIR/persistent/old.json"

TMP_SING_BOX_FOLDER="$WORK_DIR/sing-box" \
TMP_RULESET_FOLDER="$WORK_DIR/sing-box/rulesets" \
TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/run" \
FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR="$WORK_DIR/persistent" \
  ucode -L "$LIB" "$LIB/subscription/cache.uc" ensure-runtime-cache-format

mode_is "$WORK_DIR/run/section-cache" 700
mode_is "$WORK_DIR/run/section-cache/old.json" 600
mode_is "$WORK_DIR/persistent" 700
mode_is "$WORK_DIR/persistent/old.json" 600
mode_is "$WORK_DIR/subscriptions" 700

printf 'trojan://password@127.0.0.1:443?sni=example.test#probe\n' > "$WORK_DIR/input.txt"
ucode -L "$LIB" "$LIB/subscription/parser.uc" normalize-content \
  "$WORK_DIR/input.txt" "$WORK_DIR/normalized.json"
mode_is "$WORK_DIR/normalized.json" 600

chmod 0644 "$WORK_DIR/normalized.json"
ucode -L "$LIB" -e \
  'let links = require("subscription.share_link"); if (!links.populate_subscription_file(ARGV[0])) exit(1);' \
  "$WORK_DIR/normalized.json"
mode_is "$WORK_DIR/normalized.json" 600

printf 'Private subscription file checks passed\n'
