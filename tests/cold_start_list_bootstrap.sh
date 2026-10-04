#!/usr/bin/env bash
set -euo pipefail

# A cold start with list downloads through a selected section gets a private,
# temporary procd configuration.  It contains no interception policy and the
# previous live file is restored byte-for-byte, including its mode.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$LIB/singbox/generator.uc"
RUNTIME="$LIB/singbox/runtime.uc"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
UCODE_BIN="$(command -v ucode)" || fail "ucode is required"

mkdir -p "$WORK/ipv6/all" "$WORK/ipv6/lo" "$WORK/run/section-cache" "$WORK/bin"
printf '0\n' >"$WORK/ipv6/all/disable_ipv6"
printf '0\n' >"$WORK/ipv6/lo/disable_ipv6"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/logger"
chmod 0755 "$WORK/bin/logger"

cat >"$WORK/fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "dns_detour_enabled": "1",
    "dns_detour_section": "dns_path",
    "service_listen_address": "127.0.0.1",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "selected"
  },
  "section": [
    {
      ".name": "selected", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.10\",\"server_port\":1080}",
      "domain_suffix": ["selected.example"],
      "rule_set": ["https://lists.example/selected.srs"]
    },
    {
      ".name": "unrelated", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.20\",\"server_port\":1080}",
      "domain_suffix": ["unrelated.example"]
    },
    {
      ".name": "dns_path", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.30\",\"server_port\":1080}",
      "domain_suffix": ["dns.example"]
    }
  ]
}
JSON

FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" \
FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 \
  "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
  "$WORK/fixture.json" "$WORK/bootstrap.json" 127.0.0.1 0 1 '' 1.14.0 ||
  fail "bootstrap generator rejected a valid selected section"

node - "$WORK/bootstrap.json" <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function ok(value, message) { if (!value) throw new Error(message); }
ok(Array.isArray(c.inbounds) && c.inbounds.length === 1, 'bootstrap must expose exactly one inbound');
const inbound = c.inbounds[0];
ok(inbound.type === 'mixed' && inbound.listen === '127.0.0.1' && inbound.listen_port === 4534,
  'bootstrap inbound must be the loopback list service proxy');
ok(Array.isArray(c.route.rules) && c.route.rules.length === 1,
  'bootstrap must contain only the service inbound route');
ok(c.route.rules[0].inbound === inbound.tag,
  'bootstrap route must be scoped to the service inbound');
ok(c.route.rule_set === undefined, 'bootstrap must not declare rule sets');
ok(c.experimental === undefined, 'bootstrap must not expose Clash API or shared cache');
ok(Array.isArray(c.dns.rules) && c.dns.rules.length === 0,
  'bootstrap must not install production DNS rules');
ok(c.inbounds.every(i => i.type !== 'tproxy' && i.type !== 'direct'),
  'bootstrap must not expose TPROXY or DNS listeners');
ok(c.outbounds.some(o => o.server === '192.0.2.10'), 'selected connection is missing');
ok(c.outbounds.some(o => o.server === '192.0.2.30'), 'DNS detour connection is missing');
ok(!c.outbounds.some(o => o.server === '192.0.2.20'), 'unrelated connection leaked into bootstrap');
ok(c.outbounds.some(o => o.tag === c.route.rules[0].outbound),
  'service route references a missing selected outbound');
const dnsDetours = c.dns.servers.map(s => s.detour).filter(Boolean);
ok(dnsDetours.length > 0 && dnsDetours.every(tag => c.outbounds.some(o => o.tag === tag)),
  'DNS server references a missing detour outbound');
ok(!JSON.stringify(c).includes('support_x25519mlkem768'),
  'bootstrap restored automatic ML-KEM negotiation');
NODE

node - "$WORK/fixture.json" "$WORK/missing.json" <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
c.settings.download_lists_via_proxy_section = 'missing';
fs.writeFileSync(process.argv[3], JSON.stringify(c));
NODE
if FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 \
  "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
  "$WORK/missing.json" "$WORK/missing-output.json" 127.0.0.1 0 1 '' 1.14.0 \
  >"$WORK/missing.log" 2>&1; then
  fail "bootstrap accepted a missing selected section"
fi
grep -Fq 'list download section has no usable connection' "$WORK/missing.log" ||
  fail "missing selected section did not produce a useful reason"

# A subscription-only list connection can be recovered through another ready
# section before the list transport is built.  Its service port must keep the
# same index it has in the full configured section set.
cat >"$WORK/subscription-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "service_listen_address": "127.0.0.1",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "selected"
  },
  "section": [
    {
      ".name": "selected", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/selected"],
      "subscription_url_settings": "{\"https://subscriptions.example/selected\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"transport\"}}"
    },
    {
      ".name": "transport", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.40\",\"server_port\":1080}"
    },
    {
      ".name": "unrelated", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.50\",\"server_port\":1080}"
    }
  ]
}
JSON
FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" \
FORKOP_LIFECYCLE_SUBSCRIPTION_BOOTSTRAP=1 \
  "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
  "$WORK/subscription-fixture.json" "$WORK/subscription-bootstrap.json" \
  127.0.0.1 0 1 selected 1.14.0 ||
  fail "subscription dependency bootstrap was rejected"
node - "$WORK/subscription-bootstrap.json" <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function ok(value, message) { if (!value) throw new Error(message); }
ok(c.outbounds.some(o => o.server === '192.0.2.40'), 'subscription transport is missing');
ok(!c.outbounds.some(o => o.server === '192.0.2.50'), 'unrelated transport leaked');
ok(!JSON.stringify(c).includes('subscriptions.example'), 'deferred section leaked into bootstrap');
ok(c.inbounds.length === 1 && c.inbounds[0].type === 'mixed', 'subscription proxy inbound missing');
ok(c.inbounds[0].listen === '127.0.0.1' && c.inbounds[0].listen_port === 4536,
  'subscription proxy did not retain its full-config port');
ok(c.route.rules.length === 1 && c.route.rules[0].inbound === c.inbounds[0].tag,
  'subscription proxy route is not isolated');
ok(c.outbounds.some(o => o.tag === c.route.rules[0].outbound),
  'subscription proxy route references a missing outbound');
NODE
[ "$(stat -c %a "$WORK/subscription-bootstrap.json.section-cache")" = 700 ] ||
  fail "subscription bootstrap section-cache directory is not private"
[ "$(stat -c %a "$WORK/subscription-bootstrap.json.section-cache/transport.json")" = 600 ] ||
  fail "subscription bootstrap section-cache file is not private"

# The full runtime must keep the stable service-proxy port for a deferred
# subscription source, so it can recover through the configured ready section
# after startup without a direct fallback.
node - "$WORK/subscription-fixture.json" "$WORK/subscription-final-fixture.json" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
input.settings.download_lists_via_proxy = '0';
delete input.settings.download_lists_via_proxy_section;
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" \
  "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
  "$WORK/subscription-final-fixture.json" "$WORK/subscription-final.json" \
  127.0.0.1 0 1 selected 1.14.0 ||
  fail "full generator rejected a deferred subscription with a ready transport"
node - "$WORK/subscription-final.json" <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function ok(value, message) { if (!value) throw new Error(message); }
const inbound = c.inbounds.find(i => i.type === 'mixed' && i.listen_port === 4536);
ok(inbound, 'stable deferred-subscription service inbound is missing');
const route = c.route.rules.find(r => r.inbound === inbound.tag);
ok(route, 'deferred-subscription service route is missing');
const selector = c.outbounds.find(o => o.tag === route.outbound);
ok(selector && selector.type === 'selector' && Array.isArray(selector.outbounds) &&
  selector.outbounds.some(tag => c.outbounds.some(o =>
    o.tag === tag && o.server === '192.0.2.40')),
  'deferred-subscription service route does not use its configured transport');
ok(!JSON.stringify(c).includes('subscriptions.example'),
  'deferred subscription source leaked into the initial full config');
NODE

# Startup closure is broader than list downloads: component service proxies,
# global DNS, and outbound detours of retained sections are structural roots.
# An unrelated deferred leaf must remain for the ordinary post-start worker.
cat >"$WORK/startup-closure-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "dns_detour_enabled": "1",
    "dns_detour_section": "dns_path",
    "download_lists_via_proxy": "1",
    "download_lists_via_proxy_section": "selected",
    "download_components_via_proxy": "1",
    "download_components_via_proxy_section": "component"
  },
  "section": [
    {
      ".name": "selected", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/selected"],
      "subscription_url_settings": "{\"https://subscriptions.example/selected\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    },
    {
      ".name": "component", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/component"],
      "subscription_url_settings": "{\"https://subscriptions.example/component\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    },
    {
      ".name": "dns_path", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/dns"],
      "subscription_url_settings": "{\"https://subscriptions.example/dns\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    },
    {
      ".name": "terminal", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.60\",\"server_port\":1080}"
    },
    {
      ".name": "active", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.61\",\"server_port\":1080}",
      "outbound_detour_enabled": "1", "outbound_detour_section": "structural"
    },
    {
      ".name": "structural", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/structural"],
      "subscription_url_settings": "{\"https://subscriptions.example/structural\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    },
    {
      ".name": "dns_rule", ".type": "section", "enabled": "1", "action": "dns",
      "dns_server": "9.9.9.9", "domain_suffix": ["dns-rule.example"],
      "dns_detour_enabled": "1", "dns_detour_section": "rule_dns_path"
    },
    {
      ".name": "rule_dns_path", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/rule-dns"],
      "subscription_url_settings": "{\"https://subscriptions.example/rule-dns\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    },
    {
      ".name": "unrelated", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/unrelated"],
      "subscription_url_settings": "{\"https://subscriptions.example/unrelated\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"terminal\"}}"
    }
  ]
}
JSON
required="$($UCODE_BIN -L "$LIB" "$GENERATOR" startup-required-deferred-fixture \
  "$WORK/startup-closure-fixture.json" 'selected component dns_path structural rule_dns_path unrelated')" ||
  fail "startup dependency closure fixture failed"
[ "$required" = 'selected component dns_path structural rule_dns_path' ] ||
  fail "startup dependency closure was '$required'"

node - "$WORK/startup-closure-fixture.json" "$WORK/unrelated-only-fixture.json" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
input.settings.download_lists_via_proxy = '0';
input.settings.download_components_via_proxy = '0';
input.settings.dns_detour_enabled = '0';
const active = input.section.find(section => section['.name'] === 'active');
active.outbound_detour_enabled = '0';
delete active.outbound_detour_section;
const dnsRule = input.section.find(section => section['.name'] === 'dns_rule');
dnsRule.dns_detour_enabled = '0';
delete dnsRule.dns_detour_section;
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
required="$($UCODE_BIN -L "$LIB" "$GENERATOR" startup-required-deferred-fixture \
  "$WORK/unrelated-only-fixture.json" unrelated)" ||
  fail "unrelated dependency closure fixture failed"
[ -z "$required" ] || fail "unrelated deferred leaf became a startup dependency: $required"

# Nested subscription transports are valid when the dependency graph reaches a
# ready terminal connection; a cycle without a terminal must fail closed.
cat >"$WORK/nested-subscription-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings", ".type": "settings",
    "config_path": "/tmp/sing-box/config.json",
    "dns_server": "1.1.1.1",
    "dns_detour_enabled": "1",
    "dns_detour_section": "A",
    "service_listen_address": "127.0.0.1"
  },
  "section": [
    {
      ".name": "A", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/A"],
      "subscription_url_settings": "{\"https://subscriptions.example/A\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"B\"}}"
    },
    {
      ".name": "B", ".type": "section", "enabled": "1", "action": "connection",
      "subscription_urls": ["https://subscriptions.example/B"],
      "subscription_url_settings": "{\"https://subscriptions.example/B\":{\"download_via_proxy_enabled\":\"1\",\"download_via_proxy_section\":\"C\"}}"
    },
    {
      ".name": "C", ".type": "section", "enabled": "1", "action": "outbound",
      "outbound_json": "{\"type\":\"socks\",\"server\":\"192.0.2.70\",\"server_port\":1080}"
    }
  ]
}
JSON
"$UCODE_BIN" -L "$LIB" "$LIB/subscription/cache.uc" \
  subscription-bootstrap-ready-fixture "$WORK/nested-subscription-fixture.json" 'A B' ||
  fail "nested subscription dependency with a ready terminal was rejected"
FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" FORKOP_LIFECYCLE_SUBSCRIPTION_BOOTSTRAP=1 \
  "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
  "$WORK/nested-subscription-fixture.json" "$WORK/nested-subscription-bootstrap.json" \
  127.0.0.1 0 1 'A B' 1.14.0 ||
  fail "nested subscription bootstrap could not expose the ready terminal"
node - "$WORK/nested-subscription-bootstrap.json" <<'NODE'
const fs = require('fs');
const c = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
function ok(value, message) { if (!value) throw new Error(message); }
ok(c.outbounds.some(o => o.server === '192.0.2.70'), 'nested terminal outbound is missing');
ok(c.inbounds.length === 1 && c.inbounds[0].listen_port === 4537,
  'nested terminal did not retain its full configured service port');
ok(c.route.rules.length === 1 && c.outbounds.some(o => o.tag === c.route.rules[0].outbound),
  'nested terminal service route references a missing outbound');
const dnsDetours = c.dns.servers.map(server => server.detour).filter(Boolean);
ok(dnsDetours.length > 0 && dnsDetours.every(tag => c.outbounds.some(o => o.tag === tag)),
  'bootstrap DNS does not use the available configured dependency');
ok(dnsDetours.every(tag => tag === c.route.rules[0].outbound),
  'bootstrap DNS escaped the configured terminal dependency');
NODE
node - "$WORK/nested-subscription-fixture.json" "$WORK/cyclic-subscription-fixture.json" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const b = input.section.find(section => section['.name'] === 'B');
b.subscription_url_settings = JSON.stringify({
  'https://subscriptions.example/B': {
    download_via_proxy_enabled: '1', download_via_proxy_section: 'A'
  }
});
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
if "$UCODE_BIN" -L "$LIB" "$LIB/subscription/cache.uc" \
  subscription-bootstrap-ready-fixture "$WORK/cyclic-subscription-fixture.json" 'A B'; then
  fail "cyclic subscription dependency was accepted without a ready terminal"
fi

# Provider actions need their own runtime/nft policy, which intentionally is
# absent in the pre-start transport. Reject them immediately instead of
# silently downloading direct or waiting on a proxy that cannot exist yet.
for provider in byedpi zapret zapret2; do
  node - "$WORK/fixture.json" "$WORK/provider-$provider.json" "$provider" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const selected = input.section.find(section => section['.name'] === 'selected');
selected.action = process.argv[4];
delete selected.outbound_json;
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
  if FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 \
    "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
    "$WORK/provider-$provider.json" "$WORK/provider-$provider-output.json" \
    127.0.0.1 0 1 '' 1.14.0 >"$WORK/provider-$provider.log" 2>&1; then
    fail "list bootstrap accepted unavailable provider action $provider"
  fi
  grep -Fq 'initial list download through a section requires a Connection/VPN rule' \
    "$WORK/provider-$provider.log" ||
    fail "provider action $provider did not produce a clear bootstrap reason"

  node - "$WORK/subscription-fixture.json" "$WORK/subscription-provider-$provider.json" "$provider" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const transport = input.section.find(section => section['.name'] === 'transport');
transport.action = process.argv[4];
delete transport.outbound_json;
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
  if FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" FORKOP_LIFECYCLE_SUBSCRIPTION_BOOTSTRAP=1 \
    "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
    "$WORK/subscription-provider-$provider.json" "$WORK/subscription-provider-$provider-output.json" \
    127.0.0.1 0 1 selected 1.14.0 >"$WORK/subscription-provider-$provider.log" 2>&1; then
    fail "subscription bootstrap accepted provider dependency $provider"
  fi
  grep -Fq 'subscription bootstrap requires Connection/VPN dependency rules' \
    "$WORK/subscription-provider-$provider.log" ||
    fail "subscription provider dependency $provider did not produce a clear reason"

  node - "$WORK/fixture.json" "$WORK/dns-provider-$provider.json" "$provider" <<'NODE'
const fs = require('fs');
const input = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const dnsPath = input.section.find(section => section['.name'] === 'dns_path');
dnsPath.action = process.argv[4];
delete dnsPath.outbound_json;
fs.writeFileSync(process.argv[3], JSON.stringify(input));
NODE
  if FORKOP_IPV6_SYSCTL_DIR="$WORK/ipv6" FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 \
    "$UCODE_BIN" -L "$LIB" "$GENERATOR" generate-config-fixture \
    "$WORK/dns-provider-$provider.json" "$WORK/dns-provider-$provider-output.json" \
    127.0.0.1 0 1 '' 1.14.0 >"$WORK/dns-provider-$provider.log" 2>&1; then
    fail "list bootstrap accepted provider DNS detour $provider"
  fi
  grep -Fq 'initial list download through a section requires a Connection/VPN rule' \
    "$WORK/dns-provider-$provider.log" ||
    fail "provider DNS detour $provider did not produce a clear reason"
done

# Existing config: bootstrap publication keeps its own file private, keeps
# dashboard metadata untouched, and retains an exact recoverable backup.
printf 'forkop.settings=settings\n' >"$WORK/uci.state"
printf 'forkop.settings.config_path=%s\n' "$WORK/live.json" >>"$WORK/uci.state"
printf '{"old":true}\n\n' >"$WORK/expected-live.json"
cp "$WORK/expected-live.json" "$WORK/live.json"
chmod 0640 "$WORK/live.json"
printf '{"temporary":true}\n\n' >"$WORK/expected-stage.json"
cp "$WORK/expected-stage.json" "$WORK/stage.json"
chmod 0600 "$WORK/stage.json"
mkdir -p "$WORK/stage.json.section-cache"
printf '{"temporary":true}\n' >"$WORK/stage.json.section-cache/selected.json"
printf '{"dashboard":true}\n' >"$WORK/run/section-cache/selected.json"

runtime() {
  PATH="$WORK/bin:$PATH" \
  FORKOP_LIB="$LIB" \
  FORKOP_UCI_STATE_FILE="$WORK/uci.state" \
  FORKOP_RUNTIME_STATE_DIR="$WORK/run" \
  FORKOP_SECTION_CACHE_DIR="$WORK/run/section-cache" \
  FORKOP_LIFECYCLE_LIST_BOOTSTRAP=1 \
    "$UCODE_BIN" -L "$LIB" "$RUNTIME" "$@"
}

runtime commit-config-stage "$WORK/stage.json" "$WORK/backup.json" ||
  fail "bootstrap config publication failed"
cmp -s "$WORK/live.json" "$WORK/expected-stage.json" || fail "temporary config was not published byte-for-byte"
[ "$(stat -c %a "$WORK/live.json")" = 600 ] || fail "temporary live config is not private"
cmp -s "$WORK/backup.json" "$WORK/expected-live.json" || fail "previous config content was not backed up byte-for-byte"
[ "$(stat -c %a "$WORK/backup.json")" = 640 ] || fail "previous config mode was not preserved"
[ ! -e "$WORK/stage.json" ] && [ ! -e "$WORK/stage.json.section-cache" ] ||
  fail "bootstrap stage was not cleaned"
grep -Fq '"dashboard":true' "$WORK/run/section-cache/selected.json" ||
  fail "temporary bootstrap replaced full dashboard metadata"

runtime restore-config-stage "$WORK/backup.json" || fail "previous config restore failed"
cmp -s "$WORK/live.json" "$WORK/expected-live.json" || fail "previous config content was not restored byte-for-byte"
[ "$(stat -c %a "$WORK/live.json")" = 640 ] || fail "previous config mode was not restored"
[ ! -e "$WORK/backup.json" ] || fail "restore left the backup stage behind"

# No previous file: the bootstrap commit is allowed and creates no fictional
# backup; lifecycle can remove this temporary file after the managed PID exits.
rm -f "$WORK/live.json"
printf '{"temporary-no-prior":true}\n' >"$WORK/stage.json"
chmod 0600 "$WORK/stage.json"
runtime commit-config-stage "$WORK/stage.json" "$WORK/backup.json" ||
  fail "bootstrap with no previous config was rejected"
[ -s "$WORK/live.json" ] || fail "no-prior bootstrap config was not published"
[ ! -e "$WORK/backup.json" ] || fail "no-prior bootstrap fabricated a backup"
[ "$(stat -c %a "$WORK/live.json")" = 600 ] || fail "no-prior bootstrap config is not private"

printf 'cold-start list bootstrap shape and restore checks passed\n'
