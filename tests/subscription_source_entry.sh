#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
PARSER="$ROOT_DIR/forkop/files/usr/lib/subscription/parser.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_tsv() {
  local entry="$1"
  local expected_url="$2"
  local expected_user_agent="$3"
  local parsed tab url user_agent

  parsed="$(ucode -L "$FORKOP_LIB" "$PARSER" parse-source-entry-tsv "$entry")"
  tab="$(printf '\t')"
  url="${parsed%%"$tab"*}"
  if [ "$url" = "$parsed" ]; then
    user_agent=""
  else
    user_agent="${parsed#*"$tab"}"
  fi

  [ "$url" = "$expected_url" ] || fail "expected url $expected_url, got $url"
  [ "$user_agent" = "$expected_user_agent" ] || fail "expected user-agent $expected_user_agent, got $user_agent"
}

assert_rejects() {
  local entry="$1"
  local expected="$2"
  local output

  if output="$(ucode -L "$FORKOP_LIB" "$PARSER" parse-source-entry-tsv "$entry" 2>/dev/null)"; then
    fail "entry should be rejected: $entry"
  fi
  printf '%s\n' "$output" | grep -q "$expected" || fail "expected reject message containing $expected"
}

assert_tsv ' https://subscriptions.example/sub.txt ' 'https://subscriptions.example/sub.txt' ''
assert_tsv ' https://sub.flintnet.pro/b5_Ymcw6Rxo8vptW ' 'https://sub.flintnet.pro/b5_Ymcw6Rxo8vptW' ''
assert_tsv ' https://example.com/sub.txt ' 'https://example.com/sub.txt' ''
assert_tsv ' https://internet.matryoshka.my/a ' 'https://internet.matryoshka.my/a' ''
assert_tsv ' https://sub.hat.onl/nCVZ6cpZukZuS4yY ' 'https://sub.hat.onl/nCVZ6cpZukZuS4yY' ''
grep -Fq 'flintnetSubscriptionUrl(value) ? "0" : "1"' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" ||
  fail "LuCI must disable URLTest group imports by default for Flintnet"
grep -Fq 'main.validateUrl(parsed.url, ["https:"])' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js" ||
  fail "LuCI subscription validation must allow every valid HTTPS provider"
if grep -Fq 'supportedHosts' "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"; then
  fail "LuCI subscription validation must not contain a provider allowlist"
fi

assert_rejects 'https://subscriptions.example/a | Custom Agent/1.0' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://subscriptions.example/a | Agent One | Agent Two' 'Configure User-Agent in the subscription item settings'
assert_rejects 'https://subscriptions.example/a| Agent' 'Configure User-Agent in the subscription item settings'
assert_rejects 'http://subscriptions.example/sub.txt' 'Subscription URL must use HTTPS'
assert_rejects 'https:///sub.txt' 'Invalid URL format'
assert_rejects 'https://example.com/sub scription' 'Invalid URL format'
assert_rejects 'file:///tmp/sub.txt' 'Subscription URL must use HTTPS'

cat >"$WORK_DIR/require-subscription-parser.uc" <<'UCODE'
let parser = require("subscription.parser");

let parsed = parser.parse_subscription_source_entry("https://subscriptions.example/a");
if (!parsed.valid || parsed.url != "https://subscriptions.example/a" || parsed.user_agent != "")
    exit(1);

let legacy = parser.parse_subscription_source_entry("https://subscriptions.example/a | Agent");
if (legacy.valid || legacy.error != "Configure User-Agent in the subscription item settings")
    exit(1);

let invalid = parser.parse_subscription_source_entry("file:///tmp/sub.txt");
if (invalid.valid || invalid.error != "Subscription URL must use HTTPS")
    exit(1);

let flintnet = parser.parse_subscription_source_entry("https://sub.flintnet.pro/b5_Ymcw6Rxo8vptW");
if (!flintnet.valid || flintnet.url != "https://sub.flintnet.pro/b5_Ymcw6Rxo8vptW")
    exit(1);

let hat = parser.parse_subscription_source_entry("https://sub.hat.onl/nCVZ6cpZukZuS4yY");
if (!hat.valid || hat.url != "https://sub.hat.onl/nCVZ6cpZukZuS4yY")
    exit(1);

let foreign = parser.parse_subscription_source_entry("https://internet.matryoshka.my/a");
if (!foreign.valid || foreign.url != "https://internet.matryoshka.my/a")
    exit(1);
UCODE

ucode -L "$FORKOP_LIB" "$WORK_DIR/require-subscription-parser.uc"

printf 'subscription source entry checks passed\n'
