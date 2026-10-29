#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$FORKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/context.json" <<'JSON'
{}
JSON

context="$(cat "$WORK_DIR/context.json")"

validate_fixture() {
  local source="$1"
  local normalized="$WORK_DIR/normalized-$(basename "$source")"
  node - "$source" "$normalized" <<'JS'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
input.settings ??= { '.name': 'settings', '.type': 'settings' };
if (input.settings.dns_server === undefined) input.settings.dns_server = ['77.88.8.8'];
if (input.settings.bootstrap_dns_server === undefined) input.settings.bootstrap_dns_server = ['77.88.8.8'];
if (input.settings.yacd_secret_key === undefined) input.settings.yacd_secret_key = 'test-clash-secret';
fs.writeFileSync(process.argv[3], JSON.stringify(input));
JS
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR" validate-runtime-fixture "$normalized" "$context"
}

assert_rejects() {
  local label="$1"
  local fixture="$2"
  local expected="$3"
  local output

  if output="$(validate_fixture "$fixture" 2>/dev/null)"; then
    fail "$label should be rejected"
  fi

  printf '%s\n' "$output" | grep -Fq "$expected" ||
    fail "$label: expected message containing '$expected', got '$output'"
}

cat >"$WORK_DIR/valid.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "list_update_enabled": "1",
    "update_interval": "1d",
    "latency_test_url": "https://latency.example/generate_204",
    "dns_type": "doh",
    "dns_server": [ "dns.google/dns-query", "cloudflare-dns.com/dns-query" ],
    "bootstrap_dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "dns_check_interval": "10s",
    "dns_recovery_check_interval": "60s",
    "dns_check_timeout": "2s",
    "dns_strategy": "prefer_ipv6",
    "dns_detour_enabled": "1",
    "dns_detour_section": "proxy",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "proxy"
  },
  "section": [
    {
      ".name": "detour",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\"}",
      "domain_suffix": [ "detour.example" ]
    },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "ports": [ "80", "1000-2000" ],
      "subscription_urls": [ "https://example.com/sub.txt" ],
      "subscription_url_settings": "{\"https://example.com/sub.txt\":{\"user_agent\":\"Agent/1.0\"}}",
      "subscription_update_enabled": "1",
      "subscription_update_interval": "12h",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_filter_mode": "mixed",
      "urltest_tolerance": "10000",
      "urltest_testing_url": "https://urltest.example/generate_204",
      "urltest_include_countries": [ "US" ],
      "urltest_exclude_regex": [ "bad.*" ],
      "detect_server_country": "flag_emoji",
      "domain": "commented.example # keep this note\nfull:exact-comment.example // and this note\nkeyword:clip",
      "domain_suffix": [ "example.org", "сайт.рф", "full:exact.example", "full:full:legacy.example", "full:пример.испытание", "keyword:video", "keyword:пример", "regex:^api[.]example$", "regex:^сайт[.]рф$" ],
      "domain_suffix_text": "text.example\nmünich.example\nkeyword:stream",
      "community_lists": [ "discord" ],
      "rule_set": [ "https://example.com/rules.srs" ],
      "rule_set_with_subnets": [ "/tmp/local.json" ],
      "domain_ip_lists": [ "https://example.com/mixed.lst" ],
      "outbound_detour_enabled": "1",
      "outbound_detour_section": "detour"
    },
    {
      ".name": "bypass",
      ".type": "section",
      "enabled": "1",
      "action": "bypass",
      "domain_suffix": [ "bypass.example" ]
    },
    {
      ".name": "custom_dns",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_type": "dot",
      "dns_server": "9.9.9.9:5353",
      "dns_detour_enabled": "1",
      "dns_detour_section": "proxy",
      "domain_suffix": [ "dns.example" ],
      "rule_set": [ "https://example.com/domain-only.srs" ],
      "domain_ip_lists": [ "https://example.com/domains.lst" ]
    },
    {
      ".name": "device_dns",
      ".type": "section",
      "enabled": "1",
      "action": "dns",
      "dns_server": "1.1.1.1",
      "fully_routed_ips": [ "192.0.2.2/32" ]
    }
  ],
  "server": [
    {
      ".name": "srv",
      ".type": "server",
      "enabled": "1",
      "routing_mode": "section",
      "routing_section": "proxy"
    }
  ]
}
JSON

validate_fixture "$WORK_DIR/valid.json"

cat >"$WORK_DIR/bad-dns-duration.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "bootstrap_dns_server": [ "77.88.8.8" ],
    "dns_check_interval": "ten seconds"
  },
  "section": []
}
JSON
assert_rejects "bad DNS interval" "$WORK_DIR/bad-dns-duration.json" "settings.dns_check_interval"

cat >"$WORK_DIR/bad-dns-server.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "1.1.1.1", "bad value" ],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": []
}
JSON
assert_rejects "bad DNS server" "$WORK_DIR/bad-dns-server.json" "Invalid main DNS server"

cat >"$WORK_DIR/bad-dns-strategy.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_strategy": "auto"
  },
  "section": []
}
JSON
assert_rejects "bad DNS strategy" "$WORK_DIR/bad-dns-strategy.json" "Unsupported DNS strategy 'auto'"

cat >"$WORK_DIR/empty-main-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [],
    "bootstrap_dns_server": [ "77.88.8.8" ]
  },
  "section": []
}
JSON
assert_rejects "empty main DNS list" "$WORK_DIR/empty-main-dns.json" "At least one main DNS server is required"

cat >"$WORK_DIR/empty-bootstrap-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "77.88.8.8" ],
    "bootstrap_dns_server": []
  },
  "section": []
}
JSON
assert_rejects "empty Bootstrap DNS list" "$WORK_DIR/empty-bootstrap-dns.json" "At least one Bootstrap DNS server is required"

cat >"$WORK_DIR/hostname-bootstrap-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "dns.google" ],
    "bootstrap_dns_server": [ "dns.example.com" ]
  }
}
JSON
# A hostname here cannot resolve itself, so sing-box may fail to bootstrap.
# That is reported as a warning: aborting validation would stop Forkop from
# starting on a configuration which was accepted when it was written.
validate_fixture "$WORK_DIR/hostname-bootstrap-dns.json" >/dev/null ||
  fail "hostname Bootstrap DNS should warn, not abort validation"

cat >"$WORK_DIR/url-bootstrap-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "dns.google" ],
    "bootstrap_dns_server": [ "https://1.1.1.1/dns-query" ]
  }
}
JSON
validate_fixture "$WORK_DIR/url-bootstrap-dns.json" >/dev/null ||
  fail "URL Bootstrap DNS should warn, not abort validation"

cat >"$WORK_DIR/ipv6-bootstrap-dns.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_server": [ "dns.google" ],
    "bootstrap_dns_server": [ "[2606:4700:4700::1111]:53" ]
  }
}
JSON
validate_fixture "$WORK_DIR/ipv6-bootstrap-dns.json" >/dev/null || fail "IPv6 Bootstrap DNS with port should be accepted"

cat >"$WORK_DIR/bad-dns-detour-bypass.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_detour_enabled": "1",
    "dns_detour_section": "bypass"
  },
  "section": [
    { ".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass" }
  ]
}
JSON
assert_rejects "DNS detour bypass" "$WORK_DIR/bad-dns-detour-bypass.json" "unsupported action 'bypass'"

cat >"$WORK_DIR/bad-direct-action.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "old", ".type": "section", "enabled": "1", "action": "direct" }
  ]
}
JSON
assert_rejects "bad direct action" "$WORK_DIR/bad-direct-action.json" "unsupported action 'direct'"

cat >"$WORK_DIR/bad-dns-rule-server.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "dns", ".type": "section", "enabled": "1", "action": "dns", "dns_server": "bad value", "domain_suffix": [ "example.org" ] }
  ]
}
JSON
assert_rejects "bad DNS rule server" "$WORK_DIR/bad-dns-rule-server.json" "invalid DNS server"

cat >"$WORK_DIR/bad-dns-rule-protocol.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "dns", ".type": "section", "enabled": "1", "action": "dns", "dns_type": "tcp", "dns_server": "9.9.9.9", "domain_suffix": [ "example.org" ] }
  ]
}
JSON
assert_rejects "bad DNS rule protocol" "$WORK_DIR/bad-dns-rule-protocol.json" "unsupported protocol 'tcp'"

cat >"$WORK_DIR/bad-dns-rule-matchers.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "dns", ".type": "section", "enabled": "1", "action": "dns", "dns_server": "9.9.9.9" }
  ]
}
JSON
assert_rejects "DNS rule without domain matchers" "$WORK_DIR/bad-dns-rule-matchers.json" "must contain at least one domain condition"

cat >"$WORK_DIR/bad-dns-rule-subnets.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "dns", ".type": "section", "enabled": "1", "action": "dns", "dns_server": "9.9.9.9", "rule_set_with_subnets": [ "https://example.com/mixed.srs" ] }
  ]
}
JSON
assert_rejects "DNS rule subnet extraction" "$WORK_DIR/bad-dns-rule-subnets.json" "domain-only rule sets"

cat >"$WORK_DIR/bad-dns-rule-detour.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "dns", ".type": "section", "enabled": "1", "action": "dns", "dns_server": "9.9.9.9", "dns_detour_enabled": "1", "dns_detour_section": "bypass", "domain_suffix": [ "example.org" ] },
    { ".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass", "domain_suffix": [ "bypass.example" ] }
  ]
}
JSON
assert_rejects "DNS rule unsupported detour" "$WORK_DIR/bad-dns-rule-detour.json" "unsupported action 'bypass'"

cat >"$WORK_DIR/bad-port.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "ports": [ "70000" ] }
  ]
}
JSON
assert_rejects "bad port" "$WORK_DIR/bad-port.json" "Invalid port condition '70000'"

cat >"$WORK_DIR/bad-subscription.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "subscription_urls": [ "https://example.com/a| Agent" ] }
  ]
}
JSON
assert_rejects "bad subscription" "$WORK_DIR/bad-subscription.json" "Configure User-Agent in the subscription item settings"

cat >"$WORK_DIR/legacy-manual-hwid.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection" }
  ],
  "subscription_url": [
    {
      ".name": "proxy_sub_1",
      ".type": "subscription_url",
      "section": "proxy",
      "url": "https://example.com/sub.txt",
      "auto_hwid": "0"
    }
  ]
}
JSON
validate_fixture "$WORK_DIR/legacy-manual-hwid.json"

cat >"$WORK_DIR/bad-latency-url.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "latency_test_url": "ftp://example.com/ping"
  },
  "section": []
}
JSON
assert_rejects "bad latency URL" "$WORK_DIR/bad-latency-url.json" "settings.latency_test_url"

cat >"$WORK_DIR/bad-urltest-tolerance.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_tolerance": "10001"
    }
  ]
}
JSON
assert_rejects "bad URLTest tolerance" "$WORK_DIR/bad-urltest-tolerance.json" "Use a number from 0 to 10000"

cat >"$WORK_DIR/bad-detour.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "first", ".type": "section", "enabled": "1", "action": "proxy", "outbound_detour_enabled": "1", "outbound_detour_section": "second" },
    { ".name": "second", ".type": "section", "enabled": "1", "action": "proxy", "outbound_detour_enabled": "1", "outbound_detour_section": "first" }
  ]
}
JSON
assert_rejects "bad detour" "$WORK_DIR/bad-detour.json" "creates a cycle"

cat >"$WORK_DIR/bad-list-reference.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "proxy", ".type": "section", "enabled": "1", "action": "proxy", "domain_ip_lists": [ "ftp://example.com/list.lst" ] }
  ]
}
JSON
assert_rejects "bad list reference" "$WORK_DIR/bad-list-reference.json" "Unknown plain list reference"

cat >"$WORK_DIR/bad-country.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_filter_mode": "include",
      "urltest_include_countries": [ "USA" ]
    }
  ]
}
JSON
assert_rejects "bad country" "$WORK_DIR/bad-country.json" "Invalid country code 'USA'"

# Zapret, Zapret2 and ByeDPI are retired: an enabled rule that still names one
# is refused (migration disables such rules).
for retired in zapret zapret2 byedpi; do
  cat >"$WORK_DIR/retired-$retired.json" <<JSON
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    { ".name": "old", ".type": "section", "enabled": "1", "action": "$retired" }
  ]
}
JSON
  assert_rejects "retired $retired action" "$WORK_DIR/retired-$retired.json" "unsupported action '$retired'"
done

printf 'config validator runtime checks passed\n'

